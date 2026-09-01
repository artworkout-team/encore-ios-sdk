//
//  PostHogSink.swift
//  Encore
//
//  PostHog analytics sink implementation.
//

import Foundation

/// PostHog analytics sink using direct HTTP API calls
/// This avoids conflicts with publisher apps that also use PostHog SDK
internal final class PostHogSink: AnalyticsSink {
    private let apiKey = "phc_LcB1xqdojykrlUj2VEaTutqxsw7YyLw1wFfgnYzRb8I"
    private let captureURL = URL(string: "https://us.i.posthog.com/capture/")!
    private let session: URLSession
    
    init() {
        // Use a dedicated URLSession for PostHog requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
    
    func log(event: EventEnvelope) async {
        // Build properties matching PostHog format (unbox containers to [String: Any] for JSONSerialization)
        var properties = event.properties.asDict
        properties["event_id"] = event.eventId  // For deduplication with backend events
        properties["sdk_version"] = Encore.sdkVersion
        properties["timestamp"] = JSONCoding.string(from: event.timestamp)
        properties["app_bundle_id"] = Bundle.main.bundleIdentifier ?? "unknown"
        
        // Add metadata to properties
        for (key, value) in event.metadata {
            properties[key] = value
        }
        
        // Build PostHog capture payload and serialize (Data is Sendable)
        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": event.eventName,
            "distinct_id": event.distinctId,
            "properties": properties,
            "timestamp": JSONCoding.string(from: event.timestamp)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.debug(.analytics, "Failed to serialize PostHog payload")
            return
        }
        
        // Send via HTTP API (fire and forget)
        let eventName = event.eventName
        let userId = event.distinctId
        Task { [weak self, jsonData] in
            await self?.sendToPostHog(data: jsonData, eventName: eventName, userId: userId)
        }
    }
    
    private func sendToPostHog(data jsonData: Data, eventName: String, userId: String) async {
        var request = URLRequest(url: captureURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Logger.debug(.analytics, "Sent event to PostHog: \(eventName) | user: \(userId)")
            } else {
                Logger.debug(.analytics, "PostHog returned non-200 status")
            }
        } catch {
            // Silently drop network errors - analytics should never block the app
            Logger.debug(.analytics, "PostHog network error: \(error.localizedDescription)")
        }
    }

    func identify(userId: String, userProperties: [String: Any]) {
        // Build PostHog identify payload and serialize (Data is Sendable)
        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": "$identify",
            "distinct_id": userId,
            "properties": [
                "$set": userProperties
            ]
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.debug(.analytics, "Failed to serialize PostHog identify payload")
            return
        }
        
        Task { [weak self, jsonData] in
            await self?.sendToPostHog(data: jsonData, eventName: "$identify", userId: userId)
        }
        
        Logger.debug(.analytics, "PostHog identify: user=\(userId) | props=\(userProperties)")
    }
}


