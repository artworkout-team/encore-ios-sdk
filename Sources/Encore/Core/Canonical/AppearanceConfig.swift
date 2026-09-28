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
    /// Primary text; applies only together with `backgroundColor`.
    public var textColor: String?

    public init(accentColor: String? = nil, backgroundColor: String? = nil, textColor: String? = nil) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.textColor = textColor
    }
}
