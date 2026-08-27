//
//  SDUIStyleModifiers.swift
//  Encore
//
//  Style modifiers for Server-Driven UI elements
//

import SwiftUI

// MARK: - Style Modifier (broken into sub-modifiers for compiler performance)

@available(iOS 17.0, *)
struct SDUIStyleModifier: ViewModifier {
    let style: SDUIStyle?

    func body(content: Content) -> some View {
        content
            .modifier(SDUIContainerRelativeFrameModifier(config: style?.containerRelativeFrame))
            .modifier(SDUIRelativeFrameModifier(width: style?.relativeWidth, height: style?.relativeHeight))
            .modifier(SDUISafeAreaPaddingModifier(config: style?.safeAreaPadding))
            .modifier(SDUIPaddingModifier(padding: style?.padding))
            .modifier(SDUIFrameModifier(frame: style?.frame))
            .modifier(SDUIFixedSizeModifier(fixedSize: style?.fixedSize))
            .modifier(SDUIClippedModifier(clipped: style?.clipped))
            // Fill + corner-radius clip + shadow composed together so the drop
            // shadow is cast by the filled rounded SHAPE (behind the content,
            // outside the clip) and never clipped into a hard rectangle.
            .modifier(SDUISurfaceModifier(
                backgroundColor: style?.backgroundColor,
                cornerRadius: style?.cornerRadii == nil ? style?.cornerRadius : nil,
                cornerRadii: style?.cornerRadii,
                shadow: style?.shadow
            ))
            .modifier(SDUIBorderModifier(width: style?.borderWidth, color: style?.borderColor, cornerRadius: style?.cornerRadius))
            .modifier(SDUIGradientBorderModifier(border: style?.gradientBorder, fallbackCornerRadius: style?.cornerRadius))
            .modifier(SDUIInnerShadowModifier(innerShadow: style?.innerShadow, cornerRadius: style?.resolvedCornerRadius ?? 0))
            .modifier(SDUIOpacityModifier(opacity: style?.opacity))
            .modifier(SDUIClipShapeModifier(clipShape: style?.clipShape))
            .modifier(SDUISafeAreaModifier(ignoresSafeArea: style?.ignoresSafeArea))
            .modifier(SDUILayoutPriorityModifier(priority: style?.layoutPriority))
            // Transforms applied last — after frame/background/overlay resolve —
            // so scale/rotation/offset move the fully-composed element.
            .modifier(SDUIScaleModifier(scale: style?.scale))
            .modifier(SDUIRotationModifier(degrees: style?.rotation))
            .modifier(SDUIOffsetModifier(offset: style?.offset))
            // Scroll-driven transforms wrap the composed element so they
            // animate the whole card (transform + fill) as it scrolls.
            .modifier(SDUIScrollTransitionModifier(transition: style?.scrollTransition))
            .modifier(SDUIScrollFadeModifier(fade: style?.scrollFade))
    }
}

@available(iOS 17.0, *)
struct SDUIPaddingModifier: ViewModifier {
    let padding: SDUIPadding?
    func body(content: Content) -> some View {
        content.padding(padding?.edgeInsets ?? EdgeInsets())
    }
}

@available(iOS 17.0, *)
struct SDUIFrameModifier: ViewModifier {
    let frame: SDUIFrame?
    func body(content: Content) -> some View {
        content
            .frame(width: frame?.width, height: frame?.height)
            .frame(
                minWidth: frame?.minWidth,
                maxWidth: frame?.maxWidthValue,
                minHeight: frame?.minHeight,
                maxHeight: frame?.maxHeightValue,
                alignment: frame?.alignment?.alignment ?? .center
            )
    }
}

@available(iOS 17.0, *)
struct SDUIClippedModifier: ViewModifier {
    let clipped: Bool?

