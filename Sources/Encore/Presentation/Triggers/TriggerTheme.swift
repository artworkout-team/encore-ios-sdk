// A trigger's three colours: the publisher's `AppearanceConfig` first, then the
// variant's `template.colors`, then the built-in default. Shared by every trigger.

import SwiftUI

/// `template.colors` as served: raw hex, parsed at theme resolution.
internal struct TriggerColors: Sendable, Equatable, Decodable {
    let background: String?
    let accent: String?
    let text: String?

    private enum CodingKeys: String, CodingKey { case background, accent, text }

    init(background: String?, accent: String?, text: String?) {
        self.background = background
        self.accent = accent
        self.text = text
    }

    /// A malformed colour reads as absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = try? container.decodeIfPresent(String.self, forKey: .background)
        accent = try? container.decodeIfPresent(String.self, forKey: .accent)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }

    static let none = TriggerColors(background: nil, accent: nil, text: nil)
}

/// `template.strings` as served: non-string entries are dropped instead of failing.
internal struct TriggerStrings: Decodable, Sendable {
    let values: [String: String]

    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) { values[key.stringValue] = value }
        }
        self.values = values
    }

    /// Served values over `fallbacks`; a blank served value counts as missing.
    static func resolve(_ served: [String: String]?, over fallbacks: [String: String]) -> [String: String] {
        var resolved = fallbacks
        for (key, value) in served ?? [:] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved[key] = value
        }
        return resolved
    }
}

/// Light or dark for one trigger mount: the publisher's `colorScheme`, else the portal's saved mode
/// (`auto` follows the device), else dark.
internal enum TriggerColorScheme: Equatable, Sendable {
    case light
    case dark
    case system

    static func resolve(publisher: AppearanceConfig.ColorScheme?, portalMode: String?) -> TriggerColorScheme {
        switch publisher {
        case .light: return .light
        case .dark: return .dark
        case .system: return .system
        case nil: break
        }
        switch portalMode {
        case "light": return .light
        case "auto": return .system
        default: return .dark
        }
    }
}

/// Which of a look's palettes draws: its `colors` (dark) or its `lightColors`.
internal enum TriggerPalette: Equatable, Sendable {
    case dark
    case light

    /// Encore's own colours when nothing else sets a key.
    var fallback: TriggerTheme {
        switch self {
        case .dark: return .default
        case .light: return .lightDefault
        }
    }
}

/// The icon a trigger's look draws in its gift spot.
public enum TriggerIcon: String, Sendable, Hashable, CaseIterable {
    /// Encore's gift (the default).
    case gift
    /// Your app's App Store icon from Encore; the gift when Encore has none.
    case appIcon
    /// No icon.
    case none
}

extension TriggerIcon {

    /// The tree's icon values: the app icon only when the portal has one, else the gift.
    func values(portal: TriggerPortalTheme?) -> [String: String] {
        guard self == .appIcon else { return ["icon": rawValue] }
        guard let url = portal?.appIconUrl else { return ["icon": Self.gift.rawValue] }
        return ["icon": rawValue, "appIconUrl": url]
    }
}

/// What one mount draws with: the scheme's palette, plus the light one beside it when the scheme
/// follows the device (the view picks by its own appearance).
internal struct TriggerThemes: Equatable {
    let primary: TriggerTheme
    /// Set only for `system`: the palette for a light device.
    let light: TriggerTheme?

    static func resolve(appearance: AppearanceConfig?, portal: TriggerPortalTheme?, colors: TriggerColors, lightColors: TriggerColors?) -> TriggerThemes {
        func theme(_ palette: TriggerPalette) -> TriggerTheme {
            TriggerTheme.resolve(appearance: appearance, portal: portal, variant: colors, light: lightColors, palette: palette)
        }
        switch TriggerColorScheme.resolve(publisher: appearance?.colorScheme, portalMode: portal?.mode) {
        case .dark: return TriggerThemes(primary: theme(.dark), light: nil)
        case .light: return TriggerThemes(primary: theme(.light), light: nil)
        case .system: return TriggerThemes(primary: theme(.dark), light: theme(.light))
        }
    }
}

internal struct TriggerTheme: Equatable {
    let background: AppearanceHex.RGBA
    let accent: AppearanceHex.RGBA
    let text: AppearanceHex.RGBA
    /// The publisher's own inks, drawn exactly as set; nil falls back in the tree.
    var secondary: AppearanceHex.RGBA? = nil
    var track: AppearanceHex.RGBA? = nil
    var onAccentOverride: AppearanceHex.RGBA? = nil
    /// The publisher's gradient end; nil keeps the look solid in ``background``.
    var backgroundEnd: AppearanceHex.RGBA? = nil

