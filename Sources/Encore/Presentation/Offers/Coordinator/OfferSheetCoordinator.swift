// OfferSheetCoordinator.swift
//
// Coordinates the offer presentation lifecycle.
// Bridges async/await to UIKit window presentation.
// Entry point: present(placementId:) → PresentationResult.

import UIKit
import SwiftUI

/// Weak handle to the presentation window — structural evidence a `.presenting` phase is live.
/// Weak handle to the host-owned controller, plus a latch. Once the host has
/// placed it, leaving the hierarchy means the flow is dead rather than in flight.
private final class ControllerBox {
    weak var value: UIViewController?
    var wasPlaced = false
    init(_ v: UIViewController? = nil) { value = v }
}

private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
    #if DEBUG
    /// Dead box for tests: `value` starts nil.
    init() {}
    #endif
}

@MainActor
internal final class OfferSheetCoordinator {

    // MARK: - State Machine

    /// Phase within a single presentation lifecycle.
    private enum Phase {
        case loading(task: Task<Void, Never>)
        /// Carries the owned window — the liveness evidence the gate verifies.
        case presenting(window: WeakBox<UIWindow>)
        /// Carries the host-owned controller. Liveness reads differently here:
        /// the SDK owns no window, so the evidence is the host's hierarchy.
        case presentingController(controller: ControllerBox)
        case finished
    }

    /// Where a presentation renders. The gates are identical for both; the
    /// liveness evidence and the teardown are not.
    internal enum PresentationTarget {
        case managedWindow
        case hostController

        var wireValue: String {
            switch self {
            case .managedWindow: return "managed_window"
            case .hostController: return "host_controller"
            }
        }
    }

    /// Single source of truth — nil means no active presentation.
    /// Replaces separate `active` + `state` fields to prevent desynchronization.
    private struct ActivePresentation {
        let coordinator: OfferSheetCoordinator
        var phase: Phase
    }

    private static var current: ActivePresentation?
    /// Delivers the terminal result. `run()` resumes its own continuation
    /// through this; the controller path hands it to the caller instead,
    /// because that flow returns as soon as the controller exists.
    private var resultHandler: (@MainActor (PresentationResult) -> Void)?
    private var controllerContinuation: CheckedContinuation<UIViewController?, Never>?
    private let presentationTarget: PresentationTarget
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

    // MARK: - Init

    private init(placementId: String, placementLabel: String? = nil, useCase: UseCase = .reduceChurn, copyOverrides: [String: String] = [:], presentationId: String = UUID().uuidString, presentationTarget: PresentationTarget = .managedWindow) {
        self.presentationTarget = presentationTarget
        self.placementId = placementId
        self.placementLabel = placementLabel
        self.useCase = useCase
        self.copyOverrides = copyOverrides
        self.presentationId = presentationId
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
        publish(result, placementId: placementId, placementLabel: placementLabel, presentationId: presentationId, useCase: useCase, presentationTarget: .managedWindow)
        return result
    }

