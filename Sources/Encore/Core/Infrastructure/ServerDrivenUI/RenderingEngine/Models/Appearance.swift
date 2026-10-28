//
//  Appearance.swift
//  Encore
//
//  Semantic color token system for per-app theming in SDUI variants.
//  Variant JSON references colors by role (e.g. `.accent`, `.background`)
//  instead of raw hex, so the same variant renders in each host app's brand
//  without touching the JSON.
//

import SwiftUI

// MARK: - Appearance Color Tokens

/// Semantic color roles for SDUI variants.
///
/// Encore theme tokens, distinct from Apple semantics in `SDUISemanticColor`.
/// Filled from the placement's `AppearanceConfig` and the server's accent colours.
///
/// **Add a new token by:**
/// 1. Adding the case here.
/// 2. Adding a stored property to `Appearance`.
/// 3. Adding the case to `Appearance.color(for:)`.
/// 4. Providing a default in `Appearance.default`.
/// 5. Wiring its source (`AppearanceConfig` or `UIValues`) in `Appearance.init(from:overrides:)`.
///
/// Renaming a case is a breaking change for every shipped variant JSON that
/// references it — treat this enum as a stable public contract.
enum SDUIAppearanceColor: String, Decodable {
    /// Primary brand colour for CTAs and selected states: placement `accentColor`, else the server accent.
    case accent

    /// Foreground color (text, icons) that sits on top of `.accent`.
    /// Must read legibly at AA contrast against `.accent`. Default: white.
    case onAccent

    /// Secondary accent used for title highlights — e.g. the "for free" run
    /// in a segmented heading. Sourced from `RemoteConfig.accentTitleColor`.
    case accentTitle

    /// Root background of the sheet / screen. Default: system grouped background.
    case background

    /// Foreground color (text, icons) that sits on top of `.background`.
    /// Default: primary label.
    case onBackground

    /// Elevated surface — cards, rows, modals inside the background. Default:
    /// system background.
    case surface

    /// Foreground color that sits on top of `.surface`. Default: primary label.
    case onSurface

    /// Stroke/divider color. Default: separator.
    case border

    /// De-emphasized text/icon color for secondary copy, disabled states,
    /// helper text. Default: secondary label.
    case muted

    /// Ink for content on an accent fill (trigger mounts only): the trigger's background colour
    /// when it reads on the accent, else black or white. A sheet using it fails to decode.
    case inkOnAccent

    /// Secondary copy (trigger mounts only): the publisher's secondary text colour, else the text colour.
    case secondary

    /// Progress tracks (trigger mounts only): the publisher's track colour, else the text colour.
    case track

    /// A background gradient's second stop (trigger mounts only): the publisher's
    /// `backgroundEndColor`, else the background, so a card is solid unless the placement sets it.
    case backgroundEnd

    /// Tokens that exist only in trigger mounts; a sheet using one fails to decode.
    static let triggerOnly: Set<SDUIAppearanceColor> = [.inkOnAccent, .secondary, .track, .backgroundEnd]

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Trigger-only tokens fail like any unknown token outside a trigger mount.
        guard let token = SDUIAppearanceColor(rawValue: raw),
              !Self.triggerOnly.contains(token) || (decoder.userInfo[.sduiTriggerMount] as? Bool) == true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown appearance token \(raw)"))
        }
        self = token
    }

    /// Destructive/error color. Default: system red.
    case error
}

// MARK: - Appearance

/// Resolved once per presentation in `SDUIContext` (placement overrides, server accents, defaults)
/// and injected via `\.sduiAppearance` for `ViewModifier`s.
///
/// A reference type with identity equality: SwiftUI can then skip dependent
/// modifiers when the same presentation's appearance is re-injected, instead
/// of invalidating every `sduiAppearance` reader on each render (an iOS 17
/// layout-loop trigger). Every property is an immutable `Sendable` value.
final class Appearance: Equatable, Sendable {
    let accent: Color
    let onAccent: Color
    let accentTitle: Color
    let background: Color
    let onBackground: Color
    let surface: Color
    let onSurface: Color
    let border: Color
    let muted: Color
    let error: Color
    /// True when a publisher background is set, so system colours resolve onto tokens.
    let themesSemantics: Bool
    /// Set only by a trigger mount (`inkOnAccent` decodes nowhere else).
    let inkOnAccent: Color?
    /// The publisher's own secondary text and track colours (trigger mounts only). Unset, the
    /// tokens fall back to `onBackground`, faded by the node's opacity.
    let secondary: Color?
    let track: Color?
    /// The publisher's `backgroundEndColor` (trigger mounts only); unset, `backgroundEnd` is the background.
    let backgroundEnd: Color?

    static func == (lhs: Appearance, rhs: Appearance) -> Bool {
        lhs === rhs
    }

