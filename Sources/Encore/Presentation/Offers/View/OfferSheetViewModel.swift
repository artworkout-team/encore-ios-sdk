//
//  OfferSheetViewModel.swift
//  Encore
//

import Foundation
import Combine
import UIKit
import SwiftUI

/// Inputs captured at email-submission time and held until IAP confirms
/// success. Stashing the fully-built payload (not loose context strings)
/// keeps `flushPendingLead` a pure enqueue + reset, and protects the
/// submission from any context mutations that happen during the Apple
/// subscription sheet.
///
/// `transactionId` is the eager client-issued UUID v4 — generated once per
/// sheet session at the first time it's needed (see
/// `OfferSheetViewModel.ensureTransactionId`). It threads through to
/// `/leads`, where the backend atomically creates the matching
/// `transactions` row. See `docs/architecture/variants/asyncAdvertiserVerticalList.md`.
private struct PendingLead {
    let userId: String
    let campaignId: String
    let email: String
    let trialDurationDays: Int?
    let transactionId: String
}

/// Intent-to-activate snapshot captured each time the user taps "Activate
/// Gifted Trial." Overwritten on every tap so the recorded claim always
/// reflects the user's *latest* sponsor choice — they can back out to
/// re-select a different brand between attempts. Flushed exactly once on
/// sheet dismiss, giving at-least-once delivery after any Activate tap
/// while de-duplicating repeat attempts against the same brand within a
/// single session. Distinct from IAP-conversion signal: a claim fires even
/// if the user cancels the Apple sheet, because the product question it
/// answers is "which sponsor did the user commit to trying under."
private struct PendingClaim {
    let offer: Offer
    let offerIndex: Int
}

