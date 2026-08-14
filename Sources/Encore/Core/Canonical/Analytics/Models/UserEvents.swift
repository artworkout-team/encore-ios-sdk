//
//  User.swift
//  Encore
//
//  Analytics events for user identification and attributes.
//

import Foundation

// MARK: - User Events

/// Tracked when a user is identified
struct UserIdentifiedEvent: AnalyticsEvent {
    static let eventName = "user_identified"
    
    let userId: String
    let appBundleId: String
    let attributes: UserAttributes?
    
    init(userId: String, appBundleId: String = Bundle.main.bundleIdentifier ?? "unknown", attributes: UserAttributes? = nil) {
        self.userId = userId
        self.appBundleId = appBundleId
        self.attributes = attributes
    }
}
