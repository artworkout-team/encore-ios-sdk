// Sources/Encore/Features/Entitlements/EntitlementManager.swift
//
// Manages the hybrid entitlement system with provisional and verified entitlements.
// Reactive domain service - exposes @Published state for UI binding.
// @MainActor ensures all state access is thread-safe on the main thread.
//
// NOTE: User identity (userId, attributes) is managed by UserManager.
// EntitlementManager reads user data from UserRepository when needed.

import Foundation
import Combine

// MARK: - Entitlement Manager

/// Reactive domain service for the hybrid entitlement system.
/// Handles provisional + verified entitlements with caching and smart refresh.
internal class EntitlementManager {
    
    // MARK: - Dependencies
    
    private let entitlementsRepository: EntitlementsRepository
    private let userRepository: UserRepository
    
    // MARK: - Reactive State
    
    @Published internal private(set) var entitlements: Entitlements?

    // MARK: - Entitlement State
    
    /// Thread-safe tracking of expirations we've already refreshed for.
    /// Uses Atomic wrapper to prevent use-after-free from concurrent Set access.
    private let refreshedExpirations = Atomic<Set<String>>(Set())
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - User Data (Read-through to UserRepository)
    
    /// Current user ID. Reads from UserRepository (managed by UserManager).
    var currentUserId: String {
        userRepository.getUserId()
    }
    
    /// Current user attributes. Reads from UserRepository (managed by UserManager).
    var userAttributes: UserAttributes {
        userRepository.getAttributes() ?? UserAttributes()
    }
    
    // MARK: - Init
    
    internal init(entitlementsRepository: EntitlementsRepository, userRepository: UserRepository) {
        self.entitlementsRepository = entitlementsRepository
        self.userRepository = userRepository
        
        // Load cached entitlements state (user data is read-through via computed properties)
        entitlements = entitlementsRepository.getLocal()
        refreshedExpirations.value = entitlementsRepository.getRefreshedExpirations()
        Logger.debug(.entitlements, "Loaded \(refreshedExpirations.value.count) refreshed expirations")
        
        // Subscribe to app foreground events
        subscribeToLifecycle()
    }
    
    private func subscribeToLifecycle() {
        Encore.shared.lifecycle?.didForeground
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Logger.debug(.entitlements, "App foregrounded - refreshing")
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.refreshEntitlements()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - State Management
    
    /// Clears all entitlement state. Optionally refreshes for new user.
    internal func reset(thenRefresh: Bool = false) {
        Logger.debug(.entitlements, "Reset - clearing cached entitlements")
        entitlements = nil
        refreshedExpirations.mutate { $0.removeAll() }
        entitlementsRepository.clearAll()
        
        if thenRefresh {
            Task { [weak self] in
                guard let self else { return }
                try? await self.refreshEntitlements()
            }
        }
    }
    
    // MARK: - Entitlement Operations
    
    /// Refreshes entitlements from the server.
    internal func refreshEntitlements() async throws {
        // Capture userId at request time to detect stale responses.
        // Race condition: if identify() is called mid-flight, this response is for the old user.
        let requestUserId = currentUserId
        let response = try await entitlementsRepository.getRemote(userId: requestUserId)
        
        guard requestUserId == currentUserId else {
            Logger.debug(.entitlements, "Discarding stale refresh (user changed)")
            return
        }
        
        // Server-authoritative: the response replaces local state wholesale.
        // (The migration-era preservative merge was removed in 2.0.0.)
        // Write on main thread to prevent races with UI reads
        await MainActor.run { self.entitlements = response }
    }
    
    /// Revokes all entitlements for the current user.
    internal func revokeEntitlements() async throws {
        let requestUserId = currentUserId
        let response = try await entitlementsRepository.revokeRemote(userId: requestUserId)
        
        guard requestUserId == currentUserId else {
            Logger.debug(.entitlements, "Discarding stale revoke (user changed)")
            return
        }
        
        // Write on main thread to prevent races with UI reads
        await MainActor.run { self.entitlements = response }
        Logger.debug(.entitlements, "Revoked entitlements")
    }
    
    // MARK: - Smart Refresh
    
    /// Refresh if needed: first load always refreshes, verified scope triggers smart refresh.
    internal func smartRefresh(
        for type: Entitlement,
        scope: EntitlementScope,
        entitlements: Entitlements? = nil,
        at date: Date = Date()
    ) async {
        let currentEntitlements = entitlements ?? self.entitlements
        
        guard let currentEntitlements else {
            try? await refreshEntitlements()
            return
        }
        
        guard scope == .verified else { return }
        
        if Self.isActive(type, in: currentEntitlements.provisional, now: date)
            || Self.isActive(type, in: currentEntitlements.verified, now: date) { return }
        
        guard let expiresAt = getProvisionalExpiresAt(type: type, from: currentEntitlements) else { return }
        
        let expirationKey = "\(String(describing: type))_\(expiresAt.timeIntervalSince1970)"
        
        // Atomic check-and-insert using lock to prevent use-after-free crashes
        let shouldRefresh = refreshedExpirations.mutate { set -> Bool in
            guard !set.contains(expirationKey) else { return false }
            set.insert(expirationKey)
            return true
        }
        
        guard shouldRefresh else { return }
        entitlementsRepository.saveRefreshedExpirations(refreshedExpirations.value)
        Logger.debug(.entitlements, "SMART REFRESH for \(type)")
        try? await refreshEntitlements()
    }
    
    private func getProvisionalExpiresAt(type: Entitlement, from entitlements: Entitlements) -> Date? {
        switch type {
        case .freeTrial: return entitlements.provisional?.freeTrial?.expiresAt
        case .discount: return entitlements.provisional?.discounts?.first?.expiresAt
        case .credit: return entitlements.provisional?.credits?.expiresAt
        }
    }
    
    // MARK: - Entitlement Checks (Pure Static)
    
    /// Check if entitlement is active within a scope. Pure snapshot evaluation.
    internal static func isActive(
        _ type: Entitlement,
        scope: EntitlementScope,
        in snapshot: Entitlements,
        now: Date = Date()
    ) -> Bool {
        switch scope {
        case .verified:
            return Self.isActive(type, in: snapshot.provisional, now: now)
                || Self.isActive(type, in: snapshot.verified, now: now)
        case .all:
            return Self.isActive(type, in: snapshot.all, now: now)
        }
    }
    
    /// Check if entitlement is active within a details section.
    private static func isActive(
        _ type: Entitlement,
        in details: EntitlementDetails?,
        now: Date
    ) -> Bool {
        guard let details else { return false }
        
        func isNotExpired(_ expiresAt: Date?) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > now
        }
        
        switch type {
        case .freeTrial:
            guard let freeTrial = details.freeTrial else { return false }
            return isNotExpired(freeTrial.expiresAt)
        case .discount:
            guard let discounts = details.discounts else { return false }
            return discounts.contains { isNotExpired($0.expiresAt) }
        case .credit:
            guard let credits = details.credits else { return false }
            return isNotExpired(credits.expiresAt)
        }
    }
}

