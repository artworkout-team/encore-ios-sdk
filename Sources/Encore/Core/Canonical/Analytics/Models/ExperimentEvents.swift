// Sources/Encore/Core/Canonical/Analytics/Models/ExperimentEvents.swift
//
// Analytics events for A/B experiment tracking.
//

import Foundation

// MARK: - Experiment Exposure Event

/// Tracked when a user is exposed to an experiment at the trigger point.
/// Logged for BOTH Control and Treatment cohorts to establish the denominator.
///
/// **Critical for NCL measurement:**
/// - Control: Ghost Trigger (no UI shown, but exposure logged)
/// - Treatment: Paywall shown
///
/// This event is routed through the reliable outbox (not fire-and-forget analytics)
/// to guarantee delivery for accurate measurement.
struct ExperimentExposureEvent: AnalyticsEvent {
    static let eventName = "sdk_experiment_exposure"
    
    /// Experiment identifier (e.g., "ncl")
    let experiment: String
    
    /// Assigned cohort ("control" or "treatment")
    let cohort: String
    
    /// Assignment version for this experiment epoch
    let assignmentVersion: Int

    /// Use case whose presentation logged this exposure. Always
    /// `churn-intervention` today — NCL is scoped to it (D-6) — but stamped
    /// rather than assumed, so the day another surface enters the experiment
    /// the historical rows stay readable.
    let useCase: String

    /// Publisher placement that triggered the presentation.
    let placementId: String?
}
