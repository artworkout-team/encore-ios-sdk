// OfferSheetCoordinator.swift
//
// Coordinates the offer presentation lifecycle.
// Bridges async/await to UIKit window presentation.
// Entry point: present(placementId:) → PresentationResult.

import UIKit
import SwiftUI

/// Weak handle to the presentation host — structural evidence a visible phase is live.
private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
    #if DEBUG
    /// Dead box for tests: `value` starts nil.
    init() {}
    #endif
}

/// Weak handle to a host-owned controller plus evidence that it entered the
/// host hierarchy at least once.
private final class ControllerBox {
    weak var value: UIViewController?
    var wasPlaced = false

    init(_ value: UIViewController? = nil) {
        self.value = value
    }
}

@MainActor
internal final class OfferSheetCoordinator {

    // MARK: - State Machine

    /// Phase within a single presentation lifecycle.
    private enum Phase {
        case loading(task: Task<Void, Never>)
        /// Carries the owned window — the liveness evidence the gate verifies.
        case presentingWindow(window: WeakBox<UIWindow>)
        /// Carries the host-owned controller while it is active.
        case presentingViewController(viewController: ControllerBox)
        case finished
    }

    private enum PresentationTarget {
        case managedWindow
        case viewController
    }

    /// Single source of truth — nil means no active presentation.
    /// Replaces separate `active` + `state` fields to prevent desynchronization.
    private struct ActivePresentation {
        let coordinator: OfferSheetCoordinator
        var phase: Phase
    }

    private static var current: ActivePresentation?
    private var resultHandler: (@MainActor @Sendable (PresentationResult) -> Void)?
    private var viewControllerContinuation: CheckedContinuation<UIViewController?, Never>?
    private let presentationId: String
    internal let placementId: String
    /// Publisher-chosen label for this placement, or nil when the id was
    /// auto-generated. This is the ONLY placement value that goes on the wire —
    /// `/offers/search` AND every analytics property (Junaid's 2026-08-14
    /// reversal: a minted `placement_<8hex>` id is local identity for the
    /// outcomes stream, never a wire value; absent folds to `(unlabeled)`
    /// server-side, and `presentation_id` is the correlation key).
    private let placementLabel: String?
    internal let useCase: UseCase
    /// Publisher copy overrides for this presentation, keyed by template variable.
    private let copyOverrides: [String: String]
    private let presentationTarget: PresentationTarget

    // MARK: - Init

    private init(
        placementId: String,
        placementLabel: String? = nil,
        useCase: UseCase = .reduceChurn,
        copyOverrides: [String: String] = [:],
        presentationId: String = UUID().uuidString,
        presentationTarget: PresentationTarget = .managedWindow
    ) {
        self.placementId = placementId
        self.placementLabel = placementLabel
        self.useCase = useCase
        self.copyOverrides = copyOverrides
        self.presentationId = presentationId
        self.presentationTarget = presentationTarget
    }

    // MARK: - Entry Point

    /// Presents an offer sheet and suspends until the flow resolves.
    /// Never throws: every abort path is a `.notPresented(…)` value.
    /// Only one presentation may be active at a time.
    ///
    /// - Parameters:
    ///   - placementId: Publisher-defined placement identifier (local identity:
    ///     the outcomes stream and the host's `PurchaseRequest`).
    ///   - placementLabel: The same id when the publisher chose it, else nil.
    ///     The only placement value on the wire: `/offers/search` (so the
    ///     backend can stamp `sdk_offer_requested`) and every analytics
    ///     property this presentation emits — absent when auto-generated.
    ///   - useCase: Which use case is presenting. Selects the template, scopes
    ///     the NCL experiment, and is stamped on every event emitted here.
    ///   - copyOverrides: Template-variable overrides from the placement builder.
    static func present(
        placementId: String,
        placementLabel: String? = nil,
        useCase: UseCase = .reduceChurn,
        copyOverrides: [String: String] = [:]
    ) async -> PresentationResult {
        let (result, presentationId) = await presentCore(placementId: placementId, placementLabel: placementLabel, useCase: useCase, copyOverrides: copyOverrides)
        publish(
            result,
            placementId: placementId,
            placementLabel: placementLabel,
            presentationId: presentationId,
            useCase: useCase
        )
        return result
    }

