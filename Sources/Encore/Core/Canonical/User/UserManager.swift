// Sources/Encore/Core/Canonical/User/UserManager.swift
//
// Manages user identity and attributes.
// Single source of truth for "who is logged in".
// Handles business logic; delegates data operations to repository.

import Foundation
import StoreKit
import UIKit

// MARK: - User Manager

/// Domain manager for user identity.
/// - Handles business logic (validation, state transitions, side effects)
/// - Delegates data operations to repository (local + remote)
/// - Does NOT know about analytics/errors — Encore facade handles those
internal final class UserManager {
    
    private let repository: UserRepository
    
    // MARK: - Init
    
    init(repository: UserRepository) {
        self.repository = repository
        Logger.debug(.user, "UserManager initialized with userId: \(repository.getUserId())")
    }
    
    // MARK: - Computed Properties
    
    var currentUserId: String {
        repository.getUserId()
    }
    
    /// Persistent person-level identifier. On iOS, backed by Apple's appTransactionID.
    /// Cross-device, cross-session, survives reinstalls. Nil on iOS <16 or if unresolved.
    var appAccountId: String? {
        repository.getAppAccountId()
    }
    
    /// Directly set appAccountId. Exposed for `@testable` test injection.
    func setAppAccountId(_ id: String) {
        repository.setAppAccountId(id)
    }
    
    /// Post-init async setup. Resolves persistent identifiers (e.g. appAccountId via StoreKit).
    func configure() {
        guard appAccountId == nil else { 
            Logger.debug(.user, "appAccountId is set so returning \(appAccountId)")
            return 
        }
        
        if #available(iOS 16.0, *) {
            Task {
                do {
                    let result = try await AppTransaction.shared
                    if case .verified(let appTransaction) = result,
                       let id = Self.extractAppTransactionID(from: appTransaction) {
                        repository.setAppAccountId(id)
                        Logger.debug(.user, "appAccountId resolved")
                        return
                    }
                } catch {
                    Logger.debug(.user, "AppTransaction.shared failed: \(error)")
                }
                
                #if DEBUG
                fallbackToSyntheticId()
                #endif
            }
        }
    }
    
    var userAttributes: UserAttributes {
        repository.getAttributes() ?? UserAttributes()
    }
    
    // MARK: - Identity Operations
    
    /// Identify user. Returns whether anything changed (userId or attributes).
    @discardableResult
    func identify(userId: String, attributes: UserAttributes? = nil) -> Bool {
        let previousUserId = currentUserId
        let userIdChanged = previousUserId != userId
        let effectiveAttributes = attributes.map { userAttributes.merged(with: $0) } ?? userAttributes
        let attributesChanged = userAttributes != effectiveAttributes

        guard userIdChanged || attributesChanged else {
            Logger.debug(.user, "Skipping duplicate identify for userId=\(userId)")
            return false
        }

        if userIdChanged {
            Logger.debug(.user, "User changed '\(previousUserId)' → '\(userId)'")
        }

        // Delegate data operation to repository (handles local + remote)
        repository.identify(currentUserId: previousUserId, newUserId: userId, attributes: attributes)

        return true
    }

    /// Merge new attributes into current. Returns merged result, or nil if nothing changed.
    @discardableResult
    func setAttributes(_ attributes: UserAttributes) -> UserAttributes? {
        let current = userAttributes
        let merged = current.merged(with: attributes)

        guard current != merged else {
            Logger.debug(.user, "Skipping duplicate setAttributes (no changes)")
            return nil
        }

        repository.updateAttributes(merged)
        return merged
    }
    
    /// Reset to anonymous user. Returns new anonymous userId.
    @discardableResult
    func reset() -> String {
        repository.clearAll()
        let newUserId = repository.getUserId()
        Logger.debug(.user, "Reset to anonymous user: \(newUserId)")
        return newUserId
    }
    
    // MARK: - Private
    
    /// Extract appTransactionID from AppTransaction's JSON payload.
    /// Uses jsonRepresentation (iOS 16+) since the typed property requires Xcode 16.4+ SDK.
    // TODO: Replace with `appTransaction.appTransactionID` when minimum Xcode is 16.4+
    @available(iOS 16.0, *)
    private static func extractAppTransactionID(from appTransaction: AppTransaction) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: appTransaction.jsonRepresentation) as? [String: Any],
              let id = json["appTransactionId"] as? String else {
            return nil
        }
        return id
    }
    
    #if DEBUG
    /// Synthetic fallback for Xcode/simulator builds where AppTransaction has no appTransactionId.
    /// Uses identifierForVendor for a stable-per-device ID so NCL flows are testable locally.
    private func fallbackToSyntheticId() {
        let syntheticId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        repository.setAppAccountId(syntheticId)
        Logger.warn(.user, "appAccountId unavailable — using synthetic DEBUG fallback \(syntheticId)")
    }
    #endif
}