    /// Single choke point for BOTH observation channels: every resolution lands
    /// on `outcomes` AND ships as the terminal analytics record. Outbox
    /// delivery so the record survives process death offline.
    private static func publish(
        _ result: PresentationResult,
        placementId: String,
        placementLabel: String?,
        presentationId: String,
        useCase: UseCase,
        presentationTarget: PresentationTarget
    ) {
        enqueueDiagnostic(.placementResolved(
            result: result,
            placementId: placementLabel,
            presentationId: presentationId,
            useCase: useCase,
            presentationTarget: presentationTarget.wireValue,
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
        switch makeAttempt(placementId: placementId, placementLabel: placementLabel, useCase: useCase, copyOverrides: copyOverrides, presentationTarget: .managedWindow) {
        case .resolved(let result, let presentationId):
            return (result, presentationId)
        case .ready(let coordinator):
            // Ownership-checked: a resumed stale frame must not wipe a
            // successor flow's registration.
            defer { if current?.coordinator === coordinator { current = nil } }
            return (await coordinator.run(), coordinator.presentationId)
        }
    }

    /// Whether a presentation still has a host on screen, or nil while it has
    /// no host to check. A window is live while it belongs to a scene and is
    /// not hidden; a host-owned controller has no window of its own, so the
    /// evidence is that the host still holds it.
    private static func structuralLiveness(of phase: Phase) -> Bool? {
        switch phase {
        case .loading, .finished:
            return nil
        case .presenting(let box):
            return box.value.map { $0.windowScene != nil && !$0.isHidden } ?? false
        case .presentingController(let box):
            guard let controller = box.value else { return false }
            // Existence is the only honest signal until the host has placed it:
            // reading placement earlier would reconcile away a controller handed
            // over one moment ago and not yet pushed. Once placed, leaving the
            // hierarchy is the flow ending.
            if isHeldByHost(controller) { box.wasPlaced = true; return true }
            return !box.wasPlaced
        }
    }

    /// Whether the host has actually placed the controller: on screen, inside a
    /// parent, or presented. Only this warning reads it. Liveness deliberately
    /// does not, because a controller in flight is live and reading placement
    /// there would reconcile it away under the host.
    internal static func isHeldByHost(_ controller: UIViewController) -> Bool {
        controller.viewIfLoaded?.window != nil
            || controller.parent != nil
            || controller.presentingViewController != nil
    }

    /// Builds an offer controller for a host-owned navigation stack. Returns
    /// nil for every pre-presentation abort, and still delivers that abort's
    /// result through `resume`.
    ///
    /// Callable below the iOS floor on purpose: the shared gate is what reports
    /// `.unsupportedOS`, with the same diagnostics `show()` emits.
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
            presentationTarget: .hostController
        ) {
        case .resolved(let result, let presentationId):
            publish(result, placementId: placementId, placementLabel: placementLabel, presentationId: presentationId, useCase: useCase, presentationTarget: .hostController)
            // Delivered on the next turn, as every other outcome is: `resume`
            // never runs before this call has returned, so a host always holds
            // its controller, or its nil, before its callback fires.
            Task { @MainActor in resume(result) }
            return nil

        case .ready(let coordinator):
            // Unreachable below iOS 17: `Encore.isSupported` is that check, and
            // the gate above resolves on it before ever reaching here.
            guard #available(iOS 17.0, *) else { return nil }
            return await coordinator.buildController { result in
                publish(result, placementId: placementId, placementLabel: placementLabel, presentationId: coordinator.presentationId, useCase: useCase, presentationTarget: .hostController)
                // Ownership-checked, as in `presentCore`: a stale frame must not
                // wipe a successor flow's registration.
                if current?.coordinator === coordinator { current = nil }
                resume(result)
            }
        }
    }

    /// The outcome of every pre-presentation gate: either the attempt already
    /// resolved without any UI, or a registered coordinator is ready to run.
    private enum Attempt {
        case ready(OfferSheetCoordinator)
        case resolved(PresentationResult, presentationId: String)
    }

