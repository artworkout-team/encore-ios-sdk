// GiftsButton's variant: its layout, colours and copy, read leniently from `ui.template`.

import Foundation
import CoreGraphics

// MARK: - Layout

/// The GiftsButton looks a demo or test can pin with `layout` (apps never pin: Encore picks per placement).
@_spi(EncoreDemo) public enum GiftsButtonLayout: String, Sendable, Equatable, CaseIterable {
    case card
    case pulse
    case banner
    case pill
    /// The card with a scrolling strip of the waiting offers' logos; the plain card below 3 logos.
    case offerMarquee
    /// The card with two scrolling columns of the waiting offers' logos; the plain card below 3 logos.
    case offerColumns
    /// The card with a gift-card face printing your `values: ["amount": ...]` ("$" without one).
    case giftCard
    /// The plain card, "Your gift is still waiting".
    case stillWaiting
}

/// The layouts `/config` can serve. A layout this SDK does not know draws its served tree with the
/// card's fallback copy, and its events report it as served.
internal enum GiftsButtonServedLayout: String, Sendable, Equatable, CaseIterable {
    case card
    case pill
    case pulse
    case banner
    /// The card with a strip of the held offers' logos.
    case offerMarquee
    /// The card with two columns of the held offers' logos.
    case offerColumns
    /// The card with a gift-card face printing `${values.amount}`.
    case giftCard
    /// The plain card, still waiting.
    case stillWaiting
    /// `afterComplete: .thanks`'s look, asked for only after a completed claim; never an arm or a pin.
    case thanks

    init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .card
    }
}

// MARK: - Strings

/// Copy from `template.strings`, localized by the server. English covers only a missing
/// or blank key, and differs per layout.
internal struct GiftsButtonStrings: Sendable, Equatable {
    static func defaults(for layout: GiftsButtonServedLayout) -> [String: String] {
        switch layout {
        case .card:
            return ["title": "You have a gift", "subtitle": "Tap to see what's inside", "cta": "Open gift"]
        case .pill:
            return ["cta": "Open gift"]
        case .pulse:
            return ["title": "Tap to open your gift", "cta": "Open gift"]
        case .banner:
            return ["title": "A little thank you", "subtitle": "Pick a gift from our partners", "cta": "Open"]
        case .offerMarquee, .offerColumns:
            return ["title": "You have a gift", "subtitle": "Tap to see what's inside", "cta": "Open gift",
                    "offersTitle": "Pick a gift, on us"]
        case .giftCard:
            return ["title": "Your gift card", "subtitle": "Tap to see your offers", "cta": "Open gift"]
        case .stillWaiting:
            return ["title": "Your gift is still waiting", "subtitle": "Tap to see what's inside", "cta": "Open gift"]
        case .thanks:
            return ["title": "Nice work, you finished it", "subtitle": "More gifts are waiting", "cta": "See gifts"]
        }
    }

    /// Keys GiftsButton fills itself; a look string of the same name is ignored (V-4).
    static let hostKeys: Set<String> = ["layout", "icon", "appIconUrl", "offerLogos", "offerLogosA", "offerLogosB", "offerCount", "perk", "isNew"]

    private let resolved: [String: String]
    private let english: [String: String]

    init(template: [String: String], layout: GiftsButtonServedLayout) {
        english = Self.defaults(for: layout)
        resolved = TriggerStrings.resolve(template, over: english)
    }

    var title: String { resolved["title"] ?? "" }
    var subtitle: String? { resolved["subtitle"] }
    var cta: String { resolved["cta"] ?? "" }

    /// The look's `${key}` values: every resolved string filled in one pass with `publisher`
    /// (``TriggerValues/publisher(mount:defaults:)``), plus the layout drawn.
    /// `overrides` (the DEBUG demo's text edits) replace strings before the fill.
    func values(layout: GiftsButtonServedLayout, publisher: [String: String] = [:], overrides: [String: String] = [:]) -> [String: String] {
        var values = TriggerValues.filled(resolved.merging(overrides) { _, edit in edit }, english: english, publisher: publisher, hostKeys: Self.hostKeys)
        values["layout"] = layout.rawValue
        return values
    }
}

