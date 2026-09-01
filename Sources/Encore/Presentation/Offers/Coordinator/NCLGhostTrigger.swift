// Sources/Encore/Presentation/Offers/Coordinator/NCLGhostTrigger.swift
//
// The NCL experiment intercept that runs before any offer sheet is presented.
// Split out of OfferSheetCoordinator so "which use cases does NCL apply to" is
// one decision in one place, and directly testable.

import Foundation

// MARK: - NCL Ghost Trigger

/// The NCL (Net Conversion Lift) experiment intercept.
///
/// NCL measures second-chance monetisation of a **paywall decline**. Two things
/// happen here before a sheet is shown: an exposure is logged for the assigned
/// cohort, and the UI is suppressed for Control (the "Ghost Trigger").
///
/// Both are scoped to `.reduceChurn`. Every other use case skips the intercept
/// entirely — no cohort read *and* no exposure. The exposure matters as much as
/// the suppression: an exposure enqueued from a reward surface would inflate
/// NCL's enrolled population along a path that has nothing to do with paywall
/// declines. Downstream that reads as a sample-ratio mismatch, which
/// triggers a phantom assignment-version bump and re-buckets every user.
/// (Decision D-6.)
internal enum NCLGhostTrigger {

    // MARK: - Outcome

    /// What the caller should do next.
    enum Outcome: Equatable {
        /// Show the sheet. Cohort is Treatment, or the user isn't enrolled.
        case proceed
        /// Control cohort — return `.notGranted(.experimentControl)`, no UI.
        case suppress
        /// The use case is outside the experiment. No cohort was read and no
        /// exposure was logged.
        case skipped
    }

    // MARK: - Scope

    /// Whether the NCL experiment applies to `useCase`.
    static func applies(to useCase: UseCase) -> Bool {
        useCase == .reduceChurn
    }

    // MARK: - Evaluation

    /// Runs the intercept for `useCase`.
    ///
    /// The two collaborators are injected with production defaults so tests can
    /// assert that neither is *reached* for a use case other than churn intervention — the
    /// property a return-value assertion alone cannot express.
    static func evaluate(
        useCase: UseCase,
        cohortProvider: () -> Cohort = { experimentManager?.getCohort() ?? .notEnrolled },
        logExposure: (Cohort) -> Void = { defaultLogExposure($0) }
    ) -> Outcome {
        guard applies(to: useCase) else {
            Logger.debug(.experiments, "NCL does not apply to useCase=\(useCase.rawValue) — no cohort read, no exposure")
            return .skipped
        }

        let cohort = cohortProvider()

        // Exposure is logged for BOTH cohorts (critical for NCL measurement),
        // but only once the user is actually enrolled.
        if cohort != .notEnrolled {
            logExposure(cohort)
        }

        guard cohort != .control else { return .suppress }

        Logger.debug(.experiments, "Cohort: \(cohort.rawValue) - proceeding with presentation")
        return .proceed
    }

    // MARK: - Exposure

    /// Enqueues the exposure on the reliable outbox. No-ops until the
    /// assignment version resolves. Deliberately independent of `appAccountId`:
    /// it resolves asynchronously from StoreKit, and gating on it dropped
    /// first-session users out of the denominator while they still reached the
    /// numerator.
    static func defaultLogExposure(
        _ cohort: Cohort,
        variantId: String? = nil,
        useCase: UseCase = .reduceChurn,
        placementId: String? = nil
    ) {
        guard let assignmentVersion = remoteConfigManager?.experiments?.ncl?.assignmentVersion,
              let outbox = Encore.shared.services?.outbox else { return }

        outbox.enqueue(.experimentExposure(
            distinctId: EventEnvelope.resolveDistinctId(),
            appAccountId: userManager?.appAccountId,
            experiment: "ncl",
            cohort: cohort,
            assignmentVersion: assignmentVersion,
            variantId: variantId,
            useCase: useCase,
            placementId: placementId
        ))
        Logger.debug(.experiments, "Logged exposure: cohort=\(cohort.rawValue), version=\(assignmentVersion)")
    }
}
