//
//  SDUIStyle.swift
//  Encore
//
//  SDUI styling types - colors, fonts, padding, frame, shadows
//

import SwiftUI

// MARK: - Color System

/// Semantic colors that adapt to dark/light mode
enum SDUISemanticColor: String, Decodable {
    case label
    case secondaryLabel
    case tertiaryLabel
    case systemBackground
    case secondarySystemBackground
    case systemGroupedBackground
    case secondarySystemGroupedBackground
    case separator
    case tertiarySystemFill
    
    var uiColor: UIColor {
        switch self {
        case .label: return .label
        case .secondaryLabel: return .secondaryLabel
        case .tertiaryLabel: return .tertiaryLabel
        case .systemBackground: return .systemBackground
        case .secondarySystemBackground: return .secondarySystemBackground
        case .systemGroupedBackground: return .systemGroupedBackground
        case .secondarySystemGroupedBackground: return .secondarySystemGroupedBackground
        case .separator: return .separator
        case .tertiarySystemFill: return .tertiarySystemFill
        }
    }
    
    var color: Color {
        Color(uiColor)
    }
}

/// Color definition for SDUI styles. Supports three resolution strategies:
///
/// - `.hex(String)` — literal hex value. Escape hatch for one-off colors.
/// - `.semantic(SDUISemanticColor)` — Apple's UIColor semantics (`.label`,
///   `.secondarySystemFill`, etc.). Adapt automatically to light/dark and
///   accessibility settings.
/// - `.appearance(SDUIAppearanceColor)` — Encore app theme tokens (`.accent`,
///   `.background`, `.onSurface`, etc.). Resolved at render time against the
///   active `Appearance` for the current app, which is populated from the
///   backend's per-app brand config. See `Appearance.swift` for the token
///   vocabulary.
///
/// Variant authors should prefer `.appearance(_)` for any color that should
/// reflect the host app's brand — not `.hex(_)`.
/// - `.binding(key:fallback:)` — resolves a hex string from the render
///   context's values dictionary at render time (e.g.
///   `selectedOfferDominantColor`, `offerDominantColor`). When the key is
///   missing or empty, falls back to `fallback` (another `SDUIColor`) or
///   `.clear`. Bindings require the values-aware resolver
///   (`resolved(in:values:)` / `SDUIContext.resolveColor`) — they cannot
///   resolve through the legacy `.color` path that has no values dictionary.
///
/// Any color form may carry post-resolution `transforms` (`opacity`,
/// `lighten`, `darken`), authored as sibling keys in the same JSON object.
struct SDUIColor {
    /// Optional post-resolution transforms. Applied in order: lighten/darken
    /// (mix toward white/black), then opacity. Authored as sibling keys on the
    /// color object so any form can be tinted from JSON.
    struct Transforms: Equatable {
        var opacity: Double?
        var lighten: Double?
        var darken: Double?

        var isIdentity: Bool { opacity == nil && lighten == nil && darken == nil }
    }

    indirect enum Base {
        case hex(String)
        case semantic(SDUISemanticColor)
        case appearance(SDUIAppearanceColor)
        case binding(key: String, fallback: SDUIColor?)
    }

    var base: Base
    var transforms: Transforms

    init(base: Base, transforms: Transforms = Transforms()) {
        self.base = base
        self.transforms = transforms
    }

    // Convenience constructors preserve the original `.hex(_)` / `.semantic(_)`
    // / `.appearance(_)` call-site spelling used throughout the codebase.
    static func hex(_ value: String) -> SDUIColor { SDUIColor(base: .hex(value)) }
    static func semantic(_ value: SDUISemanticColor) -> SDUIColor { SDUIColor(base: .semantic(value)) }
    static func appearance(_ value: SDUIAppearanceColor) -> SDUIColor { SDUIColor(base: .appearance(value)) }
    static func binding(key: String, fallback: SDUIColor? = nil) -> SDUIColor {
        SDUIColor(base: .binding(key: key, fallback: fallback))
    }

