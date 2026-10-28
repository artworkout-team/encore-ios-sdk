// Sources/Encore/Core/Localization/SDKStrings.swift
//
// The one seam for copy the SDK itself owns (fallbacks, verification, a11y,
// duration words). English literals are the fallback; `/config` `ui.values`
// `strings` and `plurals` override per id. No `.strings` bundle on purpose.

import Foundation

/// SDK-owned copy keyed by wire id (e.g. "verification.verifying"). A served
/// value replaces its id only; any id the served locale lacks stays English.
internal struct SDKStrings: Equatable, Sendable {

    /// Every SDK-owned string. Raw values are the wire ids of `ui.values.strings`.
    enum Key: String, CaseIterable, Sendable {
        // Strict-unlock verification sheet
        case verificationSlowTitle = "verification.stillVerifying"
        case verificationSlowSubtitle = "verification.takingLonger"
        case verificationRetry = "verification.retry"
        case verificationCancel = "verification.cancel"
        case verifyingTitle = "verification.verifying"
        case verifyingSubtitle = "verification.usuallySeconds"
        // Accessibility
        case holdToActivateHint = "a11y.activateHold"
        case modalClose = "modal.close"
        case shareButton = "share.button"
        case navBack = "nav.back"
        case panelClose = "panel.close"
        /// Carries `${offerName}`, the advertiser's name as sent, never translated.
        case cardImage = "card.image"
        // Reward claim screen (its close labels reuse `modal.close`)
        case claimLoading = "claim.loading"
        case claimFinishOn = "claim.finishOn"
        case browserSecure = "browser.secure"
        // CTA fallbacks, see `offerCta`: a bound offer with no wording, no offer
        // at all, and the native offer card
        case cardClaim = "card.claim"
        case offerCtaFallback = "card.get"
        case campaignCtaFallback = "campaign.ctaFallback"
        // Native fallback sheet and `titleText`-family bindings
        case fallbackHeadline = "churn.fallbackTitle"
        case fallbackHeadlineAccent = "churn.fallbackAccent"
        case fallbackSubheadline = "churn.fallbackSubtitle"
        // Churn floor backstop, laid over the shared floor's `initialValues`
        case churnFloorTitle = "churn.floorTitle"
        case churnFloorSubtitle = "churn.floorSubtitle"
        // Lead-capture validation
        case emailInvalid = "email.invalid"
        case emailPrivateRelay = "email.relay"
        // Gift category chip labels, keyed by the English `categoryGroup`
        case giftCategoryWatch = "gift.categoryWatch"
        case giftCategoryMoney = "gift.categoryMoney"
        case giftCategoryEveryday = "gift.categoryEveryday"
        // `${premiumTierName}` when the dashboard sets none
        case premiumTierName = "premiumTier.name"

        /// The literal that shipped before this seam existed.
        var english: String {
            switch self {
            case .verificationSlowTitle: "Still verifying..."
            case .verificationSlowSubtitle: "Your completion is taking longer than expected."
            case .verificationRetry: "Retry"
            case .verificationCancel: "Cancel"
            case .verifyingTitle: "Verifying your completion..."
            case .verifyingSubtitle: "This usually takes a few seconds."
            case .holdToActivateHint: "Double tap and hold to activate"
            case .modalClose: "Close modal"
            case .navBack: "Back"
            case .panelClose: "Close panel"
            case .cardImage: "${offerName} image"
            case .claimLoading: "Loading your FREE offer"
            case .claimFinishOn: "Finish on ${domain}"
            case .browserSecure: "Secure connection"
            case .shareButton: "Share"
            case .cardClaim: "Claim"
            case .offerCtaFallback: "Get"
            case .campaignCtaFallback: "Claim Offer"
            case .fallbackHeadline: "Get 1 month"
            case .fallbackHeadlineAccent: " for free"
            case .fallbackSubheadline: "Claim an exclusive offer and get free access to all features"
            case .churnFloorTitle: "Get it for free"
            case .churnFloorSubtitle: "Claim an exclusive deal and get it for free"
            case .emailInvalid: "Please enter a valid email address"
            case .emailPrivateRelay: "Please use your real email address, not a private relay"
            case .giftCategoryWatch: "Watch & listen"
            case .giftCategoryMoney: "Money"
            case .giftCategoryEveryday: "Everyday"
            case .premiumTierName: "${appName} Premium"
            }
        }
    }

