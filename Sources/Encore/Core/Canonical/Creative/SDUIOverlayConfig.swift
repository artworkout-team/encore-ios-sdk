//
//  SDUIOverlayConfig.swift
//  Encore
//
//  Creative overlay config - dynamic text zones rendered on top of creative
//  images at runtime. Uses ratios (not pixels) so a single config adapts to
//  any screen size. Reuses SDUIColor / SDUIFontWeight instead of introducing
//  a parallel typography system.
//

import SwiftUI

// MARK: - Root Config

/// Top-level overlay config attached to a `Creative`.
///
/// `version` lets the schema evolve without a parallel column; `overlays`
/// is always an array so multi-zone creatives are a zero-migration change.
struct SDUIOverlayConfig: Decodable {
    let version: Int
    /// Image aspect ratio (width/height) — used to size the placeholder pre-load
    /// so overlay coordinates land precisely before the image resolves.
    /// Once the image loads, SwiftUI's natural aspect ratio takes over.
    var aspectRatio: CGFloat?
    let overlays: [SDUIOverlayZone]
}

// MARK: - Overlay Zone

/// One text zone painted on top of the creative. All spatial values are ratios
/// of the rendered image box.
struct SDUIOverlayZone: Decodable {
    let id: String
    /// Template text - resolved via `SDUIContext.resolveTemplateText`, so
    /// `${premiumTierName}`, `${appName}`, etc. all work.
    let template: String
    /// Top-left of the zone, as ratios of the rendered image.
    let position: SDUIOverlayPosition
    /// Zone box size as ratios of the rendered image.
    let dimensions: SDUIOverlayDimensions
    /// Horizontal alignment for wrapped text within the zone.
    let alignment: SDUIOverlayAlignment
    let typography: SDUIOverlayTypography
    var overflow: SDUIOverlayOverflow?
}

// MARK: - Spatial

/// Zone origin as a ratio of the rendered image size (0...1).
struct SDUIOverlayPosition: Decodable {
    let x: CGFloat
    let y: CGFloat
}

/// Zone box size as a ratio of the rendered image size (0...1).
struct SDUIOverlayDimensions: Decodable {
    let width: CGFloat
    let height: CGFloat
}

/// Horizontal alignment for the zone's text and frame.
enum SDUIOverlayAlignment: String, Decodable {
    case leading, center, trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Typography

/// Typography spec for a zone. Reuses `SDUIColor` + `SDUIFontWeight` from the
/// existing style system so authors don't learn a parallel vocabulary.
struct SDUIOverlayTypography: Decodable {
    /// Font size as a ratio of image width (e.g., 0.06 = 6% of width).
    let fontSizeRatio: CGFloat
    let fontWeight: SDUIFontWeight
    let color: SDUIColor
    /// Line height as a multiplier of font size (e.g., 1.1 = 110%).
    var lineHeight: CGFloat?
    /// Letter spacing in points.
    var letterSpacing: CGFloat?
}

// MARK: - Overflow Handling

/// How the zone handles text that exceeds the available box.
struct SDUIOverlayOverflow: Decodable {
    /// Minimum scale factor for auto-shrinking (0.0..<1.0). 1.0 disables.
    var minScaleFactor: CGFloat?
    var maxLines: Int?
    var truncation: SDUIOverlayTruncation?
}

enum SDUIOverlayTruncation: String, Decodable {
    case head, middle, tail, clip

    var mode: Text.TruncationMode {
        switch self {
        case .head: return .head
        case .middle: return .middle
        case .tail: return .tail
        // SwiftUI has no `clip` on Text - fall back to `.tail`.
        case .clip: return .tail
        }
    }
}