    /// Builds an offer controller for a host-owned navigation stack.
    /// Returns nil for every pre-presentation abort and still delivers its result.
    static func makeViewController(
        placementId: String,
        placementLabel: String? = nil,
        useCase: UseCase = .reduceChurn,
        copyOverrides: [String: String] = [:],
        resume: @escaping @Sendable (PresentationResult) -> Void
    ) async -> UIViewController? {
        switch makeAttempt(
            placementId: placementId,
            placementLabel: placementLabel,
            useCase: useCase,
            copyOverrides: copyOverrides,
            presentationTarget: .viewController
        ) {
        case .resolved(let result, let presentationId):
            publish(
                result,
                placementId: placementId,
                placementLabel: placementLabel,
                presentationId: presentationId,
                useCase: useCase
            )
            Task { @MainActor in resume(result) }
            return nil

        case .ready(let coordinator):
            guard #available(iOS 17.0, *) else { return nil }
            return await coordinator.buildViewController { result in
                publish(
                    result,
                    placementId: placementId,
                    placementLabel: placementLabel,
                    presentationId: coordinator.presentationId,
                    useCase: useCase
                )
                if current?.coordinator === coordinator {
                    current = nil
                }
                resume(result)
            }
        }
    }

    private static func publish(
        _ result: PresentationResult,
        placementId: String,
        placementLabel: String?,
        presentationId: String,
        useCase: UseCase
    ) {
        // Single choke point for BOTH observation channels: every resolution
        // lands on `outcomes` AND ships as the terminal analytics record.
        // Outbox delivery so the record survives process death offline.
        enqueueDiagnostic(.placementResolved(
            result: result,
            placementId: placementLabel,
            presentationId: presentationId,
            useCase: useCase,
            variantId: sduiConfigManager?.variantId(for: useCase),
            unlockMode: Encore.shared.configuration?.unlock ?? .optimistic,
            distinctId: EventEnvelope.resolveDistinctId()
        ))
        Encore.shared.yieldOutcome(.presentation(placementId: placementId, result: result))
    }

    private static func presentCore(
        placementId: String,
        placementLabel: String?,
        useCase: UseCase,
        copyOverrides: [String: String]
    ) async -> (PresentationResult, presentationId: String) {
        switch makeAttempt(
            placementId: placementId,
            placementLabel: placementLabel,
            useCase: useCase,
            copyOverrides: copyOverrides,
            presentationTarget: .managedWindow
        ) {
        case .resolved(let result, let presentationId):
            return (result, presentationId)
        case .ready(let coordinator):
            // Ownership-checked: a resumed stale frame must not wipe a successor
            // flow's registration.
            defer { if current?.coordinator === coordinator { current = nil } }
            return (await coordinator.run(), coordinator.presentationId)
        }
    }

    /// Whether the active presentation still has a live host. Before a
    /// host-owned controller is placed, retaining it is enough; after it has
    /// entered a hierarchy, leaving that hierarchy ends the flow.
    private static func structuralLiveness(of phase: Phase) -> Bool? {
        switch phase {
        case .loading, .finished:
            return nil
        case .presentingWindow(let box):
            return box.value.map { $0.windowScene != nil && !$0.isHidden } ?? false
        case .presentingViewController(let box):
            guard let viewController = box.value else { return false }
            if isHeldByHost(viewController) {
                box.wasPlaced = true
                return true
            }
            return !box.wasPlaced
        }
    }

    internal static func isHeldByHost(_ viewController: UIViewController) -> Bool {
        viewController.viewIfLoaded?.window != nil
            || viewController.parent != nil
            || viewController.presentingViewController != nil
    }

    private enum Attempt {
        case ready(OfferSheetCoordinator)
        case resolved(PresentationResult, presentationId: String)
    }

