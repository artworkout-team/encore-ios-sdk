// Sources/Encore/Core/Infrastructure/Networking/LocaleHeader.swift
//
// Builds an RFC 7231 Accept-Language header from the device's preferred
// languages. Captured once at SDK init — locale changes mid-session are rare
// enough that re-evaluating per request is not worth the cost.
//

import Foundation

internal enum LocaleHeader {
    /// Returns an Accept-Language header value from `Locale.preferredLanguages`,
    /// or `nil` when the device has no configured languages. Quality values step
    /// down from 1.0 in 0.1 increments so the user's top preference wins against
    /// an app's `enabledLocales` on the backend.
    ///
    /// Example output: `en-US, fr;q=0.9, es;q=0.8`
    static func preferredAcceptLanguage() -> String? {
        let languages = Locale.preferredLanguages
        guard !languages.isEmpty else { return nil }

        // Cap the list — DeepL/Accept-Language negotiation only cares about the
        // top few, and a long header adds bytes without adding signal.
        let capped = languages.prefix(6)

        let entries = capped.enumerated().map { index, tag -> String in
            guard index > 0 else { return tag }
            let quality = max(0.1, 1.0 - Double(index) * 0.1)
            // Trim to one decimal place to keep the header compact.
            return "\(tag);q=\(String(format: "%.1f", quality))"
        }
        return entries.joined(separator: ", ")
    }
}
