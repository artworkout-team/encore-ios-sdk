// Sources/Encore/Core/Canonical/UseCase.swift
//
// Why an Encore sheet is presented. Selects the template the backend resolves
// for /config, and travels onto every offer event so the funnel can be split
// per use case.

import Foundation

// MARK: - Use Case

/// The reason an Encore sheet is being presented.
///
/// A use case is a first-class dimension, not a placement: a placement is
/// publisher free text ("post_workout_v2"), a use case is an Encore enum that
/// selects which template the backend resolves. One use case holds many
/// placements.
///
/// Case names name the CAPABILITY (renamed 2026-08-12, ratified cross-SDK).
/// The raw values are the wire format — they are the `sdui_use_case` values the
/// backend stores, frozen and deliberately unrelated to the case names: they
/// are pinned explicitly here rather than derived from the Swift identifier so
/// that renaming a case can never silently change what goes over the wire.
///
/// ```swift
/// Encore.shared.placement("streak_complete")
///     .useCase(.rewardUsers)
///     .headline("That's three days in a row staying informed 🔥")
///     .subheadline("Here's a little thank you from us")
///     .show()
/// ```
public enum UseCase: String, Sendable, CaseIterable, Equatable {

    /// Second-chance monetisation after a paywall decline. The default, and
    /// the only use case the NCL experiment measures.
    case reduceChurn = "churn-intervention"

    /// Thanking the user for something they already did — a completed
    /// purchase, a milestone, a streak, a new level. The trigger varies; what
    /// they have in common is that the user is being rewarded rather than
    /// sold to, so this is claim-only and never presents an in-app purchase.
    ///
    /// A specific trigger (e.g. streaks) is a *variant* inside this use case,
    /// not a use case of its own.
    case rewardUsers = "post-action-reward"
}

// MARK: - Internal Behaviour

internal extension UseCase {

    /// Template variable that `PlacementBuilder.headline(_:)` overwrites.
    ///
    /// These are SDUI template variable names owned by the backend variant
    /// JSON, not use case values — they are deliberately unrelated to the
    /// case's raw value.
    var headlineVariable: String {
        switch self {
        case .reduceChurn: "customHeadline"
        case .rewardUsers: "rewardHeadline"
        }
    }

    /// Template variable that `PlacementBuilder.subheadline(_:)` overwrites.
    var subheadlineVariable: String {
        switch self {
        case .reduceChurn: "customSubheadline"
        case .rewardUsers: "rewardSubheadline"
        }
    }

    /// Whether `/config` needs the `useCase` query parameter.
    ///
    /// Omitted for `.reduceChurn` so the request stays byte-identical to
    /// what every already-shipped SDK sends — the backend defaults to churn
    /// intervention when absent.
    var needsConfigQueryParameter: Bool { self != .reduceChurn }

    /// Whether this use case may reach StoreKit at all.
    ///
    /// Post-action reward is claim-only: no IAP product fetch, no IAP-First
    /// branch, no entitlement written on claim.
    var allowsIAP: Bool { self == .reduceChurn }

    // NOTE: no entitlement-on-claim flag here (2026-08-11 decision): whether a
    // claim unlocks is VARIANT policy, not use-case policy, and results carry
    // raw facts only.

    /// Whether this use case may fall back to ITS OWN embedded floor when no
    /// remote template resolves.
    ///
    /// True for every use case: each ships its own floor, so the refused
    /// combination is cross-use-case fallback (a reward surface must never
    /// render the paywall sheet), not fallback itself.
    var allowsFallbackLayout: Bool { true }

    /// Whether a fresh `/config` response that resolved no template is an
    /// explicit server "no" (decline) rather than a knowledge gap.
    ///
    /// False for churn intervention: no remote kill switch exists on the wire
    /// for it (`ui.values` is a closed schema, nothing on `/config` can carry
    /// the signal), so a fresh null churn template only ever means "nothing
    /// resolved" and the embedded floor is the revenue safety net. True for
    /// every other use case: the prefetch block's "enabled but nothing to
    /// render" IS a resolved server answer there.
    var resolvedNullDeclines: Bool { self != .reduceChurn }
}