    /// Count-dependent copy. Raw values are the wire ids of `ui.values.plurals`.
    enum PluralKey: String, CaseIterable, Sendable {
        case durationDay = "duration.day", durationWeek = "duration.week"
        case durationMonth = "duration.month", durationYear = "duration.year"
        case periodDay = "period.day", periodWeek = "period.week"
        case periodMonth = "period.month", periodYear = "period.year"
        case unitNameDay = "unitName.day", unitNameWeek = "unitName.week"
        case unitNameMonth = "unitName.month", unitNameYear = "unitName.year"

        static func duration(_ unit: IntroOfferPeriodUnit) -> PluralKey {
            switch unit {
            case .day: .durationDay
            case .week: .durationWeek
            case .month: .durationMonth
            case .year: .durationYear
            }
        }

        static func period(_ unit: IntroOfferPeriodUnit) -> PluralKey {
            switch unit {
            case .day: .periodDay
            case .week: .periodWeek
            case .month: .periodMonth
            case .year: .periodYear
            }
        }

        /// The `unitName.*` id for an English unit word, singular or plural.
        static func unitName(forEnglishWord word: String) -> PluralKey? {
            var base = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if base.hasSuffix("s") { base.removeLast() }
            switch base {
            case "day": return .unitNameDay
            case "week": return .unitNameWeek
            case "month": return .unitNameMonth
            case "year": return .unitNameYear
            default: return nil
            }
        }

        static func unitName(_ unit: IntroOfferPeriodUnit) -> PluralKey {
            switch unit {
            case .day: .unitNameDay
            case .week: .unitNameWeek
            case .month: .unitNameMonth
            case .year: .unitNameYear
            }
        }

        var english: PluralForms {
            switch self {
            case .durationDay: PluralForms(one: "${count} day", other: "${count} days")
            case .durationWeek: PluralForms(one: "${count} week", other: "${count} weeks")
            case .durationMonth: PluralForms(one: "${count} month", other: "${count} months")
            case .durationYear: PluralForms(one: "${count} year", other: "${count} years")
            case .periodDay: PluralForms(one: "/day", other: "/${count} days")
            case .periodWeek: PluralForms(one: "/week", other: "/${count} weeks")
            case .periodMonth: PluralForms(one: "/month", other: "/${count} months")
            case .periodYear: PluralForms(one: "/year", other: "/${count} years")
            case .unitNameDay: PluralForms(one: "day", other: "days")
            case .unitNameWeek: PluralForms(one: "week", other: "weeks")
            case .unitNameMonth: PluralForms(one: "month", other: "months")
            case .unitNameYear: PluralForms(one: "year", other: "years")
            }
        }
    }

    /// One plural entry: CLDR categories, `other` required, `${count}` placeholder.
    struct PluralForms: Codable, Equatable, Sendable {
        var zero: String?
        var one: String?
        var two: String?
        var few: String?
        var many: String?
        var other: String

        init(zero: String? = nil, one: String? = nil, two: String? = nil,
             few: String? = nil, many: String? = nil, other: String) {
            (self.zero, self.one, self.two, self.few, self.many, self.other) = (zero, one, two, few, many, other)
        }

        /// Whether `other` or any form present is blank: a broken translation, so the
        /// whole entry is dropped for English rather than patched with `other`, as on web.
        var hasBlankForm: Bool {
            [zero, one, two, few, many, other].contains { $0?.isBlank == true }
        }

        /// The form for `category`, else `other` when that form is absent.
        func form(_ category: PluralCategory) -> String {
            let picked: String? = switch category {
            case .zero: zero
            case .one: one
            case .two: two
            case .few: few
            case .many: many
            case .other: nil
            }
            return picked ?? other
        }
    }

    private let strings: [Key: String]
    private let plurals: [PluralKey: PluralForms]
    /// The served language (e.g. "fr", "pt"): the rules for served plural forms.
    private let locale: String?

    /// Keeps served ids this SDK knows, drops unknown or blank ones (a plural with any blank form).
    init(strings: [String: String] = [:], plurals: [String: PluralForms] = [:], locale: String? = nil) {
        var knownStrings: [Key: String] = [:]
        for (id, value) in strings {
            guard let key = Key(rawValue: id), !value.isBlank else { continue }
            knownStrings[key] = value
        }
        var knownPlurals: [PluralKey: PluralForms] = [:]
        for (id, forms) in plurals {
            guard let key = PluralKey(rawValue: id), !forms.hasBlankForm else { continue }
            knownPlurals[key] = forms
        }
        self.strings = knownStrings
        self.plurals = knownPlurals
        self.locale = locale
    }

    /// English only.
    static let english = SDKStrings()

    /// The strings `/config` served for the session's locale, English per missing id.
    static var current: SDKStrings { SDKStrings(served: remoteConfigManager?.servedCopyConfig) }