    /// Whether `token` is a colour the publisher set, which a node's opacity never fades.
    func isPublisherSet(_ token: SDUIAppearanceColor) -> Bool {
        switch token {
        case .secondary: return secondary != nil
        case .track: return track != nil
        case .backgroundEnd: return backgroundEnd != nil
        default: return false
        }
    }

    /// Lookup — the *only* place the enum-to-stored-property mapping lives.
    /// Adding a token = add a case here.
    func color(for token: SDUIAppearanceColor) -> Color {
        switch token {
        case .accent:       return accent
        case .onAccent:     return onAccent
        case .accentTitle:  return accentTitle
        case .background:   return background
        case .onBackground: return onBackground
        case .surface:      return surface
        case .onSurface:    return onSurface
        case .border:       return border
        case .muted:        return muted
        case .error:        return error
        case .inkOnAccent:  return inkOnAccent ?? onAccent
        case .secondary:    return secondary ?? onBackground
        case .track:        return track ?? onBackground
        case .backgroundEnd: return backgroundEnd ?? background
        }
    }

    /// Neutral default palette — used when no `UIValues` are available (zero
    /// network, test environments) and as per-token fallback for tokens the
    /// backend has not yet filled in.
    ///
    /// The accent color defaults to Encore's brand purple so the SDK has a
    /// sensible look out of the box before any host-app configuration.
    static let `default` = Appearance(
        accent:       Color(hex: "#6743F5"),
        onAccent:     .white,
        accentTitle:  Color(hex: "#16BD25"),
        background:   Color(UIColor.systemGroupedBackground),
        onBackground: Color(UIColor.label),
        surface:      Color(UIColor.secondarySystemGroupedBackground),
        onSurface:    Color(UIColor.label),
        border:       Color(UIColor.separator),
        muted:        Color(UIColor.secondaryLabel),
        error:        Color(UIColor.systemRed)
    )

    /// Builds the session appearance: placement overrides, then server accents, then defaults.
    init(from uiValues: UIValues?, overrides: AppearanceConfig? = nil) {
        let fallback = Appearance.default
        let serverAccent = uiValues?.accentColor.flatMap { Color(hex: $0) }
        let accentOverride = AppearanceHex.parseField(overrides?.accentColor, name: "accentColor")?.color
        self.accent = accentOverride ?? serverAccent ?? fallback.accent
        self.onAccent = fallback.onAccent
        self.accentTitle = uiValues?.accentTitleColor.flatMap { Color(hex: $0) } ?? fallback.accentTitle
        self.error = fallback.error
        self.inkOnAccent = nil
        self.secondary = nil
        self.track = nil
        self.backgroundEnd = nil

        // Web derives surface/border/muted from background + text (web-sdk styles.ts).
        guard let background = AppearanceHex.parseField(overrides?.backgroundColor, name: "backgroundColor") else {
            self.background = fallback.background
            self.onBackground = fallback.onBackground
            self.surface = fallback.surface
            self.onSurface = fallback.onSurface
            self.border = fallback.border
            self.muted = fallback.muted
            self.themesSemantics = false
            return
        }
        let text = AppearanceHex.parseField(overrides?.textColor, name: "textColor") ?? background.contrastingInk
        let backgroundColor = background.color
        let textColor = text.color
        self.background = backgroundColor
        self.onBackground = textColor
        self.onSurface = textColor
        self.muted = textColor.opacity(0.6)
        self.surface = backgroundColor.sduiMixed(with: textColor, amount: 0.05)
        self.border = backgroundColor.sduiMixed(with: textColor, amount: 0.10)
        self.themesSemantics = true
    }

    /// Apple semantic colour, mapped onto a token when `themesSemantics` is on.
    func semanticColor(_ semantic: SDUISemanticColor) -> Color {
        guard themesSemantics else { return semantic.color }
        switch semantic {
        case .systemGroupedBackground: return background
        case .systemBackground, .secondarySystemBackground, .secondarySystemGroupedBackground: return surface
        case .label: return onBackground
        case .secondaryLabel, .tertiaryLabel: return muted
        case .separator, .tertiarySystemFill: return border
        }
    }

    /// Explicit memberwise initializer used by `.default`, trigger mounts and tests.
    /// The trigger-only tokens are parameters because an instance is never mutated.
    init(
        accent: Color,
        onAccent: Color,
        accentTitle: Color,
        background: Color,
        onBackground: Color,
        surface: Color,
        onSurface: Color,
        border: Color,
        muted: Color,
        error: Color,
        inkOnAccent: Color? = nil,
        secondary: Color? = nil,
        track: Color? = nil,
        backgroundEnd: Color? = nil
    ) {
        self.accent = accent
        self.onAccent = onAccent
        self.accentTitle = accentTitle
        self.background = background
        self.onBackground = onBackground
        self.surface = surface
        self.onSurface = onSurface
        self.border = border
        self.muted = muted
        self.error = error
        self.themesSemantics = false
        self.inkOnAccent = inkOnAccent
        self.secondary = secondary
        self.track = track
        self.backgroundEnd = backgroundEnd
    }
}

