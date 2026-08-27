//
//  SDUIElement.swift
//  Encore
//
//  SDUI element types - text, images, layout, shapes, scroll, data
//

import SwiftUI

// MARK: - Text Elements

struct SDUIText: Decodable {
    var text: String
    var font: SDUIFont?
    var color: SDUIColor?
    var alignment: SDUIAlignment?
    var lineSpacing: CGFloat?
    /// Line height multiplier (e.g., 1.2 = 120% of font size)
    ///
    /// ⚠️ ADDITIVE, and clamped at zero: this is EXTRA leading on top of the
    /// font's natural line height, so `1.1` on a 28pt font renders 33.5 + 2.8 =
    /// 36.3pt, not the 30.8pt a design tool means by "line-height 1.1". It also
    /// cannot express anything TIGHTER than the font's own leading. Kept as-is
    /// because ~13 shipped variants are authored against it; use
    /// `lineHeightMultiple` for a value read off a design.
    var lineHeight: CGFloat?
    /// TOTAL line height as a multiple of font size — the way Figma, CSS and
    /// every other design tool define it. `1.1` on a 28pt font means 30.8pt
    /// between baselines, whether that is looser or tighter than SF Pro's
    /// natural 33.5pt.
    ///
    /// A separate field rather than a fix to `lineHeight`, because changing that
    /// field's meaning would silently re-flow every variant already authored
    /// against its additive behaviour. Wins over both of the others when set.
    var lineHeightMultiple: CGFloat?
    var lineLimit: Int?
    var multilineAlignment: SDUIAlignment?
    var strikethrough: Bool?
    /// Color for `*marked*` runs inside the resolved text.
    ///
    /// `segments` can only style text the SERVER splits up; a value substituted
    /// from a single placeholder (`${rewardHeadline}`) arrives as one opaque
    /// string, so the only place to say "accent this word" is the copy itself.
    /// Set this and write the copy as `"We got a *gift* for you"`.
    ///
    /// Nil (or copy with no markers) renders exactly as before — the markers
    /// are only consumed when there is a color to apply.
    var highlightColor: SDUIColor?
    var style: SDUIStyle?

    // For dynamic text that references context data
    var textBinding: SDUITextBinding?

    // For concatenated styled text (e.g., "Get 1 month" + " for free" with different colors)
    var segments: [SDUITextSegment]?

    // NEW: Look up text from a textMap based on a stored value
    // e.g., textMapKey: "answerTitles" looks up textMaps["answerTitles"][values[textMapValueKey]]
    var textMapKey: String?

    // Which value key to use for the lookup (defaults to textMapKey if not specified)
    var textMapValueKey: String?

    /// Read text directly from context.values[valueKey].
    /// Used for displaying runtime-set values (e.g., error messages from native validation).
    /// Unlike textMapKey (server-side lookup tables) or template variables (OfferContext),
    /// this reads from the mutable state machine values dictionary.
    var valueKey: String?

    init(text: String = "", font: SDUIFont? = nil, color: SDUIColor? = nil, alignment: SDUIAlignment? = nil, lineSpacing: CGFloat? = nil, lineHeight: CGFloat? = nil, lineLimit: Int? = nil, multilineAlignment: SDUIAlignment? = nil, style: SDUIStyle? = nil, textBinding: SDUITextBinding? = nil, segments: [SDUITextSegment]? = nil, textMapKey: String? = nil, textMapValueKey: String? = nil, valueKey: String? = nil) {
        self.text = text
        self.font = font
        self.color = color
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.lineHeight = lineHeight
        self.lineLimit = lineLimit
        self.multilineAlignment = multilineAlignment
        self.style = style
        self.textBinding = textBinding
        self.segments = segments
        self.textMapKey = textMapKey
        self.textMapValueKey = textMapValueKey
        self.valueKey = valueKey
    }
}

/// A segment of styled text for concatenation
struct SDUITextSegment: Decodable {
    var text: String
    var font: SDUIFont?
    var color: SDUIColor?
    
    // For dynamic text binding
    var textBinding: SDUITextBinding?
}

