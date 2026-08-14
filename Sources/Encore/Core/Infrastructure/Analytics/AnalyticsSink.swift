//
//  AnalyticsSink.swift
//  Encore
//
//  Protocol defining the interface for analytics sinks.
//

import Foundation

/// Protocol defining the interface for analytics sinks.
///
/// Sinks are adapters that forward analytics events to external services
/// (PostHog, backend API, console, etc.).
///
/// **Sendable:** Required because sinks are dispatched to background threads via `Task.detached`.
internal protocol AnalyticsSink: Sendable {
    /// Log a tracked event to this sink
    func log(event: EventEnvelope) async
    
    /// Identify a user with their properties (for user profiles)
    func identify(userId: String, userProperties: [String: Any])
}