@MainActor
@available(iOS 17.0, *)
class OfferSheetViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var currentOfferIndex: Int? = 0
    /// Drives the in-app Safari presented as a `.sheet` (0.95 detent + drag
    /// indicator) — the old/default (`.inAppSheet`) claim presentation. SwiftUI
    /// needs distinct modifiers for `.sheet` vs `.fullScreenCover`, so the two
    /// in-app modes use two separate wrappers; only one is ever non-nil.
    @Published var safariSheetWrapper: SafariURLWrapper?
    /// Drives the in-app Safari presented as a `.fullScreenCover` — the opt-in
    /// `.inAppBrowser` claim presentation.
    @Published var safariCoverWrapper: SafariURLWrapper?
    @Published var verificationState: VerificationState = .idle

    enum VerificationState {
        case idle
        case verifying
        case timedOut
    }
    
    // MARK: - Properties
    
    let offerResponse: OfferResponse
    let userId: String
    let presentationId: String
    let placementId: String
    /// Publisher-chosen label, or nil when the placement id was auto-generated.
    /// The ONLY placement value stamped on this presentation's analytics
    /// (2026-08-14 reversal: minted ids are local identity, never wire values;
    /// `presentation_id` is the correlation key). `placementId` stays for the
    /// host-facing `PurchaseRequest` and the outcomes stream.
    let placementLabel: String?
    let offerContext: OfferContext
    let completionHandler: SheetDismissHandler
    
    private var impressionIds: [String: String] = [:]
    private var pendingOffer: Offer?
    private var verificationPoller: VerificationPoller?
    private var pendingTransactionId: String?
    /// Analytics context of the claim under strict verification, captured at
    /// staging so the async poll success can emit `sdk_offer_verified` with it.
    private var verifyingClaimContext: OfferAnalyticsContext?
    /// Claim identity held across strict-unlock verification polling, which
    /// finishes the claim flow from an async task after the claim-time state
    /// has been cleared.
    private var pendingClaimIdentity: ClaimedOffer?
    private static let appStoreURLPattern = "apps.apple.com"
    private var cancellables = Set<AnyCancellable>()

    /// Weak: the view owns the SDUI context via `@StateObject`. Storing it
    /// here by weak reference lets action handlers reach into it without
    /// forming a cycle (the view retains viewModel → viewModel → context is
    /// already a non-owning edge).
    private weak var sduiContext: SDUIContext?

    /// Captured from the view's `@Environment(\.dismiss)` so action handlers
    /// can dismiss the sheet without routing through a view method.
    private var dismiss: DismissAction?

    /// Lead payload stashed on submit; fires to the outbox only after IAP
    /// succeeds via `flushPendingLead`.
    private var pendingLead: PendingLead?

    /// Eager UUID v4 for the async-advertiser conversion attribution path.
    /// Lazily generated on first need (typically when the user submits the
    /// lead capture form), reused across sponsor switches within the same
    /// session, and reset on sheet dismiss. The backend uses it as the id of
    /// the `transactions` row the `/leads` route atomically creates. See
    /// `docs/architecture/variants/asyncAdvertiserVerticalList.md`.
    private var currentTransactionId: String?

    /// Generate-or-reuse for `currentTransactionId`. Lowercased to match
    /// PostgreSQL's canonical UUID form (`gen_random_uuid()` returns
    /// lowercase) so naive string compares against backend-issued IDs work
    /// without normalization.
    private func ensureTransactionId() -> String {
        if let existing = currentTransactionId { return existing }
        let id = UUID().uuidString.lowercased()
        currentTransactionId = id
        return id
    }

    /// Latest sponsor the user tapped "Activate Gifted Trial" under. Flushed
    /// as `OfferClaimedEvent` in `trackOfferClose` so the event records the
    /// sponsor they committed to trying — regardless of IAP outcome.
    private var pendingClaim: PendingClaim?

    /// Identity of the offer the user claimed, captured when the claim flow
    /// finishes. Nil until then.
    ///
    /// Doubles as the "was anything claimed" flag (see `offerWasClaimed`) so the
    /// two can't drift — a claim recorded without its identity would leave the
    /// advertiser axis with nothing to report.
    private(set) var claimedOffer: ClaimedOffer?

    /// Whether an offer claim ran to completion (Safari dismiss or external
    /// return). The claim itself is reported by `sdk_offer_claimed` and the
    /// advertiser axis; this is the in-flow flag the claim tests observe.
    var offerWasClaimed: Bool { claimedOffer != nil }

    /// The `onSuccessState` carried by the in-flight `claimOffer` action, if
    /// any. Captured when the claim opens Safari and consumed on Safari return
    /// to transition to a post-claim state (e.g. a "Congratulations" screen)
    /// instead of dismissing the sheet. Nil for claims/variants that don't
    /// author a post-claim screen — those keep the existing grant-then-dismiss
    /// behavior untouched.
    private var pendingClaimSuccessState: String?

    /// True between opening the offer link in the EXTERNAL browser and the
    /// completion firing on app return. Gates the foreground handler so it
    /// only completes a claim that we actually launched externally.
    private var pendingExternalClaim: Bool = false

    /// Set once the app has genuinely backgrounded AFTER arming an external
    /// claim (i.e. the user actually left for the browser). The foreground
    /// handler requires this so a `didBecomeActive` that fires without a real
    /// trip to the browser (e.g. `open` failed, or a permission alert) can't
    /// falsely complete the claim.
    private var didBackgroundSinceExternalOpen: Bool = false

    #if DEBUG
    /// Test seam: overrides the system-browser open so the external-claim path
    /// is unit-testable without launching Safari. Returns whether the open
    /// "succeeded". Production leaves this nil and uses `UIApplication`.
    var _externalURLOpenerOverride: ((URL) -> Bool)?

    /// Test seam: forces the offer-link presentation, bypassing the loaded
    /// SDUI config. Lets tests exercise both `handleOfferTap` branches since
    /// the fallback config (coordinator-owned) can't be edited to flip it.
    var _offerLinkPresentationOverride: SDUIOfferLinkPresentation?
    #endif

    // MARK: - SDUI Variant Tracking
    
    /// The assigned SDUI variant ID
    private(set) var variantId: String?
    
    // MARK: - Time Tracking State
    
    private var sheetOpenedAt: Date?
    private var currentOfferStartTime: Date?
    /// A `.appBackgrounded` emission closed the segment; didForeground re-arms.
    private var segmentPausedByBackground = false
    private var offerViewTimes: [String: TimeInterval] = [:]  // campaignId -> total time spent
    private var offerViewCounts: [String: Int] = [:]  // campaignId -> number of times viewed
    
    // Convenience accessor for offers
    private var offers: [Offer] { offerResponse.offerList }
    
    // MARK: - Initialization
    
    init(
        offerResponse: OfferResponse,
        userId: String,
        presentationId: String,
        placementId: String,
        placementLabel: String?,
        offerContext: OfferContext,
        completionHandler: SheetDismissHandler
    ) {
        self.offerResponse = offerResponse
        self.userId = userId
        self.presentationId = presentationId
        self.placementId = placementId
        self.placementLabel = placementLabel
        self.offerContext = offerContext
        self.completionHandler = completionHandler
        
        subscribeToLifecycle()
    }

    /// Register the SDUIContext and dismiss action. Action-handling closures
    /// stored on the context capture `[weak self]` — no cycle to break on
    /// deinit, so no deinit cleanup needed.
    func bind(sduiContext: SDUIContext, dismiss: DismissAction) {
        self.sduiContext = sduiContext
        self.dismiss = dismiss
    }

    /// Set variant metadata on both self and context
    func setVariantMetadata(variantId: String?, context: SDUIContext) {
        self.variantId = variantId
        context.setVariantMetadata(variantId: variantId, presentationId: presentationId, placementId: placementLabel)
    }
    
    // MARK: - Lifecycle
    
    private func subscribeToLifecycle() {
        Encore.shared.lifecycle?.didBackground
            .sink { [weak self] in self?.trackOfferClose(reason: .appBackgrounded) }
            .store(in: &cancellables)

        // Record that the app really left the foreground while an external
        // claim is armed — the browser hand-off actually happened.
        Encore.shared.lifecycle?.didBackground
            .sink { [weak self] in
                guard let self, self.pendingExternalClaim else { return }
                self.didBackgroundSinceExternalOpen = true
            }
            .store(in: &cancellables)

        // On return from the external browser, run the SAME completion the
        // in-app Safari-dismiss path runs (grant + optional post-claim
        // transition).
        Encore.shared.lifecycle?.didForeground
            .sink { [weak self] in self?.handleExternalClaimForeground() }
            .store(in: &cancellables)

        Encore.shared.lifecycle?.didForeground
            .sink { [weak self] in self?.resumeTimeTrackingIfPaused() }
            .store(in: &cancellables)

        Encore.shared.lifecycle?.willTerminate
            .sink { [weak self] in self?.trackOfferClose(reason: .appTerminated) }
            .store(in: &cancellables)
    }

    /// Completes an external-browser claim when the app returns to foreground.
    /// Fires the shared grant/transition logic exactly once, and only if an
    /// external open was armed AND a real background occurred first.
    func handleExternalClaimForeground() {
        guard pendingExternalClaim, didBackgroundSinceExternalOpen else { return }
        // Disarm BEFORE completing so a second foreground can't re-complete.
        pendingExternalClaim = false
        didBackgroundSinceExternalOpen = false
        // The app-return foreground IS the completion signal for an external
        // claim, so bypass the in-app App Store "wait for app return"
        // short-circuit — for an external claim there is no second return
        // event, so an App Store destination would otherwise never grant.
        completeClaim(bypassAppStoreWait: true)
    }

    /// Config-driven presentation for the offer-claim link. Server-driven
    /// (fallback OR remote), so flipping the remote value changes behavior
    /// with no app update. Defaults to `.inAppSheet` (the old 0.95 in-app
    /// Safari sheet) when the field is absent, preserving control-variant UX.
    private var offerLinkPresentation: SDUIOfferLinkPresentation {
        #if DEBUG
        if let override = _offerLinkPresentationOverride { return override }
        #endif
        return sduiConfigManager?.layout(for: offerContext.useCase)?.offerLinkPresentation ?? .default
    }

    /// Open the offer URL in the user's actual browser. Returns whether the
    /// open was initiated. Overridable in DEBUG for tests.
    private func openOfferURLExternally(_ url: URL) -> Bool {
        #if DEBUG
        if let override = _externalURLOpenerOverride {
            return override(url)
        }
        #endif
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
    
    // MARK: - Offer Interaction
    
    /// Handle offer tap - starts transaction and opens Safari.
    /// Sync interface for view binding; internally manages async work.
    func handleOfferTap(_ offer: Offer) {
        // Funnel denominator: fires before any guard so a failing claim path
        // is tapped-but-no-claimed, never invisible.
        track(OfferClaimTappedEvent(context(for: offer), transactionId: ensureTransactionId()))
        guard let transactions = transactionsManager else {
            Logger.warn("❌ transactionsManager not available")
            track(OfferClaimFailedEvent(context(for: offer), reason: .managerUnavailable))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let transactionId = try await transactions.start(userId: userId, campaignId: offer.id, useCase: offerContext.useCase)
                pendingTransactionId = transactionId
                // Strict mode gates the grant on verification — persist the
                // claim so it survives swipe-away/process death and can be
                // reconciled (→ outcomes stream) on a later foreground/launch.
                if Encore.shared.configuration?.unlock == .strict {
                    strictUnlockReconciler?.notePending(transactionId: transactionId, placementId: placementLabel, useCase: offerContext.useCase)
                }
                trackOfferClaimed(offer, transactionId: transactionId)

                pendingOffer = offer
                // A transaction now exists, so the failure cases below are
                // "claimed but never reached the webview" — emit the failure
                // twin (with the transactionId so it still joins the backend
                // row) instead of silently falling through.
                guard let urlString = offer.displayDestinationUrl else {
                    Logger.warn("❌ Claim started but offer has no destination URL")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .missingDestinationUrl, transactionId: transactionId))
                    return
                }

                var urlComponents = URLComponents(string: urlString)
                let trackingParameters = offer.displayTrackingParameters

                if let trackingParameters = trackingParameters {
                    if urlComponents?.queryItems == nil {
                        urlComponents?.queryItems = []
                    }
                    for parameter in trackingParameters {
                        let queryParam = URLQueryItem(name: parameter.key, value: "\(parameter.value)")
                        urlComponents?.queryItems?.append(queryParam)
                    }
                }

                var finalUrl = urlComponents?.url?.absoluteString ?? urlString
                finalUrl = finalUrl.replacingOccurrences(of: "TRANSACTION_ID", with: transactionId)

                guard let url = URL(string: finalUrl) else {
                    Logger.warn("❌ Claim started but destination URL failed to parse: \(finalUrl)")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .invalidDestinationUrl, transactionId: transactionId))
                    return
                }

                switch offerLinkPresentation {
                case .external:
                    // Arm the completion BEFORE opening so the foreground
                    // handler (gated on a real background) can complete the
                    // claim on app return. No in-app sheet is presented.
                    pendingExternalClaim = true
                    didBackgroundSinceExternalOpen = false
                    let opened = openOfferURLExternally(url)
                    if !opened {
                        Logger.warn("❌ Claim started but system browser could not open URL: \(url)")
                        pendingExternalClaim = false
                        track(OfferClaimFailedEvent(context(for: offer), reason: .invalidDestinationUrl, transactionId: transactionId))
                    }
                case .inAppBrowser:
                    // Full-screen in-app Safari (opt-in). Clear the sheet
                    // wrapper first so only one presentation is ever active,
                    // even if a stale wrapper survived a re-entrant claim.
                    safariSheetWrapper = nil
                    safariCoverWrapper = SafariURLWrapper(url: url)
                case .inAppSheet:
                    // Old/default in-app Safari as a 0.95 sheet with a drag
                    // indicator — preserves control-variant claim UX. Clear the
                    // cover wrapper first to keep the wrappers mutually exclusive.
                    safariCoverWrapper = nil
                    safariSheetWrapper = SafariURLWrapper(url: url)
                }
            } catch let error as EncoreError {
                // 409 provisionalCooldown ends the flow; other claim errors keep
                // the sheet up (user can retry) and are recorded on the funnel.
                if case .protocol(.api(let status, let code, _)) = error,
                   status == 409, code == "provisionalCooldown" {
                    Logger.info(.offers, "Claim blocked by provisional cooldown")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: error.localizedDescription))
                    completionHandler.stageAdvertiser(.cooldown)
                    completionHandler.handleImmediate(dismissal: .cooldown)
                } else {
                    Logger.warn(.offers, "Failed to start transaction: \(error)")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: error.localizedDescription))
                    completionHandler.stageAdvertiser(.failed(error))
                }
            } catch {
                Logger.warn(.offers, "Failed to start transaction: \(error)")
                track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: error.localizedDescription))
                completionHandler.stageAdvertiser(.failed(.transport(.network(error))))
            }
        }
    }

    // MARK: - Safari Dismissal Handling
    
    func handleSafariDismiss() {
        completeClaim(bypassAppStoreWait: false)
    }

    /// Shared claim-completion for both the in-app Safari dismiss and the
    /// external-browser app-return. `bypassAppStoreWait` skips the App Store
    /// "wait for app return" short-circuit: that guard is correct for the
    /// in-app path (tapping an App Store link leaves Safari, and the claim is
    /// completed on the later app-return), but wrong for the external path,
    /// whose app-return foreground IS the completion event.
    private func completeClaim(bypassAppStoreWait: Bool) {
        guard let offer = pendingOffer else { return }

        // Clear whichever in-app Safari wrapper was presenting (only one is set).
        safariSheetWrapper = nil
        safariCoverWrapper = nil
        let destinationUrl = offer.displayDestinationUrl ?? ""

        if !bypassAppStoreWait, destinationUrl.contains(Self.appStoreURLPattern) {
            Logger.debug("🛍️ App Store URL detected - waiting for app return")
            pendingOffer = nil
            return
        }

        let unlockMode = Encore.shared.configuration?.unlock ?? .optimistic

        // Capture the claim's identity HERE, the last point where both the offer
        // and its transaction are still in scope. Strict unlock grants from an
        // async poller that runs long after `pendingOffer` and
        // `pendingTransactionId` have been cleared, so resolving this lazily at
        // grant time would yield nothing in that mode.
        let claim = ClaimedOffer(
            offerId: offer.id,
            campaignId: offer.id,
            advertiserName: offer.advertiserName,
            transactionId: pendingTransactionId ?? currentTransactionId
        )

        if unlockMode == .strict {
            handleStrictUnlock(for: offer, claim: claim)
        } else {
            handleOptimisticUnlock(for: offer, claim: claim)
        }

        pendingOffer = nil
    }

    // MARK: - Unlock Modes

    private func handleOptimisticUnlock(for offer: Offer, claim: ClaimedOffer) {
        Logger.debug("✅ [OPTIMISTIC] Safari dismiss → recording claim")
        completionHandler.stageAdvertiser(.claimed(claim))
        track(OfferClaimReturnedEvent(context(for: offer), transactionId: claim.transactionId))
        finishClaimFlow(claim: claim)
    }

    /// Shared post-claim tail: entitlement refresh, then post-claim screen or
    /// IAP delegation, then delivery. Callers stage the claim fact (or its
    /// verification upgrade) before calling.
    private func finishClaimFlow(claim: ClaimedOffer?) {
        // Post-claim-state flows already purchased via triggerIAP; capture and
        // clear unconditionally so a released sduiContext can't leak the state
        // into a later claim.
        let successState = pendingClaimSuccessState
        pendingClaimSuccessState = nil
        let isPostClaimStateFlow = (successState != nil)

        if let claim { claimedOffer = claim }
        Task { try? await entitlementsManager?.refreshEntitlements() }

        // Post-claim screen: keep the sheet up; delivery happens on its close.
        if let successState, let sduiContext {
            applyTransition(successState, on: sduiContext, logPrefix: "🎉 [Claim]")
            return
        }

        // Claim-only use cases never delegate a purchase. `.rewardUsers` is the
        // whole reason: the claim IS the reward, so firing the host's purchase
        // handler here would put a subscription prompt in front of a user who
        // just accepted a gift — including, absurdly, one who was being thanked
        // for a purchase they already made. This is the last point in the claim
        // path that could still violate the "no IAP anywhere" property.
        guard offerContext.useCase.allowsIAP else {
            completionHandler.handleImmediate(dismissal: .flowCompleted)
            return
        }

        // Claim-then-IAP (original "double-tap" flow only): run the delegated
        // purchase BEFORE delivery so the StoreKit sheet presents while the
        // Encore sheet is still up and the record carries the real outcome.
        let iapProductId = remoteConfigManager?.iapProductId(for: offerContext.useCase) ?? entitlementsManager?.userAttributes.iapProductId
        guard !isPostClaimStateFlow, let iapProductId else {
            completionHandler.handleImmediate(dismissal: .flowCompleted)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await IAPClient.delegatePurchase(productId: iapProductId, placementId: placementId, placementLabel: placementLabel, presentationId: presentationId, useCase: offerContext.useCase)
            completionHandler.stagePublisher(outcome)
            completionHandler.handleImmediate(dismissal: .flowCompleted)
        }
    }

    private func handleStrictUnlock(for offer: Offer, claim: ClaimedOffer) {
        guard let transactionId = pendingTransactionId else {
            Logger.warn("❌ [STRICT] No transaction ID for verification")
            completionHandler.handleImmediate(dismissal: .lastOfferDeclined)
            return
        }

        // The claim itself is done — record it now so timeout/cancel/swipe
        // paths still carry the fact; verification upgrades it to .verified.
        completionHandler.stageAdvertiser(.claimed(claim))
        track(OfferClaimReturnedEvent(context(for: offer), transactionId: transactionId))
        // Stash context for the async poll so sdk_offer_verified can carry it.
        verifyingClaimContext = context(for: offer)

        Logger.debug("🔒 [STRICT] Polling for verification...")
        pendingClaimIdentity = claim
        verificationState = .verifying
        startVerificationPolling(transactionId: transactionId)
    }

    private func startVerificationPolling(transactionId: String) {
        let poller = VerificationPoller(transactionId: transactionId)
        self.verificationPoller = poller

        // Every exit path is identity-guarded: only the CURRENT poller's task
        // may mutate state — a superseded (retried) task must not.
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await poller.poll()
                guard self.verificationPoller === poller else { return }
                switch result {
                case .verified:
                    Logger.debug("✅ [STRICT] Verified → granting")
                    if let ctx = verifyingClaimContext {
                        track(OfferVerifiedEvent(ctx, transactionId: transactionId))
                    } else {
                        // Defensive: the per-offer context was cleared under
                        // the poll. The sheet's own placement and use case are
                        // still real, so the row stays sliceable.
                        track(OfferVerifiedEvent(
                            transactionId: transactionId,
                            placementId: placementLabel,
                            useCase: offerContext.useCase
                        ))
                    }
                    verifyingClaimContext = nil
                    verificationState = .idle
                    verificationPoller = nil
                    pendingTransactionId = nil
                    strictUnlockReconciler?.clearPending()
                    completionHandler.upgradeClaimToVerified()
                    let claim = pendingClaimIdentity
                    pendingClaimIdentity = nil
                    finishClaimFlow(claim: claim)

                case .timedOut:
                    Logger.debug("⏱️ [STRICT] Timed out")
                    verificationPoller = nil
                    verificationState = .timedOut
                }
            } catch is CancellationError {
                guard self.verificationPoller === poller else { return }
                // The CURRENT poller was cancelled (e.g. backgrounding) —
                // surface the Retry/Cancel overlay instead of a wedged spinner.
                Logger.debug("🚫 [STRICT] Polling cancelled")
                verificationPoller = nil
                verificationState = .timedOut
            } catch {
                guard self.verificationPoller === poller else { return }
                Logger.warn("❌ [STRICT] Polling error: \(error)")
                verificationPoller = nil
                verificationState = .timedOut
            }
        }
    }

    func retryVerification() {
        guard let transactionId = pendingTransactionId else { return }
        verificationPoller?.cancel()
        verificationState = .verifying
        startVerificationPolling(transactionId: transactionId)
    }

    func cancelVerification() {
        verificationPoller?.cancel()
        verificationPoller = nil
        verificationState = .idle
        pendingTransactionId = nil
        verifyingClaimContext = nil
        // Explicit user cancel — don't resurrect the claim on next launch.
        strictUnlockReconciler?.clearPending()
        completionHandler.handleImmediate(dismissal: .userTappedClose)
    }

    // MARK: - SDUI Action Dispatch

    /// Route a renderer-emitted `SDUIAction` to the right handler. Called
    /// from `SDUIContext.onAction` via a `[weak self]` closure, so this
    /// method no-ops cleanly if the sheet has been dismissed.
    func handleSDUIAction(_ action: SDUIAction, offer: Offer?) {
        switch action.type {
        case .close:
            // Staged funnel facts (e.g. a claim) ride along automatically;
            // this only records how the sheet ended.
            completionHandler.stageDismissal(.userTappedClose)
            dismiss?()
        case .claimOffer:
            if let offer {
                // Capture the post-claim state (if authored) before the claim
                // opens Safari; consumed on Safari return in `finishClaimFlow`.
                pendingClaimSuccessState = action.onSuccessState
                handleOfferTap(offer)
            }
        case .openUrl:
            break
        case .setState, .setValue, .selectOffer:
            // Handled internally by the renderer; should never reach here.
            break
        case .triggerIAP:
            handleTriggerIAP(action: action)
        case .submitLead:
            handleSubmitLead(action: action)
        }
    }

    // MARK: - Trigger IAP

    private func handleTriggerIAP(action: SDUIAction) {
        let iapProductId = remoteConfigManager?.iapProductId ?? entitlementsManager?.userAttributes.iapProductId
        guard let iapProductId else {
            Logger.warn("🛒 [TriggerIAP] No iapProductId configured")
            return
        }
        guard let sduiContext else { return }

        Logger.info("🛒 [TriggerIAP] Triggering IAP for product: \(iapProductId)")
        sduiContext.values["iapAttempted"] = "true"

        let placementId = placementId
        let placementLabel = placementLabel
        let presentationId = presentationId
        let useCase = offerContext.useCase
        Task { [weak self] in
            let outcome = await IAPClient.delegatePurchase(productId: iapProductId, placementId: placementId, placementLabel: placementLabel, presentationId: presentationId, useCase: useCase)

            await MainActor.run { [weak self] in
                guard let self, let sduiContext = self.sduiContext else { return }

                // Clear pendingLead on either outcome — success already
                // submitted it via flushPendingLead; cancel must drop so a
                // later triggerIAP can't pick up stale capture.
                defer { self.pendingLead = nil }

                self.completionHandler.stagePublisher(outcome)
                if outcome == .purchased {
                    Logger.info("✅ [TriggerIAP] Purchase successful!")
                    self.flushPendingLead()
                    self.applyTransition(action.onSuccessState, on: sduiContext, logPrefix: "✅ [TriggerIAP]")
                } else {
                    Logger.info("🚫 [TriggerIAP] Purchase cancelled or failed")
                    self.applyTransition(action.onCancelAction, on: sduiContext, logPrefix: "🚫 [TriggerIAP]")
                }
            }
        }
    }

    /// Resolve an SDUI action target string to either a sheet-close or a
    /// state transition. Nil target = stay on the current screen.
    private func applyTransition(_ target: String?, on sduiContext: SDUIContext, logPrefix: String) {
        guard let target else {
            Logger.info("\(logPrefix) No transition target — staying on current screen")
            return
        }
        if target == "close" {
            Logger.info("\(logPrefix) Closing sheet")
            completionHandler.stageDismissal(.dismissed)
            dismiss?()
        } else {
            Logger.info("\(logPrefix) Transitioning to state: \(target)")
            sduiContext.setState(target)
        }
    }

    // MARK: - Lead Submission

    /// Enqueue the deferred lead submission set by `handleSubmitLead`.
    /// Invoked from `handleTriggerIAP` on purchase success so the lead — and
    /// the deal + reminder emails it triggers — only materializes for users
    /// who actually confirmed the trial through the Apple sheet.
    ///
    /// A legacy throws-handler that returns normally on a user cancel still
    /// produces a false positive (one confusing email, no data loss or
    /// duplicate charges). We accept that tail.
    private func flushPendingLead() {
        guard let lead = pendingLead else { return }
        Encore.shared.services?.outbox.enqueue(.submitLead(
            userId: lead.userId,
            campaignId: lead.campaignId,
            email: lead.email,
            trialDurationDays: lead.trialDurationDays,
            transactionId: lead.transactionId
        ))
        pendingLead = nil
        Logger.info("📧 [Lead] Submitted deferred lead after IAP success")
    }

    private func handleSubmitLead(action: SDUIAction) {
        guard let sduiContext else { return }

        let email = sduiContext.values["email"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard EmailValidation.isValid(email) else {
            sduiContext.values["emailError"] = "Please enter a valid email address"
            return
        }

        guard !EmailValidation.isPrivateRelay(email) else {
            sduiContext.values["emailError"] = "Please use your real email address, not a private relay"
            analyticsClient?.track(LeadPrivateRelayDetectedEvent(
                presentationId: presentationId,
                variantId: variantId,
                useCase: offerContext.useCase,
                placementId: placementLabel
            ))
            return
        }

        // Resolve campaign id from the selected offer (list layouts) or
        // current offer (carousel).
        let campaignId = sduiContext.values["selectedOfferId"] ?? sduiContext.currentOffer?.id ?? ""
        guard !campaignId.isEmpty else {
            Logger.warn("📧 [Lead] Cannot submit lead: no selected or current offer")
            return
        }

        sduiContext.values.removeValue(forKey: "emailError")

        // Overwrite the queued claim so it reflects the user's LATEST
        // sponsor choice — they can back-navigate, re-select, and tap
        // Activate again; only the final attempt's brand should count.
        if let index = offers.firstIndex(where: { $0.id == campaignId }) {
            pendingClaim = PendingClaim(offer: offers[index], offerIndex: index)
            // Lead-flow claim entry point; shares the eager transaction id the
            // lead and its deferred sdk_offer_claimed flush will carry.
            track(OfferClaimTappedEvent(context(for: offers[index], at: index), transactionId: ensureTransactionId()))
        }

        // The submitLead tap itself is tracked by `SDUIButtonTappedEvent`;
        // the persisted lead is authoritative on the backend, which emits
        // `lead_captured` after `/leads` succeeds.

        userManager?.setAttributes(UserAttributes(email: email))

        pendingLead = PendingLead(
            userId: userId,
            campaignId: campaignId,
            email: email,
            trialDurationDays: sduiContext.offerContext.iap.introOfferDays,
            transactionId: ensureTransactionId()
        )

        Logger.info("📧 [Lead] Captured email; submission deferred until IAP success")

        // Fire triggerIAP from the current state (keeps capture screen
        // visible underneath the Apple subscription sheet). If
        // onSuccessState is set, look up its stateActions onEnter and fire
        // WITHOUT transitioning state.
        if let successState = action.onSuccessState {
            if let iapAction = sduiContext.stateActions[successState]?.onEnter {
                handleSDUIAction(iapAction, offer: sduiContext.currentOffer)
            } else {
                sduiContext.setState(successState)
            }
        }
    }

    #if DEBUG
    // MARK: - Test Hooks

    /// Seed the exact state a `.claimOffer` dispatch + `handleOfferTap` produce
    /// right before Safari opens, so `handleSafariDismiss()` can be exercised in
    /// unit tests without the async transaction start / Safari round-trip (that
    /// leg is only fully verifiable in-app). Mirrors the `.claimOffer` capture
    /// of `onSuccessState` and the `pendingOffer` set inside `handleOfferTap`.
    /// `transactionId` seeds the id a real transaction start would have
    /// produced, so the `ClaimedOffer` payload's join key is exercisable here.
    func _testPrepareClaim(sduiContext: SDUIContext, offer: Offer, onSuccessState: String?, transactionId: String? = "test_txn") {
        self.sduiContext = sduiContext
        self.pendingOffer = offer
        self.pendingClaimSuccessState = onSuccessState
        // A real tap always has a started transaction; the default keeps the
        // strict paths reachable (no transaction-id bail-out). Pass nil to
        // exercise the bail-out itself.
        self.pendingTransactionId = transactionId
    }

    /// Seed the exact state produced right after the EXTERNAL-browser claim
    /// launches (pending flag armed, app already backgrounded to the browser),
    /// so `handleExternalClaimForeground()` can be exercised in unit tests
    /// without a real hand-off to Safari. Mirrors `handleOfferTap`'s external
    /// branch plus the subsequent real background.
    func _testArmExternalClaim(sduiContext: SDUIContext, offer: Offer, onSuccessState: String?) {
        self.sduiContext = sduiContext
        self.pendingOffer = offer
        self.pendingClaimSuccessState = onSuccessState
        self.pendingExternalClaim = true
        self.didBackgroundSinceExternalOpen = true
    }

    /// Whether an external claim is currently armed (test visibility).
    var _testPendingExternalClaim: Bool { pendingExternalClaim }

    /// Whether EITHER in-app Safari wrapper is currently requested (test
    /// visibility).
    var _testHasSafariWrapper: Bool { safariSheetWrapper != nil || safariCoverWrapper != nil }

    /// Whether the in-app Safari SHEET wrapper (old 0.95 default) is set.
    var _testHasSafariSheetWrapper: Bool { safariSheetWrapper != nil }

    /// Whether the in-app Safari full-screen COVER wrapper (`.inAppBrowser`) is set.
    var _testHasSafariCoverWrapper: Bool { safariCoverWrapper != nil }
    #endif
}