    /// Legacy resolver kept for call sites that have not been migrated to
    /// `resolved(in:)`. Returns `.clear` for `.appearance` and `.binding`
    /// because neither has an `Appearance` / values dictionary in scope —
    /// migrate those call sites to `resolved(in:values:)` when brand-aware
    /// theming or data-bound colors matter.
    var color: Color {
        switch base {
        case .hex(let hexString):
            return Self.applyTransforms(transforms, to: Color(hex: hexString))
        case .semantic(let semanticColor):
            return Self.applyTransforms(transforms, to: semanticColor.color)
        case .appearance, .binding:
            return Self.applyTransforms(transforms, to: .clear)
        }
    }

    /// Resolves the color against an `Appearance` (no values dictionary).
    /// Bindings have no source here and fall back to their `fallback` (or
    /// `.clear`). Call `resolved(in:values:)` from imperative renderer sites
    /// that have access to `SDUIContext.values` for data-bound colors.
    func resolved(in appearance: Appearance) -> Color {
        resolved(in: appearance, values: nil)
    }

    /// Full resolver: resolves the base color (including data bindings against
    /// `values`) then applies any transforms.
    func resolved(in appearance: Appearance, values: [String: String]?) -> Color {
        Self.applyTransforms(transforms, to: baseColor(in: appearance, values: values))
    }

    private func baseColor(in appearance: Appearance, values: [String: String]?) -> Color {
        switch base {
        case .hex(let hexString):
            return Color(hex: hexString)
        case .semantic(let semanticColor):
            return semanticColor.color
        case .appearance(let token):
            return appearance.color(for: token)
        case .binding(let key, let fallback):
            if let values, let hex = values[key], !hex.isEmpty {
                return Color(hex: hex)
            }
            // Fall back gracefully — never crash, never leave undefined.
            return fallback?.resolved(in: appearance, values: values) ?? .clear
        }
    }

    /// Applies lighten/darken (mix toward white/black in sRGB) then opacity.
    private static func applyTransforms(_ t: Transforms, to color: Color) -> Color {
        guard !t.isIdentity else { return color }
        var result = color
        if let lighten = t.lighten, lighten > 0 {
            result = result.sduiMixed(with: .white, amount: min(1, lighten))
        }
        if let darken = t.darken, darken > 0 {
            result = result.sduiMixed(with: .black, amount: min(1, darken))
        }
        if let opacity = t.opacity {
            result = result.opacity(max(0, min(1, opacity)))
        }
        return result
    }
}

extension SDUIColor: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hex, semantic, appearance, binding
        case opacity, lighten, darken
    }

    /// Payload for `{"binding": {"key": "...", "fallback": {...}}}` or the
    /// shorthand `{"binding": "contextKey"}`.
    private struct BindingData: Decodable {
        let key: String
        let fallback: SDUIColor?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let transforms = Transforms(
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity),
            lighten: try container.decodeIfPresent(Double.self, forKey: .lighten),
            darken: try container.decodeIfPresent(Double.self, forKey: .darken)
        )

        let base: Base
        if let hexValue = try? container.decode(String.self, forKey: .hex) {
            base = .hex(hexValue)
        } else if let semanticValue = try? container.decode(SDUISemanticColor.self, forKey: .semantic) {
            base = .semantic(semanticValue)
        } else if let appearanceToken = try? container.decode(SDUIAppearanceColor.self, forKey: .appearance) {
            base = .appearance(appearanceToken)
        } else if let bindingKey = try? container.decode(String.self, forKey: .binding) {
            base = .binding(key: bindingKey, fallback: nil)
        } else if let bindingData = try? container.decode(BindingData.self, forKey: .binding) {
            base = .binding(key: bindingData.key, fallback: bindingData.fallback)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SDUIColor must have 'hex', 'semantic', 'appearance', or 'binding' key"
                )
            )
        }

        self.init(base: base, transforms: transforms)
    }
}

// MARK: - Typography

enum SDUIFontWeight: String, Decodable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    
    var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    /// UIKit counterpart, for the places that need font METRICS (natural line
    /// height) rather than a SwiftUI `Font` — SwiftUI exposes no metrics.
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

