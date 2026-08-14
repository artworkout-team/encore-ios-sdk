// Sources/Encore/Core/Infrastructure/Experiments/ExperimentRepository.swift
//
// Repository for experiment data access.
// Handles local persistence of cohort assignments.
//
// With deterministic cohort assignment (SHA256), stored values are a cache.
// Clearing them (reinstall) just forces a recomputation to the same result.

import Foundation

// MARK: - Experiment Repository

/// Repository for experiment cohort persistence.
/// Local-only storage (cohort assignment is client-side).
internal struct ExperimentRepository {
    private let storage: KeyValueStore
    
    // MARK: - Storage Keys
    
    private enum Keys {
        static let nclAssignment = "com.encore.experiment.ncl.assignment"
    }
    
    init(storage: KeyValueStore) {
        self.storage = storage
    }
    
    // MARK: - NCL Assignment
    
    /// Get cached NCL assignment (cohort + version).
    func getNCLAssignment() -> NCLAssignment? {
        storage.load(Keys.nclAssignment)
    }
    
    /// Cache NCL assignment (cohort + version).
    func saveNCLAssignment(_ assignment: NCLAssignment) {
        storage.save(assignment, to: Keys.nclAssignment)
        Logger.debug(.experiments, "Saved NCL assignment: \(assignment.cohort.rawValue) v\(assignment.assignmentVersion)")
    }
}