    static let `default` = TriggerTheme(
        background: AppearanceHex.RGBA(r: 0x1E, g: 0x1F, b: 0x24, a: 255),
        accent: AppearanceHex.RGBA(r: 0xDE, g: 0xB7, b: 0x69, a: 255),
        text: AppearanceHex.RGBA(r: 255, g: 255, b: 255, a: 255)
    )

    static let lightDefault = TriggerTheme(
        background: AppearanceHex.RGBA(r: 0xFF, g: 0xFF, b: 0xFF, a: 255),
        accent: AppearanceHex.RGBA(r: 0xA3, g: 0x74, b: 0x1C, a: 255),
        text: AppearanceHex.RGBA(r: 0x1B, g: 0x1C, b: 0x20, a: 255)
    )

    /// Per key: the publisher's colour, the portal's (an accent), the look's palette for `palette`
    /// (`colors` in dark, `lightColors` in light), then Encore's default. A bad value falls back one
    /// level. A publisher text colour applies on its own; text without one gets black or white on
    /// a publisher background, so a brand background never carries the look's text unread.
    static func resolve(
        appearance: AppearanceConfig?,
        portal: TriggerPortalTheme? = nil,
        variant: TriggerColors,
        light: TriggerColors? = nil,
        palette: TriggerPalette = .dark
    ) -> TriggerTheme {
        let look = palette == .dark ? variant : (light ?? .none)
        let fallback = palette.fallback
        let publisherBackground = AppearanceHex.parseField(appearance?.backgroundColor, name: "backgroundColor")
        let publisherText = AppearanceHex.parseField(appearance?.textColor, name: "textColor")
        let lookBackground = look.background.flatMap(AppearanceHex.parse)
        let lookText = look.text.flatMap(AppearanceHex.parse)
        let accent = AppearanceHex.parseField(appearance?.accentColor, name: "accentColor")
            ?? portal?.accentColor.flatMap(AppearanceHex.parse)
            ?? look.accent.flatMap(AppearanceHex.parse)
            ?? fallback.accent
        let background = publisherBackground ?? lookBackground ?? fallback.background
        let text: AppearanceHex.RGBA
        if let publisherText {
            text = publisherText
        } else if let publisherBackground {
            text = publisherBackground.contrastingInk
        } else {
            text = lookText ?? lookBackground?.contrastingInk ?? fallback.text
        }
        return TriggerTheme(
            background: background,
            accent: accent,
            text: text,
            secondary: AppearanceHex.parseField(appearance?.secondaryTextColor, name: "secondaryTextColor"),
            track: AppearanceHex.parseField(appearance?.trackColor, name: "trackColor"),
            onAccentOverride: AppearanceHex.parseField(appearance?.onAccentColor, name: "onAccentColor"),
            backgroundEnd: AppearanceHex.parseField(appearance?.backgroundEndColor, name: "backgroundEndColor")
        )
    }

    /// Black or white, whichever reads on the accent as drawn (the arrow's glyph).
    var onAccent: Color { onAccentInk.color }

    /// ``onAccent`` as a colour value, for the SDUI look's `onAccent` token: the publisher's when set.
    var onAccentInk: AppearanceHex.RGBA { onAccentOverride ?? drawnAccent.contrastingInk }

    /// Ink for content on an accent fill: the surface colour, as designed, unless it is
    /// translucent or too close to read (under 3:1) against the accent as drawn, then black or white.
    var inkOnAccent: AppearanceHex.RGBA {
        if let onAccentOverride { return onAccentOverride }
        let accent = drawnAccent
        return background.a == 255 && AppearanceHex.RGBA.contrastRatio(background, accent) >= 3 ? background : accent.contrastingInk
    }

    /// The accent as it reads on screen: a translucent accent composited over the surface.
    private var drawnAccent: AppearanceHex.RGBA {
        guard accent.a < 255 else { return accent }
        let surface = AppearanceHex.RGBA(r: background.r, g: background.g, b: background.b, a: 255)
        return surface.mixed(toward: accent, Double(accent.a) / 255)
    }
}

extension AppearanceHex.RGBA {
    static let white = AppearanceHex.RGBA(r: 255, g: 255, b: 255, a: 255)
    static let black = AppearanceHex.RGBA(r: 0, g: 0, b: 0, a: 255)

    /// This colour moved `amount` (0...1) of the way toward `other`.
    func mixed(toward other: AppearanceHex.RGBA, _ amount: Double) -> AppearanceHex.RGBA {
        let t = min(1, max(0, amount))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return AppearanceHex.RGBA(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b), a: a)
    }
}
