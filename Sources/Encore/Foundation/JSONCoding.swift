// Sources/Encore/Core/JSONCoding.swift
//
// Shared JSON encoder/decoder configuration for the Encore SDK.
// Backend returns ISO8601 dates with fractional seconds: "2024-01-01T10:30:45.123Z"

import Foundation

/// Shared JSON coding utilities for the Encore SDK.
/// All instances are thread-safe singletons — no factories needed.
internal enum JSONCoding {
    
    // MARK: - Date Formatting
    // Safe: static let uses dispatch_once, formatter is never mutated after init.
    
    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
   private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    /// Convert a Date to ISO8601 string with fractional seconds.
    static func string(from date: Date) -> String {
        dateFormatter.string(from: date)
    }
    
    // MARK: - Encoder / Decoder
    
    /// Shared JSONDecoder configured for Encore backend responses.
    /// Handles multiple date formats for backwards compatibility:
    /// 1. ISO8601 with fractional seconds (backend API format)
    /// 2. ISO8601 without fractional seconds (legacy)
    /// 3. Numeric timestamp (standard JSONEncoder, used by UserDefaultsStore)
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            
            // Try string first (backend API format)
            if let dateString = try? container.decode(String.self) {
                // ISO8601 with fractional seconds (primary backend format)
                if let date = dateFormatter.date(from: dateString) {
                    return date
                }
                // ISO8601 without fractional seconds (fallback)
                if let date = fallbackDateFormatter.date(from: dateString) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO8601 date string, got: \(dateString)"
                )
            }
            
            // Fallback: numeric timestamp (standard JSONEncoder format, used by UserDefaultsStore)
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: timestamp)
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 string or numeric timestamp"
            )
        }
        return decoder
    }()
    
    /// Shared JSONEncoder for Encore backend requests.
    /// Preserves property names as-is; generated OpenAPI DTOs declare their
    /// own snake_case CodingKeys.
    ///
    /// Output is **deterministic** (`.sortedKeys`): given the same input,
    /// `encode` produces byte-identical bytes. This is a cross-cutting
    /// guarantee — content-hash gates (`RemoteConfigurationManager`,
    /// `AnalyticsClient.identifyUser`), wire-format regression tests, and
    /// human-readable log output all depend on it. Encoding overhead is
    /// negligible at our payload sizes (10–20 keys, sub-microsecond).
    /// No downstream consumer depends on insertion order — JSON object
    /// key ordering is undefined per the spec.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Snake_case variant of `encoder` for analytics payloads — PostHog
    /// and the backend ingest both expect snake_case keys per analytics
    /// convention. Same determinism guarantee as `encoder`.
    static let snakeCaseEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Pretty-printed variant of `snakeCaseEncoder` for human-readable debug logs.
    /// Same key/date strategy as the wire encoders so logged payloads are wire-faithful.
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(dateFormatter.string(from: date))
    }
}

