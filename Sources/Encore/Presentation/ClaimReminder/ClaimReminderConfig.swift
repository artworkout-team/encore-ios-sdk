// The claim reminder's variant: `ui.template` as it reads it (every field lenient) and
// the resolved config. The generic host does the `/config` fetch and envelope checks.

import Foundation

// MARK: - Layout

/// The reminder looks; a mount can pin one with `layout`. A served layout this SDK does not know (a
/// client's own look, served by a placement pin) draws its served tree and is reported as served.
@_spi(EncoreDemo) public enum ClaimReminderLayout: String, Sendable, Equatable, CaseIterable {
    case logoProgress
    case countdownHero
    case logoMarquee
    case progressBar
    /// 85 pt: a card (a gradient when the placement sets `backgroundEndColor`) with a 44 pt logo
    /// tile, a two-line title, the time left and a button. Served only when pinned.
    case featured

    init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .progressBar
    }
}

// MARK: - Strings

/// Reminder copy from `ui.template.strings`, which the server localizes per arm.
/// The built-in English covers only a missing or blank key.
internal struct ClaimReminderStrings: Sendable, Equatable {
    static let defaults: [String: String] = [
        "title": "Didn't finish? Your gift is still here",
        "offerTitle": "Finish your ${advertiserName} gift",
        "titleMany": "${claimCount} gifts still waiting",
        "subtitle": "Pick up right where you left off",
        "cta": "Continue",
        "dismiss": "Dismiss",
        "hours": "hr",
        "minutes": "min",
        "seconds": "sec",
        // Follows the countdown ("23:32 left").
        "left": "left",
    ]

    /// Keys the reminder fills itself; a look string of the same name is ignored (V-4).
    static let hostKeys: Set<String> = [
        "layout", "claimCount", "advertiserName", "advertiserInitial", "advertiserLogoUrl", "perk", "accessibilityTitle",
        "accessibilityHint", "icon", "appIconUrl", "start", "deadline", "claims", "marqueeLogos", "marqueeLogosA", "marqueeLogosB",
    ]

    private let resolved: [String: String]

    init(template: [String: String]) {
        resolved = TriggerStrings.resolve(template, over: Self.defaults)
    }

    var title: String { resolved["title"] ?? "" }
    var subtitle: String? { resolved["subtitle"] }
    /// The arrow's accessibility label; the designs show no CTA text.
    var cta: String { resolved["cta"] ?? "" }
    var dismiss: String { resolved["dismiss"] ?? "" }
    /// Countdown unit words; optional template keys `hours`, `minutes`, `seconds`.
    var hours: String { resolved["hours"] ?? "" }
    var minutes: String { resolved["minutes"] ?? "" }
    var seconds: String { resolved["seconds"] ?? "" }

    /// The title with `${advertiserName}` filled.
    func title(advertiser: String) -> String { Self.fill(title, advertiser: advertiser) }

    /// The subtitle with `${advertiserName}` filled.
    func subtitle(advertiser: String) -> String? { subtitle.map { Self.fill($0, advertiser: advertiser) } }

    private static func fill(_ text: String, advertiser: String) -> String {
        TriggerValues.fill(text, ["advertiserName": advertiser])
    }

    /// The title, plus the advertiser unless the title already names it.
    static func accessibilityTitle(title: String, advertiser: String) -> String {
        title.localizedCaseInsensitiveContains(advertiser) ? title : "\(title), \(advertiser)"
    }

    /// The look's `${key}` values with no claim (the thanks look): every string filled in one pass.
    func values(publisher: [String: String], overrides: [String: String] = [:]) -> [String: String] {
        TriggerValues.filled(
            resolved.merging(overrides) { _, edit in edit }, english: Self.defaults, publisher: publisher,
            host: ["advertiserName": "", "claimCount": "0"], hostKeys: Self.hostKeys
        )
    }

