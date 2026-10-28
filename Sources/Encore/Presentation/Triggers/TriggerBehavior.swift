// Look behavior (vocab §2.8): a look's optional root `behavior` names its step rules (what the trigger
// does after a claim or a completion). The server applies the steps; the SDK applies only what it
// must on the device (a look's autoOpen, the custom UI handle's rules), and an unknown step or value
// never makes a look unrenderable. `resolved` and `problem` mirror the backend's rules
// for the shared parity cases only. The SDK draws another trigger's look only when the requested
// trigger may render it.

import Foundation

/// What one step of a look's behavior may hold.
internal enum TriggerBehaviorStep: Sendable, Equatable {
    /// One of these values; the first is the default.
    case values([String])
    /// A pinnable layout name (`reminderLayout`).
    case layout
    /// A JSON integer in range, resolved as its string (the backend's `days` kind).
    case integer(ClosedRange<Int>, default: Int)
}

internal enum TriggerBehavior {
    /// `behavior.autoOpen`: the look opens the sheet once by itself (only ever an experiment arm).
    static let autoOpenOn = "on"
    /// Each trigger's steps (the vocabulary's ALLOW `behavior` data).
    static let steps: [String: [String: TriggerBehaviorStep]] = [
        "giftsButton": [
            "afterClaim": .values(["showReminder", "stay"]),
            "afterComplete": .values(["gifts", "hide", "thanks"]),
            "autoOpen": .values(["off", autoOpenOn]),
            "reminderLayout": .layout,
            // The non-clicker nudge: server-only, listed so the shared data matches; the SDK applies none.
            "ifIgnored": .values(["none", "autoOpen", "preview"]),
            "ignoredAfterDays": .integer(1...30, default: 2),
            "ignoredMaxNudges": .integer(1...3, default: 1),
        ],
        "claimReminder": ["afterComplete": .values(["hide", "thanks"])],
        // The app's own view (the custom-UI handle): rules only, no look.
        "customClaim": [
            "afterClaim": .values(["showReminder", "stay"]),
            "afterComplete": .values(["gifts", "hide", "thanks"]),
            "autoOpen": .values(["off", autoOpenOn]),
        ],
    ]

    /// The other triggers a trigger's request may be answered with (ALLOW `renders`).
    static let renders: [String: Set<String>] = ["giftsButton": ["claimReminder"], "claimReminder": [], "customClaim": []]

    /// State looks: served only for a step, never an arm, a pin or a pop.
    static let stateLayouts: Set<String> = ["thanks", "offerPreview"]
    /// Layouts a `reminderLayout` may never name: the automatic arm, app-drawn views and state looks.
    private static let unpinnable: Set<String> = stateLayouts.union(["auto", "custom"])

    /// A camelCase layout name of at most 32 characters that a mount could pin.
    static func isPinnableLayout(_ layout: String) -> Bool {
        TriggerValues.isKey(layout) && !unpinnable.contains(layout)
    }

    /// The look's behavior with every step's default filled in; an unknown step, a value a step does not
    /// allow and anything not an object are skipped (as Android's `TriggerBehavior.resolved`).
    static func resolved(_ behavior: JSONValue?, trigger: String) -> [String: String] {
        let allowed = steps[trigger] ?? [:]
        var out: [String: String] = [:]
        for (step, kind) in allowed {
            switch kind {
            case .values(let values): if let first = values.first { out[step] = first }
            case .integer(_, let fallback): out[step] = String(fallback)
            case .layout: continue
            }
        }
        guard case .object(let entries)? = behavior else { return out }
        for (step, value) in entries {
            guard let kind = allowed[step] else { continue }
            switch (kind, value) {
            case (.values(let values), .string(let value)) where values.contains(value): out[step] = value
            case (.layout, .string(let value)) where isPinnableLayout(value): out[step] = value
            case (.integer(let range, _), .number(let number)):
                if let integer = integer(number, in: range) { out[step] = String(integer) }
            default: continue
            }
        }
        return out
    }

    /// `number` as an integer within `range`, else nil (a fraction, or out of range).
    private static func integer(_ number: Double, in range: ClosedRange<Int>) -> Int? {
        guard number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else { return nil }
        return Int(number)
    }

    /// Why `behavior` is not a valid set of `steps`, or nil. The server validator's rule; the SDK's
    /// strict check no longer refuses a look for it (see ``resolved(_:trigger:)``).
    static func problem(_ behavior: JSONValue, steps: [String: TriggerBehaviorStep]) -> TriggerUnrenderable? {
        guard case .object(let entries) = behavior else {
            return TriggerUnrenderable(path: "behavior", detail: "expected an object of steps and their values")
        }
        for step in entries.keys.sorted() {
            guard let allowed = steps[step] else {
                return TriggerUnrenderable(path: "behavior.\(step)", detail: "not a step this trigger has")
            }
            if case .integer(let range, _) = allowed {
                guard case .number(let number)? = entries[step], integer(number, in: range) != nil else {
                    return TriggerUnrenderable(path: "behavior.\(step)", detail: "expected an integer from \(range.lowerBound) to \(range.upperBound)")
                }
                continue
            }
            guard case .string(let value)? = entries[step] else {
                return TriggerUnrenderable(path: "behavior.\(step)", detail: "expected a string")
            }
            switch allowed {
            case .values(let values) where !values.contains(value):
                return TriggerUnrenderable(path: "behavior.\(step)", detail: "\(value) is not one of \(values.joined(separator: ", "))")
            case .layout where !isPinnableLayout(value):
                return TriggerUnrenderable(path: "behavior.\(step)", detail: "\(value) is not a pinnable layout")
            default:
                continue
            }
        }
        return nil
    }
}
