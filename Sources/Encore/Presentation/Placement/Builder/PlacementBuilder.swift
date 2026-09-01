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
}

public extension PlacementBuilderProtocol {
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

    private var onLoadingStateChangeCallback: (@Sendable (Bool) -> Void)?

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
            copyOverrides: copyOverrides
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
    /// `.useCase(.rewardUsers).headline(…)` produce the same map.
    internal var copyOverrides: [String: String] {
        var overrides: [String: String] = [:]
        if let headlineOverride, !headlineOverride.isEmpty {
            overrides[selectedUseCase.headlineVariable] = headlineOverride
        }
        if let subheadlineOverride, !subheadlineOverride.isEmpty {
            overrides[selectedUseCase.subheadlineVariable] = subheadlineOverride
        }
        return overrides
    }
}