struct SDUIFont: Decodable {
    let size: CGFloat
    let weight: SDUIFontWeight
    /// Letter spacing in points, as designs specify it (negative = tighter).
    ///
    /// Not part of `font`, because SwiftUI applies tracking as a TEXT modifier
    /// rather than a font attribute — see `Text.applySDUIFont(_:)`, which is the
    /// only correct way to apply this pair together.
    var tracking: CGFloat?

    var font: Font {
        .system(size: size, weight: weight.fontWeight)
    }
    
    static let title = SDUIFont(size: 24, weight: .semibold)
    static let subtitle = SDUIFont(size: 17, weight: .regular)
    static let body = SDUIFont(size: 16, weight: .regular)
    static let caption = SDUIFont(size: 15, weight: .semibold)
    static let small = SDUIFont(size: 12, weight: .bold)
}

// MARK: - Layout & Styling

enum SDUIAlignment: String, Decodable {
    case leading, trailing, center
    case top, bottom
    case topLeading, topTrailing
    case bottomLeading, bottomTrailing
    
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading, .topLeading, .bottomLeading: return .leading
        case .trailing, .topTrailing, .bottomTrailing: return .trailing
        case .center, .top, .bottom: return .center
        }
    }
    
    var verticalAlignment: VerticalAlignment {
        switch self {
        case .top, .topLeading, .topTrailing: return .top
        case .bottom, .bottomLeading, .bottomTrailing: return .bottom
        case .center, .leading, .trailing: return .center
        }
    }
    
    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        case .top: return .top
        case .bottom: return .bottom
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
    
    var textAlignment: TextAlignment {
        switch self {
        case .leading, .topLeading, .bottomLeading: return .leading
        case .trailing, .topTrailing, .bottomTrailing: return .trailing
        case .center, .top, .bottom: return .center
        }
    }
}

struct SDUIPadding: Decodable {
    var top: CGFloat?
    var leading: CGFloat?
    var bottom: CGFloat?
    var trailing: CGFloat?
    var horizontal: CGFloat?
    var vertical: CGFloat?
    var all: CGFloat?
    
    var edgeInsets: EdgeInsets {
        EdgeInsets(
            top: top ?? vertical ?? all ?? 0,
            leading: leading ?? horizontal ?? all ?? 0,
            bottom: bottom ?? vertical ?? all ?? 0,
            trailing: trailing ?? horizontal ?? all ?? 0
        )
    }
    
    static func all(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(all: value)
    }
    
    static func horizontal(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(horizontal: value)
    }
    
    static func vertical(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(vertical: value)
    }
    
    static func top(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(top: value)
    }
    
    static func leading(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(leading: value)
    }
    
    static func trailing(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(trailing: value)
    }
    
    static func bottom(_ value: CGFloat) -> SDUIPadding {
        SDUIPadding(bottom: value)
    }
}

/// Represents a dimension that can be a fixed value or infinity
enum SDUIDimension: Decodable {
    case fixed(CGFloat)
    case infinity
    
    var value: CGFloat? {
        switch self {
        case .fixed(let v): return v
        case .infinity: return .infinity
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self), stringValue == "infinity" {
            self = .infinity
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .fixed(CGFloat(doubleValue))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected number or 'infinity'")
        }
    }
}

struct SDUIFrame: Decodable {
    var width: CGFloat?
    var height: CGFloat?
    var minWidth: CGFloat?
    var maxWidth: SDUIDimension?
    var minHeight: CGFloat?
    var maxHeight: SDUIDimension?
    var alignment: SDUIAlignment?
    
    // Computed properties for CGFloat values
    var maxWidthValue: CGFloat? { maxWidth?.value }
    var maxHeightValue: CGFloat? { maxHeight?.value }
    
    static func fixed(width: CGFloat, height: CGFloat) -> SDUIFrame {
        SDUIFrame(width: width, height: height)
    }
    
    static func width(_ width: CGFloat) -> SDUIFrame {
        SDUIFrame(width: width)
    }
    
    static func height(_ height: CGFloat) -> SDUIFrame {
        SDUIFrame(height: height)
    }
    
    static func maxWidth(_ maxWidth: CGFloat, alignment: SDUIAlignment? = nil) -> SDUIFrame {
        SDUIFrame(maxWidth: .fixed(maxWidth), alignment: alignment)
    }
    
