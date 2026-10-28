// Sources/Encore/Core/Localization/LanguageTag.swift
//
// Validates the tag a host passes to `setLanguage(_:)`: an RFC 5646 well-formed
// langtag, the same pattern every Encore SDK uses. Kept in BCP 47 case because
// it is also the cache stamp, so "PT-br" and "pt-BR" are one language.

import Foundation

internal enum LanguageTag {
    /// RFC 5646 langtag (no grandfathered or bare private-use tags), case-insensitive.
    /// `\z`, not `$`: ICU's `$` also matches before a trailing newline.
    private static let pattern = try! NSRegularExpression(
        pattern: "^[a-z]{2,3}(-[a-z]{4})?(-([a-z]{2}|[0-9]{3}))?(-([a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*(-[0-9a-wyz](-[a-z0-9]{2,8})+)*(-x(-[a-z0-9]{1,8})+)?\\z",
        options: .caseInsensitive
    )

    /// Deprecated ISO 639 codes, as `Locale.forLanguageTag` canonicalizes them on
    /// Android. The backend matches enabled languages on the current code only.
    private static let legacyLanguages = ["iw": "he", "in": "id", "ji": "yi", "jw": "jv"]

    /// The tag in BCP 47 case ("PT-br" → "pt-BR", "iw" → "he"), or nil when it is not well-formed.
    static func normalized(_ tag: String) -> String? {
        guard pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil else { return nil }
        var pastSingleton = false
        return tag.split(separator: "-").enumerated().map { index, subtag -> String in
            if subtag.count == 1 { pastSingleton = true }
            guard index > 0 else { return legacyLanguages[subtag.lowercased()] ?? subtag.lowercased() }
            guard !pastSingleton else { return subtag.lowercased() }
            switch subtag.count {
            case 4 where subtag.allSatisfy(\.isLetter): return subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
            case 2: return subtag.uppercased()
            default: return subtag.lowercased()
            }
        }.joined(separator: "-")
    }

    /// The deprecated `UserAttributes.language` was often `Locale.identifier`
    /// ("pt_BR", "en_US@rg=gbzzzz", padded): read as its tag here only.
    static func normalizedLegacy(_ tag: String) -> String? {
        let identifier = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return normalized(identifier.replacingOccurrences(of: "_", with: "-"))
    }
}