    func body(content: Content) -> some View {
        if clipped == true {
            content.clipped()
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIFixedSizeModifier: ViewModifier {
    let fixedSize: SDUIFixedSize?

    func body(content: Content) -> some View {
        if let fixedSize {
            content.fixedSize(
                horizontal: fixedSize.horizontal ?? false,
                vertical: fixedSize.vertical ?? false
            )
        } else {
            content
        }
    }
}

/// Composes an element's rounded fill, its corner-radius clip, and its drop
/// shadow as ONE unit so the shadow is cast by the filled rounded SHAPE and is
/// never caught inside the clip.
///
/// WHY: the old chain did `.background(color).cornerRadius(r).shadow(...)`. The
/// deprecated `.cornerRadius()` establishes a clip; applying `.shadow()` after a
/// clip — and then a `.rotationEffect()` on overlapping cards (the claimed
/// screen's tilted ±5° cards) — rasterizes the shadow into a HARD RECTANGULAR
/// cutoff on device. The SwiftUI-correct pattern is to let the filled rounded
/// SHAPE draw the shadow behind the content, OUTSIDE any content clip, so it
/// stays a soft blur.
///
/// Composition, by case:
/// - fill + rounding + shadow (the card): clip CONTENT to the rounded shape,
///   then `.background(shape.fill(color).shadow(...))` — shadow lives behind the
///   content and outside the clip.
/// - fill + rounding, no shadow: identical rounded fill, no shadow introduced.
/// - fill, no rounding: a plain rectangular fill (+ shadow if present).
/// - rounding, no fill: clip the content only (no shadow shape to cast from, so
///   any shadow falls back to the content silhouette).
/// - shadow only: apply the shadow to the content silhouette.
///
/// Replaces the old separate background / cornerRadius / cornerRadii modifiers.
@available(iOS 17.0, *)
struct SDUISurfaceModifier: ViewModifier {
    let backgroundColor: SDUIColor?
    let cornerRadius: CGFloat?
    let cornerRadii: SDUICornerRadii?
    let shadow: SDUIShadow?
    @Environment(\.sduiAppearance) private var appearance
    @Environment(\.sduiColorValues) private var colorValues

    /// The rounded shape used for BOTH the content clip and the fill+shadow, so
    /// the fill silhouette and the clip are always identical. A plain rectangle
    /// when no radius is set.
    private var roundedShape: AnyShape {
        if let cornerRadii {
            return AnyShape(UnevenRoundedRectangle(cornerRadii: cornerRadii.rectCornerRadii, style: .circular))
        }
        return AnyShape(RoundedRectangle(cornerRadius: cornerRadius ?? 0, style: .circular))
    }

    private var isRounded: Bool {
        cornerRadii != nil || (cornerRadius ?? 0) > 0
    }

    func body(content: Content) -> some View {
        let fill = backgroundColor?.resolved(in: appearance, values: colorValues)
        // Clip the CONTENT ONLY (never the shadow) to the rounded shape.
        let clipped = clip(content)

        if let fill {
            // Filled surface: the fill is drawn as a background SHAPE that carries
            // the shadow, so the shadow renders behind the content and OUTSIDE the
            // content clip — a soft blur that rotates with the card.
            clipped.background(shapedFill(fill))
        } else if let shadow {
            // No fill to cast from — apply the shadow to the content silhouette.
            clipped.modifier(SDUIShadowModifier(shadow: shadow))
        } else {
            clipped
        }
    }

    @ViewBuilder
    private func clip(_ content: Content) -> some View {
        if isRounded {
            content.clipShape(roundedShape)
        } else {
            content
        }
    }

    /// The background fill shape (rounded when a radius is set, a plain rectangle
    /// otherwise) carrying the drop shadow so it renders as a soft, unclipped blur.
    @ViewBuilder
    private func shapedFill(_ fill: Color) -> some View {
        let filled = roundedShape.fill(fill)
        if let shadow {
            let shadowColor = shadow.color.resolved(in: appearance, values: colorValues)
            filled.shadow(
                color: shadowColor.opacity(shadow.opacity ?? 0.1),
                radius: shadow.radius,
                x: shadow.x,
                y: shadow.y
            )
        } else {
            filled
        }
    }
}

@available(iOS 17.0, *)
struct SDUIBorderModifier: ViewModifier {
    let width: CGFloat?
    let color: SDUIColor?
    let cornerRadius: CGFloat?
    @Environment(\.sduiAppearance) private var appearance
    @Environment(\.sduiColorValues) private var colorValues

    func body(content: Content) -> some View {
        if let width = width, let color = color {
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius ?? 0, style: .circular)
                    .strokeBorder(color.resolved(in: appearance, values: colorValues), lineWidth: width)
            )
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIShadowModifier: ViewModifier {
    let shadow: SDUIShadow?
    @Environment(\.sduiAppearance) private var appearance
    @Environment(\.sduiColorValues) private var colorValues
    func body(content: Content) -> some View {
        let resolvedColor = shadow?.color.resolved(in: appearance, values: colorValues) ?? Color.clear
        return content.shadow(
            color: resolvedColor.opacity(shadow?.opacity ?? 0.1),
            radius: shadow?.radius ?? 0,
            x: shadow?.x ?? 0,
            y: shadow?.y ?? 0
        )
    }
}

/// Inset (inner) shadow. SwiftUI has no native inner shadow, so we overlay the
/// element's rounded shape stroked in the shadow color, blur it, offset it by
/// (x,y), and MASK it to the same shape — so the soft band hugs the INSIDE of
/// the edges (stronger on the side the offset pushes toward) and is clipped to
/// the corner radius. No-op when absent; non-interactive so it never eats taps.
@available(iOS 17.0, *)
struct SDUIInnerShadowModifier: ViewModifier {
    let innerShadow: SDUIInnerShadow?
    let cornerRadius: CGFloat
    @Environment(\.sduiAppearance) private var appearance
    @Environment(\.sduiColorValues) private var colorValues

    func body(content: Content) -> some View {
        if let s = innerShadow {
            let base = s.color.resolved(in: appearance, values: colorValues)
            // The color already carries any author opacity transform; `opacity`
            // is an optional extra multiplier (parity with SDUIShadow). nil → 1.
            let tint = s.opacity.map { base.opacity(Double($0)) } ?? base
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
            content.overlay(
                shape
                    // A stroke wide enough to read after blurring; the blur
                    // softens it into a glow band along the inner edge.
                    .stroke(tint, lineWidth: max(s.radius, 1))
                    .blur(radius: s.radius)
                    .offset(x: s.x, y: s.y)
                    .mask(shape) // clip the glow to the element's shape (inside only)
                    .allowsHitTesting(false)
            )
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIOpacityModifier: ViewModifier {
    let opacity: CGFloat?
    func body(content: Content) -> some View {
        content.opacity(opacity ?? 1.0)
    }
}

@available(iOS 17.0, *)
struct SDUIClipShapeModifier: ViewModifier {
    let clipShape: SDUIClipShape?

    func body(content: Content) -> some View {
        if let clipShape = clipShape {
            switch clipShape {
            case let .rectangle(cornerRadius):
                content.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            case .circle:
                content.clipShape(Circle())
            case .capsule:
                content.clipShape(Capsule())
            }
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUISafeAreaModifier: ViewModifier {
    let ignoresSafeArea: Bool?

    func body(content: Content) -> some View {
        if ignoresSafeArea == true {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

/// Insets an element by the device safe area on the configured edges via
/// `.safeAreaPadding(...)`. Paired with the fullScreenCover root-bleed: the root
/// bleeds (full-bleed background), and the content element opts back in here.
@available(iOS 17.0, *)
struct SDUISafeAreaPaddingModifier: ViewModifier {
    let config: SDUISafeAreaPadding?

    func body(content: Content) -> some View {
        if let config = config, !config.edges.isEmpty {
            content.safeAreaPadding(config.edges)
        } else {
            content
        }
    }
}

/// Controls how the SDUI content root relates to the device safe area, applied
/// once at the presentation root (`OfferSheetView.sduiContent`).
///
/// The reliable model — don't depend on a child's `ignoresSafeArea` backing out
/// of a safe-area-respecting parent (it only extends as far as the parent's own
/// ignored region, so it bleeds horizontally but leaves the top/bottom safe
/// areas black):
///
/// - **fullScreenCover**: the root BLEEDS (`.ignoresSafeArea()`), so a full-bleed
///   background (the gradient) fills the entire screen including all four safe
///   areas. The CONTENT then opts back in with the per-element `safeAreaPadding`
///   style so text / cards / buttons clear the Dynamic Island & home indicator.
/// - **sheet**: NO root ignore — sheets already respect the safe area; leaving
///   natural behavior avoids regressing control.json and other sheet variants.
///
/// `respectsSafeArea: false` forces the bleed in BOTH presentations (variant
/// manages its own insets / opts out of content insetting entirely).
@available(iOS 17.0, *)
struct SDUIRootSafeAreaModifier: ViewModifier {
    /// Whether content should inset for the safe area (config `respectsSafeArea`,
    /// default true). When false the root always bleeds regardless of style.
    let respectsSafeArea: Bool
    /// The variant's presentation style — decides whether the root bleeds.
    let presentationStyle: SDUIPresentationStyle

    func body(content: Content) -> some View {
        if !respectsSafeArea {
            // Opt-out: whole tree bleeds; the variant owns its insets.
            content.ignoresSafeArea()
        } else {
            switch presentationStyle {
            case .fullScreenCover:
                // Root bleeds so full-bleed backgrounds fill all four safe
                // areas; content insets itself via `style.safeAreaPadding`.
                content.ignoresSafeArea()
            case .sheet:
                // Sheets respect the safe area natively — leave as-is.
                content
            }
        }
    }
}

@available(iOS 17.0, *)
struct SDUILayoutPriorityModifier: ViewModifier {
    let priority: Double?
    func body(content: Content) -> some View {
        content.layoutPriority(priority ?? 0)
    }
}

@available(iOS 17.0, *)
struct SDUIContainerRelativeFrameModifier: ViewModifier {
    let config: SDUIContainerRelativeFrame?

    func body(content: Content) -> some View {
        if let config = config {
            switch config.axis ?? .horizontal {
            case .horizontal:
                content.containerRelativeFrame(.horizontal)
            case .vertical:
                content.containerRelativeFrame(.vertical)
            }
        } else {
            content
        }
    }
}

// MARK: - Generic Transform Modifiers

/// Fractional sizing relative to the nearest container, via
/// `containerRelativeFrame`. `relativeWidth: 0.7` makes the element 70% of the
/// container's width. No-op when neither fraction is set.
@available(iOS 17.0, *)
struct SDUIRelativeFrameModifier: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?

    func body(content: Content) -> some View {
        switch (width, height) {
        case let (w?, h?):
            content
                .containerRelativeFrame(.horizontal) { length, _ in length * w }
                .containerRelativeFrame(.vertical) { length, _ in length * h }
        case let (w?, nil):
            content.containerRelativeFrame(.horizontal) { length, _ in length * w }
        case let (nil, h?):
            content.containerRelativeFrame(.vertical) { length, _ in length * h }
        case (nil, nil):
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIScaleModifier: ViewModifier {
    let scale: CGFloat?
    func body(content: Content) -> some View {
        if let scale = scale {
            content.scaleEffect(scale)
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIRotationModifier: ViewModifier {
    let degrees: CGFloat?
    func body(content: Content) -> some View {
        if let degrees = degrees {
            content.rotationEffect(.degrees(degrees))
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
struct SDUIOffsetModifier: ViewModifier {
    let offset: SDUIOffset?
    func body(content: Content) -> some View {
        if let offset = offset {
            content.offset(x: offset.x ?? 0, y: offset.y ?? 0)
        } else {
            content
        }
    }
}

/// Gradient stroke around the element. Resolves each stop through the active
/// appearance + color values (so binding/transform stops work).
@available(iOS 17.0, *)
struct SDUIGradientBorderModifier: ViewModifier {
    let border: SDUIGradientBorder?
    let fallbackCornerRadius: CGFloat?
    @Environment(\.sduiAppearance) private var appearance
    @Environment(\.sduiColorValues) private var colorValues

    func body(content: Content) -> some View {
        if let border = border, !border.colors.isEmpty {
            let colors = border.colors.map { $0.resolved(in: appearance, values: colorValues) }
            let direction = border.direction ?? .leadingToTrailing
            content.overlay(
                RoundedRectangle(cornerRadius: border.cornerRadius ?? fallbackCornerRadius ?? 0, style: .circular)
                    .strokeBorder(
                        LinearGradient(
                            colors: colors,
                            startPoint: direction.startPoint,
                            endPoint: direction.endPoint
                        ),
                        lineWidth: border.width ?? 1
                    )
            )
        } else {
            content
        }
    }
}

/// Carousel cards derive a continuous phase from their frame in the horizontal
/// scroll-view coordinate space. Other scroll-transition elements keep
/// SwiftUI's native viewport-driven interactive phase.
@available(iOS 17.0, *)
struct SDUIScrollTransitionModifier: ViewModifier {
    let transition: SDUIScrollTransition?

    @Environment(\.sduiCarouselViewportWidth) private var carouselViewportWidth

    func body(content: Content) -> some View {
        if let transition, let carouselViewportWidth {
            content.visualEffect { view, geometryProxy in
                view
                    .scaleEffect(Self.scale(
                        transition: transition,
                        frame: geometryProxy.frame(in: .scrollView(axis: .horizontal)),
                        viewportWidth: carouselViewportWidth
                    ))
                    .opacity(Self.opacity(
                        transition: transition,
                        frame: geometryProxy.frame(in: .scrollView(axis: .horizontal)),
                        viewportWidth: carouselViewportWidth
                    ))
                    .rotationEffect(.degrees(Self.rotation(
                        transition: transition,
                        frame: geometryProxy.frame(in: .scrollView(axis: .horizontal)),
                        viewportWidth: carouselViewportWidth
                    )))
                    .offset(y: Self.yOffset(
                        transition: transition,
                        frame: geometryProxy.frame(in: .scrollView(axis: .horizontal)),
                        viewportWidth: carouselViewportWidth
                    ))
            }
        } else if let transition {
            // Single trailing expression (no intermediate `let`s / explicit
            // `return`): a multi-statement closure that returns the opaque
            // `some VisualEffect` fails return-type inference on stricter
            // toolchains ("add explicit type to disambiguate"), which can't be
            // annotated for an opaque type. `mag` = 0 centered → 1 at extreme.
            content.scrollTransition(.interactive) { view, phase in
                view
                    .scaleEffect(1 - (1 - Double(transition.scale ?? 1)) * min(1.0, abs(phase.value)))
                    .opacity(1 - (1 - Double(transition.opacity ?? 1)) * min(1.0, abs(phase.value)))
                    .rotationEffect(.degrees(Double(transition.rotation ?? 0) * phase.value))
                    .offset(y: Double(transition.yOffset ?? 0) * min(1.0, abs(phase.value)))
            }
        } else {
            content
        }
    }

    private nonisolated static func phase(frame: CGRect, viewportWidth: CGFloat) -> Double {
        guard frame.width > 0 else { return 0 }
        let position = Double(frame.midX - viewportWidth / 2) / Double(frame.width)
        return min(1, max(-1, position))
    }

    private nonisolated static func magnitude(frame: CGRect, viewportWidth: CGFloat) -> Double {
        abs(phase(frame: frame, viewportWidth: viewportWidth))
    }

    private nonisolated static func scale(
        transition: SDUIScrollTransition,
        frame: CGRect,
        viewportWidth: CGFloat
    ) -> Double {
        1 - (1 - Double(transition.scale ?? 1)) * magnitude(frame: frame, viewportWidth: viewportWidth)
    }

    private nonisolated static func opacity(
        transition: SDUIScrollTransition,
        frame: CGRect,
        viewportWidth: CGFloat
    ) -> Double {
        1 - (1 - Double(transition.opacity ?? 1)) * magnitude(frame: frame, viewportWidth: viewportWidth)
    }

    private nonisolated static func rotation(
        transition: SDUIScrollTransition,
        frame: CGRect,
        viewportWidth: CGFloat
    ) -> Double {
        Double(transition.rotation ?? 0) * phase(frame: frame, viewportWidth: viewportWidth)
    }

    private nonisolated static func yOffset(
        transition: SDUIScrollTransition,
        frame: CGRect,
        viewportWidth: CGFloat
    ) -> Double {
        Double(transition.yOffset ?? 0) * magnitude(frame: frame, viewportWidth: viewportWidth)
    }
}

/// Opacity crossfade tied to which carousel card is centered. Drives opacity
/// from `centeredOpacity` on the focused card to `offCenterOpacity` on every
/// other card. Layer a colored face with this over a white face to reveal the
/// brand fill (and a checkmark badge) only on the centered card.
///
/// WHY NOT SCROLL GEOMETRY: every geometry/`.scrollTransition` approach failed
/// in the real app (a live `fullScreenCover` with a finger-driven scroll):
///   1. a NESTED `.scrollTransition` on this layer never receives a continuous
///      `phase.value` (SwiftUI collapses it to discrete states) → the fill
///      snaps 0↔1;
///   2. `visualEffect` + the implicit `.scrollView` space returns nil bounds
///      inside the scaled/nested card → everything reads centered → always
///      filled;
///   3. `visualEffect` + a NAMED coordinate space on the ScrollView works in the
///      headless snapshot harness but STILL resolves every card as centered in
///      the running app.
/// So we DON'T read scroll geometry at all. Instead `renderForEach` publishes
/// each card's distance from the centered index (`abs(index - currentIndex)`,
/// the same signal that drives the working per-card `.zIndex`) into the
/// environment; this layer — a descendant of the card — reads it. That value is
/// plain state that always resolves correctly in the real app. The trade-off is
/// a snap-at-center-change rather than finger-tracking, so we `.animation(...)`
/// the opacity on `distance` changes for a smooth crossfade as the centered card
/// changes. Reliable beats continuous-but-broken.
///
/// Default distance `0` (no carousel / static context) → `centeredOpacity`, so
/// non-scroll renders show the layer at full opacity as before.
@available(iOS 17.0, *)
struct SDUIScrollFadeModifier: ViewModifier {
    let fade: SDUIScrollFade?

    /// Distance of the enclosing card from the centered card, published by
    /// `renderForEach`. `0` on the focused card, `>= 1` on the rest.
    @Environment(\.sduiScrollFadeDistance) private var distance

    func body(content: Content) -> some View {
        if let f = fade {
            let op = Self.scrollFadeOpacity(
                distance: distance,
                centeredOpacity: Double(f.centeredOpacity ?? 1),
                offCenterOpacity: Double(f.offCenterOpacity ?? 0)
            )
            content
                .opacity(op)
                // Crossfade when the centered card changes (distance flips
                // between 0 and >=1) instead of snapping.
                .animation(.easeInOut(duration: 0.25), value: distance)
        } else {
            content
        }
    }

    /// Pure distance→opacity mapping (extracted for deterministic testing).
    ///
    /// - centered card (`distance == 0`) → `centeredOpacity`
    /// - any other card (`distance >= 1`) → `offCenterOpacity`
    ///
    /// `distance` is clamped into `[0, 1]` so the interpolation saturates at one
    /// card away — every non-centered card resolves to exactly `offCenterOpacity`
    /// regardless of how far it is. Monotonic and continuous in `distance`.
    nonisolated static func scrollFadeOpacity(
        distance: Double,
        centeredOpacity: Double,
        offCenterOpacity: Double
    ) -> Double {
        let mag = min(1, max(0, abs(distance)))
        return centeredOpacity + (offCenterOpacity - centeredOpacity) * mag
    }
}

// MARK: - ScrollView Extensions

@available(iOS 17.0, *)
extension View {
    @ViewBuilder
    func applyScrollTargetBehavior(_ behavior: SDUIScrollTargetBehavior?) -> some View {
        if let behavior = behavior {
            switch behavior {
            case .viewAligned:
                if #available(iOS 18.0, *) {
                    scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                } else {
                    scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                }
            case .paging:
                scrollTargetBehavior(.paging)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func applyContentMargin(_ margin: CGFloat?, axis: Axis.Set) -> some View {
        if let margin {
            if axis == .horizontal {
                contentMargins(.horizontal, margin, for: .scrollContent)
            } else {
                contentMargins(.vertical, margin, for: .scrollContent)
            }
        } else {
            self
        }
    }
}