    static var infinity: SDUIFrame {
        SDUIFrame(maxWidth: .infinity)
    }
    
    static func infinityWidth(alignment: SDUIAlignment) -> SDUIFrame {
        SDUIFrame(maxWidth: .infinity, alignment: alignment)
    }
    
    static func infinityBoth(alignment: SDUIAlignment) -> SDUIFrame {
        SDUIFrame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

struct SDUIShadow: Decodable {
    let color: SDUIColor
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    let opacity: CGFloat?
    
    init(color: SDUIColor, radius: CGFloat, x: CGFloat, y: CGFloat, opacity: CGFloat? = nil) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
        self.opacity = opacity
    }
    
    static func standard(opacity: CGFloat = 0.1) -> SDUIShadow {
        SDUIShadow(color: .semantic(.label), radius: 4, x: 0, y: 0, opacity: opacity)
    }
}

/// An INSET (inner) shadow — SwiftUI has no native one. Mirrors `SDUIShadow`'s
/// shape (color/x/y/opacity) but the blur falls INSIDE the element's shape and
/// is clipped to its corner radius, so it reads as an inner glow/recess on the
/// edges. Accepts either `radius` or `blur` for the blur amount. The color
/// supports the full `SDUIColor` union (e.g. `{"binding":"offerDominantColor"}`
/// + `opacity`), exactly like other colors.
///
/// Example (Figma `-8px 1px 13px 0 rgba(...,0.13) inset`):
/// `{ "color": {"binding":"offerDominantColor","opacity":0.13}, "x": -8, "y": 1, "blur": 13 }`
struct SDUIInnerShadow: Decodable {
    let color: SDUIColor
    let x: CGFloat
    let y: CGFloat
    /// Blur radius. JSON may use `radius` or `blur` (alias).
    let radius: CGFloat
    /// Extra opacity multiplier applied to the resolved color (matches
    /// `SDUIShadow.opacity`). Optional; defaults to 1.0 when omitted so a color
    /// that already encodes its own alpha/opacity renders as-authored.
    let opacity: CGFloat?

    private enum CodingKeys: String, CodingKey {
        case color, x, y, radius, blur, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.color = try c.decode(SDUIColor.self, forKey: .color)
        self.x = (try c.decodeIfPresent(CGFloat.self, forKey: .x)) ?? 0
        self.y = (try c.decodeIfPresent(CGFloat.self, forKey: .y)) ?? 0
        let radiusValue = try c.decodeIfPresent(CGFloat.self, forKey: .radius)
        let blurValue = try c.decodeIfPresent(CGFloat.self, forKey: .blur)
        self.radius = radiusValue ?? blurValue ?? 0
        self.opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity)
    }

    init(color: SDUIColor, x: CGFloat, y: CGFloat, radius: CGFloat, opacity: CGFloat? = nil) {
        self.color = color
        self.x = x
        self.y = y
        self.radius = radius
        self.opacity = opacity
    }
}

enum SDUIClipShape: Decodable {
    case rectangle(cornerRadius: CGFloat)
    case circle
    case capsule
    
    private enum CodingKeys: String, CodingKey {
        case rectangle, circle, capsule
    }
    
    private struct RectangleData: Decodable {
        let cornerRadius: CGFloat
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let data = try? container.decode(RectangleData.self, forKey: .rectangle) {
            self = .rectangle(cornerRadius: data.cornerRadius)
        } else if container.contains(.circle) {
            self = .circle
        } else if container.contains(.capsule) {
            self = .capsule
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown clip shape"))
        }
    }
}

/// Per-corner radius configuration for uneven rounded rectangles
struct SDUICornerRadii: Decodable {
    var topLeading: CGFloat?
    var topTrailing: CGFloat?
    var bottomLeading: CGFloat?
    var bottomTrailing: CGFloat?
    
    /// Returns RectangleCornerRadii for use with UnevenRoundedRectangle
    @available(iOS 16.0, *)
    var rectCornerRadii: RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: topLeading ?? 0,
            bottomLeading: bottomLeading ?? 0,
            bottomTrailing: bottomTrailing ?? 0,
            topTrailing: topTrailing ?? 0
        )
    }
}

