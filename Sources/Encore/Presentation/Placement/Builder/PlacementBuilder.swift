// Placement builder — fluent API for presenting offers.
// Lives in Presentation/ because it coordinates UI presentation.
// Async-first: delegates directly to OfferSheetCoordinator.present(placementId:).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public Protocol

/// Fluent builder for presenting Encore offers.
/// Create via `Encore.placement(_:)` and call `show()` to present.
/// Main-actor isolated, like the ``Encore`` facade — build and show from UI code.
@MainActor
public protocol PlacementBuilderProtocol {
    var id: String { get }
    /// Presents the placement and returns the outcome. **Never throws** —
    /// failures arrive as `.notPresented(.error(…))`.
    func show() async -> PresentationResult
    /// Fire-and-forget present, then run `resume` on the main actor once the flow completes, with the PresentationResult. Delivers **every** outcome, including `.notPresented`.
    func show(resume: @escaping @Sendable (PresentationResult) -> Void)

    #if canImport(UIKit)
    /// Builds an offer controller for you to place, instead of presenting it.
    ///
    /// Push or present the returned controller from your own navigation stack.
    /// `nil` means the placement could not be presented. Encore's own builder
    /// also publishes that reason to ``Encore/outcomes``; a third-party
    /// conformer on the default implementation reports it through `resume`
    /// only, because no presentation was ever registered to report on.
    func makeViewController() async -> UIViewController?

    /// Builds an offer controller and delivers its terminal result.
    ///
    /// `resume` never runs before this call has returned, so you always hold the
    /// controller, or the `nil`, before your callback fires. It then runs before
    /// the controller removes itself, so you can replace or remove it first.
    /// Leave it in place and it pops, dismisses, or detaches the way it was
    /// added. When the
    /// placement cannot be built this returns `nil` and still calls `resume`.
    func makeViewController(resume: @escaping @Sendable (PresentationResult) -> Void) async -> UIViewController?
    #endif

    /// Warms this placement's offers so `show()` opens the sheet without a
    /// network round trip. A publisher-chosen id is stamped on the offers
    /// request so publisher analytics can break the funnel out by placement;
    /// a generated id (`placement()` with no argument) never travels — the
    /// backend buckets those as `(unlabeled)`.
    ///
    /// Call it when the surface comes into view, not at the trigger. Cheap to
    /// repeat: an offer set the SDK already holds is reused, not refetched.
    ///
    /// The warm resolves for the use case selected on the builder, so chain
    /// `.useCase(...)` before `.prefetch()` the same way you will before
    /// `show()` — each use case can render a different variant, and the warm
    /// must fill the set that variant's presentation will read.
    func prefetch()

    func onLoadingStateChange(_ callback: @escaping @Sendable (Bool) -> Void) -> Self

    /// Selects the use case this presentation belongs to. Defaults to `.reduceChurn`.
    ///
    /// ```swift
    /// Encore.shared.placement("streak_complete").useCase(.rewardUsers).show()
    /// ```
    func useCase(_ useCase: UseCase) -> Self

    /// Overrides the sheet's headline for this presentation.
    ///
    /// The full string is passed through as-is — the SDK never composes copy.
    /// Priority is SDK override → backend value → shipped template default.
    /// An empty string is ignored so it can't blank the shipped copy.
    func headline(_ text: String) -> Self

    /// Overrides the sheet's subheadline for this presentation.
    /// Same priority and empty-string rules as ``headline(_:)``.
    func subheadline(_ text: String) -> Self

    /// Overrides the primary button's label, on ``UseCase/rewardUsers`` only.
    /// Same priority and empty-string rules as ``headline(_:)``. On
    /// ``UseCase/reduceChurn`` the call is accepted and has no effect: no
    /// paywall template reads a button label yet.
    func cta(_ text: String) -> Self

    /// Overrides the decline button's label. Same rules as ``cta(_:)``,
    /// including the no-op on ``UseCase/reduceChurn``.
    func decline(_ text: String) -> Self

    /// Overrides the badge on the highlighted offer. Same rules as
    /// ``cta(_:)``, including the no-op on ``UseCase/reduceChurn``.
    func badge(_ text: String) -> Self

    /// Sets brand colours for this presentation, as the web SDK's `appearance` option.
    /// Last call wins; unset fields keep the sheet's defaults.
    func appearance(_ config: AppearanceConfig) -> Self