    private static func makeAttempt(
        placementId: String,
        placementLabel: String?,
        useCase: UseCase,
        copyOverrides: [String: String],
        presentationTarget: PresentationTarget
    ) -> Attempt {
        // Resolved once for every gate event: the variant is a config-level
        // fact, known before any of them fire. Stays nil when remote config has
        // not resolved a variant for this use case.
        let variantId: String? = sduiConfigManager?.variantId(for: useCase)

        // One presentation id for the whole attempt: gate events, in-sheet
        // events, IAP events, and the terminal record all join on it.
        let presentationId = UUID().uuidString

        // Diagnostic: prove the platform layer reached native presentation,
        // BEFORE any gate or early return. Reliable outbox so it survives every
        // subsequent abort path (iOS-version, duplicate, not-configured, control).
        enqueueDiagnostic(.showEntered(placementId: placementLabel, distinctId: EventEnvelope.resolveDistinctId(), variantId: variantId, useCase: useCase, presentationId: presentationId))

        // iOS version gate. Pre-trigger, so it aborts rather than fails; the
        // public NotPresentedReason.unsupportedOS wire value is unchanged.
        // Reads `Encore.isSupported` so the gate and the capability check the
        // host reads beforehand can never drift apart.
        guard Encore.isSupported else {
            let version = UIDevice.current.systemVersion
            Logger.debug("SwiftUI offers require iOS 17+. Current: \(version)")
            enqueueDiagnostic(.showAborted(reason: .unsupportedOS, placementId: placementLabel, distinctId: EventEnvelope.resolveDistinctId(), variantId: variantId, useCase: useCase, presentationId: presentationId, iosVersion: version))
            return .resolved(.notPresented(.unsupportedOS), presentationId: presentationId)
        }

        // Defensive: clean stale finished coordinator (should never happen with defer)
        if let c = current, case .finished = c.phase {
            Logger.warn(.presentation, "Stale coordinator detected — cleaning up")
            current = nil
        }

        // Liveness guarantee: every flow resolves on a real event — its own
        // completion, window teardown, or reconciliation at the next present().
        if let active = current, let structurallyLive = structuralLiveness(of: active.phase) {
            #if DEBUG
            let isLive = _livenessOverride ?? structurallyLive
            #else
            let isLive = structurallyLive
            #endif
            if !isLive {
                Logger.warn(.presentation, "Dead presentation host detected — reconciling and continuing")
                active.coordinator.complete(.success(.presented(dismissal: .interrupted)))
                current = nil
            }
        }

        guard current == nil else {
            Logger.warn(.presentation, "Already presenting, ignoring duplicate request")
            enqueueDiagnostic(.showAborted(reason: .alreadyPresenting, placementId: placementLabel, distinctId: EventEnvelope.resolveDistinctId(), variantId: variantId, useCase: useCase, presentationId: presentationId))
            return .resolved(.notPresented(.alreadyPresenting), presentationId: presentationId)
        }

        // NCL experiment intercept. Scoped to `.reduceChurn`: every other use case
        // skips the cohort read AND the exposure log entirely (D-6). See
        // `NCLGhostTrigger` for why the exposure matters as much as the
        // suppression.
        switch NCLGhostTrigger.evaluate(
            useCase: useCase,
            logExposure: { NCLGhostTrigger.defaultLogExposure($0, variantId: variantId, useCase: useCase, placementId: placementLabel) }
        ) {
        case .suppress:
            // Ghost Trigger: Control group exits immediately (no UI, exposure
            // logged). Pre-trigger suppression, so it aborts rather than fails.
            Logger.info(.experiments, "Ghost Trigger - Control cohort, no UI shown")
            enqueueDiagnostic(.showAborted(reason: .experimentControl, placementId: placementLabel, distinctId: EventEnvelope.resolveDistinctId(), variantId: variantId, useCase: useCase, presentationId: presentationId))
            return .resolved(.notPresented(.experimentControl), presentationId: presentationId)
        case .proceed, .skipped:
            break
        }

        return .ready(OfferSheetCoordinator(
            placementId: placementId,
            placementLabel: placementLabel,
            useCase: useCase,
            copyOverrides: copyOverrides,
            presentationId: presentationId,
            presentationTarget: presentationTarget
        ))
    }

    // MARK: - Lifecycle

    /// Bridges the coordinator lifecycle to async/await via a single continuation.
    private func run() async -> PresentationResult {
        await withCheckedContinuation { continuation in
            self.resultHandler = { result in
                continuation.resume(returning: result)
            }
            self.start()
        }
    }