/// Complete styling for any element
struct SDUIStyle: Decodable {
    var padding: SDUIPadding?
    var frame: SDUIFrame?
    var cornerRadius: CGFloat?
    /// Per-corner radius (takes precedence over cornerRadius if specified)
    var cornerRadii: SDUICornerRadii?
    var backgroundColor: SDUIColor?
    var shadow: SDUIShadow?
    /// Inset (inner) shadow — glow/recess clipped inside the element's shape.
    var innerShadow: SDUIInnerShadow?
    var opacity: CGFloat?
    var clipShape: SDUIClipShape?
    var clipped: Bool?
    var ignoresSafeArea: Bool?
    var layoutPriority: Double?
    /// Makes the view fill the container width (like containerRelativeFrame(.horizontal))
    var containerRelativeFrame: SDUIContainerRelativeFrame?
    /// For scroll views - uses scrollTargetLayout
    var scrollTargetLayout: Bool?
    /// Border width in points
    var borderWidth: CGFloat?
    /// Border color
    var borderColor: SDUIColor?
    /// Shrink-wraps content along the given axes, overriding any parent
    /// proposal along that axis. Use `{ "vertical": true }` on a parent stack
    /// so it matches its tallest child's intrinsic height even when the
    /// enclosing scroll view would otherwise propose infinite space.
    var fixedSize: SDUIFixedSize?

    // MARK: - Generic transforms (additive, optional)

    /// Translates the element by `{x, y}` points after layout.
    var offset: SDUIOffset?
    /// Uniform scale factor (1.0 = normal). Applied after frame.
    var scale: CGFloat?
    /// Rotation in degrees, clockwise. Applied after frame.
    var rotation: CGFloat?
    /// Fraction (0...1) of the container's width to occupy, via
    /// `containerRelativeFrame(.horizontal) { width, _ in width * fraction }`.
    /// Enables exact fractional sizing (e.g. an anchor card at 0.70).
    var relativeWidth: CGFloat?
    /// Fraction (0...1) of the container's height to occupy.
    var relativeHeight: CGFloat?
    /// An element layered ABOVE the content (e.g. a badge, a sheen).
    var overlay: SDUIElement?
    /// An element layered BEHIND the content (e.g. a tinted card background).
    var backgroundElement: SDUIElement?
    /// Gradient stroke around the element.
    var gradientBorder: SDUIGradientBorder?

    /// Scroll-driven transform: interpolates rotation/scale/opacity based on
    /// the element's position in an enclosing scrollView. The listed values
    /// are applied at the off-center extremes (leading/trailing edges) and
    /// animate to identity (0°, 1.0, 1.0) as the element reaches the center.
    /// Use on carousel cards so side cards appear rotated/smaller/faded and
    /// smoothly settle as they slide to center. No-op outside a scrollView.
    var scrollTransition: SDUIScrollTransition?

    /// Scroll-driven opacity: maps centered → `centeredOpacity` (default 1) and
    /// off-center → `offCenterOpacity` (default 0). Layer a colored face above a
    /// white face with `scrollFade` on the colored face to crossfade the brand
    /// fill in as a card centers — a smooth alternative to a binary swap.
    var scrollFade: SDUIScrollFade?

    /// Insets THIS element by the device safe area via SwiftUI
    /// `.safeAreaPadding(...)`. The data-driven primitive for "this element
    /// respects the safe area" — put it on the content vStack so it clears the
    /// Dynamic Island / home indicator while a sibling full-bleed background
    /// fills behind it. Accepts `true` (= all edges) or an edges object
    /// `{ "top": true, "bottom": true, "leading": true, "trailing": true }`.
    var safeAreaPadding: SDUISafeAreaPadding?

    static let none = SDUIStyle()

    /// Best-effort corner radius for the element, resolved from `cornerRadius`,
    /// `cornerRadii` (max corner), or a rectangle `clipShape`. Used to clip the
    /// inner shadow so its glow follows the element's rounding. 0 = square.
    var resolvedCornerRadius: CGFloat {
        if let cornerRadius { return cornerRadius }
        if let r = cornerRadii {
            return max(r.topLeading ?? 0, r.topTrailing ?? 0, r.bottomLeading ?? 0, r.bottomTrailing ?? 0)
        }
        if let clip = clipShape, case .rectangle(let r) = clip { return r }
        return 0
    }
}