    /// Describes the prize your app pays for trying an offer. When the served variant
    /// asks "Did you finish?", the user says yes and Encore's server grants it, the
    /// result's `claim?.userConfirmedCompletion` is true: grant it then. Identified users only.
    /// When the app's reward settings pay on verification the flag stays false; the
    /// `offer_completed` webhook's `reward` pays instead, once per `transactionId`.
    func publisherReward(_ reward: PublisherReward) -> Self
}

public extension PlacementBuilderProtocol {
    /// Conformers that predate this requirement ignore appearance.
    func appearance(_ config: AppearanceConfig) -> Self { self }

    /// Conformers that predate this requirement pass no prize.
    func publisherReward(_ reward: PublisherReward) -> Self { self }

    /// Conformers that predate these keep the wording the backend serves.
    /// Defaults rather than bare requirements: a requirement added to a public
    /// protocol breaks every conformer outside this repo.
    func cta(_ text: String) -> Self { self }
    func decline(_ text: String) -> Self { self }
    func badge(_ text: String) -> Self { self }

    func show(resume: @escaping @Sendable (PresentationResult) -> Void) {
        Task { @MainActor in
            let result = await show()
            Logger.debug(.presentation, "resume firing with \(result)")
            resume(result)
        }
    }

    func prefetch() {
        Encore.shared.prefetchOffers(placementLabel: PlacementLabel.sanitized(id))
    }

    #if canImport(UIKit)
    /// A conformer that predates this requirement cannot build a controller.
    /// Reported as `.error(.domain)`, which serialises as `domain_error`.
    /// `.notConfigured` would call a configured placement unconfigured, and it
    /// is also what `.error(.integration(.notConfigured))` puts on the wire. A
    /// new `NotPresentedReason` case would be source-breaking.
    func makeViewController(resume: @escaping @Sendable (PresentationResult) -> Void) async -> UIViewController? {
        // Deferred for the same reason the coordinator defers: the contract
        // above says `resume` never runs before this call has returned, and
        // that has to hold on every path, including this one.
        Task { @MainActor in
            resume(.notPresented(.error(.domain(
                "This PlacementBuilderProtocol conformer does not implement makeViewController"
            ))))
        }
        return nil
    }

    func makeViewController() async -> UIViewController? {
        await makeViewController(resume: { _ in })
    }
    #endif
}

// MARK: - Internal Implementation

@MainActor
internal struct PlacementBuilder: PlacementBuilderProtocol {

    internal private(set) var id: String

    /// Publisher-chosen label, or nil when `placement()` generated the id.
    /// Only this reaches `/offers/search`.
    private let label: String?

    private var selectedUseCase: UseCase = .reduceChurn
    private var headlineOverride: String?
    private var subheadlineOverride: String?
    private var ctaOverride: String?
    private var declineOverride: String?
    private var badgeOverride: String?
    /// Readable for tests; set only through `appearance(_:)`.
    internal private(set) var appearanceOverride: AppearanceConfig?
    /// Readable for tests; set only through `publisherReward(_:)`.
    internal private(set) var resolvedPublisherReward: PublisherReward?

    private var onLoadingStateChangeCallback: (@Sendable (Bool) -> Void)?
    /// Set by a trigger that opens this sheet and attributes its tap to it.
    internal private(set) var suppliedPresentationId: String?
    /// Cancelling the calling task while the sheet still loads aborts it. Triggers' auto pops only.
    internal private(set) var cancelsWithTask = false

    internal init(id: String, label: String? = nil) {
        self.id = id
        self.label = label
    }

    // MARK: - Present

    func show() async -> PresentationResult {
        // Outcome is delivered via the returned PresentationResult / show(resume:).
        Logger.debug(.presentation, "show(\(id)) — presenting")
        onLoadingStateChangeCallback?(true)
        defer { onLoadingStateChangeCallback?(false) }

        let result = await OfferSheetCoordinator.present(
            placementId: id,
            placementLabel: label,
            useCase: selectedUseCase,
            copyOverrides: copyOverrides,
            appearance: appearanceOverride,
            publisherReward: resolvedPublisherReward,
            presentationId: suppliedPresentationId,
            cancelsWithTask: cancelsWithTask
        )
        Logger.info(.presentation, "show(\(id)) → \(result) | advertiser=\(String(describing: result.advertiser)) publisher=\(String(describing: result.publisher))")
        return result
    }

