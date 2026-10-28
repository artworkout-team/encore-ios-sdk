// Sources/Encore/Core/Configuration/Remote/ServedStringsSanitizer.swift
//
// `/config` decodes strictly, except for the served SDK string maps: one bad
// `strings` or `plurals` entry must cost that entry, never the whole config.

import Foundation

/// Retries a failed `ui` / `values` decode with malformed `strings` and
/// `plurals` entries removed. Any other contract violation still throws.
enum ServedStringsSanitizer {

    /// Decodes `type` at `key`; on failure, drops bad string-map entries under
    /// `valuesPath` and decodes once more.
    static func decode<T: Decodable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        valuesPath: [String]
    ) throws -> T {
        do {
            return try container.decode(type, forKey: key)
        } catch {
            let raw = try container.decode(JSONValue.self, forKey: key)
            let (cleaned, dropped) = sanitize(raw, at: valuesPath)
            guard dropped > 0 else { throw error }
            Logger.warn(.configuration, "Dropped \(dropped) malformed served SDK string(s)")
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(cleaned))
        }
    }

    /// `value` with malformed entries of `strings` / `plurals` at `path` removed,
    /// and how many were removed.
    static func sanitize(_ value: JSONValue, at path: [String]) -> (JSONValue, Int) {
        guard let head = path.first else { return sanitizeValues(value) }
        guard case .object(var object) = value, let child = object[head] else { return (value, 0) }
        let (cleaned, dropped) = sanitize(child, at: Array(path.dropFirst()))
        object[head] = cleaned
        return (.object(object), dropped)
    }

    private static let pluralCategories: Set<String> = ["zero", "one", "two", "few", "many", "other"]

    private static func sanitizeValues(_ value: JSONValue) -> (JSONValue, Int) {
        guard case .object(var values) = value else { return (value, 0) }
        var dropped = 0

        switch values["strings"] {
        case .object(let strings)?:
            let kept = strings.filter { if case .string = $0.value { true } else { false } }
            dropped += strings.count - kept.count
            values["strings"] = .object(kept)
        case .null?, nil:
            break
        default:
            values["strings"] = nil
            dropped += 1
        }

        switch values["plurals"] {
        case .object(let plurals)?:
            let kept = plurals.filter { isValidPlural($0.value) }
            dropped += plurals.count - kept.count
            values["plurals"] = .object(kept)
        case .null?, nil:
            break
        default:
            values["plurals"] = nil
            dropped += 1
        }
        return (.object(values), dropped)
    }

    /// An object whose known categories are all strings, `other` included.
    private static func isValidPlural(_ value: JSONValue) -> Bool {
        guard case .object(let forms) = value, case .string? = forms["other"] else { return false }
        return forms.allSatisfy { category, form in
            guard pluralCategories.contains(category) else { return true }
            if case .string = form { return true }
            return false
        }
    }
}

/// Any JSON value, for the sanitizer's one-off rewrite.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
