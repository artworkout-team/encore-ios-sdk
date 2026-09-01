//
//  AppEvents.swift
//  Encore
//
//  Analytics events for SDK and app lifecycle.
//

import Foundation

// MARK: - SDK Lifecycle Events

/// Tracked when the SDK is initialized
struct SDKInitializedEvent: AnalyticsEvent {
    static let eventName = "sdk_initialized"
    
    let sdkVersion: String
    let appBundleId: String
    let platform: String = "ios"
}

// MARK: - App Lifecycle Events

/// Tracked when the app returns to foreground
struct AppForegroundedEvent: AnalyticsEvent {
    static let eventName = "sdk_app_foregrounded"
    
    let appBundleId: String
}

/// Tracked when the app enters background
struct AppBackgroundedEvent: AnalyticsEvent {
    static let eventName = "sdk_app_backgrounded"
    
    let appBundleId: String
    let offerSheetVisible: Bool
}

/// Tracked when the app is terminated
struct AppTerminatedEvent: AnalyticsEvent {
    static let eventName = "sdk_app_terminated"
    
    let appBundleId: String
    let offerSheetVisible: Bool
}
