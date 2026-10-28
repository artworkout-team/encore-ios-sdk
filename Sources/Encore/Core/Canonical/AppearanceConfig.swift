//
//  AppearanceConfig.swift
//  Encore
//
//  Placement-level brand colours, set in app code alongside the app's own theme.
//  Mirrors the web SDK's `PlacementOptions.appearance` names and hex formats.
//

import Foundation

/// Brand colours for one presentation. Unset fields keep the sheet's defaults.
/// Hex formats: `#RGB`, `#RRGGBB`, `#RRGGBBAA` (alpha last, as in CSS).
public struct AppearanceConfig: Sendable, Equatable {
    /// Primary CTAs, selected states and the active page dot.
    public var accentColor: String?
    /// Sheet canvas; card and divider colours are derived from it.
    public var backgroundColor: String?
    /// Primary text; on the sheet it applies only together with `backgroundColor`.
    public var textColor: String?
    /// Secondary copy in trigger components; unset, the text colour faded as each look draws it.
    public var secondaryTextColor: String?
    /// Progress tracks in trigger components; unset, the text colour faded as each look draws it.
    public var trackColor: String?
    /// Ink on the accent (arrows, button labels) in trigger components. Unset, an arrow is black or
    /// white for contrast, and a label is the background colour when it reads at 3:1 on the accent,
    /// else black or white.
    public var onAccentColor: String?
    /// Light or dark for trigger components; nil follows the app's portal setting, else dark.
    public var colorScheme: ColorScheme?
    /// The second stop of a trigger look's background gradient (leading to trailing); unset, the
    /// look is solid in the background colour. Trigger components only; the sheet ignores it.
    public var backgroundEndColor: String?

    /// The palette a trigger component draws with.
    public enum ColorScheme: String, Sendable, CaseIterable {
        /// Follows the device's light or dark appearance.
        case system
        case light
        case dark
    }

    /// The 2.1 initializer, kept as its own symbol so binaries built against it still link.
    public init(accentColor: String? = nil, backgroundColor: String? = nil, textColor: String? = nil) {
        self.init(accentColor: accentColor, backgroundColor: backgroundColor, textColor: textColor, colorScheme: nil)
    }

    /// Disfavoured so a call that names only the three sheet colours keeps resolving to the 2.1
    /// initializer above.
    @_disfavoredOverload
    public init(
        accentColor: String? = nil,
        backgroundColor: String? = nil,
        backgroundEndColor: String? = nil,
        textColor: String? = nil,
        secondaryTextColor: String? = nil,
        trackColor: String? = nil,
        onAccentColor: String? = nil,
        colorScheme: ColorScheme? = nil
    ) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.backgroundEndColor = backgroundEndColor
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.trackColor = trackColor
        self.onAccentColor = onAccentColor
        self.colorScheme = colorScheme
    }
}
