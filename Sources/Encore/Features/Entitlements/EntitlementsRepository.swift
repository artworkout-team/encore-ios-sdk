// Sources/Encore/Features/Entitlements/EntitlementsRepository.swift
//
// Repository for entitlement data access.
// Handles both network (remote) and local persistence.
// Owns semantic storage keys (what to store), delegates mechanism to KeyValueStore (how to store).

import Foundation

// MARK: - Entitlements Repository

/// Repository for entitlements data access.
/// Provides explicit `getLocal()` and `getRemote()` methods so the Manager
/// can make informed decisions about latency and freshness.
internal struct EntitlementsRepository {
    private let client: HTTPClientProtocol
    private let storage: KeyValueStore
    
    // MARK: - Storage Keys (Repository owns the schema)
    private enum Keys {
        static let entitlements = "com.encore.entitlements"
        static let refreshedExpirations = "com.encore.refreshedExpirations"
    }
    
    init(client: HTTPClientProtocol, storage: KeyValueStore) {
        self.client = client
        self.storage = storage
    }
    
    // MARK: - Local Access (Sync, Disk/Cache)
    
    /// Get entitlements from local storage.
    /// Synchronous - returns immediately from cache.
    func getLocal() -> Entitlements? {
        storage.load(Keys.entitlements)
    }
    
    /// Save entitlements to local storage.
    func saveLocal(_ entitlements: Entitlements) {
        storage.save(entitlements, to: Keys.entitlements)
        Logger.debug(.entitlements, "Saved entitlements to local storage")
    }
    
    /// Clear entitlements from local storage.
    func clearLocal() {
        storage.remove(Keys.entitlements)
    }
    
    // MARK: - Remote Access (Async, Network)
    
    /// Get entitlements from remote server.
    ///
    /// Asynchronous - hits network.
    ///
    /// - **Invariant:** Automatically updates local cache (Write-Through) to ensure
    ///   subsequent `getLocal()` calls return fresh data. This is not configurable;
    ///   the Repository guarantees cache coherence.
    func getRemote(userId: String) async throws -> Entitlements {
        Logger.debug(.entitlements, "Fetching entitlements from remote for user: \(userId)")
        
        let response: EntitlementsResponse = try await client.request(
            path: "entitlements",
            method: "GET",
            body: nil,
            query: ["userId": userId]
        )
        
        guard response.success else {
            throw EncoreError.protocol(.api(status: 400, code: "fetch_failed", message: "Failed to fetch entitlements"))
        }
        
        let entitlements = Entitlements(from: response)
        saveLocal(entitlements)
        
        Logger.debug(.entitlements, "Successfully fetched entitlements from remote")
        return entitlements
    }
    
    /// Revoke all entitlements via remote server.
    ///
    /// Asynchronous - hits network.
    ///
    /// - **Invariant:** Automatically updates local cache (Write-Through) with the
    ///   revoked state to ensure subsequent `getLocal()` calls reflect the revocation.
    func revokeRemote(userId: String) async throws -> Entitlements {
        let request = DTO.Entitlements.RevokeRequest(userId: userId)
        
        Logger.debug(.entitlements, "Revoking entitlements via remote for user: \(userId)")
        
        let response: EntitlementsResponse = try await client.request(
            path: "entitlements/revoke",
            method: "POST",
            body: request,
            query: nil
        )
        
        guard response.success else {
            throw EncoreError.protocol(.api(status: 400, code: "revoke_failed", message: "Failed to revoke entitlements"))
        }
        
        let entitlements = Entitlements(from: response)
        saveLocal(entitlements)
        
        Logger.debug(.entitlements, "Successfully revoked entitlements via remote")
        return entitlements
    }
    
    // MARK: - Smart Refresh Tracking (Local)
    
    /// Get refreshed expirations from local storage.
    func getRefreshedExpirations() -> Set<String> {
        let array: [String]? = storage.load(Keys.refreshedExpirations)
        return Set(array ?? [])
    }
    
    /// Save refreshed expirations to local storage.
    func saveRefreshedExpirations(_ expirations: Set<String>) {
        storage.save(Array(expirations), to: Keys.refreshedExpirations)
    }
    
    /// Clear refreshed expirations from local storage.
    func clearRefreshedExpirations() {
        storage.remove(Keys.refreshedExpirations)
    }
    
    // MARK: - Full Reset
    
    /// Clears all persisted entitlement data (for user reset/logout)
    func clearAll() {
        clearLocal()
        clearRefreshedExpirations()
    }
}