/// Per-element safe-area inset config. Decodes from `true` (all edges) or an
/// edges object selecting individual edges. The data-driven counterpart to the
/// root-bleed policy: the root bleeds (full-bleed background), this opts an
/// element back into the safe area.
struct SDUISafeAreaPadding: Decodable {
    var top: Bool?
    var bottom: Bool?
    var leading: Bool?
    var trailing: Bool?

    /// The SwiftUI `Edge.Set` to inset. `true` → `.all`; otherwise the union of
    /// the individually-selected edges.
    var edges: Edge.Set {
        if isAll { return .all }
        var set: Edge.Set = []
        if top == true { set.insert(.top) }
        if bottom == true { set.insert(.bottom) }
        if leading == true { set.insert(.leading) }
        if trailing == true { set.insert(.trailing) }
        return set
    }

    /// True when decoded from the `true` shorthand (all edges).
    private var isAll: Bool = false

    private enum CodingKeys: String, CodingKey {
        case top, bottom, leading, trailing
    }

    init(from decoder: Decoder) throws {
        // Shorthand: `"safeAreaPadding": true` → all edges. `false` → none.
        if let single = try? decoder.singleValueContainer(),
           let flag = try? single.decode(Bool.self) {
            self.isAll = flag
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.top = try container.decodeIfPresent(Bool.self, forKey: .top)
        self.bottom = try container.decodeIfPresent(Bool.self, forKey: .bottom)
        self.leading = try container.decodeIfPresent(Bool.self, forKey: .leading)
        self.trailing = try container.decodeIfPresent(Bool.self, forKey: .trailing)
    }

    /// Memberwise init for tests / programmatic construction.
    init(top: Bool? = nil, bottom: Bool? = nil, leading: Bool? = nil, trailing: Bool? = nil, all: Bool = false) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
        self.isAll = all
    }
}

/// Scroll-driven transform applied via SwiftUI `.scrollTransition`. Values are
/// the off-center extremes; the element interpolates to identity at center.
struct SDUIScrollTransition: Decodable {
    /// Degrees of rotation at the off-center extreme (interpolates to 0).
    var rotation: CGFloat?
    /// Scale at the off-center extreme (interpolates to 1.0).
    var scale: CGFloat?
    /// Opacity at the off-center extreme (interpolates to 1.0).
    var opacity: CGFloat?
    /// Vertical offset (points) at the off-center extreme (interpolates to 0).
    var yOffset: CGFloat?
}

/// Scroll-driven opacity crossfade. `centeredOpacity` when the element is
/// centered in the scrollView, `offCenterOpacity` at the extremes.
struct SDUIScrollFade: Decodable {
    var centeredOpacity: CGFloat?
    var offCenterOpacity: CGFloat?
}

/// `{x, y}` translation in points.
struct SDUIOffset: Decodable {
    var x: CGFloat?
    var y: CGFloat?
}

/// Gradient stroke configuration. Stops accept the full `SDUIColor` union
/// (hex / semantic / appearance / binding + transforms).
struct SDUIGradientBorder: Decodable {
    let colors: [SDUIColor]
    var width: CGFloat?
    /// Direction of the gradient sweep. Default: leadingToTrailing.
    var direction: SDUIGradientDirection?
    /// Corner radius the stroke follows. Falls back to the style's
    /// `cornerRadius` when omitted.
    var cornerRadius: CGFloat?
}

struct SDUIFixedSize: Decodable {
    var horizontal: Bool?
    var vertical: Bool?
}

/// Configuration for containerRelativeFrame behavior
struct SDUIContainerRelativeFrame: Decodable {
    var axis: SDUIScrollAxis?
    
    static let horizontal = SDUIContainerRelativeFrame(axis: .horizontal)
    static let vertical = SDUIContainerRelativeFrame(axis: .vertical)
}

// MARK: - Scroll Axis (needed by SDUIContainerRelativeFrame)

enum SDUIScrollAxis: String, Decodable {
    case horizontal, vertical
    
    var axis: Axis.Set {
        switch self {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}