// MARK: - Config

internal struct GiftsButtonConfig: Sendable, Equatable {
    let layout: GiftsButtonServedLayout
    let colors: TriggerColors
    /// The look's light palette; nil uses Encore's light default.
    var lightColors: TriggerColors? = nil
    let strings: GiftsButtonStrings
    /// The checked look, or why it cannot be drawn; nil for a config the SDK made with no look.
    let look: Result<TriggerLook, TriggerUnrenderable>?
    let maxFontScale: Double
    /// The look's `values` defaults; a mount's own value overrides each.
    var valueDefaults: [String: String] = [:]
    /// The app text this look takes: each slot over one of its own strings.
    var textSlots: [TriggerTextSlot: String] = [:]
    /// The look's `behavior.autoOpen` is `on`: it opens the sheet once by itself where the mount and
    /// device allow.
    var autoOpen = false
    /// The layout events report: the one drawn. A served layout this SDK does not know still draws
    /// its served tree (with the card's fallback copy), so it is reported as served; `custom` is
    /// reserved for app-drawn views, so it reads as the card it falls back to.
    var eventLayout: String

    /// A step's state look (thanks, offerPreview): never opens the sheet by itself.
    var isStateLook: Bool { TriggerBehavior.stateLayouts.contains(eventLayout) }

    /// ``eventLayout`` for a served wire value decoded as `layout`.
    static func eventLayout(wire: String?, decoded layout: GiftsButtonServedLayout) -> String {
        guard let wire = wire?.trimmingCharacters(in: .whitespacesAndNewlines), !wire.isEmpty,
              wire != "custom", GiftsButtonServedLayout(rawValue: wire) == nil else { return layout.rawValue }
        return String(wire.prefix(64))
    }

    init(
        layout: GiftsButtonServedLayout, colors: TriggerColors = .none, strings: [String: String] = [:],
        look: Result<TriggerLook, TriggerUnrenderable>? = nil, maxFontScale: Double = TriggerLookSource.defaultMaxFontScale
    ) {
        self.layout = layout
        self.colors = colors
        self.strings = GiftsButtonStrings(template: strings, layout: layout)
        self.look = look
        self.maxFontScale = maxFontScale
        self.eventLayout = layout.rawValue
    }

    init(template: GiftsButtonTemplate) {
        let layout = GiftsButtonServedLayout(wire: template.layout)
        self.init(
            layout: layout, colors: template.colors ?? .none, strings: template.strings ?? [:],
            look: TriggerLookCheck.check(template.look, vocabulary: .v1, rules: .giftsButton),
            maxFontScale: template.look.maxFontScale
        )
        lightColors = template.lightColors
        eventLayout = Self.eventLayout(wire: template.layout, decoded: layout)
        valueDefaults = (try? template.look.defaults.get()) ?? [:]
        textSlots = template.look.textSlots
        autoOpen = TriggerBehavior.resolved(template.look.behavior, trigger: GiftsButtonTrigger.id)["autoOpen"] == TriggerBehavior.autoOpenOn
    }
}

/// `ui.template` as GiftsButton reads it. A malformed field reads as absent.
internal struct GiftsButtonTemplate: Decodable, Sendable {
    let layout: String?
    let colors: TriggerColors?
    let lightColors: TriggerColors?
    let strings: [String: String]?
    /// `root`, `maxFontScale` and any keys outside the template's own.
    let look: TriggerLookSource

    private enum CodingKeys: String, CodingKey { case layout, colors, lightColors, strings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try? container.decodeIfPresent(String.self, forKey: .layout)
        colors = try? container.decodeIfPresent(TriggerColors.self, forKey: .colors)
        lightColors = try? container.decodeIfPresent(TriggerColors.self, forKey: .lightColors)
        strings = (try? container.decodeIfPresent(TriggerStrings.self, forKey: .strings))?.values
        look = (try? TriggerLookSource(from: decoder)) ?? TriggerLookSource(root: nil)
    }
}