enum SDUITextBinding: String, Decodable {
    case offerAdvertiserName
    case offerDescription
    case offerPerk
    case offerCtaText
    case titleText
    case accentTitleText
    case subtitleText
}

// MARK: - Image Elements

struct SDUISystemImage: Decodable {
    let systemName: String
    var font: SDUIFont?
    var color: SDUIColor?
    var style: SDUIStyle?
    /// SF Symbol animation on appear (e.g., "bounce")
    var symbolEffect: String?
}

struct SDUIAsyncImage: Decodable {
    var urlBinding: SDUICreativeBinding?
    var url: String?
    var aspectRatio: CGFloat?
    var contentMode: SDUIContentMode?
    var placeholderColor: SDUIColor?
    var style: SDUIStyle?
}

/// Renders the host app's bundle icon in place. No network, no async — the
/// icon is read from `Bundle.main` at render time, so it always matches the
/// icon the user sees on their home screen (including alternate icons if the
/// host app switches them at runtime).
struct SDUIAppIcon: Decodable {
    var style: SDUIStyle?
}

struct SDUIAsyncVideo: Decodable {
    var urlBinding: SDUICreativeBinding?
    var url: String?
    var contentMode: SDUIContentMode?
    var style: SDUIStyle?
}

enum SDUICreativeBinding: String, Decodable {
    case offerPrimaryCreative
    case offerLogoImage
}

enum SDUIContentMode: String, Decodable {
    case fit, fill
    
    var contentMode: ContentMode {
        switch self {
        case .fit: return .fit
        case .fill: return .fill
        }
    }
}

// MARK: - Layout Elements

struct SDUIButton: Decodable {
    let content: SDUIElement
    let action: SDUIAction
    var style: SDUIStyle?
    var disabled: Bool?
}

struct SDUIStack: Decodable {
    let children: [SDUIElement]
    var spacing: CGFloat?
    var alignment: SDUIAlignment?
    var style: SDUIStyle?
    /// If true, render via `LazyVStack` / `LazyHStack` instead of the eager
    /// `VStack` / `HStack`. Lazy variants materialize child views only as
    /// they approach the viewport, so row `.onAppear` correlates with
    /// on-screen visibility rather than parent mount. Needed for correct
    /// impression tracking on long scrolling lists. Default false.
    var lazy: Bool?
}

struct SDUISpacer: Decodable {
    var minLength: CGFloat?
    var style: SDUIStyle?
}

struct SDUIGroup: Decodable {
    let content: SDUIElement
    var style: SDUIStyle?
}

// MARK: - Input Elements

struct SDUITextField: Decodable {
    /// Key in SDUIContext.values to bind this field to
    let valueKey: String
    var placeholder: String?
    var keyboardType: SDUIKeyboardType?
    var textContentType: SDUITextContentType?
    var style: SDUIStyle?
}

struct SDUIToggle: Decodable {
    /// Key in SDUIContext.values to bind ("true"/"false")
    let valueKey: String
    /// Label element rendered beside the checkbox
    let label: SDUIElement
    var style: SDUIStyle?
}

struct SDUISlideButton: Decodable {
    /// Text displayed on the track when active
    let text: String
    /// Text displayed when disabled (e.g., "Enter Email")
    var disabledText: String?
    /// Action triggered when slide completes
    let action: SDUIAction
    /// Track background color
    var trackColor: SDUIColor?
    /// Thumb color (active state)
    var thumbColor: SDUIColor?
    /// Text color
    var textColor: SDUIColor?
    /// When set, slide is disabled until context.values[key] is non-empty
    var requiredValueKey: String?
    var style: SDUIStyle?
}

/// Optional styling for the compact page indicator. All fields are optional;
/// `{"compactPageIndicator": {}}` renders with the appearance-derived defaults
/// (active = `appearance.accent`), so existing variants keep their look.
struct SDUICompactPageIndicator: Decodable {
    /// Color of the active dot. Falls back to `appearance.accent`.
    var activeColor: SDUIColor?
    /// Color of inactive dots. Falls back to the default indicator gray.
    var inactiveColor: SDUIColor?
}

enum SDUIKeyboardType: String, Decodable {
    case emailAddress

