// Core/Infrastructure/Errors/ErrorProvider.swift
//
// Protocol defining the interface for error reporting providers.
//

import Foundation

/// Protocol defining the interface for error providers.
///
/// Providers are adapters that forward errors to external services
/// (Sentry, Console, etc.).
internal protocol ErrorProvider: Sendable {
    /// Report an error with its context and optional underlying system error.
    /// - Parameters:
    ///   - error: The domain error (EncoreError)
    ///   - underlying: The underlying system error (e.g., URLError) for stack traces
    ///   - context: Where the error occurred
    ///   - location: Source location (file:line function) for debugging
    ///   - sdkVersion: SDK version for debugging/tracking
    ///   - userId: Current user ID (passed from ErrorsClient, not fetched internally)
    func report(_ error: EncoreError, underlying: Error?, context: ErrorContext, location: String?, sdkVersion: String, userId: String?)
}