    /// The strings `config` carries; English when it carries none.
    init(served config: RemoteConfiguration?) {
        self.init(
            strings: config?.ui.values.strings ?? [:],
            plurals: config?.ui.values.plurals ?? [:],
            locale: config?.locale
        )
    }

    // MARK: - Lookup

    subscript(_ key: Key) -> String { strings[key] ?? key.english }

    /// The served value for `key`, or nil when English would render.
    func served(_ key: Key) -> String? { strings[key] }

    /// The served form for `count`, or nil when the locale lacks `key`, so a
    /// caller's own wording is never replaced by the SDK's English.
    func servedPlural(_ key: PluralKey, count: Int) -> String? {
        guard plurals[key] != nil else { return nil }
        return plural(key, count: count)
    }

    /// An `offerCtaText` binding: the offer's own wording, else `card.claim` when
    /// an offer is bound, else `card.get`. Same rule as Android.
    func offerCta(_ offer: Offer?) -> String {
        guard let offer else { return self[.offerCtaFallback] }
        return offer.servedCtaText ?? self[.cardClaim]
    }

    /// A gift category chip label: the English `categoryGroup` translated when
    /// it is one the catalog names, otherwise as sent.
    func giftCategory(_ group: String) -> String {
        Self.giftGroups[group].map { self[$0] } ?? group
    }

    private static let giftGroups: [String: Key] = [
        "Watch & listen": .giftCategoryWatch, "Money": .giftCategoryMoney, "Everyday": .giftCategoryEveryday,
    ]

    /// `self[key]` with `${name}` tokens replaced from `arguments`.
    func format(_ key: Key, _ arguments: [String: String]) -> String {
        Self.substitute(self[key], arguments)
    }

    /// The form for `count` with `${count}` filled in. Served forms follow the
    /// served locale's rules; English forms follow English's.
    func plural(_ key: PluralKey, count: Int) -> String {
        Self.substitute(form(key, count: count), ["count": "\(count)"])
    }

    private func form(_ key: PluralKey, count: Int) -> String {
        let (forms, language) = plurals[key].map { ($0, locale) } ?? (key.english, "en")
        return forms.form(PluralRules.category(count, language: language))
    }

    // MARK: - Durations

    /// A count with its unit, e.g. "7 days".
    func duration(_ count: Int, _ unit: IntroOfferPeriodUnit) -> String {
        plural(.duration(unit), count: count)
    }

    /// The unit word alone, e.g. "days", chosen by `count`.
    func unit(_ unit: IntroOfferPeriodUnit, count: Int) -> String {
        plural(.unitName(unit), count: count)
    }

    /// A billing period suffix, e.g. "/month" or "/3 months".
    func period(_ count: Int, _ unit: IntroOfferPeriodUnit) -> String {
        plural(.period(unit), count: count)
    }

    private static func substitute(_ text: String, _ arguments: [String: String]) -> String {
        arguments.reduce(text) { text, argument in
            text.replacingOccurrences(of: "${\(argument.key)}", with: argument.value)
        }
    }
}

// MARK: - Plurals

enum PluralCategory: Sendable { case zero, one, two, few, many, other }

/// CLDR cardinal rules for whole counts, by language subtag, for every language
/// CLDR has. Pinned to `Intl.PluralRules` (what web-sdk uses) by a test fixture;
/// a language CLDR lacks gets `one` for 1 only.
enum PluralRules {

