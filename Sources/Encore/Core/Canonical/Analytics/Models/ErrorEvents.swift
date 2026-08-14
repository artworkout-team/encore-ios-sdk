//
//  ErrorEvents.swift
//  Encore
//
//  Analytics events for error tracking.
//

import Foundation

// MARK: - Error Events

/// Tracked when an SDK error occurs
struct SDKErrorEvent: AnalyticsEvent {
    static let eventName = "sdk_error"
    
    let errorType: String
    let errorDescription: String
    let context: String
    
    init(error: EncoreError, context: ErrorContext) {
        self.errorType = String(describing: error)
        self.errorDescription = error.errorDescription ?? "Unknown error"
        self.context = context.rawValue
    }
}

// Note: ErrorContext is defined in Domain/Entities/Error.swift