    /// Starts the normal loading pipeline but resolves once its controller is ready.
    /// The terminal result is delivered later, after the host removes the controller.
    @available(iOS 17.0, *)
    private func buildViewController(
        onCompletion: @escaping @MainActor @Sendable (PresentationResult) -> Void
    ) async -> UIViewController? {
        await withCheckedContinuation { continuation in
            self.resultHandler = onCompletion
            self.viewControllerContinuation = continuation
            self.start()
        }
    }

    private func start() {
        guard let analyticsClient = analyticsClient,
              let entitlementsManager = entitlementsManager,
              let offersManager = offersManager else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            Self.enqueueDiagnostic(.showAborted(reason: .notConfigured, placementId: placementLabel, distinctId: EventEnvelope.resolveDistinctId(), variantId: sduiConfigManager?.variantId(for: useCase), useCase: useCase, presentationId: presentationId))
            complete(.failure(.integration(.notConfigured)))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }

            let userId = entitlementsManager.currentUserId
            let attributes = entitlementsManager.userAttributes
            let useCase = self.useCase

            // The availability ladder, uniform across use cases: join an
            // in-flight /config under a 2s ceiling, else render the persisted
            // (variantId, template) pair, else this use case's own floor. A use
            // case the app is enabled for is already cached, so this returns
            // straight away. Anything else (serving is ungated, so a publisher
            // may present a use case with no `app_use_cases` row) is fetched
            // here once under the same ceiling, and earns an [INTEGRATION] hint
            // saying how to avoid paying for it again.
            await remoteConfigManager?.loadConfig(
                for: useCase,
                userId: userId,
                sdkVersion: Encore.sdkVersion,
                language: userManager?.userAttributes.language
            )

            // Get variant ID from remote config manager (pre-fetched on user identify).
            let variantId: String? = sduiConfigManager?.variantId(for: useCase)
            Logger.debug(.configuration, "OfferPresentation reading useCase=\(useCase.rawValue), variantId=\(variantId ?? "nil"), hasRemoteConfig=\(remoteConfigManager?.config(for: useCase) != nil)")

            analyticsClient.track(OfferPresentationTriggeredEvent(presentationId: presentationId, variantId: variantId, useCase: useCase, placementId: self.placementLabel))

            // KILL SWITCH: the only remaining decline. A layout of nil now
            // means the server explicitly resolved no template for this use
            // case on this session, which is a publisher decision. Every
            // knowledge gap (offline, nothing cached, a stale template-less
            // blob) renders this use case's own floor instead: integrators wire
            // show() to explicit UI, where a silent decline is a broken button.
            // Checked before /offers so a declined presentation never burns
            // offer inventory either.
            if sduiConfigManager?.layout(for: useCase) == nil {
                Logger.info(.presentation, "Server resolved no \(useCase.rawValue) template, no UI shown")
                analyticsClient.track(
                    OfferPresentationFailedEvent(reason: NotPresentedReason.useCaseUnavailable, presentationId: presentationId, variantId: variantId, useCase: useCase, placementId: self.placementLabel)
                )
                self.complete(.success(.notPresented(.useCaseUnavailable)))
                return
            }