// MARK: - Environment

/// SwiftUI environment key holding the active `Appearance`. Set once at the
/// SDUI render root in `OfferSheetView`; read by any `ViewModifier` that
/// needs to resolve `SDUIColor.appearance(_)`.
@available(iOS 17.0, *)
private struct SDUIAppearanceKey: EnvironmentKey {
    static let defaultValue: Appearance = .default
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiAppearance: Appearance {
        get { self[SDUIAppearanceKey.self] }
        set { self[SDUIAppearanceKey.self] = newValue }
    }
}

/// SwiftUI environment holding the color-binding values dictionary
/// (`context.values` plus per-render overrides like `offerDominantColor`).
/// Lets generic `ViewModifier`s — which have no `SDUIContext` — resolve
/// `SDUIColor.binding(_)` (e.g. for `gradientBorder`). Set at the SDUI render
/// root and refreshed per element where row-scoped overrides apply.
@available(iOS 17.0, *)
private struct SDUIColorValuesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiColorValues: [String: String] {
        get { self[SDUIColorValuesKey.self] }
        set { self[SDUIColorValuesKey.self] = newValue }
    }
}

/// How far the enclosing carousel card is from the centered card, as an integer
/// distance (`abs(index - currentIndex)`). Set per card in `renderForEach` so
/// descendant `scrollFade` layers (brand-color fill, checkmark badge) know
/// whether they belong to the focused card without any scroll geometry.
///
/// Default `0` (== centered) so static / non-carousel contexts render fade
/// layers at full `centeredOpacity`, matching the pre-existing "no scroll
/// context → show the layer" behavior.
@available(iOS 17.0, *)
private struct SDUIScrollFadeDistanceKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

/// Width of the carousel viewport. Nil outside a centered offer carousel so
/// ordinary `scrollTransition` elements keep SwiftUI's native phase.
@available(iOS 17.0, *)
private struct SDUICarouselViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiScrollFadeDistance: Double {
        get { self[SDUIScrollFadeDistanceKey.self] }
        set { self[SDUIScrollFadeDistanceKey.self] = newValue }
    }

    var sduiCarouselViewportWidth: CGFloat? {
        get { self[SDUICarouselViewportWidthKey.self] }
        set { self[SDUICarouselViewportWidthKey.self] = newValue }
    }
}

/// Whether the enclosing scroll view centers its snapped cards
/// (`scrollAlignment: center`) and so needs the first offer card's laid-out
/// width. Set by `renderScrollView` on the carousel content; `renderForEach`
/// only attaches the measuring `GeometryReader` when it is true, so legacy
/// templates do no extra layout work.
@available(iOS 17.0, *)
private struct SDUIMeasuresCarouselItemWidthKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiMeasuresCarouselItemWidth: Bool {
        get { self[SDUIMeasuresCarouselItemWidthKey.self] }
        set { self[SDUIMeasuresCarouselItemWidthKey.self] = newValue }
    }
}

/// Whether an enclosing offer row OWNS the impression decision for this offer.
///
/// True for every offer row, including a silenced one. A creative inside a row
/// always stands down: inside a probing row it would double-report, and inside
/// a silenced row it would report what the variant asked to suppress.
@available(iOS 17.0, *)
private struct SDUIInsideOfferRowKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiInsideOfferRow: Bool {
        get { self[SDUIInsideOfferRowKey.self] }
        set { self[SDUIInsideOfferRowKey.self] = newValue }
    }
}

/// Whether this element is a button's label. A glyph there may be the
/// button's only name; anywhere else it is decorative.
@available(iOS 17.0, *)
private struct SDUIInsideControlKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiInsideControl: Bool {
        get { self[SDUIInsideControlKey.self] }
        set { self[SDUIInsideControlKey.self] = newValue }
    }
}

/// The state machine's current state, as a plain VALUE.
///
/// The context is carried by reference, and SwiftUI does
/// not track a read through it: on a state change the renderer rebuilds an
/// identical `SDUIStyleModifier` around an identical environment value, so the
/// modifier body is skipped and keeps the state it mounted with. A per-state
/// style then never moved on a mounted sheet, which is the only place it is
/// ever used.
@available(iOS 17.0, *)
private struct SDUICurrentStateKey: EnvironmentKey {
    static let defaultValue: String = ""
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiCurrentState: String {
        get { self[SDUICurrentStateKey.self] }
        set { self[SDUICurrentStateKey.self] = newValue }
    }
}
