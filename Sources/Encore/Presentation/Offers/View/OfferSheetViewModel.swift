//
//  OfferSheetViewModel.swift
//  Encore
//

import Foundation
import Combine
import UIKit
import SwiftUI
import SafariServices

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
    /// The sheet's served locale, so the lead email matches what the user read.
    let language: String?
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

/// The "Did you finish?" question a reward-for-trying variant is showing.
private struct CompletionPrompt {
    let claim: ClaimedOffer
    let analytics: OfferAnalyticsContext
    /// The SDUI state the question lives in; leaving it for another state is a "No".
    let state: String
    /// Present only when the prize promise was shown.
    let rewardId: String?
    /// Why this question can't earn the prize; nil when it can.
    let ineligibility: PublisherRewardIneligibility?
    let secondsAway: Int?

    var eligible: Bool { ineligibility == nil }
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
    /// The `.inAppPreload` claim: set on the tap, before any await; nil otherwise.
    @Published var claimPreload: ClaimPreloadController?
    /// The steps-screen preload: the selected offer's link loading off screen before the Continue tap.
    private var stepsPreload: StepsPreload?
    private var stepsPreloadObservation: AnyCancellable?
    /// This stay in the preload state has made its one attempt. Only re-entering the state
    /// resets it, so a discard or a new selection never books a second click in the stay.
    private var stepsPreloadAttempted = false
    /// The started preload page still owed its terminal `sdk_offer_preload` row, through the hand-over.
    private var preloadAccount: PreloadAccount?
    /// The app is in the background: nothing starts a preload until it returns.
    private var isAppBackgrounded = false
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
    
    /// One impression id per campaign, minted when the sheet is built so every claim has one. See docs/architecture/analytics-funnel.md#impression-id.
    private var impressionIds: [String: String] = [:]

    /// The display position each campaign was PRESENTED at, kept for the life
    /// of the sheet.
    ///
    /// `sdk_offer_presented` is first-write-wins, so an offer's position in a
    /// presentation is the first one it was seen at. A promote moves the live
    /// index afterwards, and every later event about that offer has to keep
    /// naming the position the impression was billed at, or the numerator and
    /// the denominator of a position rate describe different slots and the
    /// documented `(presentation_id, offer_index)` join stops matching.
    private var presentedIndex: [String: Int] = [:]
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

    /// Stable container-owned dismissal callback. Using SwiftUI's
    /// `@Environment(\.dismiss)` here makes the offer view observe a
    /// continuously-changing `DismissAction` on iOS 17, which can trap the
    /// presentation in a root-view invalidation loop.
    private var onDismiss: (() -> Void)?

    /// True from the share tap until the chooser closes. Without it a double
    /// tap presents twice and, with `onSuccessState: close`, dismisses twice.
    private var shareInFlight = false

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

    /// True while a claim's return is the app coming back to the foreground:
    /// the EXTERNAL browser, or an App Store link, which leaves the in-app browser
    /// and never reports a return there. Gates the foreground handler.
    private var pendingExternalClaim: Bool = false

    /// Set once the app has genuinely backgrounded AFTER arming an external
    /// claim (i.e. the user actually left for the browser). The foreground
    /// handler requires this so a `didBecomeActive` that fires without a real
    /// trip to the browser (e.g. `open` failed, or a permission alert) can't
    /// falsely complete the claim.
    private var didBackgroundSinceExternalOpen: Bool = false

    /// An App Store claim headed for the question, whose in-app browser is up but
    /// has not handed off yet. Opening the browser does not arm the foreground
    /// return; the hand-off does (see `noteAppDidBackground`).
    private var awaitingAppStoreHandoff = false
    /// The browser's initial load settled, or redirected onto the App Store. A
    /// background before that is a lock while the page loads, not a hand-off.
    private var appStorePageReached = false

    // MARK: - Reward for trying

    /// How long a promised Yes waits for the server's grant before failing closed.
    static let selfReportTimeout: TimeInterval = 5

    /// Campaigns this user said they finished; written on every Yes.
    var selfReportedCampaigns = Encore.shared.selfReportedCampaigns
    var selfReporter: SelfReportSending = SelfReporter.live
    /// The Encore user right now. The prize goes only to the user the sheet opened for.
    var currentUserId: () -> String? = { userManager?.currentUserId }
    /// Whether the app identified the user; anonymous users are promised nothing.
    var isIdentified: () -> Bool = { userManager?.isIdentified ?? false }
    /// States of the served variant that ask "Did you finish?" (see `SDUIConfig.questionStates`).
    private var questionStates: Set<String> = []
    /// The prize promise was written into the sheet for this presentation.
    private var promiseShown = false
    /// Why no promise was written, when the variant asks the question.
    private var promiseIneligibility: PublisherRewardIneligibility?
    /// A Yes waiting for (or sending) its self-report; further Yes taps are ignored.
    private var selfReportTask: Task<Void, Never>?
    private var claimTask: Task<Void, Never>?
    /// Offers dropped from this sheet because the user already finished them.
    @Published private(set) var hiddenCampaignIds: Set<String> = []
    /// When the offer link opened, and how long the user was away once back.
    private var claimOpenedAt: Date?
    private var claimSecondsAway: Int?
    private var completionPrompt: CompletionPrompt?
    private var completionPromptObservation: AnyCancellable?
    /// The question state whose wording is on `publisherRewardTitle`; nil while it holds the flat title.
    private var titledState: String?
    private var titledStateObservation: AnyCancellable?

    #if DEBUG
    /// Test seam: overrides the system-browser open so the external-claim path
    /// is unit-testable without launching Safari. Returns whether the open
    /// "succeeded". Production leaves this nil and uses `UIApplication`.
    var _externalURLOpenerOverride: ((URL) -> Bool)?

    /// Test seam: forces the offer-link presentation, bypassing the loaded
    /// SDUI config. Lets tests exercise both `handleOfferTap` branches since
    /// the fallback config (coordinator-owned) can't be edited to flip it.
    var _offerLinkPresentationOverride: SDUIOfferLinkPresentation?

    /// Test seam: builds the `.inAppPreload` web view, so tests can count constructions and loads.
    var _claimPreloadWebViewFactory: ClaimPreloadController.WebViewFactory?
    var _claimPreloadTiming: ClaimPreloadController.Timing?

    /// Test seam: replaces `transactions.start`, so a failing start is reachable.
    var _transactionStartOverride: ((Offer) async throws -> String)?
    /// Test seam: the transactions manager a claim goes through, so a test can read its body.
    var _transactionsOverride: TransactionsManager?
    /// Test seam: replaces the steps-screen preload's `transactions.start(intent: .preload)`.
    var _preloadTransactionStartOverride: ((Offer) async throws -> String)?
    /// Test seams: the steps-screen preload's clock and refresh timer, so tests never sleep.
    var _clockOverride: (() -> Date)?
    var _preloadRefreshSchedulerOverride: PreloadRefreshScheduler?
    #endif

    /// Runs `fire` on the main actor after `delay` seconds; cancelling the token stops it.
    typealias PreloadRefreshScheduler = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> AnyCancellable

    // MARK: - SDUI Variant Tracking
    
    /// The assigned SDUI variant ID
    private(set) var variantId: String?
    /// Experiment that decided `variantId`, echoed on presentation-level events.
    private(set) var experimentId: String?
    
    // MARK: - Time Tracking State
    
    private var sheetOpenedAt: Date?
    private var currentOfferStartTime: Date?
    /// A `.appBackgrounded` emission closed the segment; didForeground re-arms.
    private var segmentPausedByBackground = false
    private var offerViewTimes: [String: TimeInterval] = [:]  // campaignId -> total time spent
    private var offerViewCounts: [String: Int] = [:]  // campaignId -> number of times viewed
    
    // Convenience accessor for offers
    /// The DISPLAY-ordered list, which is what every index in this file means.
    ///
    /// `currentOfferIndex` is fed from `sduiContext.currentIndex` by the bridge
    /// in `OfferSheetView`, so indexing the backend list names a different
    /// campaign after `offerDisplayOrder` or a `promoteOffer`. Falls back while
    /// the renderer has not initialised, when backend order is all there is.
    private var offers: [Offer] {
        let displayed = sduiContext?.offers ?? []
        return displayed.isEmpty ? visibleOffers : displayed
    }

    /// The served list minus offers dropped in this sheet; what the fallback view shows.
    var visibleOffers: [Offer] {
        hiddenCampaignIds.isEmpty ? offerResponse.offerList : offerResponse.offerList.filter { !hiddenCampaignIds.contains($0.id) }
    }
    
    /// The layout this presentation rendered with, taken once when it mounted.
    private let layout: SDUIConfig?
    /// The variant whose remote template this sheet rendered, sent on every claim from it.
    /// Nil on a floor render, so the server never freezes a reward the sheet did not show.
    private let claimVariantId: String?