            do {
                let unlockMode = Encore.shared.configuration?.unlock ?? .optimistic
                let maxPostbackTimeMs: Int? = unlockMode == .strict ? StrictUnlock.maxPostbackTimeMs : nil

                // Publisher product lookup runs CONCURRENTLY with the offers
                // fetch: both are network round trips and the sheet needs
                // both, so serializing them stacked their latencies on the
                // tap-to-sheet path (validation finding, 2026-08-11).
                let resolvedIAPProductId: String? = useCase.allowsIAP
                    ? (remoteConfigManager?.iapProductId(for: useCase) ?? attributes.iapProductId)
                    : nil
                let productInfoTask: Task<IAPProductInfo?, Never>? = resolvedIAPProductId.map { productId in
                    Task { await IAPClient.fetchProductInfo(productId: productId) }
                }

                let response = try await offersManager.fetchOffers(
                    userId: userId,
                    attributes: attributes,
                    variantId: variantId,
                    placementId: self.placementLabel,
                    maxPostbackTimeMs: maxPostbackTimeMs
                )
                guard !response.offerList.isEmpty else {
                    analyticsClient.track(
                        OfferPresentationFailedEvent(reason: NotPresentedReason.noOffers, presentationId: presentationId, variantId: variantId, useCase: useCase, placementId: self.placementLabel)
                    )
                    self.complete(.success(.notPresented(.noOffers)))
                    return
                }

                analyticsClient.track(
                    OfferPresentationSuccessEvent(
                        presentationId: presentationId,
                        offerCount: "\(response.offerCount)",
                        variantId: variantId,
                        useCase: useCase,
                        placementId: self.placementLabel
                    )
                )

                // IAP is paywall-only. Reward is claim-only — no product
                // fetch, no IAP-First branch, no entitlement written on claim —
                // so a surface that thanks the user never touches StoreKit.
                var iapProductId: String?
                var iapContext: IAPContext = .empty

                if useCase.allowsIAP {
                    iapProductId = resolvedIAPProductId

                    // Join the lookup kicked off alongside the offers fetch.
                    if let iapProductId {
                        if let productInfo = await productInfoTask?.value {
                            iapContext = IAPContext(from: productInfo)
                            Logger.debug(.iap, "Fetched subscription: \(productInfo.displayPrice)\(productInfo.subscriptionPeriod ?? "")")
                        } else if sduiConfigManager?.requiresIAP(for: useCase) == true {
                            Logger.warn(.iap, "Config requires IAP but product '\(iapProductId)' not found - using fallback config")
                            sduiConfigManager?.useFallbackConfig(for: useCase, reason: "Invalid IAP product: \(iapProductId)")
                        }
                    } else if sduiConfigManager?.requiresIAP(for: useCase) == true {
                        Logger.warn(.iap, "Config requires IAP but no iapProductId configured - using fallback config")
                        sduiConfigManager?.useFallbackConfig(for: useCase, reason: "No iapProductId configured")
                    }
                }

                // Create offer context combining remote config and IAP data
                let offerContext = OfferContext(
                    uiValues: remoteConfigManager?.ui(for: useCase)?.values,
                    entitlements: remoteConfigManager?.entitlements(for: useCase),
                    iap: iapContext,
                    useCase: useCase,
                    copyOverrides: self.copyOverrides
                )

                // Check for IAP-First flow
                if useCase.allowsIAP, sduiConfigManager?.layout(for: useCase)?.triggerIAPFirst == true {
                    guard let iapProductIdForPurchase = iapProductId else {
                        Logger.warn(.iap, "triggerIAPFirst is true but no iapProductId configured")
                        sduiConfigManager?.useFallbackConfig(for: useCase, reason: "No iapProductId for triggerIAPFirst")
                        if #available(iOS 17.0, *) {
                            self.presentOfferSheet(response: response, userId: userId, offerContext: offerContext, initialStateOverride: nil)
                        }
                        return
                    }

                    Logger.info(.iap, "Triggering IAP before showing offers")
                    let outcome = await IAPClient.delegatePurchase(productId: iapProductIdForPurchase, placementId: self.placementId, placementLabel: self.placementLabel, presentationId: self.presentationId, useCase: useCase)

                    if outcome == .purchased {
                        Logger.info(.iap, "Purchase successful - showing offers")
                        if #available(iOS 17.0, *) {
                            // The purchase already happened — stage it so the
                            // record carries it however the sheet ends.
                            self.presentOfferSheet(response: response, userId: userId, offerContext: offerContext, initialStateOverride: nil, initiallyPurchased: true)
                        }
                    } else {
                        Logger.info(.iap, "Purchase cancelled or failed - dismissing")
                        // The purchase sheet was the presentation; record its outcome.
                        // Errors are not completions: .failed reads as interrupted,
                        // only a real cancel as user-cancelled; .pending completed the flow.
                        let dismissal: DismissReason
                        switch outcome {
                        case .cancelled: dismissal = .userCancelled
                        case .failed:    dismissal = .interrupted
                        default:         dismissal = .flowCompleted
                        }
                        self.complete(.success(.presented(publisher: outcome, dismissal: dismissal)))
                    }
                    return
                }

                if #available(iOS 17.0, *) {
                    self.presentOfferSheet(response: response, userId: userId, offerContext: offerContext, initialStateOverride: nil)
                }
            } catch let error as EncoreError {
                Logger.error(error, context: .fetchOfferData)
                // A total offers-API outage used to produce ZERO events —
                // presentation_failed is the only iOS-side evidence of it.
                analyticsClient.track(
                    OfferPresentationFailedEvent(reason: .error(error), presentationId: presentationId, variantId: variantId, useCase: useCase, placementId: self.placementLabel)
                )
                self.complete(.failure(error))
            } catch {
                let wrapped = EncoreError.transport(.network(error))
                Logger.error(wrapped, context: .fetchOfferData)
                analyticsClient.track(
                    OfferPresentationFailedEvent(reason: .error(wrapped), presentationId: presentationId, variantId: variantId, useCase: useCase, placementId: self.placementLabel)
                )
                self.complete(.failure(wrapped))
            }
        }
        Self.current = ActivePresentation(coordinator: self, phase: .loading(task: task))
    }

    @available(iOS 17.0, *)
    private func presentOfferSheet(response: OfferResponse, userId: String, offerContext: OfferContext, initialStateOverride: String?, initiallyPurchased: Bool = false) {
        // The flow may already have resolved — presenting now would leak a
        // presentation host nobody owns or tears down.
        guard resultHandler != nil else {
            Logger.warn(.presentation, "Skipping presentation — flow already resolved")
            return
        }
        Logger.info(.presentation, "Presenting offer sheet with \(response.offerCount) offers")

        let presentationStyle = sduiConfigManager?.layout(for: offerContext.useCase)?.presentationStyle ?? .sheet
        let presentationHost: OfferSheetPresentationHost
        let dismissalRelay: OfferSheetViewControllerDismissalRelay?
        switch presentationTarget {
        case .managedWindow:
            presentationHost = .managedWindow(presentationStyle)
            dismissalRelay = nil
        case .viewController:
            presentationHost = .viewController
            dismissalRelay = OfferSheetViewControllerDismissalRelay()
        }
        let containerView = OfferSheetContainer(
            offerResponse: response,
            userId: userId,
            presentationId: presentationId,
            placementId: placementId,
            placementLabel: placementLabel,
            offerContext: offerContext,
            initialStateOverride: initialStateOverride,
            initiallyPurchased: initiallyPurchased,
            presentationHost: presentationHost,
            onDismissRequest: {
                dismissalRelay?.requestDismissal()
            },
            onCompletion: { [weak self] result in
                self?.complete(result)
            }
        )

        switch presentationTarget {
        case .managedWindow:
            let window = PresentationWindow.present(
                containerView,
                presentationStyle: presentationStyle,
                overrideUserInterfaceStyle: offerContext.appearanceMode.userInterfaceStyle
            ) { [weak self] in
                self?.complete(.success(.presented(dismissal: .dismissed)))
            }
            if let window {
                Self.current = ActivePresentation(
                    coordinator: self,
                    phase: .presentingWindow(window: WeakBox(window))
                )
            } else {
                Logger.error(.integration(.notConfigured), context: .presentOfferInitialization)
                complete(.failure(.integration(.notConfigured)))
            }

        case .viewController:
            let viewController = OfferSheetViewController(rootView: containerView)
            viewController.overrideUserInterfaceStyle = offerContext.appearanceMode.userInterfaceStyle
            dismissalRelay?.viewController = viewController
            let viewControllerBox = ControllerBox(viewController)
            Self.current = ActivePresentation(
                coordinator: self,
                phase: .presentingViewController(viewController: viewControllerBox)
            )
            guard let viewControllerContinuation else {
                Logger.error(.integration(.notConfigured), context: .presentOfferInitialization)
                complete(.failure(.integration(.notConfigured)))
                return
            }
            self.viewControllerContinuation = nil
            viewControllerContinuation.resume(returning: viewController)
            observePlacement(viewController, box: viewControllerBox)
        }
    }

    @available(iOS 17.0, *)
    private func observePlacement(_ viewController: OfferSheetViewController, box: ControllerBox) {
        Task { [weak self, weak viewController] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let viewController, self.resultHandler != nil else { return }
            guard !Self.isHeldByHost(viewController) else {
                box.wasPlaced = true
                return
            }
            Logger.warn(
                .presentation,
                "makeViewController(\(self.placementId)) returned a controller that was never pushed or presented. "
                    + "This placement stays active, so the next show() reports alreadyPresenting."
            )
        }
    }

    // MARK: - Completion

    /// Single completion path — idempotent.
    /// Handles cleanup based on current phase:
    /// - `.loading`: cancels in-flight task, no window to tear down
    /// - `.presentingWindow`: tears down the presentation window
    /// - `.presentingViewController`: the host already owns controller removal
    /// - `.finished` / nil: no-op (already completed)
    ///
    /// Internal plumbing (dismiss handler, container, fetch) still speaks
    /// `Result`; this is the one boundary where failures collapse into
    /// `.notPresented` values so `present()` never throws.
    private func complete(_ result: Result<PresentationResult, EncoreError>) {
        // The handler is the idempotency guard — consumed exactly once.
        // This also handles the edge case where start() fails before setting current.
        guard let resultHandler else { return }
        self.resultHandler = nil
        let pendingViewControllerContinuation = viewControllerContinuation
        viewControllerContinuation = nil
        let presentationResult = Self.collapse(result)

        let finish = {
            pendingViewControllerContinuation?.resume(returning: nil)
            resultHandler(presentationResult)
        }

        // Phase-based cleanup (only if this coordinator owns current)
        if let active = Self.current, active.coordinator === self {
            if case .loading(let task) = active.phase { task.cancel() }

            if case .presentingWindow = active.phase {
                PresentationWindow.cleanup(animated: true) { [self] in
                    if Self.current?.coordinator === self {
                        Self.current = ActivePresentation(coordinator: self, phase: .finished)
                    }
                    finish()
                }
                return
            }

            Self.current = ActivePresentation(coordinator: self, phase: .finished)
        }

        finish()
    }

    /// Failure → value mapping for the never-throw surface.
    private static func collapse(_ result: Result<PresentationResult, EncoreError>) -> PresentationResult {
        switch result {
        case .success(let value):
            return value
        case .failure(.integration(.notConfigured)):
            return .notPresented(.notConfigured)
        case .failure(let error):
            return .notPresented(.error(error))
        }
    }

    // MARK: - Diagnostics

    /// Enqueue a diagnostic event on the reliable outbox.
    ///
    /// Falls back to the unconfigured queue when no container exists: the
    /// `.notConfigured` abort fires precisely when `services` is nil, so
    /// routing it only through `services.outbox` dropped the one event that
    /// proves show() ran before configure(). Both queues are the same
    /// directory — the next configure() drains it.
    private static func enqueueDiagnostic(_ job: OutboxJob) {
        guard let outbox = Encore.shared.services?.outbox else {
            UnconfiguredOutbox.enqueue(job)
            return
        }
        outbox.enqueue(job)
    }

    // MARK: - Test Hooks

    /// Whether a non-finished presentation is in progress.
    static var isPresenting: Bool {
        guard let current else { return false }
        if case .finished = current.phase { return false }
        return true
    }

    /// Whether offer UI is currently attached to a visible window.
    static var isVisible: Bool {
        guard let current else { return false }
        switch current.phase {
        case .loading, .finished:
            return false
        case .presentingWindow(let box):
            return box.value.map { $0.windowScene != nil && !$0.isHidden } ?? false
        case .presentingViewController(let box):
            return box.value?.viewIfLoaded?.window != nil
        }
    }

    #if DEBUG
    /// Overrides the presentation-host liveness check — a real test-env UIWindow
    /// has `windowScene == nil`, so the structural check can't pass there.
    static var _livenessOverride: Bool?

    /// Force the coordinator into an active (non-idle) state for gate testing.
    static func _forcePresenting() {
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        let task = Task<Void, Never> { }
        current = ActivePresentation(coordinator: coordinator, phase: .loading(task: task))
    }

    /// Force a presenting-window phase whose window evidence is already dead.
    static func _forcePresentingDeadWindow() {
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        current = ActivePresentation(coordinator: coordinator, phase: .presentingWindow(window: WeakBox()))
    }

    /// Force a presenting-window phase the gate treats as live (via `_livenessOverride`).
    static func _forcePresentingLiveWindow() {
        _livenessOverride = true
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        current = ActivePresentation(coordinator: coordinator, phase: .presentingWindow(window: WeakBox()))
    }

    /// Force-clear all state for test isolation.
    static func _forceReset() {
        current = nil
        _livenessOverride = nil
    }
    #endif
}
