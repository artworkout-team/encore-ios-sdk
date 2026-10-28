// Text slots (vocab §2.9): an app sets a GiftsButton's or claim reminder's headline, subheadline and
// CTA, and a look takes the ones it lists in `textSlots`, each over one of its own strings, which is the
// variant's default. App text is sanitised the same way on every SDK and never leaves the phone.

import Foundation

/// A piece of copy an app may set on a trigger.
internal enum TriggerTextSlot: String, Sendable, CaseIterable, Comparable {
    case headline, subheadline, cta

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

internal enum TriggerTextSlots {
    /// Longest app text, in UTF-16 units (as the backend and Android count).
    static let maxLength = 120

    /// A look's `textSlots`, read leniently: an unknown slot, a non-string value or a key the look's
    /// strings lack is skipped, never a reason to refuse the look.
    static func slots(_ block: JSONValue?, strings: [String: String]) -> [TriggerTextSlot: String] {
        guard case .object(let entries)? = block else { return [:] }
        var slots: [TriggerTextSlot: String] = [:]
        for (name, value) in entries {
            guard let slot = TriggerTextSlot(rawValue: name), case .string(let key) = value, strings[key] != nil else { continue }
            slots[slot] = key
        }
        return slots
    }

    /// `text` as a look may draw it, or nil to keep the variant's default. In order: strip control
    /// characters, U+2028/U+2029, bidi embeddings, overrides and isolates (keeping LRM, RLM, ALM) and
    /// unpaired surrogates (U+FFFD in Swift); trim both ends; nothing visible left is nil; cut to 120 UTF-16 units, never
    /// mid pair; anything still holding `${` is nil.
    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        // A Swift string holds no unpaired surrogate: one arriving from an NSString (a bridge) is
        // already U+FFFD, so U+FFFD is stripped as the unpaired surrogate it stands for.
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { keeps($0) && $0.value != 0xFFFD })
        var scalars = kept[...]
        while let first = scalars.first, isTrimmed(first) { scalars = scalars.dropFirst() }
        while let last = scalars.last, isTrimmed(last) { scalars = scalars.dropLast() }
        guard scalars.contains(where: { !isInvisible($0) }) else { return nil }
        var units = Array(String(String.UnicodeScalarView(scalars)).utf16)
        if units.count > maxLength {
            let cut = UTF16.isLeadSurrogate(units[maxLength - 1]) ? maxLength - 1 : maxLength
            units = Array(units.prefix(cut))
        }
        let result = String(decoding: units, as: UTF16.self)
        return result.contains("${") ? nil : result
    }

    /// For each slot the look lists and the app set with text that survives ``sanitized(_:)``: the
    /// look string it replaces. `drawn` is those slots' names, sorted (S-8; never the text).
    static func overrides(slots: [TriggerTextSlot: String], texts: [TriggerTextSlot: String]) -> (strings: [String: String], drawn: [String]) {
        var strings: [String: String] = [:]
        var drawn: [String] = []
        for (slot, key) in slots.sorted(by: { $0.key < $1.key }) {
            guard let text = sanitized(texts[slot]) else { continue }
            strings[key] = text
            drawn.append(slot.rawValue)
        }
        return (strings, drawn)
    }

    private static func keeps(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return false }
        switch scalar.value {
        case 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: return false
        default: return true
        }
    }

    private static func isTrimmed(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.value == 0xFEFF || scalar.value == 0x200B
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x2060, 0x061C, 0xFEFF: return true
        default: return false
        }
    }
}
