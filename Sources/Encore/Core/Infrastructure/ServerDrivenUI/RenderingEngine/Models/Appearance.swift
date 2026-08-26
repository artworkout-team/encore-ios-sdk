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
/// Distinct from `SDUISemanticColor`, which wraps Apple's UIColor semantics
/// (`.label`, `.secondarySystemFill`, etc.). `SDUIAppearanceColor` represents
/// **Encore app theme tokens** — colors the host app configures via the
/// admin portal and serves through `RemoteConfig`. At render time they
/// resolve against the active `Appearance` (see below).
///
/// **Add a new token by:**
/// 1. Adding the case here.
/// 2. Adding a stored property to `Appearance`.
/// 3. Adding the case to `Appearance.color(for:)`.
/// 4. Providing a default in `Appearance.default`.
/// 5. Wiring the source field in `Appearance.init(from:)` when/if the
///    backend `UIValues` schema grows to include it.
///
/// Renaming a case is a breaking change for every shipped variant JSON that
/// references it — treat this enum as a stable public contract.
enum SDUIAppearanceColor: String, Decodable {
    /// The app's primary brand color. Use for primary CTAs, selected states,
    /// and brand highlights. Sourced from `RemoteConfig.accentColor`.
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

    /// Destructive/error color. Default: system red.
    case error
}

// MARK: - Appearance

/// Resolved theme for the current app session. One instance per render of the
/// SDUI tree. Built from the backend's `UIValues` at `OfferSheetView` render
/// time, with per-token fallbacks so partially-configured apps (or no remote
/// config at all) still render correctly.
///
/// Injected into the SwiftUI environment via `\.sduiAppearance` so any
/// `ViewModifier` can resolve `SDUIColor.appearance(_)` without explicit
/// plumbing.
struct Appearance: Equatable {
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

    /// Builds an `Appearance` from the backend's `UIValues`, falling back to
    /// `.default` for any token the payload has not filled in. This is the
    /// single chokepoint where token → remote field mapping is defined —
    /// when the backend grows new fields (`primaryColor`, `surfaceColor`,
    /// etc.), only this initializer needs to learn about them.
    ///
    /// Backwards compat note: today `UIValues` only carries `accentColor` +
    /// `accentTitleColor`. Every other token resolves to its default. Apps
    /// that have configured `accentColor` immediately get brand-aware
    /// theming on `.accent` (and the future `.onAccent` contrast default)
    /// with zero backend migration.
    init(from uiValues: UIValues?) {
        let fallback = Appearance.default
        self.accent = uiValues?.accentColor.flatMap { Color(hex: $0) } ?? fallback.accent
        self.onAccent = fallback.onAccent
        self.accentTitle = uiValues?.accentTitleColor.flatMap { Color(hex: $0) } ?? fallback.accentTitle
        self.background = fallback.background
        self.onBackground = fallback.onBackground
        self.surface = fallback.surface
        self.onSurface = fallback.onSurface
        self.border = fallback.border
        self.muted = fallback.muted
        self.error = fallback.error
    }

}

// Memberwise init kept in an extension: declaring `init(from:)` above
// suppresses Swift's synthesized memberwise init, and `.default` + tests
// rely on the label-per-arg form.
extension Appearance {
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
        error: Color
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

/// SwiftUI environment carrying the active render `SDUIContext` and the
/// current row `Offer`, so generic `ViewModifier`s can render sub-elements
/// (`style.overlay`, `style.backgroundElement`) through `SDUIElementRenderer`.
/// Set per element in the renderer's `body`.
@available(iOS 17.0, *)
final class SDUIRenderEnvironment: Equatable {
    weak var context: SDUIContext?
    let offer: Offer?

    init(context: SDUIContext? = nil, offer: Offer? = nil) {
        self.context = context
        self.offer = offer
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }
}

@available(iOS 17.0, *)
private struct SDUIRenderEnvironmentKey: EnvironmentKey {
    static let defaultValue = SDUIRenderEnvironment()
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiRenderEnvironment: SDUIRenderEnvironment {
        get { self[SDUIRenderEnvironmentKey.self] }
        set { self[SDUIRenderEnvironmentKey.self] = newValue }
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

@available(iOS 17.0, *)
extension EnvironmentValues {
    var sduiScrollFadeDistance: Double {
        get { self[SDUIScrollFadeDistanceKey.self] }
        set { self[SDUIScrollFadeDistanceKey.self] = newValue }
    }
}
