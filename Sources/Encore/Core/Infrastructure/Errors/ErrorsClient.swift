// Core/Infrastructure/Errors/Errors.swift
//
// Error reporting client with userId context.
// Stores userId for automatic error attribution.
//

import Foundation

// MARK: - Errors Client

/// Error reporting client for the Encore SDK.
/// Stores userId so error reports are attributed to the current user.
internal final class ErrorsClient {
    
    // MARK: - Properties
    
    private let providers: [ErrorProvider]
    private let sdkVersion: String
    
    /// Current user ID for error attribution. Atomic for thread-safe access.
    private let userId = Atomic<String?>(nil)
    
    // MARK: - Initialization
    
    init(providers: [ErrorProvider], sdkVersion: String) {
        self.providers = providers
        self.sdkVersion = sdkVersion
    }
    
    // MARK: - User Context
    
    /// Set the current user ID. Called from Encore.identify() and Encore.reset().
    func setUserId(_ userId: String?) {
        self.userId.value = userId
    }
    
    // MARK: - Reporting
    
    /// Report an error to all configured providers.
    /// Returns the error for fluent usage in catch blocks.
    ///
    /// Fire-and-forget: dispatches to background thread to avoid blocking main thread.
    @discardableResult
    func report(_ error: EncoreError, context: ErrorContext, location: String? = nil) -> EncoreError {
        let underlying = error.underlying
        let sdkVersion = self.sdkVersion
        let userId = self.userId.value  // Atomic capture
        
        for provider in providers {
            Task.detached(priority: .utility) {
                provider.report(error, underlying: underlying, context: context, location: location, sdkVersion: sdkVersion, userId: userId)
            }
        }
        return error
    }
}
