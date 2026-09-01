//
//  BackendAnalyticsSink.swift
//  Encore
//
//  Backend analytics sink that forwards events to the Encore API.
//  Creates its own HTTPClient since analytics uses a separate base URL and auth header.
//

import Foundation
internal import OpenAPIRuntime

/// Backend analytics sink that forwards events to the API.
internal final class BackendAnalyticsSink: AnalyticsSink {
    
    private let httpClient: HTTPClientProtocol
    
    init(httpClient: HTTPClientProtocol) {
        self.httpClient = httpClient
    }
    
    func log(event: EventEnvelope) async {
        // Merge properties and metadata
        var properties = event.properties
        for (key, value) in event.metadata {
            properties[key] = try? OpenAPIValueContainer(unvalidatedValue: value)  // String always validates
        }
        
        // Build typed request payload from OpenAPI-generated types
        let body = DTO.Analytics.IngestEvent(
            event_id: event.eventId,
            event_name: event.eventName,
            event_timestamp: event.timestamp,
            distinct_id: event.distinctId,
            properties: properties.nonEmpty.map { .init(additionalProperties: $0) }
        )
        
        // Fire-and-forget: log outcome, never throw
        do {
            let _: EmptyResponse = try await httpClient.request(
                path: "events",
                method: "POST",
                body: body
            )
        } catch {
            Logger.debug(.analytics, "Backend event send failed: \(error)")
        }
    }
    
    func identify(userId: String, userProperties: [String: Any]) {
        // No-op for backend sink (no identify endpoint yet)
    }
}
