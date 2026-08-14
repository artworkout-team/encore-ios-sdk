// Sources/Encore/Core/Infrastructure/Analytics/AnalyticsEnvelopeAudit.swift
//
// Boundary check that a funnel event still carries the context that makes it
// joinable. An impression with no impression_id, variant_id or sdk_version is
// not a lossy row — it is an unusable one, and it looks identical to a healthy
// row until someone runs the funnel query weeks later.

import Foundation

/// Verifies the attribution envelope at the one place every typed event passes
/// through, `AnalyticsClient.track`.
///
/// Loud, never fatal in a host app: a violation logs at error level and reports
/// through the errors client, and the event still ships — telemetry must never
/// cost a publisher a crash, and a partial row still beats no row. The SDK's own
/// suite sets `failFast` so a regression fails the build instead.
internal enum AnalyticsEnvelopeAudit {

    /// Envelope keys the analytics client owns for every event.
    static let machineKeys: Set<String> = ["sdk_version", "platform", "app_bundle_id"]

    #if DEBUG
    /// Armed by a test around its OWN emission, never suite-wide: an assertion
    /// on shared state fires inside whichever suite emits first and takes the
    /// test host with it, after which xcodebuild blames the next test. A
    /// publisher's Debug build gets the log and nothing else — telemetry never
    /// costs a host app a crash.
    nonisolated(unsafe) static var failFast = false
    #endif

    /// Every envelope key this event should carry and does not, sorted.
    static func missingKeys(
        properties: [String: Any],
        metadata: [String: String],
        required: Set<String>
    ) -> [String] {
        var missing: [String] = []

        for key in machineKeys.sorted() where isBlank(metadata[key]) {
            missing.append(key)
        }
        for key in required.sorted() where isBlank(properties[key]) {
            // A variant the SDK never resolved cannot be stamped: the offline
            // first launch renders the embedded floor, and reporting that as a
            // defect would train everyone to ignore this check. Only a variant
            // the SDK HELD and dropped is a real loss.
            if key == "variant_id", !heldVariant(for: properties["use_case"] as? String) { continue }
            missing.append(key)
        }
        return missing
    }

    /// Report any missing member of `required` (event properties) or of the
    /// machine-supplied metadata.
    static func check(
        eventName: String,
        properties: [String: Any],
        metadata: [String: String],
        required: Set<String>
    ) {
        let missing = missingKeys(properties: properties, metadata: metadata, required: required)
        guard !missing.isEmpty else { return }

        let message = "[ANALYTICS] \(eventName) is missing \(missing.joined(separator: ", ")) — the row cannot be joined to its impression. Emit it through the offer analytics context, or stop emitting it here."
        Logger.error(.domain(message), context: .analytics)
        #if DEBUG
        if failFast { assertionFailure(message) }
        #endif
    }

    /// Whether the SDK currently holds a variant for `useCase` — i.e. whether a
    /// nil `variant_id` is a dropped fact or an honest absence.
    private static func heldVariant(for useCase: String?) -> Bool {
        guard let useCase, let resolved = UseCase(rawValue: useCase) else { return false }
        return sduiConfigManager?.variantId(for: resolved) != nil
    }

    private static func isBlank(_ value: Any?) -> Bool {
        switch value {
        case .none: return true
        case let string as String: return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case is NSNull: return true
        default: return false
        }
    }
}