    /// The look's `${key}` values for `claim` among `claimCount` eligible claims (vocab-contract
    /// §2.2, §2.7): every string filled in one pass with `publisher` (``TriggerValues/publisher(mount:defaults:)``),
    /// the advertiser and the count, then the claim's own keys. A blank advertiser, a missing logo
    /// and a blank perk are absent, so `hasValue` is false for them.
    /// `overrides` (the DEBUG demo's text edits) replace strings before the fill.
    /// The title strings the reminder picks between by claim count and advertiser; a headline on one
    /// of them is spoken only when that branch is drawn.
    static let titleBranches: Set<String> = ["title", "offerTitle", "titleMany"]

    /// Whether the card draws the title string `key` for this claim: a title branch only when it is
    /// the one picked (count line on the marquee with 2+ claims, the offer's line with an advertiser,
    /// else the generic line); any other string always.
    static func drawsTitle(_ key: String, layout: ClaimReminderLayout, claimCount: Int, hasAdvertiser: Bool) -> Bool {
        guard titleBranches.contains(key) else { return true }
        if layout == .logoMarquee, claimCount >= 2 { return key == "titleMany" }
        return key == (hasAdvertiser ? "offerTitle" : "title")
    }

    /// The slots drawn with app text (S-8): a headline on a title branch this claim does not draw (the
    /// marquee's count line with 2+ claims, the generic line with no advertiser) is not drawn, so not counted.
    static func drawnSlots(
        _ drawn: [String], textSlots: [TriggerTextSlot: String], layout: ClaimReminderLayout, claimCount: Int, hasAdvertiser: Bool
    ) -> [String] {
        guard let key = textSlots[.headline], !drawsTitle(key, layout: layout, claimCount: claimCount, hasAdvertiser: hasAdvertiser) else { return drawn }
        return drawn.filter { $0 != TriggerTextSlot.headline.rawValue }
    }

    /// `headlineKey`: the look string its headline slot names; the card speaks it where it draws it (S-4).
    func values(
        for claim: ReminderClaim, layout: ClaimReminderLayout, claimCount: Int = 1, publisher: [String: String] = [:],
        overrides: [String: String] = [:], headlineKey: String? = nil
    ) -> [String: String] {
        let advertiser = claim.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = TriggerValues.filled(
            resolved.merging(overrides) { _, edit in edit }, english: Self.defaults, publisher: publisher,
            host: ["advertiserName": advertiser, "claimCount": String(claimCount)], hostKeys: Self.hostKeys
        )
        values["layout"] = layout.rawValue
        values["claimCount"] = String(claimCount)
        values["advertiserLogoUrl"] = claim.advertiserLogoUrl?.absoluteString
        if !advertiser.isEmpty {
            values["advertiserName"] = advertiser
            values["advertiserInitial"] = advertiser.first.map { String($0).uppercased() }
        }
        let perk = claim.perk.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        values["perk"] = perk
        values["accessibilityHint"] = perk ?? values["subtitle"]
        // The title the tree draws: the count on the marquee with several claims, else the offer's
        // own line when the advertiser is named, else the generic line.
        let drawn: String?
        if layout == .logoMarquee, claimCount >= 2 {
            drawn = values["titleMany"]
        } else if let key = headlineKey, !Self.titleBranches.contains(key), let headline = values[key], !headline.isEmpty {
            // A headline on a line of its own (Walkie's talkTitle), drawn whatever the advertiser.
            drawn = headline
        } else if !advertiser.isEmpty {
            drawn = values["offerTitle"]
        } else {
            drawn = values["title"]
        }
        let spoken = drawn ?? values["title"] ?? ""
        values["accessibilityTitle"] = advertiser.isEmpty ? spoken : Self.accessibilityTitle(title: spoken, advertiser: advertiser)
        return values
    }
}

// MARK: - Config

/// One resolved reminder variant.
internal struct ClaimReminderConfig: Sendable, Equatable {
    static let defaultWindowHours: Double = 24
    /// Longer windows are malformed. The backend refuses to serve one.
    static let maxWindowHours: Double = 720

    typealias Colors = TriggerColors