    var uiKeyboardType: UIKeyboardType {
        switch self {
        case .emailAddress: return .emailAddress
        }
    }
}

enum SDUITextContentType: String, Decodable {
    case emailAddress

    var uiTextContentType: UITextContentType {
        switch self {
        case .emailAddress: return .emailAddress
        }
    }
}

// MARK: - Shape Elements

enum SDUIShapeType: String, Decodable {
    case rectangle
    case roundedRectangle
    case circle
    case capsule
}

struct SDUIShape: Decodable {
    let type: SDUIShapeType
    var cornerRadius: CGFloat?
    var fillColor: SDUIColor?
    var style: SDUIStyle?
}

enum SDUIGradientDirection: String, Decodable {
    case topToBottom
    case bottomToTop
    case leadingToTrailing
    case trailingToLeading
    
    var startPoint: UnitPoint {
        switch self {
        case .topToBottom: return .top
        case .bottomToTop: return .bottom
        case .leadingToTrailing: return .leading
        case .trailingToLeading: return .trailing
        }
    }
    
    var endPoint: UnitPoint {
        switch self {
        case .topToBottom: return .bottom
        case .bottomToTop: return .top
        case .leadingToTrailing: return .trailing
        case .trailingToLeading: return .leading
        }
    }
}

struct SDUIGradient: Decodable {
    let colors: [SDUIColorStop]
    let direction: SDUIGradientDirection
    var style: SDUIStyle?
}

struct SDUIColorStop: Decodable {
    let color: SDUIColor
    let opacity: CGFloat?
    
    static func color(_ color: SDUIColor, opacity: CGFloat = 1.0) -> SDUIColorStop {
        SDUIColorStop(color: color, opacity: opacity)
    }
}

// MARK: - Effect Elements

/// Native confetti. SDUI JSON can't express particle systems, so this element
/// is a thin data shell that the renderer maps to a native view (see
/// `ConfettiView`).
///
/// Two independent layers: a one-shot BURST (`intensity`/`duration`) for motion
/// on appear, and a settled SCATTER (`scatter`) that stays put. Use both when
/// the screen should animate in AND still look decorated while it's read.
///
/// Every field is optional so `{"confetti": {}}` is valid and renders a lively
/// default burst.
struct SDUIConfetti: Decodable {
    /// Hex colors for the confetti pieces. Nil or empty falls back to a festive
    /// multicolor palette.
    var colors: [String]?
    /// Total particle birth rate (pieces per second) spread across the colors.
    /// Nil defaults to a lively-but-not-overwhelming burst.
    var intensity: Int?
    /// Seconds the emitter emits before it stops (birthRate → 0) and settles.
    /// It's a one-shot burst, not a loop. Nil defaults to ~2.5s.
    var duration: Double?
    /// Fraction (0...1) of the container height where the emission line/point
    /// sits; particles fall DOWN from there. 0 = top edge (default), 0.5 =
    /// vertical center, 1 = bottom. Nil defaults to 0 so existing behavior is
    /// unchanged.
    var originY: Double?
    /// Fraction (0...1) of the container width for a POINT burst. Nil = the
    /// default full-width LINE (rain across the whole top). When set (e.g. 0.5),
    /// confetti sprays from a single point centered at `width * originX` and
    /// fans outward — a top-center burst.
    var originX: Double?
    /// Number of SETTLED decorative pieces drawn into the view and left there.
    ///
    /// The burst is one-shot: it emits for `duration`, the pieces fall away, and
    /// seconds later the screen has no confetti at all — and because a
    /// `CAEmitterLayer` is composited by the render server, it never shows up in
    /// a screenshot either. `scatter` is the persistent half: real drawn
    /// content, stable across redraws, present the whole time the screen is up.
    ///
    /// Nil or 0 keeps burst-only behavior, so existing variants are unchanged.
    var scatter: Int?
    /// Fraction (0...1) of the container height the settled `scatter` spans,
    /// measured from the top. Nil defaults to 0.45 — the upper third plus the
    /// headline it decorates. Ignored when `scatter` is nil/0.
    var scatterHeight: Double?
    /// Participates in layout/frame like other elements.
    var style: SDUIStyle?
}