    // MARK: - Initialization
    
    init(
        offerResponse: OfferResponse,
        userId: String,
        presentationId: String,
        placementId: String,
        placementLabel: String?,
        offerContext: OfferContext,
        completionHandler: SheetDismissHandler,
        layout: SDUIConfig? = nil,
        claimVariantId: String? = nil
    ) {
        self.layout = layout
        self.claimVariantId = claimVariantId
        self.offerResponse = offerResponse
        self.userId = userId
        self.presentationId = presentationId
        self.placementId = placementId
        self.placementLabel = placementLabel
        self.offerContext = offerContext
        self.completionHandler = completionHandler
        self.impressionIds = Dictionary(offerResponse.offerList.map { ($0.id, UUID().uuidString) }, uniquingKeysWith: { first, _ in first })

        subscribeToLifecycle()
    }

    /// Register the SDUIContext and stable dismiss callback. Action-handling
    /// closures stored on the context capture `[weak self]` — no cycle to
    /// break on deinit, so no deinit cleanup needed.
    func bind(sduiContext: SDUIContext, onDismiss: @escaping () -> Void) {
        self.sduiContext = sduiContext
        self.onDismiss = onDismiss
        followClaimEnabled(on: sduiContext)
    }

    /// The host can turn claiming off or on while this sheet is open; the sheet follows it.
    private func followClaimEnabled(on context: SDUIContext) {
        claimEnabledObservation = Encore.shared.claimEnabledChanges
            .sink { [weak context] enabled in context?.isClaimEnabled = enabled }
    }

    /// Replaced on each bind, so a view that appears again does not stack subscriptions.
    private var claimEnabledObservation: AnyCancellable?

    /// Set variant metadata on both self and context
    func setVariantMetadata(variantId: String?, experimentId: String?, context: SDUIContext) {
        self.variantId = variantId
        self.experimentId = experimentId
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
            .sink { [weak self] in self?.noteAppDidBackground() }
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

        Encore.shared.lifecycle?.didBackground
            .sink { [weak self] in self?.noteStepsPreloadBackgrounded() }
            .store(in: &cancellables)

        Encore.shared.lifecycle?.didForeground
            .sink { [weak self] in self?.noteStepsPreloadForegrounded() }
            .store(in: &cancellables)

        Encore.shared.lifecycle?.willTerminate
            .sink { [weak self] in self?.trackOfferClose(reason: .appTerminated) }
            .store(in: &cancellables)
    }

    /// The app really left the foreground; a pending foreground-return claim may
    /// now complete on the next foreground.
    func noteAppDidBackground() {
        if awaitingAppStoreHandoff, appStorePageReached, isInAppBrowserUp {
            // The App Store took over from the in-app browser: this is the hand-off.
            awaitingAppStoreHandoff = false
            pendingExternalClaim = true
        }
        guard pendingExternalClaim else { return }
        didBackgroundSinceExternalOpen = true
    }

    /// Safari (sheet or cover), or the inAppPreload browser once it has loaded the link.
    private var isInAppBrowserUp: Bool {
        safariSheetWrapper != nil || safariCoverWrapper != nil || (claimPreload?.hasOpenedClaimLink ?? false)
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
    var offerLinkPresentation: SDUIOfferLinkPresentation {
        #if DEBUG
        if let override = _offerLinkPresentationOverride { return override }
        #endif
        return (layout ?? sduiConfigManager?.layout(for: offerContext.useCase))?.offerLinkPresentation ?? .default
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
        // A second tap before the cover takes over must not start a second claim,
        // and nor may a tap while a Yes waits for the server.
        if isPreloadClaimInFlight || selfReportTask != nil {
            Logger.debug("Claim already in progress; ignoring tap")
            return
        }
        presentIfUnseen(offer)
        // Funnel denominator: fires before any guard so a failing claim path
        // is tapped-but-no-claimed, never invisible.
        track(OfferClaimTappedEvent(context(for: offer), transactionId: ensureTransactionId()))
        // A new claim abandons any earlier one still waiting for a foreground,
        // so that return can never complete an offer whose link did not open.
        pendingExternalClaim = false
        didBackgroundSinceExternalOpen = false
        awaitingAppStoreHandoff = false
        appStorePageReached = false
        claimOpenedAt = nil
        let presentation = offerLinkPresentation.resolved
        // A claim in the preload state spends that stay's attempt: nothing preloads after it.
        if let state = stepsPreloadState, sduiContext?.currentState == state { stepsPreloadAttempted = true }
        // A steps-screen preload of THIS offer whose link is loading carries over to the claim;
        // any other preload is dropped here.
        let handedOver = presentation == .inAppPreload ? takeStepsPreload(for: offer) : nil
        if handedOver == nil { discardStepsPreload(.claimMismatch) }
        guard let startTransaction = transactionStarter() else {
            if let handedOver {
                settlePreloadAccount(for: handedOver.controller, reason: .claimFailed)
                handedOver.controller.discard()
            }
            Logger.warn("❌ transactionsManager not available")
            track(OfferClaimFailedEvent(context(for: offer), reason: .managerUnavailable))
            return
        }

        // On the tap, before any await: the claim screen covers the transaction round trip.
        let preload: ClaimPreloadController?
        if let handedOver {
            preload = presentPreloadedClaim(handedOver.controller)
        } else {
            preload = presentation == .inAppPreload ? presentClaimPreload(for: offer) : nil
        }
        let preloadedTransactionId = handedOver?.transactionId

        claimTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transactionId = try await startTransaction(offer)
                // Left through the claim screen's ×: already settled as a failure.
                if let preload, preload.isAbandoned {
                    Logger.info(.offers, "Claim abandoned before the transaction returned; not opening the link")
                    return
                }
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
                guard let finalUrl = offer.claimURLString(transactionId: transactionId) else {
                    endClaimPreload(preload)
                    Logger.warn("❌ Claim started but offer has no destination URL")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .missingDestinationUrl, transactionId: transactionId))
                    abandonUnopenedClaim()
                    return
                }

