//
//  AnalyticsEvent.swift
//  Encore
//
//  Analytics event protocol and internal tracking model.
//

import Foundation
import CryptoKit
internal import OpenAPIRuntime

// MARK: - Analytics Event Protocol

/// Protocol for typed analytics events.
/// Conforming types provide a static event name and are Encodable.
internal protocol AnalyticsEvent: Encodable {
    static var eventName: String { get }

    /// Wire keys this event is worthless without — checked at the analytics
    /// client boundary (`AnalyticsEnvelopeAudit`). Empty means the event stands
    /// on its own.
    static var requiredContext: Set<String> { get }
}

internal extension AnalyticsEvent {
    static var requiredContext: Set<String> { [] }
}

/// An event built from `OfferAnalyticsContext`. Every one of these is a row in
/// the offer funnel, so it must identify the impression it belongs to: without
/// `impression_id` it joins to nothing, and without `variant_id` no result can
/// be attributed to the variant that produced it. `use_case` is unconditional
/// on every live event (the context stamps it from a non-optional field), so a
/// row without it means the event bypassed the context — the same defect class.
/// `placement_id` is deliberately NOT here: the canon is include-when-present,
/// omit-when-absent, so absence is not evidence of a dropped envelope.
internal protocol OfferContextEvent: AnalyticsEvent {}

internal extension OfferContextEvent {
    static var requiredContext: Set<String> { ["campaign_id", "impression_id", "presentation_id", "variant_id", "use_case"] }
}

// MARK: - Event Envelope

/// Full event envelope sent to analytics sinks. Matches backend `EventEnvelope` schema.
/// Created from AnalyticsEvent types by AnalyticsManager.
internal struct EventEnvelope: Encodable, Sendable {
    let eventId: String          // backend: event_id (deterministic UUID via SHA256)
    let eventName: String        // backend: event_name (e.g. "offer_shown")
    let timestamp: Date          // backend: event_timestamp
    let distinctId: String       // backend: distinct_id
    let properties: [String: OpenAPIValueContainer]
    let metadata: [String: String]  // sdk_version, app_id, platform, etc.

    /// Snake_case keys to match the backend wire format (synthesized Encodable).
    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventName = "event_name"
        case timestamp = "event_timestamp"
        case distinctId = "distinct_id"
        case properties
        case metadata
    }

    init(eventName: String, distinctId: String, properties: [String: Any], metadata: [String: String]) {
        self.eventName = eventName
        self.distinctId = distinctId
        self.properties = properties.asOpenAPIProperties  // erase to the Codable carrier once; drops are logged
        self.metadata = metadata
        self.timestamp = Date()
        self.eventId = Self.generateEventId(eventName: eventName, distinctId: distinctId, timestamp: timestamp)
    }
    
    /// The one `distinct_id` rule, shared by every delivery path: the resolved
    /// user id, or `"anonymous"` when the SDK has none. Never `appAccountId`
    /// (that ships alongside as `app_account_id`) and never the bundle id, so a
    /// funnel joined on `distinct_id` cannot split across namespaces.
    static func resolveDistinctId(_ candidate: String? = nil) -> String {
        if let candidate, !candidate.isEmpty { return candidate }
        if let userId = userManager?.currentUserId, !userId.isEmpty { return userId }
        Logger.warn(.analytics, "No user id available, distinct_id falls back to 'anonymous'")
        return "anonymous"
    }

    /// Generate deterministic event ID using SHA256.
    /// Uses microsecond precision to avoid collisions for multiple events within the same second.
    static func generateEventId(eventName: String, distinctId: String, timestamp: Date) -> String {
        let timestampMicros = Int64(timestamp.timeIntervalSince1970 * 1_000_000)
        let contentString = "\(eventName)_\(distinctId)_\(timestampMicros)"
        let hash = SHA256.hash(data: Data(contentString.utf8))
        let bytes = Array(hash.prefix(16))
        
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      bytes[0], bytes[1], bytes[2], bytes[3],
                      bytes[4], bytes[5],
                      (bytes[6] & 0x0f) | 0x40,  // Version 4
                      bytes[7],
                      (bytes[8] & 0x3f) | 0x80,  // Variant
                      bytes[9],
                      bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }
}