// MARK: - Scroll Elements

struct SDUIScrollView: Decodable {
    let content: SDUIElement
    var axis: SDUIScrollAxis?
    var showsIndicators: Bool?
    var style: SDUIStyle?
    /// Content margins for scroll content
    var contentMargins: SDUIPadding?
    /// Whether to use view-aligned scroll target behavior (for paging)
    var scrollTargetBehavior: SDUIScrollTargetBehavior?
    /// Alignment of the selected target within the scroll viewport.
    var scrollAlignment: SDUIScrollAlignment?
}

enum SDUIScrollTargetBehavior: String, Decodable {
    case viewAligned
    case paging
}

enum SDUIScrollAlignment: String, Decodable {
    case leading
    case center
    case trailing

    var unitPoint: UnitPoint {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Data Elements

struct SDUIForEach: Decodable {
    let dataSource: SDUIDataSource
    let itemTemplate: SDUIElement
    var limit: Int?
    var style: SDUIStyle?
}

enum SDUIDataSource: String, Decodable {
    case offers
    case pageIndicators
}

struct SDUIConditional: Decodable {
    let condition: SDUICondition
    let ifTrue: SDUIElement
    var ifFalse: SDUIElement?
}

/// An operand for the generic `equals` condition: either a literal value or a
/// reference resolved at evaluation time.
///
/// - `{"value": "expensive"}` — literal string.
/// - `{"binding": "selectedAnswer"}` — `context.values["selectedAnswer"]`.
/// - `{"state": true}` — the current state name.
/// - `{"offerIndex": true}` — the current row offer's index (as a string).
enum SDUIValueRef: Decodable {
    case literal(String)
    case binding(String)
    case state
    case offerIndex

    private enum CodingKeys: String, CodingKey {
        case value, binding, state, offerIndex
    }

    init(from decoder: Decoder) throws {
        // Bare string literal: `"foo"`.
        if let single = try? decoder.singleValueContainer(),
           let str = try? single.decode(String.self) {
            self = .literal(str)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .value) {
            self = .literal(value)
        } else if let key = try? container.decode(String.self, forKey: .binding) {
            self = .binding(key)
        } else if container.contains(.state) {
            self = .state
        } else if container.contains(.offerIndex) {
            self = .offerIndex
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown value ref"))
        }
    }
}

indirect enum SDUICondition: Decodable {
    case hasMultipleOffers
    case isCurrentPage(index: Int)
    case isCurrentPageBinding // Uses context's current index

    // Generic state machine conditions
    case stateEquals(String)                      // currentState == value
    case valueEquals(key: String, value: String)  // values[key] == value
    case hasValue(String)                         // values[key] != nil

    /// True when the IAP product loaded into `offerContext.iap` has ANY
    /// introductory offer (free trial, pay-as-you-go, or pay-up-front). Use to
    /// gate intro-only UI (e.g., discount subtitle, strikethrough renewal price)
    /// so variants degrade cleanly when no intro is configured.
    case hasIntroOffer

    /// True when the IAP product's introductory offer is specifically a free
    /// trial (`paymentMode == .freeTrial`). Narrower than `hasIntroOffer` — use
    /// to branch price framing between "$0" and the intro's display price.
    case hasFreeTrial

    /// Row-aware: true when the current `forEach` offer's id matches
    /// `context.values[targetKey ?? "selectedOfferId"]`. Read-side pair to
    /// the `selectOffer` action — use to render per-card selected states
    /// (checkmark, accent border) inside a list of offers.
    case isSelectedOffer(targetKey: String?)

    // Generic boolean combinators
    case and([SDUICondition])
    case or([SDUICondition])
    case not(SDUICondition)
    /// True when both operands resolve to the same string.
    case equals(lhs: SDUIValueRef, rhs: SDUIValueRef)

    // Offer-position predicates (row-aware, against the current forEach offer)
    case isFirstOffer
    case isLastOffer
    case isMiddleOffer
    case offerIndexEquals(Int)

    private enum CodingKeys: String, CodingKey {
        case hasMultipleOffers, isCurrentPage, isCurrentPageBinding
        case stateEquals, valueEquals, hasValue
        case hasIntroOffer, hasFreeTrial
        case isSelectedOffer
        case and, or, not, equals
        case isFirstOffer, isLastOffer, isMiddleOffer, offerIndexEquals
    }

    private struct CurrentPageData: Decodable {
        let index: Int
    }

    private struct ValueEqualsData: Decodable {
        let key: String
        let value: String
    }

    /// Payload for `isSelectedOffer`. Optional — `{"isSelectedOffer": {}}`
    /// defaults to checking `selectedOfferId`; pass `{"targetKey": "..."}`
    /// to read from a different key.
    private struct IsSelectedOfferData: Decodable {
        let targetKey: String?
    }

    private struct EqualsData: Decodable {
        let lhs: SDUIValueRef
        let rhs: SDUIValueRef
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.hasMultipleOffers) {
            self = .hasMultipleOffers
        } else if let data = try? container.decode(CurrentPageData.self, forKey: .isCurrentPage) {
            self = .isCurrentPage(index: data.index)
        } else if container.contains(.isCurrentPageBinding) {
            self = .isCurrentPageBinding
        } else if let state = try? container.decode(String.self, forKey: .stateEquals) {
            self = .stateEquals(state)
        } else if let data = try? container.decode(ValueEqualsData.self, forKey: .valueEquals) {
            self = .valueEquals(key: data.key, value: data.value)
        } else if let key = try? container.decode(String.self, forKey: .hasValue) {
            self = .hasValue(key)
        } else if container.contains(.hasIntroOffer) {
            self = .hasIntroOffer
        } else if container.contains(.hasFreeTrial) {
            self = .hasFreeTrial
        } else if container.contains(.isSelectedOffer) {
            // Support both `{"isSelectedOffer": {}}` (default key) and
            // `{"isSelectedOffer": {"targetKey": "customKey"}}`.
            let data = try? container.decode(IsSelectedOfferData.self, forKey: .isSelectedOffer)
            self = .isSelectedOffer(targetKey: data?.targetKey)
        } else if let conditions = try? container.decode([SDUICondition].self, forKey: .and) {
            self = .and(conditions)
        } else if let conditions = try? container.decode([SDUICondition].self, forKey: .or) {
            self = .or(conditions)
        } else if let condition = try? container.decode(SDUICondition.self, forKey: .not) {
            self = .not(condition)
        } else if let data = try? container.decode(EqualsData.self, forKey: .equals) {
            self = .equals(lhs: data.lhs, rhs: data.rhs)
        } else if container.contains(.isFirstOffer) {
            self = .isFirstOffer
        } else if container.contains(.isLastOffer) {
            self = .isLastOffer
        } else if container.contains(.isMiddleOffer) {
            self = .isMiddleOffer
        } else if let index = try? container.decode(Int.self, forKey: .offerIndexEquals) {
            self = .offerIndexEquals(index)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown condition type"))
        }
    }
}

// MARK: - Main Element Enum

indirect enum SDUIElement {
    case text(SDUIText)
    case systemImage(SDUISystemImage)
    case asyncImage(SDUIAsyncImage)
    case asyncVideo(SDUIAsyncVideo)
    case appIcon(SDUIAppIcon)
    case button(SDUIButton)
    case vStack(SDUIStack)
    case hStack(SDUIStack)
    case zStack(SDUIStack)
    case spacer(SDUISpacer)
    case shape(SDUIShape)
    case gradient(SDUIGradient)
    case scrollView(SDUIScrollView)
    case forEach(SDUIForEach)
    case conditional(SDUIConditional)
    case group(SDUIGroup)
    case textField(SDUITextField)
    case toggle(SDUIToggle)
    case slideButton(SDUISlideButton)
    case compactPageIndicator(SDUICompactPageIndicator)
    case confetti(SDUIConfetti)
    case empty
    
    // Convenience initializers
    static func text(_ text: String, font: SDUIFont? = nil, color: SDUIColor? = nil, style: SDUIStyle? = nil) -> SDUIElement {
        .text(SDUIText(text: text, font: font, color: color, style: style))
    }
    
    static func dynamicText(binding: SDUITextBinding, font: SDUIFont? = nil, color: SDUIColor? = nil, style: SDUIStyle? = nil) -> SDUIElement {
        .text(SDUIText(text: "", font: font, color: color, style: style, textBinding: binding))
    }
}

// MARK: - SDUIElement Decodable

extension SDUIElement: Decodable {
    private enum CodingKeys: String, CodingKey {
        case text, systemImage, asyncImage, asyncVideo, appIcon, button
        case vStack, hStack, zStack
        case spacer, shape, gradient, scrollView
        case forEach, conditional, group, textField, toggle, slideButton
        case compactPageIndicator, confetti, empty
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // OPTIMIZATION: First find which key exists, then decode only that type.
        // This avoids the stack overhead of try? decoding all types in sequence,
        // which was causing stack overflow on deeply nested JSON structures.
        