    /// Runs every gate that gets an answer before any UI exists, so a second
    /// presentation target cannot drift from `present()` on any of them.
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
        if let active = current, let structurallyLive = Self.structuralLiveness(of: active.phase) {
            #if DEBUG
            let isLive = _livenessOverride ?? structurallyLive
            #else
            let isLive = structurallyLive
            #endif
            if !isLive {
                Logger.warn(.presentation, "Dead presentation detected (window gone) — reconciling and continuing")
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

        return .ready(OfferSheetCoordinator(placementId: placementId, placementLabel: placementLabel, useCase: useCase, copyOverrides: copyOverrides, presentationId: presentationId, presentationTarget: presentationTarget))
    }

    // MARK: - Lifecycle

    /// Bridges the coordinator lifecycle to async/await via a single continuation.
    private func run() async -> PresentationResult {
        await withCheckedContinuation { continuation in
            self.resultHandler = { continuation.resume(returning: $0) }
            self.start()
        }
    }

    /// Runs the same pipeline but resolves as soon as the controller exists.
    /// The terminal result arrives later, through `onCompletion`.
    @available(iOS 17.0, *)
    private func buildController(
        onCompletion: @escaping @MainActor (PresentationResult) -> Void
    ) async -> UIViewController? {
        await withCheckedContinuation { continuation in
            self.resultHandler = onCompletion
            self.controllerContinuation = continuation
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
        // window nobody owns or tears down.
        guard resultHandler != nil else {
            Logger.warn(.presentation, "Skipping presentation — flow already resolved")
            return
        }
        Logger.info(.presentation, "Presenting offer sheet with \(response.offerCount) offers")

        let containerView = OfferSheetContainer(
            offerResponse: response,
            userId: userId,
            presentationId: presentationId,
            placementId: placementId,
            placementLabel: placementLabel,
            offerContext: offerContext,
            presentationStyle: sduiConfigManager?.layout(for: offerContext.useCase)?.presentationStyle ?? .sheet,
            initialStateOverride: initialStateOverride,
            initiallyPurchased: initiallyPurchased,
            onCompletion: { [weak self] result in
                self?.complete(result)
            }
        )

        switch presentationTarget {
        case .managedWindow:
            let window = PresentationWindow.present(
                containerView,
                overrideUserInterfaceStyle: offerContext.appearanceMode.userInterfaceStyle
            ) { [weak self] in
                self?.complete(.success(.presented(dismissal: .dismissed)))
            }
            if let window {
                Self.current = ActivePresentation(coordinator: self, phase: .presenting(window: WeakBox(window)))
            } else {
                Logger.error(.integration(.notConfigured), context: .presentOfferInitialization)
                complete(.failure(.integration(.notConfigured)))
            }

        case .hostController:
            let controller = OfferSheetViewController(rootView: containerView)
            controller.overrideUserInterfaceStyle = offerContext.appearanceMode.userInterfaceStyle
            let box = ControllerBox(controller)
            Self.current = ActivePresentation(coordinator: self, phase: .presentingController(controller: box))
            let continuation = controllerContinuation
            controllerContinuation = nil
            continuation?.resume(returning: controller)
            observePlacement(controller, box: box)
        }
    }

    /// Arms the placement latch once the host has placed the controller, and
    /// warns when it never does: that placement stays active, so the next
    /// `show()` reports `.alreadyPresenting`. A warning rather than a fix,
    /// because only the host can place it and abandoning one is its right.
    @available(iOS 17.0, *)
    private func observePlacement(_ controller: OfferSheetViewController, box: ControllerBox) {
        // How long a host may reasonably take to place it.
        let grace = Duration.seconds(5)
        Task { [weak self, weak controller] in
            try? await Task.sleep(for: grace)
            guard let self, let controller, self.resultHandler != nil else { return }
            guard !Self.isHeldByHost(controller) else { box.wasPlaced = true; return }
            Logger.warn(.presentation, "makeViewController(\(self.placementId)) returned a controller that was never pushed or presented. This placement stays active, so the next show() reports alreadyPresenting.")
        }
    }

    // MARK: - Completion

    /// Single completion path — idempotent.
    /// Handles cleanup based on current phase:
    /// - `.loading`: cancels in-flight task, no window to tear down
    /// - `.presenting`: tears down the presentation window
    /// - `.finished` / nil: no-op (already completed)
    ///
    /// Internal plumbing (dismiss handler, container, fetch) still speaks
    /// `Result`; this is the one boundary where failures collapse into
    /// `.notPresented` values so `present()` never throws.
    private func complete(_ result: Result<PresentationResult, EncoreError>) {
        // The handler is the idempotency guard — consumed exactly once. This
        // also handles the edge case where start() fails before setting current.
        guard let resultHandler else { return }
        self.resultHandler = nil

        // A flow that never reached a controller still has a caller awaiting one.
        let pendingController = controllerContinuation
        self.controllerContinuation = nil

        // Phase-based cleanup (only if this coordinator owns current)
        var hostController: UIViewController?
        if let active = Self.current, active.coordinator === self {
            if case .loading(let task) = active.phase { task.cancel() }
            if case .presenting = active.phase { PresentationWindow.cleanup() }
            if case .presentingController(let box) = active.phase { hostController = box.value }
            Self.current = ActivePresentation(coordinator: self, phase: .finished)
        }

        let collapsed = Self.collapse(result)

        if let pendingController {
            // Resuming schedules the caller, it does not preempt, so delivering
            // the result here would run the host's callback while it is still
            // awaiting the controller. Hand back nil, then deliver on the next
            // turn. Nothing is left to dismiss: a pending continuation means the
            // controller was never built, so the phase cannot be
            // `.presentingController`.
            pendingController.resume(returning: nil)
            Task { @MainActor in resultHandler(collapsed) }
            return
        }

        resultHandler(collapsed)

        // After the host has had its turn: it may have removed or replaced the
        // controller already, and asking a controller that is gone to dismiss
        // is a no-op rather than a second removal.
        if #available(iOS 17.0, *), let hostController = hostController as? OfferSheetViewController {
            hostController.requestDismissal()
        }
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

    #if DEBUG
    /// Overrides the `.presenting` liveness check — a real test-env UIWindow
    /// has `windowScene == nil`, so the structural check can't pass there.
    static var _livenessOverride: Bool?

    /// Force the coordinator into an active (non-idle) state for gate testing.
    static func _forcePresenting() {
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        let task = Task<Void, Never> { }
        current = ActivePresentation(coordinator: coordinator, phase: .loading(task: task))
    }

    /// Force a `.presenting` phase whose window evidence is already dead.
    static func _forcePresentingDeadWindow() {
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        current = ActivePresentation(coordinator: coordinator, phase: .presenting(window: WeakBox()))
    }

    /// Force a `.presenting` phase the gate treats as live (via `_livenessOverride`).
    static func _forcePresentingLiveWindow() {
        _livenessOverride = true
        let coordinator = OfferSheetCoordinator(placementId: "test_placement")
        current = ActivePresentation(coordinator: coordinator, phase: .presenting(window: WeakBox()))
    }

    /// Force a host-controller phase the gate treats as live, so the two
    /// liveness readings can be exercised against the same gate.
    static func _forcePresentingLiveController() {
        _livenessOverride = true
        let coordinator = OfferSheetCoordinator(placementId: "test_placement", presentationTarget: .hostController)
        current = ActivePresentation(coordinator: coordinator, phase: .presentingController(controller: ControllerBox()))
    }

    /// Whether a dead host-controller phase reads as dead, with no override.
    static func _hostControllerPhaseIsStructurallyLive() -> Bool? {
        structuralLiveness(of: .presentingController(controller: ControllerBox()))
    }

    /// Registers a real controller so liveness can be read against one the host
    /// is holding but has not placed.
    @available(iOS 17.0, *)
    static func _forcePresentingController(_ controller: OfferSheetViewController) {
        let coordinator = OfferSheetCoordinator(placementId: "test_placement", presentationTarget: .hostController)
        current = ActivePresentation(coordinator: coordinator, phase: .presentingController(controller: ControllerBox(controller)))
    }

    static func _currentPhaseIsStructurallyLive() -> Bool? {
        current.flatMap { structuralLiveness(of: $0.phase) }
    }

    /// Force-clear all state for test isolation.
    static func _forceReset() {
        current = nil
        _livenessOverride = nil
    }
    #endif
}