// MARK: - Analytics

@available(iOS 17.0, *)
extension OfferSheetViewModel {
    
    // MARK: - Context & Tracking Helpers
    
    /// Build analytics context for the given offer, including variant metadata
    private func context(for offer: Offer, at index: Int? = nil) -> OfferAnalyticsContext {
        OfferAnalyticsContext(
            offer: offer,
            impressionId: impressionIds[offer.id] ?? "",
            offerIndex: index ?? currentOfferIndex ?? 0,
            totalOffers: offers.count,
            presentationId: presentationId,
            variantId: variantId,
            useCase: offerContext.useCase,
            placementId: placementLabel
        )
    }

    /// Parsimonious tracking helper (uses AnalyticsClient's stored userId)
    private func track<E: AnalyticsEvent>(_ event: E) {
        analyticsClient?.track(event)
    }
    
    // MARK: - Time Tracking
    
    /// Called when the offer sheet appears - starts tracking sheet and first offer time
    func startTimeTracking() {
        let now = Date()
        sheetOpenedAt = now
        currentOfferStartTime = now
        
        // Track first offer view
        if let firstOffer = offers.first {
            offerViewCounts[firstOffer.id] = 1
        }
        
        Logger.debug("⏱️ [OfferSheet] Started time tracking at \(now)")
    }
    