    static func category(_ count: Int, language: String?) -> PluralCategory {
        let n = count.magnitude
        let mod10 = n % 10, mod100 = n % 100
        switch normalize(language) {
        case let base? where noPlural.contains(base):
            return .other
        case let base? where zeroIsOne.contains(base):
            return n <= 1 ? .one : .other
        case let base? where zeroOneOther.contains(base):
            return n == 0 ? .zero : (n == 1 ? .one : .other)
        case "fr", "pt":
            return n <= 1 ? .one : (n % 1_000_000 == 0 ? .many : .other)
        case "es", "it", "ca", "lld", "scn", "vec":
            return n == 1 ? .one : (n != 0 && n % 1_000_000 == 0 ? .many : .other)
        case "ru", "uk", "be":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "pl":
            if n == 1 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "cs", "sk":
            return n == 1 ? .one : ((2...4).contains(n) ? .few : .other)
        case "hr", "sr", "bs", "sh":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .other
        case "lt":
            if mod10 == 1 && !(11...19).contains(mod100) { return .one }
            if (2...9).contains(mod10) && !(11...19).contains(mod100) { return .few }
            return .other
        case "lv", "prg":
            if mod10 == 0 || (11...19).contains(mod100) { return .zero }
            return mod10 == 1 && mod100 != 11 ? .one : .other
        case "ro", "mo":
            if n == 1 { return .one }
            return n == 0 || (1...19).contains(mod100) ? .few : .other
        case "sl", "dsb", "hsb":
            switch mod100 {
            case 1: return .one
            case 2: return .two
            case 3, 4: return .few
            default: return .other
            }
        case "mk", "is":
            return mod10 == 1 && mod100 != 11 ? .one : .other
        case "he", "iu", "naq", "sat", "se", "sma", "smi", "smj", "smn", "sms":
            return n == 1 ? .one : (n == 2 ? .two : .other)
        case "ar", "ars":
            switch n {
            case 0: return .zero
            case 1: return .one
            case 2: return .two
            default: return (3...10).contains(mod100) ? .few : ((11...99).contains(mod100) ? .many : .other)
            }
        case "ga":
            switch n {
            case 1: return .one
            case 2: return .two
            case 3...6: return .few
            case 7...10: return .many
            default: return .other
            }
        case "cy":
            switch n {
            case 0: return .zero
            case 1: return .one
            case 2: return .two
            case 3: return .few
            case 6: return .many
            default: return .other
            }
        case "mt":
            if n == 1 { return .one }
            if n == 2 { return .two }
            if n == 0 || (3...10).contains(mod100) { return .few }
            return (11...19).contains(mod100) ? .many : .other
        case "fil", "ceb":
            return n <= 3 || ![4, 6, 9].contains(mod10) ? .one : .other
        case "br":
            if mod10 == 1 && ![11, 71, 91].contains(mod100) { return .one }
            if mod10 == 2 && ![12, 72, 92].contains(mod100) { return .two }
            if [3, 4, 9].contains(mod10) && !(10...19).contains(mod100) && !(70...79).contains(mod100)
                && !(90...99).contains(mod100) { return .few }
            return n != 0 && n % 1_000_000 == 0 ? .many : .other
        case "kw":
            let mod1000 = n % 1000, mod100k = n % 100_000
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if [2, 22, 42, 62, 82].contains(mod100)
                || (mod1000 == 0 && ((1000...20000).contains(mod100k) || [40000, 60000, 80000].contains(mod100k)))
                || n % 1_000_000 == 100_000 { return .two }
            if [3, 23, 43, 63, 83].contains(mod100) { return .few }
            return [1, 21, 41, 61, 81].contains(mod100) ? .many : .other
        case "gd":
            switch n {
            case 1, 11: return .one
            case 2, 12: return .two
            case 3...10, 13...19: return .few
            default: return .other
            }
        case "gv":
            if mod10 == 1 { return .one }
            if mod10 == 2 { return .two }
            return [0, 20, 40, 60, 80].contains(mod100) ? .few : .other
        case "sgs":
            if mod10 == 1 && mod100 != 11 { return .one }
            if n == 2 { return .two }
            return (2...9).contains(mod10) && !(11...19).contains(mod100) ? .few : .other
        case "shi":
            return n <= 1 ? .one : ((2...10).contains(n) ? .few : .other)
        case "tzm":
            return n <= 1 || (11...99).contains(n) ? .one : .other
        default:
            return n == 1 ? .one : .other
        }
    }

    /// The language subtag, lowercased, with legacy ISO codes mapped to current ones.
    private static func normalize(_ language: String?) -> String? {
        guard let base = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init), !base.isEmpty else { return nil }
        return legacy[base] ?? base
    }

    private static let legacy = ["iw": "he", "in": "id", "ji": "yi", "jw": "jv", "tl": "fil"]

    /// Languages with a single cardinal form.
    private static let noPlural: Set<String> = [
        "ja", "zh", "ko", "th", "vi", "id", "ms", "lo", "my", "km", "bo", "dz",
        "yo", "ig", "jv", "su", "to", "wo", "sg", "ii", "kea", "ses", "sah", "yue",
        "bm", "hnj", "jbo", "kde", "lkt", "nqo", "osa", "tpi",
    ]

    /// `one` covers 0 and 1; no `many`.
    private static let zeroIsOne: Set<String> = [
        "hi", "bn", "fa", "gu", "kn", "zu", "am", "as", "hy", "ff", "kab", "pcm", "si",
        "ak", "bho", "csw", "doi", "guw", "kok", "ln", "mg", "nso", "pa", "ti", "wa",
    ]

    /// `zero` for 0, `one` for 1, `other` otherwise.
    private static let zeroOneOther: Set<String> = ["blo", "cv", "ksh", "lag"]
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
