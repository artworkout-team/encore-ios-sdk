//
//  Analytics.swift
//  Encore
//
//  Analytics client that routes events to registered sinks.
//  Stores userId for automatic event attribution.
//

import Foundation
import CryptoKit

// MARK: - Analytics Client

/// Analytics client for tracking Encore SDK events.
/// Stores userId so callers don't need to pass it for every event.
internal final class AnalyticsClient {

    // MARK: - Properties

    private let sinks: [AnalyticsSink]
    private let sdkVersion: String
    private let appBundleId: String
    private let dedupStorage: KeyValueStore?

    /// Current user ID for event attribution. Atomic for thread-safe access.
    private let userId = Atomic<String?>(nil)

    /// SHA-256 of the last identity payload (userId + attributes) emitted as
    /// a `user_identified` event. The 30-day audit (Apr 2026) flagged the
    /// event at 16% of total volume — host apps re-call `identifyUser` per
    /// session with unchanged inputs. The backend ingest filter is a
    /// temporary bridge until SDK consumers (notably Knowunity) ship this
    /// version; once they're on it, the SDK owns suppression end-to-end.
    private static let lastIdentifiedHashKey = "analytics_dedup_user_identified_hash"

    // MARK: - Initialization

    #if DEBUG
    /// Emission-test observer, invoked SYNCHRONOUSLY from `track()` after the
    /// envelope is built — the real path (encode, envelope, dedup) minus the
    /// sink fan-out. A sink-based seam proved order-flaky in CI: suites that
    /// leak never-resuming StoreKit tasks can starve the cooperative pool, so
    /// detached sink deliveries never run and the recording sink sees nothing.
    /// Synchronous observation is immune. Production never sets it.
    nonisolated(unsafe) static var emissionObserverForTesting: ((EventEnvelope) -> Void)?
    #endif

    init(sinks: [AnalyticsSink], sdkVersion: String, appBundleId: String, dedupStorage: KeyValueStore? = nil) {
        self.sinks = sinks
        self.sdkVersion = sdkVersion
        self.appBundleId = appBundleId
        self.dedupStorage = dedupStorage
    }
    
    // MARK: - Encoding Helper
    
    /// Encode any Encodable to a snake_cased dictionary
    private func encode<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONCoding.snakeCaseEncoder.encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }
    
    // MARK: - Event Tracking
    
    /// Track a typed analytics event. Uses stored userId if distinctId not provided.
    func track<T: AnalyticsEvent>(_ event: T, distinctId: String? = nil) {
        let resolvedId = EventEnvelope.resolveDistinctId(distinctId ?? userId.value)

        guard let properties = encode(event) else {
            Logger.error(.protocol(.decoding(EncodingError.invalidValue(event, .init(codingPath: [], debugDescription: "Failed to encode \(T.eventName)")))), context: .analytics)
            return
        }
        
        var metadata: [String: String] = [
            "platform": "ios",
            "sdk_version": sdkVersion,
            "app_bundle_id": appBundleId,
        ]
        if let appAccountId = userManager?.appAccountId {
            metadata["app_account_id"] = appAccountId
        }
        
        // The one boundary every typed event crosses: an envelope that lost its
        // attribution here ships a row nobody can join, and it looks healthy
        // until the funnel query runs weeks later.
        AnalyticsEnvelopeAudit.check(
            eventName: T.eventName,
            properties: properties,
            metadata: metadata,
            required: T.requiredContext
        )

        let envelope = EventEnvelope(
            eventName: T.eventName,
            distinctId: resolvedId,
            properties: properties,
            metadata: metadata
        )

        // Gated overload: no pretty-JSON encode cost unless .debug is enabled.
        Logger.debug(.analytics, envelope.eventName, object: envelope)

        #if DEBUG
        Self.emissionObserverForTesting?(envelope)
        #endif

        // Send to all sinks concurrently
        for sink in sinks {
            Task.detached(priority: .utility) { [sink, envelope] in
                await sink.log(event: envelope)
            }
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Identify a user with their attributes.
    ///
    /// **Synchronous:** Ensures user profile is set up before subsequent `track()` calls.
    /// This guarantees events are properly associated with the user.
    func identifyUser(userId: String, attributes: UserAttributes) {
        self.userId.value = userId

        var userProperties = encode(attributes) ?? [:]
        userProperties["user_id"] = userId
        userProperties["app_bundle_id"] = appBundleId

        // Sink identify always runs — refreshes PostHog user properties even
        // when the analytics emit is suppressed below.
        for sink in sinks {
            sink.identify(userId: userId, userProperties: userProperties)
        }

        if shouldEmitUserIdentified(userId: userId, attributes: attributes) {
            track(UserIdentifiedEvent(userId: userId, attributes: attributes))
        }
    }

    // MARK: - Dedup

    /// Mirrors the `sdui_config_loaded` pattern: hash the identity payload,
    /// store one key, emit only when the hash changes. Storage is bounded
    /// (single key) and naturally captures both userId and attribute deltas.
    /// Fail-open when storage is unavailable.
    private func shouldEmitUserIdentified(userId: String, attributes: UserAttributes) -> Bool {
        guard let storage = dedupStorage,
              let hash = identityHash(userId: userId, attributes: attributes) else {
            return true
        }
        let last: String? = storage.load(Self.lastIdentifiedHashKey)
        if last == hash { return false }
        storage.save(hash, to: Self.lastIdentifiedHashKey)
        return true
    }

    private func identityHash(userId: String, attributes: UserAttributes) -> String? {
        // `JSONCoding.snakeCaseEncoder` is deterministic by contract
        // (sorted keys, stable date format) — same property the
        // `RemoteConfigurationManager` hash gate depends on. See
        // `docs/CONTRIBUTING.md § JSON Encoding`.
        struct Payload: Encodable { let userId: String; let attributes: UserAttributes }
        guard let data = try? JSONCoding.snakeCaseEncoder.encode(Payload(userId: userId, attributes: attributes)) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