    let layout: ClaimReminderLayout
    /// How long after the claim the banner shows. Not an offer expiry.
    let windowHours: Double
    let dismissible: Bool
    let colors: Colors
    /// The look's light palette; nil uses Encore's light default.
    var lightColors: Colors? = nil
    let strings: ClaimReminderStrings
    /// The checked look, or why it cannot be drawn.
    let look: Result<TriggerLook, TriggerUnrenderable>
    let maxFontScale: Double
    /// The look's `values` defaults; a mount's own value overrides each.
    var valueDefaults: [String: String] = [:]
    /// The app text this look takes: each slot over one of its own strings.
    var textSlots: [TriggerTextSlot: String] = [:]
    /// The layout events and `${layout}` report: the served one, which the tree draws even when this
    /// SDK has no case for it.
    var eventLayout: String

    var window: TimeInterval { windowHours * 3600 }

    /// ``eventLayout`` for a served wire value decoded as `layout`.
    static func eventLayout(wire: String?, decoded layout: ClaimReminderLayout) -> String {
        guard let wire = wire?.trimmingCharacters(in: .whitespacesAndNewlines), !wire.isEmpty,
              ClaimReminderLayout(rawValue: wire) == nil else { return layout.rawValue }
        return String(wire.prefix(64))
    }

    init(
        layout: ClaimReminderLayout, windowHours: Double, dismissible: Bool, colors: Colors, strings: ClaimReminderStrings,
        look: Result<TriggerLook, TriggerUnrenderable> = .failure(TriggerUnrenderable(path: "root", detail: "missing")),
        maxFontScale: Double = TriggerLookSource.defaultMaxFontScale
    ) {
        self.layout = layout
        self.windowHours = windowHours
        self.dismissible = dismissible
        self.colors = colors
        self.strings = strings
        self.look = look
        self.maxFontScale = maxFontScale
        self.eventLayout = layout.rawValue
    }

    init(template: ClaimReminderTemplate) {
        let window = template.windowHours.flatMap {
            $0.isFinite && $0 > 0 && $0 <= Self.maxWindowHours ? $0 : nil
        }
        let dismissible = template.dismissible ?? true
        self.init(
            layout: ClaimReminderLayout(wire: template.layout),
            windowHours: window ?? Self.defaultWindowHours,
            dismissible: dismissible,
            colors: template.colors ?? .none,
            strings: ClaimReminderStrings(template: template.strings ?? [:]),
            // The reminder has no auto arm: every layout draws its root.
            look: TriggerLookCheck.check(template.look, vocabulary: .v1, rules: .claimReminder(dismissible: dismissible))
                ?? .failure(TriggerUnrenderable(path: "root", detail: "missing")),
            maxFontScale: template.look.maxFontScale
        )
        lightColors = template.lightColors
        valueDefaults = (try? template.look.defaults.get()) ?? [:]
        textSlots = template.look.textSlots
        eventLayout = Self.eventLayout(wire: template.layout, decoded: layout)
    }
}

// MARK: - Template

/// `ui.template` as the reminder reads it. Every field is optional and a malformed
/// one reads as absent, so no served shape can fail the decode.
internal struct ClaimReminderTemplate: Decodable, Sendable {
    let layout: String?
    let windowHours: Double?
    let dismissible: Bool?
    let colors: TriggerColors?
    let lightColors: TriggerColors?
    let strings: [String: String]?
    /// `root`, `maxFontScale` and any keys outside the template's own.
    let look: TriggerLookSource

    private enum CodingKeys: String, CodingKey { case layout, windowHours, dismissible, colors, lightColors, strings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try? container.decodeIfPresent(String.self, forKey: .layout)
        windowHours = try? container.decodeIfPresent(Double.self, forKey: .windowHours)
        dismissible = try? container.decodeIfPresent(Bool.self, forKey: .dismissible)
        colors = try? container.decodeIfPresent(TriggerColors.self, forKey: .colors)
        lightColors = try? container.decodeIfPresent(TriggerColors.self, forKey: .lightColors)
        strings = (try? container.decodeIfPresent(TriggerStrings.self, forKey: .strings))?.values
        look = (try? TriggerLookSource(from: decoder)) ?? TriggerLookSource(root: nil)
    }
}