    #if canImport(UIKit)
    func makeViewController(resume: @escaping @Sendable (PresentationResult) -> Void) async -> UIViewController? {
        Logger.debug(.presentation, "makeViewController(\(id)) — preparing")
        onLoadingStateChangeCallback?(true)
        defer { onLoadingStateChangeCallback?(false) }

        let controller = await OfferSheetCoordinator.makeViewController(
            placementId: id,
            placementLabel: label,
            useCase: selectedUseCase,
            copyOverrides: copyOverrides,
            appearance: appearanceOverride,
            publisherReward: resolvedPublisherReward,
            resume: resume
        )
        Logger.info(.presentation, "makeViewController(\(id)) → \(controller == nil ? "not built" : "ready")")
        return controller
    }
    #endif

    // MARK: - Builder Methods

    func useCase(_ useCase: UseCase) -> PlacementBuilder {
        var copy = self
        copy.selectedUseCase = useCase
        return copy
    }

    /// Presents under `id` instead of a fresh one, so the trigger whose tap opened
    /// this sheet can put the same id on its tap event. Internal: triggers only.
    func presentationId(_ id: String) -> PlacementBuilder {
        var copy = self
        copy.suppliedPresentationId = id
        return copy
    }

    /// Aborts the sheet if the calling task is cancelled before it shows; once on screen it
    /// stays. Internal: a trigger's auto pop, which must not open for a mount that is gone.
    func cancellingWithTask() -> PlacementBuilder {
        var copy = self
        copy.cancelsWithTask = true
        return copy
    }

    func headline(_ text: String) -> PlacementBuilder {
        var copy = self
        copy.headlineOverride = text
        return copy
    }

    func subheadline(_ text: String) -> PlacementBuilder {
        var copy = self
        copy.subheadlineOverride = text
        return copy
    }

    func cta(_ text: String) -> PlacementBuilder {
        var copy = self
        copy.ctaOverride = text
        return copy
    }

    func decline(_ text: String) -> PlacementBuilder {
        var copy = self
        copy.declineOverride = text
        return copy
    }

    func badge(_ text: String) -> PlacementBuilder {
        var copy = self
        copy.badgeOverride = text
        return copy
    }

    func appearance(_ config: AppearanceConfig) -> PlacementBuilder {
        var copy = self
        copy.appearanceOverride = config
        return copy
    }

    func publisherReward(_ reward: PublisherReward) -> PlacementBuilder {
        var copy = self
        copy.resolvedPublisherReward = reward
        return copy
    }

    func onLoadingStateChange(_ callback: @escaping @Sendable (Bool) -> Void) -> PlacementBuilder {
        var copy = self
        copy.onLoadingStateChangeCallback = callback
        return copy
    }

    func prefetch() {
        // The builder's resolved use case travels with the warm: show() resolves
        // the variant per use case, so a warm that ignored the selection filled
        // a set the presentation could never hit whenever the variants differ.
        Encore.shared.prefetchOffers(placementLabel: label, useCase: selectedUseCase)
    }

    // MARK: - Internal

    /// The use case this builder presents under.
    internal var resolvedUseCase: UseCase { selectedUseCase }

    /// The label that travels on `/offers/search`, or nil for a generated id.
    internal var offerRequestLabel: String? { label }

    /// Copy overrides keyed by the template variable each one replaces.
    ///
    /// Resolved at `show()` time rather than inside `headline(_:)` so the chain
    /// is order-independent: `.headline(…).useCase(.rewardUsers)` and
    /// `.useCase(.rewardUsers).headline(…)` produce the same map. Blank is
    /// absent, so dashboard or backstop copy still renders.
    internal var copyOverrides: [String: String] {
        let pairs: [(String?, String)] = [
            (headlineOverride, selectedUseCase.headlineVariable),
            (subheadlineOverride, selectedUseCase.subheadlineVariable),
            (ctaOverride, selectedUseCase.ctaVariable),
            (declineOverride, selectedUseCase.declineVariable),
            (badgeOverride, selectedUseCase.badgeVariable),
        ]
        var overrides: [String: String] = [:]
        for (text, variable) in pairs {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            overrides[variable] = text
        }
        return overrides
    }
}