    /// Called when the user swipes to a different offer - updates time for previous offer
    func trackOfferSwipe(from previousIndex: Int?, to newIndex: Int) {
        guard let startTime = currentOfferStartTime else { return }
        
        // Record time spent on previous offer
        if let prevIndex = previousIndex, prevIndex < offers.count {
            let previousOffer = offers[prevIndex]
            let timeSpent = Date().timeIntervalSince(startTime)
            let existingTime = offerViewTimes[previousOffer.id] ?? 0
            offerViewTimes[previousOffer.id] = existingTime + timeSpent
            
            Logger.debug("⏱️ [OfferSheet] Spent \(String(format: "%.1f", timeSpent))s on offer \(prevIndex) (\(previousOffer.advertiserName))")
        }
        
        // Increment view count for the new offer
        if newIndex < offers.count {
            let newOffer = offers[newIndex]
            let existingCount = offerViewCounts[newOffer.id] ?? 0
            offerViewCounts[newOffer.id] = existingCount + 1
        }
        
        // Start timing the new offer
        currentOfferStartTime = Date()
    }
    
    // MARK: - Impression Tracking
    
    func trackOfferImpression(at index: Int) {
        guard index < offers.count else { return }

        let offer = offers[index]
        let campaignId = offer.id

        // Dedupe by campaignId: SwiftUI re-mounts rows on scroll-recycle, so
        // `.onAppear`-driven callers can fire the same offer many times per
        // session. Revenue attribution reads these events as 1-per-user.
        if impressionIds[campaignId] != nil { return }

        impressionIds[campaignId] = UUID().uuidString

        let ctx = context(for: offer, at: index)
        // "scroll" reads honestly for both axes — vertical lists scroll
        // and horizontal carousels scroll-snap; "swipe" was carousel-era
        // wording that misreads when the variant is a vertical list.
        track(OfferPresentedEvent(ctx, trigger: index == 0 ? "initial_load" : "scroll"))
    }
    
