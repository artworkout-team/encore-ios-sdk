// Sources/Encore/Core/Infrastructure/Experiments/ExperimentManager.swift
//
// Manages A/B experiment cohort assignment for NCL.
// Cross-cutting measurement infrastructure (like Analytics/Outbox).
//
// Reads appAccountId from UserManager (resolved at configure time by ServiceContainer).
// Cohort is deterministic: SHA256(appAccountId + version) % 100.
// UserDefaults cache avoids re-hashing on every call.
// Clearing the cache (reinstall) recomputes to the same value.

import Foundation
import CryptoKit

// MARK: - Experiment Manager

/// Manages NCL (Net Conversion Lift) experiment cohort assignment.
///
/// **Reads `appAccountId` from `UserManager`** — the persistent person-level identifier
/// (Apple's appTransactionID on iOS). ServiceContainer resolves it at configure time.
///
/// **Deterministic Cohorts:** Cohort is derived from `appAccountId` and `assignmentVersion`.
/// Same person always gets the same cohort on any device.
/// Bumping `assignmentVersion` server-side re-buckets all users (clean epoch).
///
/// **No reset():** Cohort is a pure function of immutable inputs — nothing to reset.
internal final class ExperimentManager {
    
    // MARK: - Dependencies
    
    private let repository: ExperimentRepository
    
    // MARK: - Initialization
    
    init(repository: ExperimentRepository) {
        self.repository = repository
    }
    
    // MARK: - Cohort Assignment
    
    /// Gets the current cohort for the NCL experiment.
    ///
    /// **Behavior:**
    /// 1. If `appAccountId` unavailable (iOS <16 or unverified) → `.notEnrolled`
    /// 2. If experiment is disabled or config unavailable → `.notEnrolled`
    /// 3. If cached cohort exists for current version → returns cached
    /// 4. Otherwise → deterministic assignment via SHA256 hash
    func getCohort() -> Cohort {
        guard userManager?.appAccountId != nil else {
            return .notEnrolled
        }
        
        guard let nclConfig = remoteConfigManager?.experiments?.ncl else {
            return .notEnrolled
        }
        
        guard nclConfig.enabled else {
            return .notEnrolled
        }
        
        let currentVersion = nclConfig.assignmentVersion
        
        if let stored = repository.getNCLAssignment(),
           stored.assignmentVersion == currentVersion {
            return stored.cohort
        }
        
        let cohort = assignCohort(rolloutPct: nclConfig.rolloutPct, version: currentVersion)
        let assignment = NCLAssignment(cohort: cohort, assignmentVersion: currentVersion)
        repository.saveNCLAssignment(assignment)
        
        Logger.info(.experiments, "Assigned cohort: \(cohort.rawValue) (version \(currentVersion), rollout \(nclConfig.rolloutPct)%)")
        return cohort
    }
    
    // MARK: - Hash (internal for testability)
    
    /// Deterministic cohort assignment: SHA256(appAccountId:version) % 100.
    /// CryptoKit SHA256 output is uniformly distributed — mod 100 has negligible bias.
    func assignCohort(appAccountId: String, rolloutPct: Int, version: Int) -> Cohort {
        let input = "\(appAccountId):\(version)"
        let digest = SHA256.hash(data: Data(input.utf8))
        
        let hashBytes = Array(digest.prefix(8))
        let hashValue = hashBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let bucket = Int(hashValue % 100)
        
        return bucket < rolloutPct ? .treatment : .control
    }
    
    /// Convenience that reads appAccountId from UserManager.
    private func assignCohort(rolloutPct: Int, version: Int) -> Cohort {
        guard let appAccountId = userManager?.appAccountId else { return .control }
        return assignCohort(appAccountId: appAccountId, rolloutPct: rolloutPct, version: version)
    }
}
