// Sources/Encore/Core/Infrastructure/Experiments/Experiment.swift
//
// Domain models for A/B experiments.

import Foundation

// MARK: - Cohort

/// Experiment cohort assignment.
/// - `.treatment`: User sees the Encore paywall
/// - `.control`: User experiences "Ghost Trigger" (no UI, but exposure logged)
/// - `.notEnrolled`: Experiment disabled or config unavailable (fallback to treatment behavior)
public enum Cohort: String, Codable, Sendable {
    case treatment
    case control
    case notEnrolled
}

// MARK: - NCL Assignment

/// Persisted NCL experiment assignment state.
internal struct NCLAssignment: Codable {
    let cohort: Cohort
    let assignmentVersion: Int
}
