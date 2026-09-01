// Sources/Encore/Core/Canonical/User/UserRepository.swift
//
// Repository for user identity and attributes.
// Encapsulates ALL data sources (local storage + remote sync via outbox).
// Manager handles business logic; Repository handles data consistency.

import Foundation

// MARK: - User Repository

/// Repository for user identity and attributes.
/// Encapsulates both local persistence AND remote synchronization.
/// Each transactional method ensures data consistency across all data sources.
internal struct UserRepository {
    private let storage: KeyValueStore
    private let outbox: OutboxManaging?
    
    // MARK: - Storage Keys
    private enum Keys {
        static let userId = "com.encore.userId"
        static let userAttributes = "com.encore.userAttributes"
        static let appAccountId = "com.encore.appAccountId"
    }
    
    init(storage: KeyValueStore, outbox: OutboxManaging? = nil) {
        self.storage = storage
        self.outbox = outbox
    }
    
    // MARK: - Read Operations
    
    /// Get user ID, creating and syncing if needed. Single source of truth.
    func getUserId() -> String {
        if let existing: String = storage.load(Keys.userId) {
            return existing
        }
        let newId = UUID().uuidString
        storage.save(newId, to: Keys.userId)
        outbox?.enqueue(.userInit(userId: newId, attributes: nil))
        return newId
    }
    
    /// Get user attributes from local storage.
    func getAttributes() -> UserAttributes? {
        storage.load(Keys.userAttributes)
    }
    
    /// Persistent person-level identifier (Apple's appTransactionID on iOS).
    /// Survives reinstalls, device changes, and session resets.
    func getAppAccountId() -> String? {
        storage.load(Keys.appAccountId)
    }
    
    func setAppAccountId(_ id: String) {
        storage.save(id, to: Keys.appAccountId)
    }
    
    // MARK: - Transactional Operations (Local + Remote)
    
    /// Set a specific user ID and sync. Used for tests and explicit state setup.
    func initialize(userId: String, attributes: UserAttributes?) {
        storage.save(userId, to: Keys.userId)
        if let attributes {
            storage.save(attributes, to: Keys.userAttributes)
        }
        outbox?.enqueue(.userInit(userId: userId, attributes: attributes))
    }
    
    /// Identify/re-identify a user. Persists locally AND syncs to backend.
    func identify(currentUserId: String, newUserId: String, attributes: UserAttributes?) {
        // 1. Local persistence
        storage.save(newUserId, to: Keys.userId)
        if let attributes {
            storage.save(attributes, to: Keys.userAttributes)
        }
        
        // 2. Remote sync
        outbox?.enqueue(.userIdentify(currentUserId: currentUserId, newUserId: newUserId, attributes: attributes))
    }
    
    /// Update user attributes. Local-only (no remote sync for attributes alone).
    func updateAttributes(_ attributes: UserAttributes) {
        storage.save(attributes, to: Keys.userAttributes)
    }
    
    /// Clear all user data from local storage.
    func clearAll() {
        storage.remove(Keys.userId)
        storage.remove(Keys.userAttributes)
    }
}
