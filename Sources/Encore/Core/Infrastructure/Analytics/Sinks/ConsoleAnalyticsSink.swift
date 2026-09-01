//
//  ConsoleSink.swift
//  Encore
//
//  Console analytics sink for development environments.
//

import Foundation

/// Console analytics sink for development environments.
/// Logs events to console instead of sending to external services.
internal final class ConsoleSink: AnalyticsSink {
    func log(event: EventEnvelope) async {
        var propertiesStr = ""
        if !event.properties.isEmpty {
            propertiesStr = " | properties: \(event.properties.asDict)"
        }
        Logger.debug(.analytics, "\(event.eventName)\(propertiesStr)")
    }
    
    func identify(userId: String, userProperties: [String: Any]) {
        // No-op in console sink
    }
}


