// Publisher values (vocab §2.7): an app passes `values` on a trigger mount and a look shows them as
// `${values.K}`, with a default for each in its root `values` block. A value never leaves the phone.

import Foundation

internal enum TriggerValues {
    /// The token prefix, as in `${values.minutes}`.
    static let tokenPrefix = "values."
    static let keyPattern = "^[a-z][A-Za-z0-9]{0,31}$"
    static let maxKeys = 16
    /// Longest default or mount value, in UTF-16 units (as the backend and Android count).
    static let maxLength = 64

    /// A lowerCamel key of at most 32 characters.
    static func isKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first, ("a"..."z").contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// A look's default: 1 to 64 units, no letter (`\p{L}`; defaults are never translated), no
    /// control character (`\p{Cc}`) and no `${`.
    static func isDefault(_ value: String) -> Bool {
        isValue(value) && !value.unicodeScalars.contains(where: isLetter)
    }

    /// A mount value: 1 to 64 units of plain text, no `${` and no control character (newlines included).
    static func isValue(_ value: String) -> Bool {
        (1...maxLength).contains(value.utf16.count)
            && !value.contains("${")
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// The value keys `text` names, in order (`minutes` for `${values.minutes}`).
    static func keys(in text: String) -> [String] {
        TriggerLookCheck.tokens(in: text).compactMap { $0.hasPrefix(tokenPrefix) ? String($0.dropFirst(tokenPrefix.count)) : nil }
    }

    /// The mount's values a look may show: each entry checked on its own, an invalid one dropped (its
    /// default shows), then past 16 keys the first 16 in key order. Logs name keys, never values.
    static func mountValues(_ values: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for key in values.keys.sorted() {
            // A slot is a first-class parameter (`.headline(_:)` and the rest), never a value.
            if TriggerTextSlot(rawValue: key) != nil {
                Logger.debug(.configuration, "[TRIGGER] mount value '\(key)' ignored: set it with the \(key) parameter")
                continue
            }
            guard let value = values[key], isKey(key), isValue(value) else {
                Logger.debug(.configuration, "[TRIGGER] mount value '\(key)' dropped: a key is lowerCamel, a value 1 to \(maxLength) characters with no ${ or control character")
                continue
            }
            guard kept.count < maxKeys else {
                Logger.debug(.configuration, "[TRIGGER] more than \(maxKeys) mount values; '\(key)' and the keys after it dropped")
                break
            }
            kept[key] = value
        }
        return kept
    }

    // MARK: Fill

    /// What a look's `${values.K}` tokens read: the mount's value over the look's default, for every
    /// key the look declares. A mount value the look has no default for is not offered.
    static func publisher(mount: [String: String], defaults: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: defaults.map { ("\(tokenPrefix)\($0.key)", mount[$0.key] ?? $0.value) })
    }

    /// One pass over `text`: each `${name}` in `tokens` becomes its value, any other is kept. What was
    /// put in is never scanned again, so a value cannot bring in a token.
    static func fill(_ text: String, _ tokens: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            result += rest[..<open.lowerBound]
            let name = String(rest[open.upperBound..<close])
            result += tokens[name] ?? String(rest[open.lowerBound...close])
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// A look's resolved strings, filled before anything reads them, plus its `${values.K}` values.
    /// A string the host fills itself is ignored; one still holding `${values.` (a bad translation)
    /// shows its English (`english`), else nothing: a raw token is never drawn or spoken.
    static func filled(
        _ strings: [String: String], english: [String: String], publisher: [String: String],
        host: [String: String] = [:], hostKeys: Set<String>
    ) -> [String: String] {
        let tokens = publisher.merging(host) { _, host in host }
        var filled: [String: String] = [:]
        for (key, text) in strings {
            if hostKeys.contains(key) {
                logOnce("look string '\(key)' ignored: the host fills it")
                continue
            }
            let once = fill(text, tokens)
            filled[key] = once.contains("${\(tokenPrefix)") ? english[key].map { fill($0, tokens) } ?? "" : once
        }
        return filled.merging(publisher) { string, _ in string }
    }

    private static let logged = NSLock()
    nonisolated(unsafe) private static var loggedMessages = Set<String>()

    private static func logOnce(_ message: String) {
        logged.lock()
        let first = loggedMessages.insert(message).inserted
        logged.unlock()
        if first { Logger.debug(.configuration, "[TRIGGER] \(message)") }
    }

    /// A look's `values` block: its defaults, or why it is refused.
    static func defaults(_ block: JSONValue?) -> Result<[String: String], TriggerUnrenderable> {
        guard let block else { return .success([:]) }
        guard case .object(let entries) = block else {
            return .failure(TriggerUnrenderable(path: "values", detail: "expected an object of value keys and their defaults"))
        }
        guard entries.count <= maxKeys else {
            return .failure(TriggerUnrenderable(path: "values", detail: "\(entries.count) keys; at most \(maxKeys)"))
        }
        var defaults: [String: String] = [:]
        for key in entries.keys.sorted() {
            guard isKey(key) else { return .failure(TriggerUnrenderable(path: "values.\(key)", detail: "not a value key")) }
            guard TriggerTextSlot(rawValue: key) == nil else {
                return .failure(TriggerUnrenderable(path: "values.\(key)", detail: "a text slot is not a value key"))
            }
            guard case .string(let value)? = entries[key], isDefault(value) else {
                return .failure(TriggerUnrenderable(path: "values.\(key)", detail: "a default is 1 to \(maxLength) digits or punctuation"))
            }
            defaults[key] = value
        }
        return .success(defaults)
    }
}

/// What a look's tree may name beyond its host's values: its own strings (V-4) and its value defaults.
internal struct TriggerLookTokens: Sendable, Equatable {
    var strings: [String: String] = [:]
    var defaults: [String: String] = [:]
}