        if container.contains(.text) {
            self = .text(try container.decode(SDUIText.self, forKey: .text))
        } else if container.contains(.systemImage) {
            self = .systemImage(try container.decode(SDUISystemImage.self, forKey: .systemImage))
        } else if container.contains(.asyncImage) {
            self = .asyncImage(try container.decode(SDUIAsyncImage.self, forKey: .asyncImage))
        } else if container.contains(.asyncVideo) {
            self = .asyncVideo(try container.decode(SDUIAsyncVideo.self, forKey: .asyncVideo))
        } else if container.contains(.appIcon) {
            self = .appIcon(try container.decode(SDUIAppIcon.self, forKey: .appIcon))
        } else if container.contains(.button) {
            self = .button(try container.decode(SDUIButton.self, forKey: .button))
        } else if container.contains(.vStack) {
            self = .vStack(try container.decode(SDUIStack.self, forKey: .vStack))
        } else if container.contains(.hStack) {
            self = .hStack(try container.decode(SDUIStack.self, forKey: .hStack))
        } else if container.contains(.zStack) {
            self = .zStack(try container.decode(SDUIStack.self, forKey: .zStack))
        } else if container.contains(.spacer) {
            self = .spacer(try container.decode(SDUISpacer.self, forKey: .spacer))
        } else if container.contains(.shape) {
            self = .shape(try container.decode(SDUIShape.self, forKey: .shape))
        } else if container.contains(.gradient) {
            self = .gradient(try container.decode(SDUIGradient.self, forKey: .gradient))
        } else if container.contains(.scrollView) {
            self = .scrollView(try container.decode(SDUIScrollView.self, forKey: .scrollView))
        } else if container.contains(.forEach) {
            self = .forEach(try container.decode(SDUIForEach.self, forKey: .forEach))
        } else if container.contains(.conditional) {
            self = .conditional(try container.decode(SDUIConditional.self, forKey: .conditional))
        } else if container.contains(.group) {
            self = .group(try container.decode(SDUIGroup.self, forKey: .group))
        } else if container.contains(.textField) {
            self = .textField(try container.decode(SDUITextField.self, forKey: .textField))
        } else if container.contains(.toggle) {
            self = .toggle(try container.decode(SDUIToggle.self, forKey: .toggle))
        } else if container.contains(.slideButton) {
            self = .slideButton(try container.decode(SDUISlideButton.self, forKey: .slideButton))
        } else if container.contains(.compactPageIndicator) {
            // Tolerant of legacy `{"compactPageIndicator": true}` / `null` and
            // the new `{"compactPageIndicator": {"activeColor": {...}}}` form.
            let config = (try? container.decode(SDUICompactPageIndicator.self, forKey: .compactPageIndicator))
                ?? SDUICompactPageIndicator()
            self = .compactPageIndicator(config)
        } else if container.contains(.confetti) {
            // Tolerant of `{"confetti": {}}` / `null` — an empty payload is a
            // valid, fully-defaulted burst.
            let config = (try? container.decode(SDUIConfetti.self, forKey: .confetti))
                ?? SDUIConfetti()
            self = .confetti(config)
        } else if container.contains(.empty) {
            self = .empty
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown SDUIElement type. Available keys: \(container.allKeys.map { $0.stringValue })"
                )
            )
        }
    }
}