    // MARK: - Offer Event Tracking
    
    func trackOfferClaimed(_ offer: Offer, transactionId: String) {
        let ctx = context(for: offer)
        track(OfferClaimedEvent(ctx, transactionId: transactionId))
    }
    
    // MARK: - Close/Dismiss Tracking

    func trackOfferClose(reason: DismissReason) {
        // Cancel only — the poll task's identity guard needs the field intact
        // to clear it and surface .timedOut (Retry/Cancel) on return.
        verificationPoller?.cancel()

        // At-least-once claim delivery: if the user tapped "Activate Gifted
        // Trial" at least once this session, fire OfferClaimedEvent for the
        // sponsor they chose on their LAST attempt (pendingClaim was
        // overwritten each time). Fires on any dismiss reason — success,
        // close, or swipe — because the product question "which sponsor did
        // the user try to activate under" is independent of whether the IAP
        // actually completed. The transactionId reuses the eager UUID
        // already stashed for the lead (and ultimately the backend
        // `transactions` row) so the BigQuery join
        // sdk_offer_claimed.transactionId ↔ sdk_offer_completed.transactionId
        // can attribute conversions back to the click. Falls back to a
        // synthetic UUID only if the claim somehow exists without one (no
        // current code path produces this — defensive).
        if let claim = pendingClaim {
            let ctx = context(for: claim.offer, at: claim.offerIndex)
            let txId = currentTransactionId ?? UUID().uuidString.lowercased()
            track(OfferClaimedEvent(ctx, transactionId: txId))
            pendingClaim = nil
        }

        guard let sheetOpened = sheetOpenedAt else { return }
        
        let now = Date()
        let totalSheetTime = now.timeIntervalSince(sheetOpened)
        
        // Capture final offer info
        var finalCampaignId: String?
        var finalCreativeId: String?
        var finalAdvertiserName: String?
        
        // Record time for the current offer being viewed
        if let startTime = currentOfferStartTime,
           let currentIndex = currentOfferIndex,
           currentIndex < offers.count {
            let currentOffer = offers[currentIndex]
            let timeSpent = now.timeIntervalSince(startTime)
            let existingTime = offerViewTimes[currentOffer.id] ?? 0
            offerViewTimes[currentOffer.id] = existingTime + timeSpent
            
            finalCampaignId = currentOffer.id
            finalCreativeId = currentOffer.primaryCreative?.id
            finalAdvertiserName = currentOffer.advertiserName
        }
        
        // Log summary analytics event
        track(OfferSheetDismissedEvent(
            presentationId: presentationId,
            totalTime: totalSheetTime,
            reason: reason,
            totalOffers: offers.count,
            offersViewed: offerViewTimes.count,
            finalIndex: currentOfferIndex ?? 0,
            finalCampaignId: finalCampaignId,
            finalCreativeId: finalCreativeId,
            finalAdvertiserName: finalAdvertiserName,
            variantId: variantId,
            useCase: offerContext.useCase,
            placementId: placementLabel
        ))
        
        // Log separate event for each offer's time tracking
        for (index, offer) in offers.enumerated() {
            if let timeSpent = offerViewTimes[offer.id] {
                track(OfferTimeSpentEvent(
                    offer: offer,
                    index: index,
                    timeSpent: timeSpent,
                    viewCount: offerViewCounts[offer.id] ?? 0,
                    totalOffers: offers.count,
                    sheetTime: totalSheetTime,
                    reason: reason,
                    presentationId: presentationId,
                    variantId: variantId,
                    useCase: offerContext.useCase,
                    placementId: placementLabel
                ))
            }
        }
        
        Logger.debug("⏱️ [OfferSheet] Dismissed after \(String(format: "%.1f", totalSheetTime))s - viewed \(offerViewTimes.count) offers")
        for (campaignId, time) in offerViewTimes {
            if let offer = offers.first(where: { $0.id == campaignId }) {
                let viewCount = offerViewCounts[campaignId] ?? 0
                Logger.debug("  └─ \(offer.advertiserName): \(String(format: "%.1f", time))s (\(viewCount) view\(viewCount == 1 ? "" : "s"))")
            }
        }

        // Close the tracking segment. Three callers reach this method
        // (onDisappear, didBackground, willTerminate) and nothing else guards
        // re-entry, so without this a backgrounding followed by the real
        // dismissal reported the same rows twice, the second time with times
        // inflated by the whole background excursion. The guard on
        // `sheetOpenedAt` above makes any later call a no-op; didForeground
        // re-arms a fresh segment when the sheet survived the background.
        sheetOpenedAt = nil
        currentOfferStartTime = nil
        offerViewTimes.removeAll()
        offerViewCounts.removeAll()
        segmentPausedByBackground = reason == .appBackgrounded
    }