                guard let url = URL(string: finalUrl) else {
                    endClaimPreload(preload)
                    Logger.warn("❌ Claim started but destination URL failed to parse: \(finalUrl)")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .invalidDestinationUrl, transactionId: transactionId))
                    abandonUnopenedClaim()
                    return
                }

                // Each branch below logs the claim the moment its link opens, before the user leaves: an
                // app killed while they are at the advertiser keeps it, so the reminder shows on the next
                // launch. A link that never opens logs nothing. The sheet's close updates the row (by
                // transaction); it never adds a second.
                claimOpenedAt = Date()
                claimSecondsAway = nil
                // A previous claim's foreground arm must not complete this one.
                pendingExternalClaim = false
                didBackgroundSinceExternalOpen = false
                awaitingAppStoreHandoff = false
                appStorePageReached = false
                switch presentation {
                case .inAppPreload:
                    // The first and only request to the claim link, into THIS tap's screen.
                    if let preload, claimPreload === preload {
                        logClaim(offer, transactionId: transactionId)
                        armForegroundReturnIfAppStore(offer)
                        if preload.isUnconfirmedPreload, transactionId == preloadedTransactionId {
                            // The preload's link already carries this transaction: show that page.
                            // Adopted goes out after the claim's events, before the replayed web view ones.
                            settlePreloadAccount(for: preload, adopted: true)
                            preload.confirmHandover()
                        } else {
                            if preload.isUnconfirmedPreload {
                                Logger.info(.offers, "Claim's transaction differs from the preload's; opening the claim's link")
                                settlePreloadAccount(for: preload, reason: .claimMismatch)
                                preload.discardPreloadedPage()
                            }
                            preload.load(url)
                        }
                    } else {
                        // Closed or torn down mid-transaction: nothing to load into.
                        Logger.info(.offers, "Claim preload gone before the transaction returned")
                    }
                case .external:
                    // Arm the completion BEFORE opening so the foreground
                    // handler (gated on a real background) can complete the
                    // claim on app return. No in-app sheet is presented.
                    pendingExternalClaim = true
                    didBackgroundSinceExternalOpen = false
                    let opened = openOfferURLExternally(url)
                    if opened { logClaim(offer, transactionId: transactionId) }
                    if !opened {
                        pendingExternalClaim = false
                        // SFSafariViewController raises on any scheme but http(s), so only those can fall back.
                        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Logger.warn("⚠️ System browser unavailable; opening the claim in the in-app browser: \(url)")
                            track(OfferClaimFailedEvent(context(for: offer), reason: .externalBrowserUnavailable, transactionId: transactionId))
                            logClaim(offer, transactionId: transactionId)
                            presentInAppBrowser(url, for: offer)
                            // Still an external claim: its App Store return completes it, whatever the success state.
                            if (offer.displayDestinationUrl ?? "").contains(Self.appStoreURLPattern) {
                                awaitingAppStoreHandoff = true
                                appStorePageReached = false
                            }
                        } else {
                            Logger.warn("❌ Claim started but system browser could not open URL: \(url)")
                            track(OfferClaimFailedEvent(context(for: offer), reason: .invalidDestinationUrl, transactionId: transactionId))
                        }
                    }
                case .inAppBrowser:
                    logClaim(offer, transactionId: transactionId)
                    presentInAppBrowser(url, for: offer)
                case .inAppSheet, .unrecognized:
                    logClaim(offer, transactionId: transactionId)
                    armForegroundReturnIfAppStore(offer)
                    // Old/default in-app Safari as a 0.95 sheet with a drag
                    // indicator — preserves control-variant claim UX. Clear the
                    // cover wrapper first to keep the wrappers mutually exclusive.
                    safariCoverWrapper = nil
                    safariSheetWrapper = SafariURLWrapper(url: url)
                }
            } catch let error as EncoreError {
                if let preload, preload.isAbandoned { return }
                // The user already finished this offer: drop it and let them pick
                // another, never a retry into the same 409. Other claim errors keep
                // the sheet up (user can retry) and are recorded on the funnel.
                if case .protocol(.api(let status, let code, _)) = error,
                   status == 409, code == "offerAlreadyCompleted" {
                    // No web view was built; the claim screen just goes away.
                    endClaimPreload(preload)
                    Logger.info(.offers, "Claim refused: this user already completed the offer")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .alreadyCompleted))
                    pendingClaimSuccessState = nil
                    selfReportedCampaigns.add(campaignId: offer.id, userId: userId)
                    hideCampaign(offer.id)
                    if visibleOffers.isEmpty {
                        completionHandler.handleImmediate(dismissal: .flowCompleted)
                    }
                } else {
                    // No web view was built; the claim screen just goes away.
                    endClaimPreload(preload)
                    Logger.warn(.offers, "Failed to start transaction: \(error)")
                    track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: error.localizedDescription))
                    completionHandler.stageAdvertiser(.failed(error))
                }
            } catch {
                if let preload, preload.isAbandoned { return }
                endClaimPreload(preload)
                Logger.warn(.offers, "Failed to start transaction: \(error)")
                track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: error.localizedDescription))
                completionHandler.stageAdvertiser(.failed(.transport(.network(error))))
            }
        }
    }

    private func transactionStarter(intent: TransactionIntent = .claim) -> ((Offer) async throws -> String)? {
        #if DEBUG
        if intent == .preload, let override = _preloadTransactionStartOverride { return override }
        if intent == .claim, let override = _transactionStartOverride { return override }
        #endif
        #if DEBUG
        let manager = _transactionsOverride ?? transactionsManager
        #else
        let manager = transactionsManager
        #endif
        guard let transactions = manager else { return nil }
        let userId = userId
        let useCase = offerContext.useCase
        let variantId = claimVariantId
        return { offer in
            try await transactions.start(userId: userId, campaignId: offer.id, useCase: useCase, variantId: variantId, intent: intent)
        }
    }

    /// Full-screen in-app Safari. Clears the sheet wrapper so only one presentation is ever active.
    private func presentInAppBrowser(_ url: URL, for offer: Offer) {
        armForegroundReturnIfAppStore(offer)
        safariSheetWrapper = nil
        safariCoverWrapper = SafariURLWrapper(url: url)
    }

    /// A claim made in this sheet, logged as open with what the reminder shows.
    private func logClaim(_ offer: Offer, transactionId: String) {
        let claim = ClaimedOffer(offerId: offer.id, campaignId: offer.id, advertiserName: offer.advertiserName, transactionId: transactionId)
        ClaimLog.shared.record(claim, verified: false, logoUrl: offer.displayLogoUrl, perk: offer.perk,
                               useCase: offerContext.useCase, placement: placementLabel, userId: userId)
    }

    /// The transaction started but no link opened: nothing may complete this claim later.
    private func abandonUnopenedClaim() {
        pendingOffer = nil
        pendingTransactionId = nil
    }

    // MARK: - Claim Preload

    /// An inAppPreload claim screen or browser is up; another Claim is ignored. The cover on
    /// screen decides, not the config, which a refresh can change mid-claim.
    private var isPreloadClaimInFlight: Bool {
        claimPreload != nil
    }

    private func presentClaimPreload(for offer: Offer) -> ClaimPreloadController {
        show(makeClaimPreloadController(for: offer, preload: false))
    }

    /// The claim was tapped on a steps-screen preload: its claim screen goes up over the page.
    private func presentPreloadedClaim(_ controller: ClaimPreloadController) -> ClaimPreloadController {
        controller.showForClaim()
        return show(controller)
    }

    private func makeClaimPreloadController(for offer: Offer, preload: Bool) -> ClaimPreloadController {
        var makeWebView: ClaimPreloadController.WebViewFactory = ClaimPreloadController.makeDefaultWebView
        var timing = ClaimPreloadController.Timing.standard
        #if DEBUG
        if let factory = _claimPreloadWebViewFactory { makeWebView = factory }
        if let override = _claimPreloadTiming { timing = override }
        #endif
        let controller = ClaimPreloadController(content: .init(offer: offer), offerId: offer.id, timing: timing,
                                                makeWebView: makeWebView, preload: preload)
        controller.onPreloadAborted = { [weak self, weak controller] abort in
            guard let self, let controller else { return }
            self.handlePreloadAborted(controller, abort)
        }
        controller.onTrackingEvent = { [weak self] event in
            self?.handleSafariTrackingEvent(event)
        }
        controller.onPageGone = { [weak self, weak controller] in
            guard let self, let controller, self.claimPreload === controller else { return }
            self.handleClaimPreloadClosed()
        }
        controller.onSystemHandoff = { [weak self, weak controller] url, opened in
            guard let self, let controller, self.claimPreload === controller else { return }
            self.noteSystemHandoff(url, opened: opened)
        }
        return controller
    }

    private func show(_ controller: ClaimPreloadController) -> ClaimPreloadController {
        safariSheetWrapper = nil
        safariCoverWrapper = nil
        // Up at once, with no slide-in: the design has no entrance motion.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            claimPreload = controller
        }
        return controller
    }

    /// The preload's page handed a link to the system. In a WKWebView this is the only App
    /// Store hand-off: apps.apple.com loads as a web page and stays in the app.
    private func noteSystemHandoff(_ url: URL, opened: Bool) {
        guard Self.isAppStoreScheme(url) else {
            // The page sent the user somewhere else after all; a later App Store hand-off still counts.
            if opened { appStorePageReached = false }
            return
        }
        if opened {
            if awaitingAppStoreHandoff { appStorePageReached = true }
            return
        }
        // Nothing left the app. If a background already armed the return, revoke it.
        appStorePageReached = false
        if pendingExternalClaim {
            pendingExternalClaim = false
            didBackgroundSinceExternalOpen = false
            awaitingAppStoreHandoff = true
        }
    }

    /// The App Store app's own schemes; other `itms` schemes (enterprise installs, iTunes) are not it.
    private static func isAppStoreScheme(_ url: URL) -> Bool {
        ["itms-apps", "itms-appss"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Removes the claim screen without completing a claim (a failed start).
    private func endClaimPreload(_ controller: ClaimPreloadController?) {
        // A preloaded page under a claim that failed was never confirmed by it.
        if let controller { settlePreloadAccount(for: controller, reason: .claimFailed) }
        controller?.cancel()
        if let controller, claimPreload === controller { claimPreload = nil }
        retryStepsPreload()
    }

    /// The claim screen's × after the cap: abandon the claim and settle it as a
    /// non-409 failure. The sheet stays up; a late transaction opens nothing.
    func handleClaimPreloadEscaped() {
        guard let controller = claimPreload, !controller.hasOpenedClaimLink else { return }
        settlePreloadAccount(for: controller, reason: .claimFailed)
        controller.abandon()
        claimPreload = nil
        defer { retryStepsPreload() }
        let offer = offers.first { $0.id == controller.offerId }
        if let offer {
            track(OfferClaimFailedEvent(context(for: offer), reason: .transactionStartFailed, errorDescription: Self.claimAbandonedDescription))
        }
        completionHandler.stageAdvertiser(.failed(.transport(.network(URLError(.cancelled)))))
    }

    /// The cover went away without either ×. Settles it as that × would have; a no-op
    /// when a handler already did, or the claim was torn down (a failed start, a cooldown).
    func handleClaimPreloadDisappeared(_ controller: ClaimPreloadController) {
        guard claimPreload === controller, !controller.isCancelled else { return }
        if !controller.hasOpenedClaimLink {
            handleClaimPreloadEscaped()
        } else {
            handleClaimPreloadClosed()
        }
    }

    static let claimAbandonedDescription = "claim screen closed before the transaction returned"

    /// The in-app browser's ×: the same completion as closing Safari.
    func handleClaimPreloadClosed() {
        guard let controller = claimPreload else { return }
        controller.noteClosed()
        claimPreload = nil
        handleSafariDismiss()
        retryStepsPreload()
    }

    // MARK: - Steps-Screen Preload

    /// A link loading off screen for the offer the preload state shows, before the Continue tap.
    private struct StepsPreload {
        let offer: Offer
        let controller: ClaimPreloadController
        var offerId: String { offer.id }
        /// Set once the preload's transaction returned and its link started loading.
        var transactionId: String?
        var task: Task<Void, Never>?
        /// The last 200 with the preload's id: the next refresh counts from it.
        var lastReservedAt: Date?
        /// When that POST was sent: the server's 30 min window runs from here.
        var reservedSentAt: Date?
        var refreshTimer: AnyCancellable?
        var refreshTask: Task<Void, Never>?
    }

    /// The state whose entry preloads the selected offer's link. Only `inAppPreload` has one;
    /// with no state, nothing here runs and the claim is exactly today's.
    private var stepsPreloadState: String? {
        guard offerLinkPresentation.resolved == .inAppPreload,
              let state = layout?.preloadOfferLinkOnState?.value, !state.isEmpty else { return nil }
        return state
    }

    /// Follows the sheet's state and selection once its config is in. A no-op without a preload state.
    func startStepsPreload(on context: SDUIContext) {
        guard stepsPreloadObservation == nil, stepsPreloadState != nil else { return }
        // `@Published` publishes before the property changes, so the new values come from the stream.
        // Only the explicit selection (a tap, a swipe, initialSelection), never the card the claim
        // falls back to with nothing picked: a preload books a click.
        stepsPreloadObservation = context.$currentState
            .combineLatest(context.$values, context.$isClaimEnabled, context.$isAwaitingAnswer)
            .sink { [weak self, weak context] state, values, claimEnabled, awaitingAnswer in
                guard let self, let context else { return }
                self.reconcileStepsPreload(
                    state: state,
                    offer: context.selectedOffer(values: values),
                    claimEnabled: claimEnabled,
                    awaitingAnswer: awaitingAnswer
                )
            }
    }

    /// A transient gate (a claim, a Yes, the background) may have held this stay's attempt back.
    private func retryStepsPreload() {
        guard stepsPreloadObservation != nil, let context = sduiContext else { return }
        reconcileStepsPreload(state: context.currentState, offer: context.selectedOffer,
                              claimEnabled: context.isClaimEnabled, awaitingAnswer: context.isAwaitingAnswer)
    }

    /// The sheet is going away: stop following it and drop any preload. A later presentation of
    /// this view model is a new stay.
    func endStepsPreload() {
        stepsPreloadObservation = nil
        stepsPreloadAttempted = false
        discardStepsPreload(.sheetClosed)
        if let account = preloadAccount { trackPreload(account, .discarded, reason: .sheetClosed) }
        preloadAccount = nil
    }

    private func reconcileStepsPreload(state: String, offer: Offer?, claimEnabled: Bool, awaitingAnswer: Bool) {
        guard let preloadState = stepsPreloadState else { return }
        guard state == preloadState else {
            stepsPreloadAttempted = false
            discardStepsPreload(.stateLeft)
            return
        }
        if let live = stepsPreload, live.offerId != offer?.id || !claimEnabled {
            discardStepsPreload(claimEnabled ? .selectionChanged : .notClaimable)
        }
        guard stepsPreload == nil, !stepsPreloadAttempted, let offer, claimEnabled, !awaitingAnswer, isClaimOpen,
              !isAppBackgrounded else { return }
        // The stay's one attempt goes to the first offer seen with the claim open, preloadable or not.
        stepsPreloadAttempted = true
        guard !hiddenCampaignIds.contains(offer.id), Self.carriesTransactionId(offer) else {
            Logger.debug(.offers, "Not preloading \(offer.id): hidden, or its link carries no transaction id")
            return
        }
        beginStepsPreload(for: offer)
    }

    /// Gates that a later moment in the same stay may pass: no claim or Yes in flight.
    private var isClaimOpen: Bool {
        claimPreload == nil && selfReportTask == nil
    }

    /// The resolved claim link has a `TRANSACTION_ID` slot. Without one the preloaded click
    /// could not be tied to the claim, so the server would not attribute it.
    static func carriesTransactionId(_ offer: Offer) -> Bool {
        let probe = "encore-preload-probe"
        return offer.claimURLString(transactionId: probe)?.contains(probe) ?? false
    }

    private func beginStepsPreload(for offer: Offer) {
        guard let start = transactionStarter(intent: .preload) else { return }
        let controller = makeClaimPreloadController(for: offer, preload: true)
        Logger.debug(.offers, "Preloading the claim link for \(offer.id)")
        stepsPreload = StepsPreload(offer: offer, controller: controller)
        let sentAt = now()
        stepsPreload?.task = Task { [weak self] in
            do {
                let transactionId = try await start(offer)
                guard let self, self.stepsPreload?.controller === controller, !controller.isCancelled else { return }
                guard let link = offer.claimURLString(transactionId: transactionId), let url = URL(string: link) else {
                    Logger.debug(.offers, "Preload not started: the offer has no usable link")
                    self.discardStepsPreload(.notClaimable)
                    return
                }
                self.stepsPreload?.transactionId = transactionId
                self.stepsPreload?.lastReservedAt = self.now()
                self.stepsPreload?.reservedSentAt = sentAt
                controller.load(url)
                // The load is the advertiser's click: from here it is accounted until adopted or discarded.
                if controller.webView != nil {
                    let account = PreloadAccount(offer: offer, transactionId: transactionId, controller: ObjectIdentifier(controller))
                    self.preloadAccount = account
                    self.trackPreload(account, .started)
                }
                self.scheduleStepsPreloadRefresh()
            } catch {
                // Silent: the Continue tap then runs today's claim, including its own error handling.
                Logger.debug(.offers, "Preload not started: its transaction failed: \(error)")
                guard let self, self.stepsPreload?.controller === controller else { return }
                self.discardStepsPreload(.notClaimable)
            }
        }
    }

    /// Hands a loading preload of `offer` to the claim, or nil (and the preload, if any, is dropped).
    private func takeStepsPreload(for offer: Offer) -> (controller: ClaimPreloadController, transactionId: String)? {
        guard let preload = stepsPreload else { return nil }
        stepsPreload = nil
        preload.task?.cancel()
        stopRefreshing(preload)
        guard preload.offerId == offer.id, let transactionId = preload.transactionId,
              preload.controller.webView != nil, !preload.controller.isCancelled else {
            settlePreloadAccount(for: preload.controller, reason: .claimMismatch)
            preload.controller.discard()
            Logger.debug(.offers, "Preload not usable for this claim; opening the link on the Continue tap")
            return nil
        }
        return (preload.controller, transactionId)
    }

    private func discardStepsPreload(_ reason: OfferPreloadEvent.Reason) {
        guard let preload = stepsPreload else { return }
        stepsPreload = nil
        preload.task?.cancel()
        stopRefreshing(preload)
        settlePreloadAccount(for: preload.controller, reason: reason)
        preload.controller.discard()
        Logger.debug(.offers, "Preload discarded: \(reason.rawValue)")
    }

    private func handlePreloadAborted(_ controller: ClaimPreloadController, _ abort: ClaimPreloadController.PreloadAbort) {
        let reason: OfferPreloadEvent.Reason = abort == .pageGone ? .webContentCrashed : .appHandoffBlocked
        if stepsPreload?.controller === controller {
            discardStepsPreload(reason)
        } else if claimPreload === controller, controller.isUnconfirmedPreload {
            // The claim's own link opens instead once its transaction returns.
            settlePreloadAccount(for: controller, reason: reason)
            controller.discardPreloadedPage()
        }
    }

    func noteStepsPreloadBackgrounded() {
        isAppBackgrounded = true
    }

    /// Backgrounding alone never drops the preload: only a reservation that lapsed while away does.
    func noteStepsPreloadForegrounded() {
        isAppBackgrounded = false
        defer { retryStepsPreload() }
        guard let preload = stepsPreload else { return }
        if isReservationExpired(preload) {
            discardStepsPreload(.reservationExpired)
            return
        }
        // A reservation that answered while away may have found no window to park in.
        preload.controller.parkIfNeeded()
        // A refresh that fell due while away goes out now.
        resumeStepsPreloadRefresh()
    }

    private func isReservationExpired(_ preload: StepsPreload) -> Bool {
        guard let sentAt = preload.reservedSentAt else { return false }
        return now().timeIntervalSince(sentAt) >= ClaimPreloadTokens.preloadReservationWindowSeconds
    }

    // MARK: - Steps-Screen Preload Accounting

    private struct PreloadAccount {
        let offer: Offer
        let transactionId: String
        let controller: ObjectIdentifier
    }

    /// Sends the account's one terminal row, if `controller` still owes it.
    private func settlePreloadAccount(for controller: ClaimPreloadController, adopted: Bool = false,
                                      reason: OfferPreloadEvent.Reason? = nil) {
        guard let account = preloadAccount, account.controller == ObjectIdentifier(controller) else { return }
        preloadAccount = nil
        trackPreload(account, adopted ? .adopted : .discarded, reason: adopted ? nil : reason)
    }

    private func trackPreload(_ account: PreloadAccount, _ phase: OfferPreloadEvent.Phase, reason: OfferPreloadEvent.Reason? = nil) {
        track(OfferPreloadEvent(context(for: account.offer), transactionId: account.transactionId, phase: phase, reason: reason))
    }

    // MARK: - Steps-Screen Preload Refresh

    // The server adopts the preload's id on the claim only within 30 min of the LAST preload POST,
    // and treats a repeat POST of the same body as a refresh. A live preload re-sends it, so a
    // screen held past 30 min still hands its loaded page (and its recorded click) to the Continue tap.

    /// Arms the next refresh, counted from the last success.
    private func scheduleStepsPreloadRefresh() {
        guard let preload = stepsPreload, preload.refreshTask == nil,
              let reservedAt = preload.lastReservedAt else { return }
        let controller = preload.controller
        let delay = max(0, ClaimPreloadTokens.preloadRefreshIntervalSeconds - now().timeIntervalSince(reservedAt))
        stepsPreload?.refreshTimer = refreshScheduler(delay) { [weak self] in
            self?.refreshStepsPreloadIfDue(controller)
        }
    }

    /// Back in the foreground with the preload kept: refresh now if due, else re-arm for the rest.
    private func resumeStepsPreloadRefresh() {
        guard let controller = stepsPreload?.controller else { return }
        refreshStepsPreloadIfDue(controller)
        if stepsPreload?.refreshTask == nil { scheduleStepsPreloadRefresh() }
    }

    /// Re-sends the preload's exact body. Never in the background, never two at once. Same id: the
    /// clock restarts. Refused: discarded. No answer: kept, retried in a minute until the window ends.
    private func refreshStepsPreloadIfDue(_ controller: ClaimPreloadController) {
        guard let preload = stepsPreload, preload.controller === controller, !controller.isCancelled,
              preload.refreshTask == nil, !isAppBackgrounded,
              let transactionId = preload.transactionId, let reservedAt = preload.lastReservedAt else { return }
        if isReservationExpired(preload) {
            discardStepsPreload(.reservationExpired)
            return
        }
        guard now().timeIntervalSince(reservedAt) >= ClaimPreloadTokens.preloadRefreshIntervalSeconds,
              let start = transactionStarter(intent: .preload) else { return }
        let offer = preload.offer
        let sentAt = now()
        stepsPreload?.refreshTimer = nil
        stepsPreload?.refreshTask = Task { [weak self] in
            let outcome: PreloadRefreshOutcome
            do {
                outcome = try await start(offer) == transactionId ? .renewed : .refused
            } catch {
                Logger.debug(.offers, "Preload refresh failed: \(error)")
                outcome = Self.isRefusal(error) ? .refused : .unanswered
            }
            guard let self else { return }
            // After the Continue tap or a discard the answer is ignored.
            guard !Task.isCancelled, self.stepsPreload?.controller === controller, !controller.isCancelled else {
                if self.stepsPreload?.controller === controller { self.stepsPreload?.refreshTask = nil }
                return
            }
            self.stepsPreload?.refreshTask = nil
            switch outcome {
            case .renewed:
                self.stepsPreload?.lastReservedAt = self.now()
                self.stepsPreload?.reservedSentAt = sentAt
                if let account = self.preloadAccount, account.controller == ObjectIdentifier(controller) {
                    self.trackPreload(account, .refreshed)
                }
                self.scheduleStepsPreloadRefresh()
            case .refused:
                self.discardStepsPreload(.refreshRefused)
            case .unanswered:
                self.stepsPreload?.refreshTimer = self.refreshScheduler(ClaimPreloadTokens.preloadRefreshRetrySeconds) { [weak self] in
                    self?.refreshStepsPreloadIfDue(controller)
                }
            }
        }
    }

    private enum PreloadRefreshOutcome {
        case renewed
        /// An HTTP answer that is not 200, or 200 with another id.
        case refused
        /// No HTTP answer: a timeout, no network, a body that would not decode.
        case unanswered
    }

    private static func isRefusal(_ error: Error) -> Bool {
        guard case EncoreError.protocol(let failure) = error else { return false }
        switch failure {
        case .api, .http: return true
        case .decoding: return false
        }
    }

    private func stopRefreshing(_ preload: StepsPreload) {
        preload.refreshTimer?.cancel()
        preload.refreshTask?.cancel()
    }

    private var refreshScheduler: PreloadRefreshScheduler {
        #if DEBUG
        if let override = _preloadRefreshSchedulerOverride { return override }
        #endif
        return { delay, fire in
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                fire()
            }
            return AnyCancellable { task.cancel() }
        }
    }

    private func now() -> Date {
        #if DEBUG
        if let clock = _clockOverride { return clock() }
        #endif
        return Date()
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
        // Or the inAppPreload browser, still up when an App Store return completes the claim.
        if let preload = claimPreload, preload.hasOpenedClaimLink {
            preload.noteClosed()
            claimPreload = nil
        }
        let destinationUrl = offer.displayDestinationUrl ?? ""

        if !bypassAppStoreWait, destinationUrl.contains(Self.appStoreURLPattern) {
            Logger.debug("🛍️ App Store URL detected - waiting for app return")
            // The browser closed before any hand-off to the App Store: the claim
            // is abandoned, as in 2.2.0, so a later lock and unlock cannot complete it.
            if !pendingExternalClaim {
                pendingOffer = nil
                awaitingAppStoreHandoff = false
                appStorePageReached = false
            }
            return
        }
        pendingExternalClaim = false
        didBackgroundSinceExternalOpen = false
        claimSecondsAway = claimOpenedAt.map { max(0, Int(Date().timeIntervalSince($0).rounded(.down))) }
        claimOpenedAt = nil

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
        ClaimLog.shared.noteOffer(logoUrl: offer.displayLogoUrl, perk: offer.perk, campaignId: claim.campaignId)
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
            if questionStates.contains(successState), let prompted = claim ?? claimedOffer {
                beginCompletionPrompt(for: prompted, in: successState, on: sduiContext)
            }
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
        let iapProductId = offerContext.entitlements?.iapProductId ?? entitlementsManager?.userAttributes.iapProductId
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
        ClaimLog.shared.noteOffer(logoUrl: offer.displayLogoUrl, perk: offer.perk, campaignId: claim.campaignId)
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
    func handleSDUIAction(_ action: SDUIAction, offer: Offer?, trigger: SDUIActionTrigger = .tap) {
        // While a promised Yes waits, only close runs: a second claim would take the
        // staged slot and the late answer would land on the wrong claim.
        guard selfReportTask == nil || action.type == .close else {
            Logger.debug(.offers, "\(action.type) ignored: a Yes is waiting for the server")
            return
        }
        switch action.type {
        case .close:
            // Staged funnel facts (e.g. a claim) ride along automatically;
            // this only records how the sheet ended.
            completionHandler.stageDismissal(.userTappedClose)
            onDismiss?()
        case .claimOffer:
            // Ignored before it can touch the in-flight claim's success state or question.
            if isPreloadClaimInFlight {
                Logger.debug("Claim already in progress; ignoring tap")
                return
            }
            // Every claim is asked about afresh: eligibility is decided on return.
            sduiContext?.values.removeValue(forKey: PublisherRewardValueKey.eligible)
            restoreFlatTitle()
            endCompletionPrompt()
            if let offer {
                // Capture the post-claim state (if authored) before the claim
                // opens Safari; consumed on Safari return in `finishClaimFlow`.
                pendingClaimSuccessState = action.onSuccessState
                handleOfferTap(offer)
            }
        case .openUrl:
            openOfferLink(action: action, offer: offer)
        case .share:
            if let offer {
                handleShare(offer, onSuccessState: action.onSuccessState)
            }
        case .setState, .setValue, .selectOffer, .setOfferIndex:
            // Handled internally by the renderer; should never reach here.
            break
        case .triggerIAP:
            handleTriggerIAP(action: action)
        case .submitLead:
            handleSubmitLead(action: action)
        case .reportCompletion:
            guard trigger == .tap else {
                Logger.warn(.offers, "reportCompletion from onEnter ignored: only a tap answers the question")
                return
            }
            handleReportCompletion(action)
        case .trigger, .dismissTrigger:
            // Trigger-mount actions; inside a sheet they stay a no-op, as any unhandled action was.
            break
        case .unknown:
            break
        }
    }

    // MARK: - Reward for Trying

    /// The app's prize, when it passed a usable one.
    private var usablePrize: PublisherReward? {
        offerContext.publisherReward.flatMap { $0.isUsable ? $0 : nil }
    }

    private var publisherRewardPolicy: PublisherRewardPolicy {
        Encore.shared.publisherRewardPolicy
    }

    /// Writes the prize promise into the sheet when the served variant asks the
    /// question, a prize was passed, the user is identified and the server's search
    /// answer promised it. Call after the config has initialised the context.
    func preparePublisherReward(config: SDUIConfig?, context: SDUIContext) {
        questionStates = config?.questionStates ?? []
        promiseShown = false
        promiseIneligibility = nil
        // Only the SDK writes these; a variant's own initial values cannot fake them.
        for key in [PublisherRewardValueKey.title, PublisherRewardValueKey.detail,
                    PublisherRewardValueKey.iconUrl, PublisherRewardValueKey.eligible] {
            context.values.removeValue(forKey: key)
        }
        context.offerValues = [:]
        titledState = nil
        titledStateObservation = nil
        guard !questionStates.isEmpty else { return }
        guard let prize = usablePrize else { promiseIneligibility = .noPrize; return }
        guard isIdentified() else {
            promiseIneligibility = .anonymous
            Logger.info(.offers, "No prize promised: prizes need an identified user (call identify())")
            return
        }
        switch offerResponse.publisherRewardPromise {
        case nil:
            promiseIneligibility = .unverified
            Logger.info(.offers, "No prize promised: the server gave no promise answer")
            return
        case false?:
            promiseIneligibility = .dailyCap
            return
        case true?:
            break
        }
        // Outside the rows: the flat prize, but none in on_verified, where no offer pays it.
        context.values[PublisherRewardValueKey.title] = sheetTitle
        if let detail = prize.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            context.values[PublisherRewardValueKey.detail] = detail
        }
        if let iconUrl = prize.promisableIconUrl {
            context.values[PublisherRewardValueKey.iconUrl] = iconUrl
        }
        // Each card's own prize, else the flat title (none in on_verified), so a card never
        // shows the claimed offer's prize while the question has it. Set only here, with
        // the promise shown, so no card can promise without the sheet.
        context.offerValues = Dictionary(
            offerResponse.offers.map { ($0.id, [PublisherRewardValueKey.title: cardPrize(for: $0)]) },
            uniquingKeysWith: { first, _ in first }
        )
        promiseShown = true
    }

    /// The prize an offer's card and question name: its own value, else the flat title.
    /// Nil in on_verified for an offer without a value: a Yes never pays there and the
    /// webhook carries no reward for it, so the flat prize could never arrive.
    private func cardPrize(for offer: Offer?) -> String? {
        if let label = offer?.publisherRewardLabel { return label }
        return offerResponse.publisherRewardMode == .onVerified ? nil : flatTitle
    }

    private func claimedOffer(_ claim: ClaimedOffer) -> Offer? {
        offerResponse.offers.first { $0.id == claim.campaignId }
    }

    /// The promise's own wording, as `preparePublisherReward` wrote it.
    private var flatTitle: String {
        usablePrize?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// `publisherRewardTitle` outside the rows: absent in on_verified, where no offer
    /// pays the flat prize (a valued one pays its own, one without pays nothing).
    private var sheetTitle: String? {
        offerResponse.publisherRewardMode == .onVerified ? nil : flatTitle
    }

    /// Words the question's `publisherRewardTitle` for `claim` until the sheet leaves
    /// `state`. Only while the promise shows.
    private func titleQuestion(for claim: ClaimedOffer, in state: String, on context: SDUIContext) {
        guard promiseShown else { return }
        // Absent when this offer carries no prize, so a `hasValue` gate hides the line.
        context.values[PublisherRewardValueKey.title] = cardPrize(for: claimedOffer(claim))
        titledState = state
        // Not ended by a Yes: the answered question stays on screen until the sheet moves on.
        titledStateObservation = context.$currentState
            .dropFirst()
            .sink { [weak self] newState in
                guard let self, newState != self.titledState else { return }
                self.restoreFlatTitle()
            }
    }

    private func restoreFlatTitle() {
        guard titledState != nil else { return }
        titledState = nil
        titledStateObservation = nil
        sduiContext?.values[PublisherRewardValueKey.title] = sheetTitle
    }

    /// Why this question cannot earn the prize, or nil when it can. Only the
    /// server's answer to the Yes decides whether it does.
    private func completionIneligibility(for claim: ClaimedOffer) -> PublisherRewardIneligibility? {
        guard usablePrize != nil else { return .noPrize }
        guard promiseShown else { return promiseIneligibility ?? .unverified }
        // This offer carries no prize (on_verified with no value): nothing to promise.
        guard cardPrize(for: claimedOffer(claim)) != nil else { return .noPrize }
        return nil
    }

    /// Opens the question for `claim`. Eligibility is written as a present key or
    /// left absent (never "false"), because the variant tests it with `hasValue`.
    private func beginCompletionPrompt(for claim: ClaimedOffer, in state: String, on context: SDUIContext) {
        // The question is no longer this sheet's user's once identify()/reset() moved
        // off them: the state still shows, but nothing is prompted, eligible or sent.
        guard isSheetUser else {
            context.values.removeValue(forKey: PublisherRewardValueKey.eligible)
            return
        }
        let ineligibility = completionIneligibility(for: claim)
        if ineligibility == nil {
            context.values[PublisherRewardValueKey.eligible] = "true"
        } else {
            context.values.removeValue(forKey: PublisherRewardValueKey.eligible)
        }
        titleQuestion(for: claim, in: state, on: context)
        let prompt = CompletionPrompt(
            claim: claim,
            analytics: self.context(forCampaignId: claim.campaignId, advertiserName: claim.advertiserName),
            state: state,
            // No prize id for a question that cannot earn one (on_verified, no value).
            rewardId: ineligibility == nil ? usablePrize?.id : nil,
            ineligibility: ineligibility,
            secondsAway: claimSecondsAway
        )
        completionPrompt = prompt
        track(OfferCompletionPromptedEvent(
            prompt.analytics,
            transactionId: claim.transactionId,
            publisherRewardId: prompt.rewardId,
            ineligibility: ineligibility
        ))
        // Leaving the question for any other state ("No, back to offers") is a No.
        completionPromptObservation = context.$currentState
            .dropFirst()
            .sink { [weak self] newState in self?.completionPromptStateWillChange(to: newState) }
    }

    private func completionPromptStateWillChange(to newState: String) {
        guard let prompt = completionPrompt, newState != prompt.state else { return }
        endCompletionPrompt()
        sduiContext?.values.removeValue(forKey: PublisherRewardValueKey.eligible)
        if isSheetUser { trackCompletionAnswer(.no, for: prompt, userConfirmedCompletion: false, ineligibility: prompt.ineligibility) }
    }

    /// Whether the Encore user is still the one this sheet opened for.
    private var isSheetUser: Bool { currentUserId() == userId }

    private func endCompletionPrompt() {
        completionPrompt = nil
        completionPromptObservation = nil
    }

    /// "Yes, I finished". Every Yes is recorded here and reported to the server,
    /// which hides the offer for this user and alone decides the prize. A promised
    /// Yes waits up to `selfReportTimeout` for `granted`; only that sets
    /// `userConfirmedCompletion`. No answer means no flag.
    private func handleReportCompletion(_ action: SDUIAction) {
        guard let prompt = completionPrompt else {
            finishYes(action: action, confirmed: false, campaignId: nil)
            return
        }
        endCompletionPrompt()
        let promised = prompt.eligible && sduiContext?.hasValue(key: PublisherRewardValueKey.eligible) == true
        sduiContext?.values.removeValue(forKey: PublisherRewardValueKey.eligible)
        // identify() to someone else or reset() since the sheet opened: the app
        // would pay whoever is current now, not the user who tried the offer.
        guard isSheetUser else {
            Logger.info(.offers, "User changed while the sheet was open; the Yes confirms nothing")
            finishYes(action: action, confirmed: false, campaignId: nil)
            return
        }
        let campaignId = prompt.claim.campaignId
        selfReportedCampaigns.add(campaignId: campaignId, userId: userId)
        guard let transactionId = prompt.claim.transactionId else {
            Logger.warn(.offers, "Yes on a claim with no transaction; nothing to report")
            trackCompletionAnswer(.yes, for: prompt, userConfirmedCompletion: false,
                                  ineligibility: prompt.ineligibility ?? .unverified)
            finishYes(action: action, confirmed: false, campaignId: campaignId)
            return
        }
        let report = SelfReport(
            transactionId: transactionId,
            userId: userId,
            reportId: UUID().uuidString.lowercased(),
            publisherRewardId: promised ? prompt.rewardId : nil,
            dailyLimit: promised ? publisherRewardPolicy.dailyLimit : nil
        )
        // Queued now, in this turn, so it goes out before any identify() that follows.
        let reporter = selfReporter
        reporter.record(report)
        guard promised else {
            // Nothing to grant: move on without waiting.
            trackCompletionAnswer(.yes, for: prompt, userConfirmedCompletion: false, ineligibility: prompt.ineligibility)
            finishYes(action: action, confirmed: false, campaignId: campaignId)
            return
        }
        let context = sduiContext
        context?.isAwaitingAnswer = true
        // Holds self (at most `selfReportTimeout`) so the answer is still tracked
        // when the sheet is dismissed during the wait.
        selfReportTask = Task { [self] in
            let answer = await reporter.answer(for: report, waitingUpTo: Self.selfReportTimeout)
            selfReportTask = nil
            context?.isAwaitingAnswer = false
            // identify() or reset() during the wait: the grant is the old user's.
            guard isSheetUser else {
                Logger.info(.offers, "User changed while the Yes waited; it confirms nothing")
                finishYes(action: action, confirmed: false, campaignId: campaignId)
                return
            }
            var confirmed = false
            var reason: PublisherRewardIneligibility?
            switch answer {
            case .granted where offerResponse.publisherRewardMode == .onVerified:
                // Paid when the brand confirms: a grant here is an inconsistent answer.
                reason = .paysOnVerification
            case .granted:
                // False once the sheet is closing: a close during the wait fails closed.
                confirmed = completionHandler.markUserConfirmedCompletion(for: prompt.claim)
            case .notGranted(let serverReason):
                reason = serverReason
            case .noAnswer:
                reason = .unverified
            }
            trackCompletionAnswer(.yes, for: prompt, userConfirmedCompletion: confirmed, ineligibility: reason)
            finishYes(action: action, confirmed: confirmed, campaignId: campaignId)
        }
    }

    /// Leaves the question. A confirmed Yes always ends the sheet, so no second
    /// claim can follow it; otherwise the variant's own transition, with the
    /// finished offer dropped from the list and the sheet closed if none remain.
    private func finishYes(action: SDUIAction, confirmed: Bool, campaignId: String?) {
        // Closed or closing since the Yes started waiting: there is no sheet left to move.
        guard let sduiContext, !completionHandler.isEnding else { return }
        var target = confirmed ? "close" : (action.onSuccessState ?? "close")
        if target != "close", let campaignId {
            hideCampaign(campaignId)
            if visibleOffers.isEmpty { target = "close" }
        }
        applyTransition(target, on: sduiContext, logPrefix: "✅ [SelfReport]")
    }

    private func hideCampaign(_ campaignId: String) {
        // The fallback carousel reads `currentOfferIndex` (its sheet binds a context too);
        // keep it on the same card. An SDUI sheet's context adjusts its own index.
        if let removed = visibleOffers.firstIndex(where: { $0.id == campaignId }), let current = currentOfferIndex {
            let remaining = visibleOffers.count - 1
            currentOfferIndex = remaining == 0 ? nil : min(current > removed ? current - 1 : current, remaining - 1)
        }
        hiddenCampaignIds.insert(campaignId)
        sduiContext?.removeOffer(id: campaignId)
    }

    private func trackCompletionAnswer(_ answer: OfferCompletionAnsweredEvent.Answer, for prompt: CompletionPrompt,
                                       userConfirmedCompletion: Bool, ineligibility: PublisherRewardIneligibility?) {
        track(OfferCompletionAnsweredEvent(
            prompt.analytics,
            answer: answer,
            transactionId: prompt.claim.transactionId,
            publisherRewardId: prompt.rewardId,
            rewardEligible: prompt.eligible,
            ineligibility: ineligibility,
            userConfirmedCompletion: userConfirmedCompletion,
            secondsAway: prompt.secondsAway
        ))
    }

    /// App Store links leave the in-app browser for the App Store app and never
    /// report a return there, so the next foreground after a real background is
    /// it. Only for a claim headed for the question: nothing else waits on it.
    private func armForegroundReturnIfAppStore(_ offer: Offer) {
        guard (offer.displayDestinationUrl ?? "").contains(Self.appStoreURLPattern),
              let successState = pendingClaimSuccessState,
              questionStates.contains(successState) else { return }
        awaitingAppStoreHandoff = true
        appStorePageReached = false
    }

    private static func isAppStoreURL(_ url: URL) -> Bool {
        url.scheme?.lowercased().hasPrefix("itms") == true || url.host?.lowercased() == appStoreURLPattern
    }

    // MARK: - Share

    /// Presents the system share sheet for `offer`. The link is minted by the
    /// backend rather than composed here, because the claim URL is bound to the
    /// sharer's own transaction and cannot be reused.
    private func handleShare(_ offer: Offer, onSuccessState: String?) {
        guard !shareInFlight else { return }
        shareInFlight = true

        let ctx = context(for: offer)
        track(OfferShareTappedEvent(ctx))

        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.shareURL(for: offer) else {
                // Every tap gets a terminal event, the same rule the claim path
                // follows, or the funnel cannot tell "no link" from "cancelled".
                self.shareInFlight = false
                self.track(OfferShareFailedEvent(ctx, reason: .missingShareLink))
                Logger.warn("🔗 [Share] No shareable link available for \(offer.id)")
                return
            }
            self.presentShareSheet(url: url, ctx: ctx, onSuccessState: onSuccessState)
        }
    }

    /// The link the backend minted for this offer, or nil when it minted none.
    ///
    /// Server-supplied rather than composed here, so the attribution it carries
    /// is the backend's to decide and change without an SDK release. No
    /// fallback to `displayDestinationUrl`: an unattributed link loses the
    /// claim, silently.
    private func shareURL(for offer: Offer) async -> URL? {
        offer.shareUrl.flatMap(URL.init(string:))
    }

    /// Takes the context captured at TAP time rather than rebuilding it. The
    /// presentation happens after a suspension, and `context(for:)` falls back
    /// to the live `currentOfferIndex`, so a scroll in between would attribute
    /// a tap and its terminal event to different positions.
    private func presentShareSheet(url: URL, ctx: OfferAnalyticsContext, onSuccessState: String?) {
        // Encore's OWN overlay window, with no fallback. `topViewController()`
        // starts at the scene's first window, which is the host app's, and that
        // sits below our window level, so the chooser would render underneath
        // the sheet — present nothing rather than present it invisibly.
        guard let root = PresentationWindow.window?.rootViewController else {
            shareInFlight = false
            track(OfferShareFailedEvent(ctx, reason: .noPresenter))
            Logger.warn("🔗 [Share] No presenter available")
            return
        }
        let presenter = PresentationWindow.topViewController(from: root)

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        // iPad presents this as a popover and traps without an anchor.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        controller.completionWithItemsHandler = { [weak self] activityType, completed, _, _ in
            guard let self else { return }
            self.shareInFlight = false
            self.track(OfferShareCompletedEvent(
                ctx,
                destination: activityType?.rawValue,
                completed: completed
            ))
            guard completed, let sduiContext = self.sduiContext else { return }
            self.applyTransition(onSuccessState, on: sduiContext, logPrefix: "🔗 [Share]")
        }

        presenter.present(controller, animated: true)
    }

    // MARK: - Open URL

    /// Opens one of the acting offer's own links in an in-app browser.
    ///
    /// Not the claim path's Safari sheet: that one grants and transitions on
    /// dismiss, so a terms tap routed through it would credit a claim the user
    /// never made. This presents on Encore's own window, like the share chooser,
    /// and the sheet is still there when the browser closes.
    private func openOfferLink(action: SDUIAction, offer: Offer?) {
        guard let attribute = action.urlAttribute else {
            Logger.warn("🔗 [OpenUrl] No urlAttribute on the action")
            return
        }
        // The scheme rule lives at the Campaign boundary, so the gate a variant
        // wrote and this tap read one field rather than two.
        let target = offer ?? sduiContext?.currentOffer
        guard let raw = Self.offerLink(attribute, on: target), let url = URL(string: raw) else {
            Logger.warn("🔗 [OpenUrl] No link for \(attribute.rawValue)")
            return
        }
        guard let root = PresentationWindow.window?.rootViewController else {
            Logger.warn("🔗 [OpenUrl] No presenter available")
            return
        }
        let presenter = PresentationWindow.topViewController(from: root)
        let browser = SFSafariViewController(url: url)
        browser.modalPresentationStyle = .pageSheet
        presenter.present(browser, animated: true)
    }

    /// The offer's own value for one link attribute, nil when it carries none.
    ///
    /// Static and internal so a test can drive it: the presentation half needs a
    /// device, and the half that picks the URL is where a wrong answer sends a
    /// user to the wrong page.
    static func offerLink(_ attribute: SDUIOfferAttribute, on offer: Offer?) -> String? {
        guard let target = offer else { return nil }
        switch attribute {
        case .termsUrl: return target.termsUrl
        case .shareUrl: return target.shareUrl
        case .badgeLabel, .perk, .advertiserName, .description, .category, .quickInstructions, .instructions:
            return nil
        }
    }

    // MARK: - Trigger IAP

    private func handleTriggerIAP(action: SDUIAction) {
        let iapProductId = offerContext.entitlements?.iapProductId ?? entitlementsManager?.userAttributes.iapProductId
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
            onDismiss?()
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
            transactionId: lead.transactionId,
            language: lead.language
        ))
        pendingLead = nil
        Logger.info("📧 [Lead] Submitted deferred lead after IAP success")
    }

    private func handleSubmitLead(action: SDUIAction) {
        guard let sduiContext else { return }

        let email = sduiContext.values["email"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard EmailValidation.isValid(email) else {
            sduiContext.values["emailError"] = offerContext.strings[.emailInvalid]
            return
        }

        guard !EmailValidation.isPrivateRelay(email) else {
            sduiContext.values["emailError"] = offerContext.strings[.emailPrivateRelay]
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
            presentIfUnseen(offers[index], at: index)
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
            transactionId: ensureTransactionId(),
            language: sduiContext.offerContext.servedLocale
        )

        Logger.info("📧 [Lead] Captured email; submission deferred until IAP success")

        // Fire triggerIAP from the current state (keeps capture screen
        // visible underneath the Apple subscription sheet). If
        // onSuccessState is set, look up its stateActions onEnter and fire
        // WITHOUT transitioning state.
        if let successState = action.onSuccessState {
            if let iapAction = sduiContext.stateActions[successState]?.onEnter {
                handleSDUIAction(iapAction, offer: sduiContext.currentOffer, trigger: .onEnter)
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
    var _testSelfReportTask: Task<Void, Never>? { selfReportTask }
    var _testClaimTask: Task<Void, Never>? { claimTask }

    func _testPrepareClaim(sduiContext: SDUIContext, offer: Offer, onSuccessState: String?, transactionId: String? = "test_txn") {
        self.sduiContext = sduiContext
        self.pendingOffer = offer
        self.pendingClaimSuccessState = onSuccessState
        // A real tap always has a started transaction; the default keeps the
        // strict paths reachable (no transaction-id bail-out). Pass nil to
        // exercise the bail-out itself.
        self.pendingTransactionId = transactionId
        self.claimOpenedAt = Date()
        self.pendingExternalClaim = false
        self.didBackgroundSinceExternalOpen = false
        self.awaitingAppStoreHandoff = false
        self.appStorePageReached = false
        // The in-app browser is up, as after a real tap.
        if let url = offer.displayDestinationUrl.flatMap(URL.init(string:)) {
            self.safariSheetWrapper = SafariURLWrapper(url: url)
        }
        armForegroundReturnIfAppStore(offer)
    }

    func _testBackdateClaimOpen(by seconds: TimeInterval) {
        claimOpenedAt = claimOpenedAt.map { $0.addingTimeInterval(-seconds) }
    }

    var _testClaimSecondsAway: Int? { claimSecondsAway }

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

    /// Whether the `.inAppPreload` claim screen or browser is up.
    var _testHasClaimPreload: Bool { claimPreload != nil }

    /// The steps-screen preload's controller and transaction, while one is alive.
    var _testStepsPreloadController: ClaimPreloadController? { stepsPreload?.controller }
    var _testStepsPreloadTransactionId: String? { stepsPreload?.transactionId }
    var _testStepsPreloadTask: Task<Void, Never>? { stepsPreload?.task }
    var _testStepsPreloadRefreshTask: Task<Void, Never>? { stepsPreload?.refreshTask }

    /// An App Store claim is waiting for the hand-off out of the in-app browser.
    var _testAwaitingAppStoreHandoff: Bool { awaitingAppStoreHandoff }

    /// `bind(sduiContext:dismiss:)` without a SwiftUI `DismissAction`.
    func _testAttach(sduiContext: SDUIContext) {
        self.sduiContext = sduiContext
        followClaimEnabled(on: sduiContext)
    }
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
            impressionId: impressionId(for: offer.id),
            // The PRESENTED position wins over the live one. See `presentedIndex`.
            offerIndex: presentedIndex[offer.id] ?? index ?? currentOfferIndex ?? 0,
            totalOffers: offers.count,
            presentationId: presentationId,
            variantId: variantId,
            experimentId: experimentId,
            useCase: offerContext.useCase,
            placementId: placementLabel
        )
    }

    /// Context for a claim that may have outlived its offer's scope (strict mode).
    private func context(forCampaignId campaignId: String, advertiserName: String) -> OfferAnalyticsContext {
        if let offer = offers.first(where: { $0.id == campaignId }) { return context(for: offer) }
        return OfferAnalyticsContext(
            campaignId: campaignId,
            creativeId: nil,
            advertiserName: advertiserName,
            impressionId: impressionId(for: campaignId),
            offerIndex: presentedIndex[campaignId] ?? currentOfferIndex ?? 0,
            totalOffers: offers.count,
            presentationId: presentationId,
            variantId: variantId,
            experimentId: experimentId,
            useCase: offerContext.useCase,
            placementId: placementLabel
        )
    }

    /// The campaign's pre-minted impression id; a campaign outside the served list gets one on first use.
    private func impressionId(for campaignId: String) -> String {
        if let id = impressionIds[campaignId] { return id }
        let id = UUID().uuidString
        impressionIds[campaignId] = id
        return id
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
    
    /// The offer arrives by identity, not by index: this view model holds the
    /// BACKEND-ordered list while the tree renders the DISPLAY-ordered one, so
    /// under `offerDisplayOrder` an index alone names the wrong campaign.
    func trackSDUIOfferImpression(_ offer: Offer, displayIndex: Int) {
        recordImpression(offer, index: displayIndex)
    }

    func trackOfferImpression(at index: Int) {
        guard index < offers.count else { return }
        recordImpression(offers[index], index: index)
    }

    /// Emits at most one `sdk_offer_presented` per campaign per presentation:
    /// the ledger is instance state and the sheet builds a view model per show.
    private func recordImpression(_ offer: Offer, index: Int) {
        // The visibility probe is geometry-only; a row that crosses 50% behind the claim cover was never seen.
        guard claimPreload == nil else { return }
        let campaignId = offer.id

        // Dedupe by campaignId: SwiftUI re-mounts rows on scroll-recycle, so
        // `.onAppear`-driven callers can fire the same offer many times per
        // session. Revenue attribution reads these events as 1-per-user.
        if presentedIndex[campaignId] != nil { return }

        // "scroll" reads honestly for both axes — vertical lists scroll
        // and horizontal carousels scroll-snap; "swipe" was carousel-era
        // wording that misreads when the variant is a vertical list.
        emitPresented(offer, index: index, trigger: index == 0 ? "initial_load" : "scroll")
    }

    /// A tap proves the offer was seen: a claim before the visibility rule fired reports the impression first.
    private func presentIfUnseen(_ offer: Offer, at index: Int? = nil) {
        guard presentedIndex[offer.id] == nil else { return }
        emitPresented(offer, index: index ?? offers.firstIndex { $0.id == offer.id } ?? currentOfferIndex ?? 0, trigger: "claim")
    }

    private func emitPresented(_ offer: Offer, index: Int, trigger: String) {
        presentedIndex[offer.id] = index
        track(OfferPresentedEvent(
            context(for: offer, at: index), trigger: trigger,
            imageCacheHit: SDUIImageLoader.imageCacheHit(for: offer)))
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
            experimentId: experimentId,
            useCase: offerContext.useCase,
            placementId: placementLabel
        ))
        
        // Log separate event for each offer's time tracking
        for (index, offer) in offers.enumerated() {
            if let timeSpent = offerViewTimes[offer.id] {
                track(OfferTimeSpentEvent(
                    offer: offer,
                    // The presented position, for the same reason every other
                    // per-offer event uses it. This is the event the corpus
                    // joins to `presented` on `(presentation_id, offer_index)`.
                    index: presentedIndex[offer.id] ?? index,
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
            // Safari hands an App Store page off itself, so its settle counts, as on main. The
            // preload's hand-off comes only from `onSystemHandoff`.
            if awaitingAppStoreHandoff, claimPreload == nil { appStorePageReached = true }
            if didLoadSuccessfully {
                track(OfferWebviewLoadSuccessEvent(ctx, url: url))
            } else {
                track(OfferWebviewLoadFailedEvent(ctx, url: url))
            }
            
        case .initialRedirect(let from, let to):
            if awaitingAppStoreHandoff, claimPreload == nil, Self.isAppStoreURL(to) { appStorePageReached = true }
            track(OfferWebviewInitialRedirectEvent(ctx, from: from, to: to))
            
        case .dismissed(let timeSpentSeconds):
            track(OfferWebviewDismissedEvent(ctx, timeSpent: timeSpentSeconds))
        }
    }
}
