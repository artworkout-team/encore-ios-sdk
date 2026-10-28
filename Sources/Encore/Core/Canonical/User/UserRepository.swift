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
    /// The age the app set in this process, shared by every copy of this repository. Never saved: a
    /// saved age sent on a later launch would read as a fresh statement and freeze the age. The app keeps
    /// it current by setting it each launch, or by passing a date of birth, which is saved and turned
    /// into an age at every send.
    private let sessionAge = SessionAge()
    
    // MARK: - Storage Keys
    private enum Keys {
        static let userId = "com.encore.userId"
        static let userAttributes = "com.encore.userAttributes"
        static let appAccountId = "com.encore.appAccountId"
        static let languageOverride = "com.encore.languageOverride"
        static let identified = "com.encore.userIdentified"
    }
    
    init(storage: KeyValueStore, outbox: OutboxManaging? = nil) {
        self.storage = storage
        self.outbox = outbox
    }
    
    /// Makes "save the id, enqueue its job" one step across every copy of this
    /// struct. Without it an identify() on another thread could read a freshly
    /// minted id and enqueue its alias before that id's handshake, which leaves
    /// an orphan users row on the server.
    private static let identityWriteLock = NSLock()

    // MARK: - Read Operations
    
    /// Get user ID, creating and syncing if needed. Single source of truth.
    func getUserId() -> String {
        if let existing: String = storage.load(Keys.userId) {
            return existing
        }
        Self.identityWriteLock.lock()
        defer { Self.identityWriteLock.unlock() }
        // Another thread may have minted while this one waited.
        if let existing: String = storage.load(Keys.userId) {
            return existing
        }
        let newId = UUID().uuidString
        storage.save(newId, to: Keys.userId)
        outbox?.enqueue(.userInit(userId: newId, attributes: nil))
        return newId
    }
    
    /// The saved attributes with this launch's age. An age an earlier build saved is ignored.
    func getAttributes() -> UserAttributes? {
        let saved: UserAttributes? = storage.load(Keys.userAttributes)
        let age = sessionAge.value
        if saved == nil, age == nil { return nil }
        return (saved ?? UserAttributes()).withAge(age)
    }

    /// Saves everything but the age, which is held for this launch only.
    private func save(_ attributes: UserAttributes) {
        sessionAge.value = attributes.age
        storage.save(attributes.withAge(nil), to: Keys.userAttributes)
    }
    
    /// Persistent person-level identifier (Apple's appTransactionID on iOS).
    /// Survives reinstalls, device changes, and session resets.
    func getAppAccountId() -> String? {
        storage.load(Keys.appAccountId)
    }
    
    func setAppAccountId(_ id: String) {
        storage.save(id, to: Keys.appAccountId)
    }

    /// Whether the current user id came from the app's identify(), not the SDK: the
    /// bit identify() sets, or (for installs identified before 2.3.0) a stored id
    /// that isn't the shape the SDK mints.
    func isIdentified() -> Bool {
        if storage.load(Keys.identified) ?? false { return true }
        guard let id: String = storage.load(Keys.userId) else { return false }
        return !Self.isSDKMinted(id)
    }

    /// The anonymous id `getUserId()` mints: `UUID().uuidString`, uppercase.
    static func isSDKMinted(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.uppercased()
    }

    func markIdentified() {
        storage.save(true, to: Keys.identified)
    }
    
    // MARK: - Language Override (device-only, never synced)

    /// The host's `setLanguage` tag. Kept until cleared, across users and launches.
    func getLanguageOverride() -> String? {
        storage.load(Keys.languageOverride)
    }

    func setLanguageOverride(_ tag: String?) {
        if let tag {
            storage.save(tag, to: Keys.languageOverride)
        } else {
            storage.remove(Keys.languageOverride)
        }
    }

    /// Moves a `language` saved in the attributes by an older SDK into the
    /// override, once: it is removed from the attributes, so a later launch
    /// finds nothing to move. An override already set wins; an unreadable tag is dropped.
    func migrateLegacyLanguage() {
        guard let attributes = getAttributes(), let legacy = attributes.languageTag else { return }
        if getLanguageOverride() == nil, let tag = LanguageTag.normalizedLegacy(legacy) {
            setLanguageOverride(tag)
        }
        save(attributes.withLanguage(nil))
    }

    // MARK: - Transactional Operations (Local + Remote)
    
    /// Set a specific user ID and sync. Used for tests and explicit state setup.
    func initialize(userId: String, attributes: UserAttributes?) {
        Self.identityWriteLock.lock()
        defer { Self.identityWriteLock.unlock() }
        storage.save(userId, to: Keys.userId)
        if let attributes {
            save(attributes)
        }
        outbox?.enqueue(.userInit(userId: userId, attributes: attributes))
    }
    
    /// Identify/re-identify a user. Persists locally AND syncs to backend.
    func identify(currentUserId: String, newUserId: String, attributes: UserAttributes?) {
        Self.identityWriteLock.lock()
        defer { Self.identityWriteLock.unlock() }
        // 1. Local persistence
        storage.save(newUserId, to: Keys.userId)
        if let attributes {
            save(attributes)
        }
        
        // 2. Remote sync
        outbox?.enqueue(.userIdentify(currentUserId: currentUserId, newUserId: newUserId, attributes: attributes))
    }
    
    /// Update user attributes. Local-only (no remote sync for attributes alone).
    func updateAttributes(_ attributes: UserAttributes) {
        save(attributes)
    }
    
    /// Clear all user data from local storage.
    func clearAll() {
        storage.remove(Keys.userId)
        storage.remove(Keys.userAttributes)
        storage.remove(Keys.identified)
        sessionAge.value = nil
    }
}

/// The in-process age (see `UserRepository.sessionAge`), a reference so every copy of the repository shares it.
private final class SessionAge: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