    /// Reopens time tracking when the app returns with the sheet still up.
    /// The `.appBackgrounded` emission closed the previous segment; timing
    /// restarts at foreground so the Safari/background excursion is excluded
    /// from every duration instead of inflating them.
    private func resumeTimeTrackingIfPaused() {
        guard segmentPausedByBackground else { return }
        segmentPausedByBackground = false

        let now = Date()
        sheetOpenedAt = now
        currentOfferStartTime = now
        if let index = currentOfferIndex, index < offers.count {
            offerViewCounts[offers[index].id] = 1
        }
    }
    
    // MARK: - Safari Event Tracking
    
    func handleSafariTrackingEvent(_ event: SafariTrackingEvent) {
        guard let offer = pendingOffer else { return }
        
        let ctx = context(for: offer)
        
        switch event {
        case .attemptingToOpen(let url):
            track(OfferWebviewAttemptingOpenEvent(ctx, url: url))
            
        case .didOpen(let url, let openedAt):
            track(OfferWebviewOpenedEvent(ctx, url: url, openedAt: openedAt))
            
        case .initialLoadCompleted(let url, let didLoadSuccessfully):
            if didLoadSuccessfully {
                track(OfferWebviewLoadSuccessEvent(ctx, url: url))
            } else {
                track(OfferWebviewLoadFailedEvent(ctx, url: url))
            }
            
        case .initialRedirect(let from, let to):
            track(OfferWebviewInitialRedirectEvent(ctx, from: from, to: to))
            
        case .dismissed(let timeSpentSeconds):
            track(OfferWebviewDismissedEvent(ctx, timeSpent: timeSpentSeconds))
        }
    }
}
