//
//  SDUIElementRenderer.swift
//  Encore
//
//  Recursive view renderer for Server-Driven UI elements
//

import AVKit
import SwiftUI

// MARK: - Main Element Renderer

@available(iOS 17.0, *)
struct SDUIElementRenderer: View {
    let element: SDUIElement
    @ObservedObject var context: SDUIContext
    var offer: Offer? = nil
    var isCurrentPage: Bool = false

    /// Observed so the tree re-renders when a logo's dominant color is
    /// extracted asynchronously, letting `{"binding": "offerDominantColor"}`
    /// update from the neutral fallback to the real brand color.
    @ObservedObject private var dominantColors = DominantColorStore.shared

    var body: some View {
        renderElement(element)
            .background {
                if let backgroundElement = elementStyle?.backgroundElement {
                    SDUIElementRenderer(element: backgroundElement, context: context, offer: offer)
                }
            }
            .overlay {
                if let overlayElement = elementStyle?.overlay {
                    SDUIElementRenderer(element: overlayElement, context: context, offer: offer)
                }
            }
            // Publish the row-scoped color binding values so generic
            // ViewModifiers (border, gradientBorder, background) that have no
            // SDUIContext can still resolve `{"binding": "..."}` colors.
            .environment(\.sduiColorValues, colorValues)
    }

    private var elementStyle: SDUIStyle? {
        switch element {
        case let .text(config): config.style
        case let .systemImage(config): config.style
        case let .asyncImage(config): config.style
        case let .asyncVideo(config): config.style
        case let .appIcon(config): config.style
        case let .button(config): config.style
        case let .vStack(config), let .hStack(config), let .zStack(config): config.style
        case let .spacer(config): config.style
        case let .shape(config): config.style
        case let .gradient(config): config.style
        case let .scrollView(config): config.style
        case let .forEach(config): config.style
        case let .group(config): config.style
        case let .textField(config): config.style
        case let .toggle(config): config.style
        case let .slideButton(config): config.style
        case let .confetti(config): config.style
        case .conditional, .compactPageIndicator, .empty: nil
        }
    }

    /// Per-render color binding values: the current row offer's dominant color
    /// and the selected offer's dominant color. Merged on top of
    /// `context.values` by `context.resolveColor(_:extraValues:)`. Reads
    /// cached colors and schedules extraction on miss (non-blocking).
    private var colorValues: [String: String] {
        var v: [String: String] = [:]
        let rowOffer = offer ?? context.currentOffer
        // Schedule extraction on miss (discardable), but only publish the key
        // once a REAL color is cached — leaving it unset until then so the
        // JSON-authored `fallback` applies, instead of masking it with the
        // extractor's neutral placeholder (mirrors `appDominantColor` below).
        dominantColors.dominantHex(for: rowOffer?.displayLogoUrl)
        if let hex = dominantColors.cachedHex(for: rowOffer?.displayLogoUrl) {
            v["offerDominantColor"] = hex
        }
        dominantColors.dominantHex(for: context.selectedOfferLogoUrl)
        if let hex = dominantColors.cachedHex(for: context.selectedOfferLogoUrl) {
            v["selectedOfferDominantColor"] = hex
        }
        // Host app's OWN icon color. Left unset until extraction lands (or when
        // the host has no / a white icon) so the JSON `fallback` is used; once
        // computed, the store publishes and the observed re-render swaps it in.
        #if canImport(UIKit)
            if let appHex = dominantColors.dominantHexForHostAppIcon() {
                v["appDominantColor"] = appHex
            }
        #endif
        return v
    }

    /// Terse wrapper threading `colorValues` into color resolution.
    private func resolveColor(_ color: SDUIColor?) -> Color? {
        context.resolveColor(color, extraValues: colorValues)
    }

    @ViewBuilder
    private func renderElement(_ element: SDUIElement) -> some View {
        switch element {
        case let .text(config):
            renderText(config)
        case let .systemImage(config):
            renderSystemImage(config)
        case let .asyncImage(config):
            renderAsyncImage(config)
        case let .asyncVideo(config):
            renderAsyncVideo(config)
        case let .appIcon(config):
            renderAppIcon(config)
        case let .button(config):
            renderButton(config)
        case let .vStack(config):
            renderVStack(config)
        case let .hStack(config):
            renderHStack(config)
        case let .zStack(config):
            renderZStack(config)
        case let .spacer(config):
            renderSpacer(config)
        case let .shape(config):
            renderShape(config)
        case let .gradient(config):
            renderGradient(config)
        case let .scrollView(config):
            renderScrollView(config)
        case let .forEach(config):
            renderForEach(config)
        case let .conditional(config):
            renderConditional(config)
        case let .group(config):
            renderGroup(config)
        case let .textField(config):
            renderTextField(config)
        case let .toggle(config):
            renderToggle(config)
        case let .slideButton(config):
            renderSlideButton(config)
        case let .compactPageIndicator(config):
            renderCompactPageIndicator(config)
        case let .confetti(config):
            renderConfetti(config)
        case .empty:
            EmptyView()
        }
    }

    // MARK: - Text Renderer

    /// Resolves a text binding using the item-specific offer (for forEach loops) or falls back to context
    private func resolveTextBinding(_ binding: SDUITextBinding) -> String {
        // If we have an item-specific offer (inside a forEach loop), use it for offer-related bindings
        if let itemOffer = offer {
            switch binding {
            case .offerAdvertiserName:
                return itemOffer.advertiserName ?? ""
            case .offerDescription:
                return itemOffer.creativeAdvertiserDescription ?? ""
            case .offerPerk:
                return itemOffer.perk ?? ""
            case .offerCtaText:
                return itemOffer.displayCtaText ?? "Get"
            default:
                // For non-offer bindings, fall back to context
                return context.resolveText(binding)
            }
        }
        // No item-specific offer, use context (which uses currentOffer)
        return context.resolveText(binding)
    }

    private func resolveText(_ config: SDUIText) -> String {
        // First, check for valueKey (direct read from context.values)
        if let valueKey = config.valueKey, let value = context.values[valueKey] {
            return context.resolveTemplateText(value)
        }

        // Check for textMapKey (dynamic text from text maps)
        if let mapKey = config.textMapKey {
            let valueKey = config.textMapValueKey ?? mapKey
            if let resolvedText = context.resolveTextMap(mapKey: mapKey, valueKey: valueKey) {
                return resolvedText
            }
            // Fall back to static text if map lookup fails
        }

        // Check for text binding
        if let binding = config.textBinding {
            return resolveTextBinding(binding)
        }

        // Resolve template placeholders (${variableName}) in the text
        return context.resolveTemplateText(config.text)
    }

    @ViewBuilder
    private func renderText(_ config: SDUIText) -> some View {
        // Calculate effective line spacing from lineHeight or lineSpacing
        let effectiveLineSpacing = calculateLineSpacing(config)

        // If we have segments, render concatenated text. Without an explicit
        // lineLimit, segmented (multi-run) Text otherwise collapses to a single
        // truncated line inside width-greedy parents (HStacks, carousel cards).
        // `fixedSize(vertical:)` re-enables wrapping so it behaves exactly like
        // single-run text: honor an explicit `lineLimit`, otherwise grow
        // vertically and wrap across lines respecting `multilineAlignment` and
        // `lineHeight`.
        if let segments = config.segments, !segments.isEmpty {
            renderConcatenatedText(config, segments: segments)
                .lineSpacing(effectiveLineSpacing)
                .lineLimit(config.lineLimit)
                .multilineTextAlignment(config.multilineAlignment?.textAlignment ?? .leading)
                .fixedSize(horizontal: false, vertical: config.lineLimit == nil)
                .modifier(SDUIStyleModifier(style: config.style))
        } else {
            renderSingleText(config, effectiveLineSpacing: effectiveLineSpacing)
        }
    }

    private func renderSingleText(_ config: SDUIText, effectiveLineSpacing: CGFloat) -> some View {
        let resolved = resolveText(config)
        let baseColor = resolveColor(config.color) ?? Color(UIColor.label)

        // A `*marked*` run only becomes a separate run when the author asked for
        // a highlight color; otherwise the markers stay literal and this is the
        // same single `Text` it always was.
        var text: Text
        if let highlight = config.highlightColor.flatMap({ resolveColor($0) }) {
            text = Self.highlightedText(
                resolved,
                font: config.font,
                baseColor: baseColor,
                highlightColor: highlight
            )
        } else {
            text = Text(resolved)
        }

        if let font = config.font {
            text = text.applySDUIFont(font)
        }
        if config.strikethrough == true {
            text = text.strikethrough(true, color: baseColor)
        }

        return text
            .foregroundColor(baseColor)
            .lineSpacing(effectiveLineSpacing)
            .lineLimit(config.lineLimit)
            .multilineTextAlignment(config.multilineAlignment?.textAlignment ?? .leading)
            .modifier(SDUIStyleModifier(style: config.style))
    }

    /// Builds a `Text` whose `*marked*` runs carry `highlightColor`.
    ///
    /// Concatenated `Text` rather than `AttributedString` so the result is still
    /// a `Text` — `lineLimit`, `multilineTextAlignment` and `lineSpacing` all
    /// apply to it exactly as they do to the single-run path, and it wraps
    /// across lines normally. Per-run `.font` is applied so the concatenation
    /// keeps a consistent face before the outer `.font` lands.
    static func highlightedText(
        _ resolved: String,
        font: SDUIFont?,
        baseColor: Color,
        highlightColor: Color
    ) -> Text {
        SDUIInlineMarkup.parse(resolved).reduce(Text("")) { accumulated, run in
            var piece = Text(run.text)
            if let font {
                piece = piece.applySDUIFont(font)
            }
            return accumulated + piece.foregroundColor(run.isHighlighted ? highlightColor : baseColor)
        }
    }

    /// Calculates effective line spacing from lineHeight multiplier or direct lineSpacing value
    /// lineHeight is a multiplier (e.g., 1.2 = 120% of font size), lineSpacing is in points
    private func calculateLineSpacing(_ config: SDUIText) -> CGFloat {
        // Design-tool semantics first: a TOTAL line height, converted to the
        // gap SwiftUI actually wants by subtracting the font's own leading.
        // Negative is legitimate and necessary — Figma's 1.1 on 28pt (30.8pt)
        // is TIGHTER than SF Pro's natural 33.5pt, and `lineSpacing` accepts
        // negative values where `lineHeight`'s clamp cannot.
        if let multiple = config.lineHeightMultiple, let font = config.font {
            return Self.lineSpacing(forTotalLineHeight: multiple, font: font)
        }

        // If lineHeight is provided, calculate spacing from font size
        if let lineHeight = config.lineHeight, let font = config.font {
            // lineHeight is a multiplier, so additional spacing = (lineHeight - 1.0) * fontSize
            // For example: lineHeight 1.2 with fontSize 16 = 0.2 * 16 = 3.2pt additional spacing
            let additionalSpacing = (lineHeight - 1.0) * font.size
            return max(0, additionalSpacing)
        }

        // Fall back to direct lineSpacing value
        return config.lineSpacing ?? 0
    }

    /// `lineSpacing` that yields a total line height of `multiple x size`.
    /// Pure and `nonisolated` so the arithmetic is testable without a renderer.
    nonisolated static func lineSpacing(forTotalLineHeight multiple: CGFloat, font: SDUIFont) -> CGFloat {
        let natural = UIFont.systemFont(ofSize: font.size, weight: font.weight.uiFontWeight).lineHeight
        return multiple * font.size - natural
    }

    /// Renders concatenated text segments (like SwiftUI's Text + Text)
    private func renderConcatenatedText(_ config: SDUIText, segments: [SDUITextSegment]) -> Text {
        // Use the shared font from config as default
        let defaultFont = config.font
        let defaultColor = resolveColor(config.color) ?? Color(UIColor.label)

        var result = TemplateText("", context: context.offerContext).text

        for segment in segments {
            let segmentText = resolveSegmentText(segment)
            let font = segment.font ?? defaultFont
            let color = resolveColor(segment.color) ?? defaultColor

            var piece = TemplateText(segmentText, context: context.offerContext).text
            if let font {
                piece = piece.applySDUIFont(font)
            } else {
                piece = piece.font(.body)
            }
            result = result + piece.foregroundColor(color)
        }

        return result
    }

    /// Resolves text from a segment, checking for bindings and substituting template placeholders
    private func resolveSegmentText(_ segment: SDUITextSegment) -> String {
        if let binding = segment.textBinding {
            return resolveTextBinding(binding)
        }
        // Resolve template placeholders (${variableName}) in the text
        return context.resolveTemplateText(segment.text)
    }

    // MARK: - System Image Renderer

    @ViewBuilder
    private func renderSystemImage(_ config: SDUISystemImage) -> some View {
        let image = Image(systemName: config.systemName)
            .font(config.font?.font)
            .foregroundColor(resolveColor(config.color))
            .modifier(SDUIStyleModifier(style: config.style))

        if config.symbolEffect == "bounce" {
            #if compiler(>=6.0)
                if #available(iOS 18.0, *) {
                    image.symbolEffect(.bounce, options: .nonRepeating)
                } else {
                    image
                }
            #else
                image
            #endif
        } else {
            image
        }
    }

    // MARK: - Async Image Renderer

    private func resolveImageUrl(_ config: SDUIAsyncImage) -> String? {
        if let binding = config.urlBinding {
            return context.resolveCreativeUrl(binding, for: offer)
        }
        // Resolve template variables in static URLs (e.g., "${selectedOfferLogoUrl}")
        if let url = config.url {
            let resolved = context.resolveTemplateText(url)
            return resolved.contains("${") ? nil : resolved // unresolved placeholder → no URL
        }
        return nil
    }

    private func renderAsyncImage(_ config: SDUIAsyncImage) -> some View {
        let url = URL(string: resolveImageUrl(config) ?? "")
        let contentMode = config.contentMode?.contentMode ?? .fit
        let placeholderColor = resolveColor(config.placeholderColor) ?? Color(UIColor.tertiarySystemFill)

        // The primary creative is the offer's *ad image* — when this view
        // enters the screen, the user has been shown the ad.
        // Other bindings (logoImage, static URLs) are decorative chrome and
        // don't represent the ad itself, so they don't fire impressions or
        // carry overlay config.
        let isPrimaryCreative = config.urlBinding == .offerPrimaryCreative

        let overlayConfig: SDUIOverlayConfig? = {
            guard isPrimaryCreative else { return nil }
            let targetOffer = offer ?? context.currentOffer
            return targetOffer?.displayOverlayConfig
        }()

        // Placeholder-only aspect ratio. Priority: creative (authoritative) →
        // variant-level hint (existing DSL contract) → default. Once the image
        // loads, SwiftUI's natural aspect ratio from the bitmap takes over.
        let placeholderAspectRatio: CGFloat? = overlayConfig?.aspectRatio
            ?? config.aspectRatio
            ?? 1412.0 / 596.0

        // Impression source: when the LOADED primary creative is ≥ 50%
        // visible in the active window, fire `onOfferVisible(idx)`. The
        // gate is wired only when this is a primary creative — non-binding
        // (decorative logo strip on the intro screen) and non-creative
        // images stay silent. Failed loads also stay silent because
        // `onLoadedVisible` only fires on the loaded-image branch inside
        // CachedAsyncImage. Once-per-session dedup lives at the viewModel
        // (`impressionIds[campaignId]`), which outlasts any view recycle.
        let onLoadedVisible: (() -> Void)? = isPrimaryCreative ? {
            let resolvedOffer = offer ?? context.currentOffer
            guard let resolvedOffer,
                  let idx = context.offers.firstIndex(where: { $0.id == resolvedOffer.id })
            else { return }
            context.onOfferVisible?(idx)
        } : nil

        return CachedAsyncImage(
            url: url,
            contentMode: contentMode,
            placeholder: { placeholderColor.aspectRatio(placeholderAspectRatio, contentMode: contentMode) },
            onLoadedVisible: onLoadedVisible
        )
        .modifier(SDUIStyleModifier(style: config.style))
        .modifier(CreativeOverlayModifier(config: overlayConfig, context: context))
    }

    // MARK: - Async Video Renderer

    private func resolveVideoUrl(_ config: SDUIAsyncVideo) -> String? {
        if let binding = config.urlBinding {
            return context.resolveCreativeUrl(binding, for: offer)
        }
        return config.url
    }

    private func renderAsyncVideo(_ config: SDUIAsyncVideo) -> some View {
        let urlString = resolveVideoUrl(config)
        let contentMode = config.contentMode ?? .fill

        return SDUIVideoPlayerView(urlString: urlString, contentMode: contentMode)
            .modifier(SDUIStyleModifier(style: config.style))
    }

    // MARK: - App Icon Renderer

    /// Renders the host app's bundle icon, or nothing when the bundle has no
    /// primary icon (e.g. running under a test target without an app
    /// container, or a non-UIKit build slice). Returning an omitted subview
    /// — not a placeholder — lets the parent HStack/VStack reclaim the slot
    /// and its spacing so a missing icon doesn't leave an empty black square
    /// in the layout.
    @ViewBuilder
    private func renderAppIcon(_ config: SDUIAppIcon) -> some View {
        #if canImport(UIKit)
            if let uiImage = Bundle.hostAppIcon {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .modifier(SDUIStyleModifier(style: config.style))
            }
        #endif
    }

    // MARK: - Button Renderer

    private func renderButton(_ config: SDUIButton) -> some View {
        let isClaimDisabled = config.action.type == .claimOffer && !context.isClaimEnabled
        let isDisabled = (config.disabled ?? false) || isClaimDisabled

        // Render as a real `Button` rather than `.onTapGesture`. Inside a
        // horizontal carousel `ScrollView(.scrollClipDisabled(true))`, each
        // full-width `containerRelativeFrame` card's un-clipped frame bleeds
        // across the viewport; an `.onTapGesture` hit region is not bounded to
        // the clipped/on-screen area and does not arbitrate with the scroll
        // gesture, so taps on non-leading cards get swallowed by an off-screen
        // sibling. A `Button` bounds hit-testing to the rendered region and
        // coordinates with the scroll gesture. This also matches `renderToggle`.
        return Button {
            handleAction(config.action)
        } label: {
            SDUIElementRenderer(element: config.content, context: context, offer: offer)
                .modifier(SDUIStyleModifier(style: config.style))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isClaimDisabled ? 0.4 : 1.0)
        // Per-card UI-test hook: every claim button (one per carousel card)
        // carries this id so XCUITest can target a specific card's CTA and
        // assert non-leading cards are tappable (regression guard for #2).
        .accessibilityIdentifier(config.action.type == .claimOffer ? "encore_claim_offer_button" : "")
    }

    /// Handle button actions - state machine actions are handled internally, others are delegated
    private func handleAction(_ action: SDUIAction) {
        // Track button tap analytics
        context.trackButtonTap(actionType: action.type)

        switch action.type {
        case .setState:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let newState = action.setState {
                context.setState(newState)
            }
        case .setValue:
            // Handle setValue action internally (also tracks value set)
            if let key = action.setValueKey, let value = action.setValueValue {
                context.setValue(key: key, value: value)
            }
        case .selectOffer:
            // Row-aware: write the current forEach offer's id into the target key.
            // `offer` is the forEach iteration binding; falls back to
            // context.currentOffer if the action is fired outside a row.
            // Analytics: the tap is captured by `trackButtonTap` above; each
            // field write emits `SDUIValueSetEvent` via `context.selectOffer`.
            if let selected = (offer ?? context.currentOffer) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()

                withAnimation(.easeInOut(duration: 0.25)) {
                    context.selectOffer(selected, primaryKey: action.targetKey ?? "selectedOfferId")
                }
            }
        case .claimOffer:
            // Increment offers claimed counter for analytics
            context.incrementOffersClaimed()
            // Delegate to external handler
            context.onAction(action, offer ?? context.currentOffer)
        case .close, .openUrl, .triggerIAP, .submitLead:
            // Delegate to external handler
            context.onAction(action, offer ?? context.currentOffer)
        }
    }

    // MARK: - Stack Renderers

    @ViewBuilder
    private func renderVStack(_ config: SDUIStack) -> some View {
        let alignment = config.alignment?.horizontalAlignment ?? .center
        let spacing = config.spacing ?? 0
        if config.lazy == true {
            LazyVStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        } else {
            VStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        }
    }

    /// A carousel's offer loop must be the target HStack's direct dynamic
    /// content. Rendering it through a generic `SDUIElementRenderer` wrapper
    /// makes SwiftUI register the whole loop as one target, so view-aligned
    /// scrolling can only snap back to the same row.
    private static func directOfferLoop(in config: SDUIStack) -> SDUIForEach? {
        guard config.style?.scrollTargetLayout == true,
              config.children.count == 1,
              case let .forEach(loop) = config.children[0]
        else { return nil }
        guard case .offers = loop.dataSource else { return nil }
        return loop
    }

    @ViewBuilder
    private func renderHStack(_ config: SDUIStack) -> some View {
        let alignment = config.alignment?.verticalAlignment ?? .center
        let spacing = config.spacing ?? 0
        let hasScrollTargetLayout = config.style?.scrollTargetLayout == true

        if let offerLoop = Self.directOfferLoop(in: config) {
            if config.lazy == true {
                LazyHStack(alignment: alignment, spacing: spacing) {
                    renderOfferItems(offerLoop)
                }
                .scrollTargetLayout()
                .modifier(SDUIStyleModifier(style: config.style))
            } else {
                HStack(alignment: alignment, spacing: spacing) {
                    renderOfferItems(offerLoop)
                }
                .scrollTargetLayout()
                .modifier(SDUIStyleModifier(style: config.style))
            }
        } else if config.lazy == true {
            if hasScrollTargetLayout {
                LazyHStack(alignment: alignment, spacing: spacing) {
                    ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                        SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                    }
                }
                .scrollTargetLayout()
                .modifier(SDUIStyleModifier(style: config.style))
            } else {
                LazyHStack(alignment: alignment, spacing: spacing) {
                    ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                        SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                    }
                }
                .modifier(SDUIStyleModifier(style: config.style))
            }
        } else if hasScrollTargetLayout {
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                }
            }
            .scrollTargetLayout()
            .modifier(SDUIStyleModifier(style: config.style))
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        }
    }

    private func renderZStack(_ config: SDUIStack) -> some View {
        ZStack(alignment: config.alignment?.alignment ?? .center) {
            ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                SDUIElementRenderer(element: child, context: context, offer: offer, isCurrentPage: isCurrentPage)
            }
        }
        .modifier(SDUIStyleModifier(style: config.style))
    }

    // MARK: - Spacer Renderer

    /// A styled spacer is a PROPORTIONAL gap:
    /// `{"spacer": {"style": {"relativeHeight": 0.1}}}` stays 10% of the
    /// container at every screen height, instead of letting a taller device's
    /// extra height pool into one oversized void.
    ///
    /// A STYLELESS spacer must stay a BARE `Spacer()`. A stack special-cases
    /// `Spacer` and sizes it from what its siblings leave; wrapped in `Group` +
    /// modifiers it is just another flexible view, so the stack splits leftover
    /// height evenly between it and the offer carousel's `ScrollView` — and the
    /// creative, the only flexible thing in the card, absorbs the shortfall.
    @ViewBuilder
    private func renderSpacer(_ config: SDUISpacer) -> some View {
        if config.style == nil {
            if let minLength = config.minLength {
                Spacer(minLength: minLength)
            } else {
                Spacer()
            }
        } else {
            Group {
                if let minLength = config.minLength {
                    Spacer(minLength: minLength)
                } else {
                    Spacer()
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        }
    }

    // MARK: - Shape Renderer

    @ViewBuilder
    private func renderShape(_ config: SDUIShape) -> some View {
        let fillColor = resolveColor(config.fillColor) ?? Color.clear

        switch config.type {
        case .rectangle:
            Rectangle().fill(fillColor).modifier(SDUIStyleModifier(style: config.style))
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: config.cornerRadius ?? 0).fill(fillColor).modifier(SDUIStyleModifier(style: config.style))
        case .circle:
            Circle().fill(fillColor).modifier(SDUIStyleModifier(style: config.style))
        case .capsule:
            Capsule().fill(fillColor).modifier(SDUIStyleModifier(style: config.style))
        }
    }

    // MARK: - Gradient Renderer

    private func renderGradient(_ config: SDUIGradient) -> some View {
        let colors = config.colors.map { stop in
            (resolveColor(stop.color) ?? .clear).opacity(stop.opacity ?? 1.0)
        }

        return LinearGradient(
            colors: colors,
            startPoint: config.direction.startPoint,
            endPoint: config.direction.endPoint
        )
        .modifier(SDUIStyleModifier(style: config.style))
        .allowsHitTesting(false)
    }

    // MARK: - ScrollView Renderer

    @ViewBuilder
    private func renderScrollView(_ config: SDUIScrollView) -> some View {
        if #available(iOS 18.0, *) {
            SDUISemanticScrollViewRenderer(
                config: config,
                context: context,
                offer: offer
            )
        } else {
            SDUIScrollViewRenderer(
                config: config,
                context: context,
                offer: offer
            )
        }
    }

    /// Whether this scroll view owns the carousel's `currentIndex`.
    ///
    /// Only a scroll view with a target behavior owns live carousel position.
    /// The actual `.scrollTargetLayout()` belongs on its authored HStack, where
    /// each offer is a direct target; applying it to the scroll content wrapper
    /// collapses the whole carousel into one target.
    static func tracksCarouselPosition(_ config: SDUIScrollView) -> Bool {
        config.scrollTargetBehavior != nil
    }

    // MARK: - ForEach Renderer

    @ViewBuilder
    private func renderForEach(_ config: SDUIForEach) -> some View {
        switch config.dataSource {
        case .offers:
            renderOfferItems(config)
        case .pageIndicators:
            ForEach(0 ..< context.offers.count, id: \.self) { index in
                SDUIElementRenderer(
                    element: config.itemTemplate,
                    context: context,
                    offer: nil,
                    isCurrentPage: context.focusedIndex == index
                )
            }
        }
    }

    private func renderOfferItems(_ config: SDUIForEach) -> some View {
        let limitedOffers = config.limit.map { Array(context.offers.prefix($0)) } ?? context.offers
        let usesCoverflowZIndex = Self.elementHasScrollTransition(config.itemTemplate)
        let centeredIndex = context.focusedIndex ?? 0
        return ForEach(Array(limitedOffers.enumerated()), id: \.element.id) { index, offerItem in
            SDUIElementRenderer(
                element: config.itemTemplate,
                context: context,
                offer: offerItem,
                isCurrentPage: context.focusedIndex == index
            )
            .background {
                GeometryReader { geometryProxy in
                    Color.clear.preference(
                        key: SDUIOfferCenterPreferenceKey.self,
                        value: [index: geometryProxy.frame(in: .global).midX]
                    )
                }
            }
            .id(index)
            .zIndex(usesCoverflowZIndex ? Double(-abs(index - centeredIndex)) : 0)
            .environment(\.sduiScrollFadeDistance, Double(abs(index - centeredIndex)))
        }
    }

    /// Whether the (top-level) style of an item template carries a
    /// `scrollTransition` — the signal that a carousel item wants coverflow
    /// behavior (and thus centeredness-based zIndex). Checks the wrapping
    /// element's own style; the offer card is a `button`, but this also covers
    /// group/stack wrappers that hold the scrollTransition.
    private static func elementHasScrollTransition(_ element: SDUIElement) -> Bool {
        switch element {
        case let .button(c): return c.style?.scrollTransition != nil
        case let .group(c): return c.style?.scrollTransition != nil
        case let .vStack(c), let .hStack(c), let .zStack(c): return c.style?.scrollTransition != nil
        case let .shape(c): return c.style?.scrollTransition != nil
        case let .asyncImage(c): return c.style?.scrollTransition != nil
        default: return false
        }
    }

    // MARK: - Compact Page Indicator Renderer

    private func renderCompactPageIndicator(_ config: SDUICompactPageIndicator) -> some View {
        CompactPageIndicator(
            totalPages: context.offers.count,
            currentPage: context.focusedIndex ?? 0,
            activeColor: resolveColor(config.activeColor) ?? context.appearance.accent,
            inactiveColor: resolveColor(config.inactiveColor) ?? OfferSheetStyles.indicatorGray
        )
    }

    // MARK: - Confetti Renderer

    /// Renders a native one-shot confetti burst. Fills its container by default
    /// (so it can be dropped into a zStack overlay above the claimed screen) and
    /// disables hit testing so it never intercepts taps on the buttons beneath.
    /// Authors can override sizing via `style.frame`.
    @ViewBuilder
    private func renderConfetti(_ config: SDUIConfetti) -> some View {
        let colors: [UIColor] = (config.colors ?? [])
            .filter { !$0.isEmpty }
            .map { UIColor(Color(hex: $0)) }

        ConfettiView(
            colors: colors,
            intensity: config.intensity ?? 20,
            duration: config.duration ?? 2.5,
            originY: config.originY ?? 0,
            originX: config.originX,
            scatter: config.scatter ?? 0,
            scatterHeight: config.scatterHeight ?? 0.45
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .modifier(SDUIStyleModifier(style: config.style))
    }

    // MARK: - Conditional Renderer

    private func evaluateCondition(_ condition: SDUICondition) -> Bool {
        switch condition {
        case .hasMultipleOffers:
            return context.offers.count > 1
        case let .isCurrentPage(index):
            return context.focusedIndex == index
        case .isCurrentPageBinding:
            return isCurrentPage
        // NEW: Generic state machine conditions
        case let .stateEquals(state):
            return context.isState(state)
        case let .valueEquals(key, value):
            return context.valueEquals(key: key, value: value)
        case let .hasValue(key):
            return context.hasValue(key: key)
        case .hasIntroOffer:
            return context.offerContext.iap.hasIntroOffer
        case .hasFreeTrial:
            return context.offerContext.iap.hasFreeTrial
        case let .isSelectedOffer(targetKey):
            // Row-aware: true when the current forEach offer's id matches
            // the stored selection. Used by list-style layouts to render
            // per-card selection state without row-binding literals.
            guard let current = (offer ?? context.currentOffer) else { return false }
            let key = targetKey ?? "selectedOfferId"
            return context.values[key] == current.id
        // Generic boolean combinators
        case let .and(conditions):
            return conditions.allSatisfy { evaluateCondition($0) }
        case let .or(conditions):
            return conditions.contains { evaluateCondition($0) }
        case let .not(condition):
            return !evaluateCondition(condition)
        case let .equals(lhs, rhs):
            return resolveValueRef(lhs) == resolveValueRef(rhs)
        // Offer-position predicates (row-aware)
        case .isFirstOffer:
            return currentOfferIndex == 0
        case .isLastOffer:
            guard let idx = currentOfferIndex else { return false }
            return idx == context.offers.count - 1
        case .isMiddleOffer:
            guard let idx = currentOfferIndex, context.offers.count > 0 else { return false }
            return idx == context.offers.count / 2
        case let .offerIndexEquals(target):
            return currentOfferIndex == target
        }
    }

    /// Index of the current row offer within `context.offers`, or nil when
    /// rendering outside a forEach row (no offer in scope).
    private var currentOfferIndex: Int? {
        guard let current = (offer ?? context.currentOffer) else { return nil }
        return context.offers.firstIndex(where: { $0.id == current.id })
    }

    /// Resolves an `equals` operand to a comparable string.
    private func resolveValueRef(_ ref: SDUIValueRef) -> String? {
        switch ref {
        case let .literal(value):
            return value
        case let .binding(key):
            return context.values[key]
        case .state:
            return context.currentState
        case .offerIndex:
            return currentOfferIndex.map(String.init)
        }
    }

    private func renderConditional(_ config: SDUIConditional) -> some View {
        Group {
            if evaluateCondition(config.condition) {
                SDUIElementRenderer(element: config.ifTrue, context: context, offer: offer, isCurrentPage: isCurrentPage)
            } else if let ifFalse = config.ifFalse {
                SDUIElementRenderer(element: ifFalse, context: context, offer: offer, isCurrentPage: isCurrentPage)
            }
        }
        // Keep state-branch replacement free of an inherited crossfade without
        // clearing animation transactions for interactive descendants such as
        // a carousel's explicit tap-to-scroll animation.
        .transition(.identity)
    }

    // MARK: - Group Renderer

    private func renderGroup(_ config: SDUIGroup) -> some View {
        SDUIElementRenderer(element: config.content, context: context, offer: offer, isCurrentPage: isCurrentPage)
            .modifier(SDUIStyleModifier(style: config.style))
    }

    // MARK: - TextField Renderer

    private func renderTextField(_ config: SDUITextField) -> some View {
        SDUITextFieldView(config: config, context: context)
    }

    // MARK: - Toggle Renderer (Checkbox Style)

    @ViewBuilder
    private func renderToggle(_ config: SDUIToggle) -> some View {
        let isOn = context.values[config.valueKey] == "true"

        Button {
            let newValue = isOn ? "false" : "true"
            context.setValue(key: config.valueKey, value: newValue)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(isOn ? context.appearance.accent : Color(UIColor.tertiaryLabel))
                    .font(.title3)
                SDUIElementRenderer(element: config.label, context: context, offer: offer)
            }
        }
        .buttonStyle(.plain)
        .modifier(SDUIStyleModifier(style: config.style))
    }

    // MARK: - Slide Button Renderer

    private func renderSlideButton(_ config: SDUISlideButton) -> some View {
        SDUISlideButtonView(config: config, onComplete: {
            handleAction(config.action)
        }, context: context)
    }
}

// MARK: - Scroll View Renderer

/// iOS 18+ semantic scroll-position path. Unlike the legacy optional-ID
/// binding, `ScrollPosition.scrollTo(id:)` is a mutating scroll command whose
/// transaction keeps the physical content movement animated.
@available(iOS 18.0, *)
private struct SDUISemanticScrollViewRenderer: View {
    let config: SDUIScrollView
    @ObservedObject var context: SDUIContext
    let offer: Offer?

    @State private var position: ScrollPosition

    private var axis: Axis.Set {
        config.axis?.axis ?? .vertical
    }

    private var scrollAxis: SDUIScrollAxis {
        config.axis ?? .vertical
    }

    private var hasScrollTarget: Bool {
        SDUIElementRenderer.tracksCarouselPosition(config)
    }

    private var resolvedContentMargin: CGFloat? {
        guard let margins = config.contentMargins else { return nil }
        return axis == .horizontal ? margins.edgeInsets.leading : margins.edgeInsets.top
    }

    private var usesCenteredGeometry: Bool {
        axis == .horizontal
            && config.scrollAlignment == .center
            && SDUIScrollLayout.offerItemWidth(for: config) != nil
    }

    init(config: SDUIScrollView, context: SDUIContext, offer: Offer?) {
        self.config = config
        self.context = context
        self.offer = offer
        _position = State(initialValue: ScrollPosition(
            id: context.focusedIndex ?? 0,
            anchor: config.scrollAlignment?.unitPoint
        ))
    }

    var body: some View {
        if usesCenteredGeometry {
            GeometryReader { proxy in
                scrollView(contentMargin: SDUIScrollLayout.centeredContentMargin(
                    for: config,
                    viewportWidth: proxy.size.width
                ))
            }
            .modifier(SDUIStyleModifier(style: config.style))
        } else {
            scrollView(contentMargin: resolvedContentMargin)
                .modifier(SDUIStyleModifier(style: config.style))
        }
    }

    private func scrollView(contentMargin: CGFloat?) -> some View {
        ScrollView(axis, showsIndicators: config.showsIndicators ?? true) {
            SDUIElementRenderer(element: config.content, context: context, offer: offer)
        }
        .applyScrollTargetBehavior(config.scrollTargetBehavior)
        .applyContentMargin(contentMargin, axis: axis)
        .scrollPosition($position, anchor: config.scrollAlignment?.unitPoint)
        .scrollClipDisabled(true)
        .onChange(of: position.viewID(type: Int.self)) { _, newIndex in
            commitScrolledPosition(newIndex)
        }
        .onChange(of: context.focusedIndex) { _, newIndex in
            animateContextSelection(newIndex)
        }
    }

    private func animateContextSelection(_ newIndex: Int?) {
        guard let newIndex, newIndex != position.viewID(type: Int.self) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            position.scrollTo(id: newIndex, anchor: config.scrollAlignment?.unitPoint)
        }
    }

    private func commitScrolledPosition(_ newIndex: Int?) {
        guard let newIndex, newIndex != context.currentIndex else { return }
        let requestedIndex = context.focusedIndex
        context.currentIndex = newIndex
        context.selectCenteredOffer(at: newIndex)
        if newIndex != requestedIndex {
            context.trackScroll(axis: scrollAxis, position: newIndex)
        }
    }
}

private struct SDUIOfferCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

/// Renders an SDUI scroll view while adapting centered carousels to the actual
/// viewport. A centered fixed-width carousel needs enough leading/trailing
/// content margin to place its first and last cards at the viewport center.
@available(iOS 17.0, *)
private struct SDUIScrollViewRenderer: View {
    let config: SDUIScrollView
    @ObservedObject var context: SDUIContext
    let offer: Offer?

    @State private var scrollPosition: Int?
    @State private var programmaticScrollTarget: Int?
    @State private var userDrivenSelection: Int?

    private var axis: Axis.Set {
        config.axis?.axis ?? .vertical
    }

    private var scrollAxis: SDUIScrollAxis {
        config.axis ?? .vertical
    }

    private var hasScrollTarget: Bool {
        SDUIElementRenderer.tracksCarouselPosition(config)
    }

    init(config: SDUIScrollView, context: SDUIContext, offer: Offer?) {
        self.config = config
        self.context = context
        self.offer = offer
        _scrollPosition = State(initialValue: context.focusedIndex)
        _programmaticScrollTarget = State(initialValue: nil)
        _userDrivenSelection = State(initialValue: nil)
    }

    private var resolvedContentMargin: CGFloat? {
        guard let margins = config.contentMargins else { return nil }
        return axis == .horizontal ? margins.edgeInsets.leading : margins.edgeInsets.top
    }

    private var usesCenteredGeometry: Bool {
        axis == .horizontal
            && config.scrollAlignment == .center
            && SDUIScrollLayout.offerItemWidth(for: config) != nil
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            Group {
                if usesCenteredGeometry {
                    GeometryReader { geometryProxy in
                        scrollView(contentMargin: SDUIScrollLayout.centeredContentMargin(
                            for: config,
                            viewportWidth: geometryProxy.size.width
                        ))
                        .onPreferenceChange(SDUIOfferCenterPreferenceKey.self) { offerCenters in
                            updateVisibleOffer(
                                from: offerCenters,
                                viewportCenter: geometryProxy.frame(in: .global).midX
                            )
                        }
                    }
                    .modifier(SDUIStyleModifier(style: config.style))
                } else {
                    scrollView(contentMargin: resolvedContentMargin)
                        .modifier(SDUIStyleModifier(style: config.style))
                }
            }
            .onAppear {
                guard let index = context.focusedIndex else { return }
                scrollProxy.scrollTo(index, anchor: config.scrollAlignment?.unitPoint)
            }
            .onChange(of: context.focusedIndex) { _, newIndex in
                animateContextSelection(newIndex)
            }
        }
    }

    private func scrollView(contentMargin: CGFloat?) -> some View {
        ScrollView(axis, showsIndicators: config.showsIndicators ?? true) {
            SDUIElementRenderer(element: config.content, context: context, offer: offer)
        }
        .applyScrollTargetBehavior(config.scrollTargetBehavior)
        .applyContentMargin(contentMargin, axis: axis)
        .modifier(SDUICarouselPositionModifier(
            position: carouselPosition.animation(.easeInOut(duration: 0.35)),
            alignment: config.scrollAlignment,
            isEnabled: hasScrollTarget
        ))
        .scrollClipDisabled(true)
        .onChange(of: scrollPosition) { _, newIndex in
            commitScrolledPosition(newIndex)
        }
    }

    private var carouselPosition: Binding<Int?> {
        Binding(
            get: { scrollPosition },
            set: { newPosition in
                if let programmaticScrollTarget {
                    guard newPosition == programmaticScrollTarget else { return }
                    self.programmaticScrollTarget = nil
                }
                guard newPosition != scrollPosition else { return }
                scrollPosition = newPosition
            }
        )
    }

    private func animateContextSelection(_ newIndex: Int?) {
        if userDrivenSelection == newIndex {
            return
        }
        guard let newIndex, newIndex != scrollPosition else { return }
        withAnimation(.easeInOut(duration: 0.35), completionCriteria: .logicallyComplete) {
            programmaticScrollTarget = newIndex
            scrollPosition = newIndex
        } completion: {
            guard programmaticScrollTarget == newIndex else { return }
            programmaticScrollTarget = nil
        }
    }

    private func updateVisibleOffer(from offerCenters: [Int: CGFloat], viewportCenter: CGFloat) {
        guard programmaticScrollTarget == nil,
              context.currentIndex == scrollPosition || userDrivenSelection != nil,
              let visibleOffer = offerCenters.min(by: {
                  abs($0.value - viewportCenter) < abs($1.value - viewportCenter)
              }),
              visibleOffer.key != context.currentIndex
        else { return }

        userDrivenSelection = visibleOffer.key
        context.currentIndex = visibleOffer.key
        context.selectCenteredOffer(at: visibleOffer.key)
        context.trackScroll(axis: scrollAxis, position: visibleOffer.key)
    }

    private func commitScrolledPosition(_ newIndex: Int?) {
        if userDrivenSelection == newIndex {
            userDrivenSelection = nil
        }
        guard let newIndex, newIndex != context.currentIndex else { return }
        let requestedIndex = context.focusedIndex
        context.currentIndex = newIndex
        context.selectCenteredOffer(at: newIndex)
        if newIndex != requestedIndex {
            context.trackScroll(axis: scrollAxis, position: newIndex)
        }
    }
}

enum SDUIScrollLayout {
    static func centeredContentMargin(for config: SDUIScrollView, viewportWidth: CGFloat) -> CGFloat? {
        guard let itemWidth = offerItemWidth(for: config) else { return nil }
        let authoredMargin = config.contentMargins?.edgeInsets.leading ?? 0
        return max(authoredMargin, (viewportWidth - itemWidth) / 2)
    }

    static func offerItemWidth(for config: SDUIScrollView) -> CGFloat? {
        guard case let .hStack(stack) = config.content,
              stack.children.count == 1,
              case let .forEach(loop) = stack.children[0],
              case .offers = loop.dataSource,
              let itemWidth = fixedWidth(of: loop.itemTemplate)
        else { return nil }
        return itemWidth
    }

    private static func fixedWidth(of element: SDUIElement) -> CGFloat? {
        switch element {
        case let .button(config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case let .group(config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case let .vStack(config), let .hStack(config), let .zStack(config):
            if let width = config.style?.frame?.width {
                return width
            }
            return config.children.lazy.compactMap(fixedWidth(of:)).first
        default:
            return nil
        }
    }
}

// MARK: - Carousel Scroll Position

/// Binds a carousel to view-local scroll state — and only for the scroll view
/// that actually owns the carousel.
///
/// `SDUIContext.currentIndex` is committed selection state, not a suitable
/// two-way ScrollView binding: publishing that same value back from the binding
/// getter during a drag makes SwiftUI restore the old card before the gesture
/// can settle. The renderer owns the live position instead, then commits it to
/// the context from `onChange` after SwiftUI resolves a new centered target.
///
/// A variant may nest several scroll views around one carousel; only the scroll
/// view with target behavior receives this modifier, so a page scroller cannot
/// clear or overwrite the carousel position.
@available(iOS 17.0, *)
private struct SDUICarouselPositionModifier: ViewModifier {
    @Binding var position: Int?
    let alignment: SDUIScrollAlignment?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.scrollPosition(id: $position, anchor: alignment?.unitPoint)
        } else {
            content
        }
    }
}

// MARK: - Slide Button View

/// Swipe-to-unlock style button with trailing fill, shimmer text, and draggable thumb.
/// Adapts between disabled ("Enter Email") and active ("Slide to Unlock Sponsorship") states.
@available(iOS 17.0, *)
private struct SDUISlideButtonView: View {
    let config: SDUISlideButton
    let onComplete: () -> Void
    @ObservedObject var context: SDUIContext

    @State private var dragOffset: CGFloat = 0
    @State private var isCompleted = false
    @State private var shimmerOffset: CGFloat = -200
    @State private var bounceOffset: CGFloat = 0
    @State private var bounceTimer: Timer?

    private let thumbSize: CGFloat = 48
    private let trackHeight: CGFloat = 56
    private let inset: CGFloat = 4
    private let completionThreshold: CGFloat = 0.85

    private var isDisabled: Bool {
        guard let key = config.requiredValueKey else { return false }
        let value = context.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty
    }

    private var displayText: String {
        let raw = isDisabled ? (config.disabledText ?? config.text) : config.text
        // Resolve ${placeholders} against OfferContext so variant authors can
        // write e.g. "Activate ${appName}" in the button label.
        return context.resolveTemplateText(raw)
    }

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let maxDrag = trackWidth - thumbSize - (inset * 2)
            let thumbColor = config.thumbColor?.color ?? Color(hex: "#6743F5")
            let textColor = config.textColor?.color ?? Color(UIColor.secondaryLabel)

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(context.resolveColor(config.trackColor) ?? Color(UIColor.tertiarySystemFill))
                    .frame(height: trackHeight)

                // Purple fill — trails behind thumb, clipped to track shape independently
                thumbColor
                    .frame(width: inset + thumbSize + dragOffset, height: trackHeight)
                    .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2))
                    .opacity(dragOffset > 0 || isCompleted ? 1 : 0)

                // Text
                if isDisabled {
                    // Static disabled text — no shimmer
                    Text(displayText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                        .frame(maxWidth: .infinity)
                } else if !isCompleted {
                    // Shimmer text — sweeping highlight
                    ZStack {
                        Text(displayText)
                            .foregroundColor(textColor.opacity(0.35))

                        Text(displayText)
                            .foregroundColor(textColor)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .white, location: 0.4),
                                        .init(color: .white, location: 0.6),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 120)
                                .offset(x: shimmerOffset)
                            )
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }

                // Draggable thumb
                Circle()
                    .fill(isDisabled ? Color(UIColor.systemGray4) : thumbColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isDisabled ? Color(UIColor.systemGray2) : .white)
                    )
                    .shadow(color: (isDisabled ? Color.clear : thumbColor).opacity(0.3), radius: 4, y: 2)
                    .offset(x: inset + dragOffset + bounceOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isCompleted, !isDisabled else { return }
                                bounceOffset = 0 // Stop bounce hint on interaction
                                dragOffset = min(max(0, value.translation.width), maxDrag)
                            }
                            .onEnded { _ in
                                guard !isCompleted, !isDisabled else { return }
                                if dragOffset > maxDrag * completionThreshold {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        isCompleted = true
                                        dragOffset = maxDrag
                                    }
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    onComplete()
                                } else {
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: trackHeight)
        .modifier(SDUIStyleModifier(style: config.style))
        .onChange(of: isDisabled) { wasDisabled, nowDisabled in
            if !nowDisabled && wasDisabled {
                startShimmer()
                startBounceHint()
            } else if nowDisabled {
                bounceTimer?.invalidate()
                bounceTimer = nil
            }
        }
        .onAppear {
            if !isDisabled {
                startShimmer()
                startBounceHint()
            }
        }
        .onDisappear {
            bounceTimer?.invalidate()
            bounceTimer = nil
        }
    }

    private func startShimmer() {
        shimmerOffset = -200
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
            shimmerOffset = 200
        }
    }

    private func startBounceHint() {
        // Bounce the thumb right briefly every 3 seconds to hint "drag me".
        // The timer self-terminates when the button is completed or the user
        // starts dragging; `onDisappear` covers the dismiss-while-idle tail
        // so stale closures don't fire into a torn-down view.
        bounceTimer?.invalidate()
        bounceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { timer in
            guard !isCompleted, dragOffset == 0 else {
                timer.invalidate()
                return
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                bounceOffset = 18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    bounceOffset = 0
                }
            }
        }
    }
}

// MARK: - TextField Wrapper View

/// Dedicated view for text field input that uses local @State to avoid
/// re-rendering the entire SDUI tree on every keystroke.
/// Syncs to SDUIContext.values on focus loss / submit.
@available(iOS 17.0, *)
private struct SDUITextFieldView: View {
    let config: SDUITextField
    @ObservedObject var context: SDUIContext
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(config.placeholder ?? "", text: $text)
            .keyboardType(config.keyboardType?.uiKeyboardType ?? .default)
            .textContentType(config.textContentType?.uiTextContentType)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($isFocused)
            .onAppear {
                // Initialize from context (handles prefill)
                text = context.values[config.valueKey] ?? ""
            }
            .onSubmit {
                syncToContext()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    syncToContext()
                }
            }
            .onChange(of: text) { _, newText in
                // Sync to context on every keystroke (enables dependent elements like slideButton)
                context.values[config.valueKey] = newText
                // Clear any associated error when user edits
                let errorKey = "\(config.valueKey)Error"
                if context.values[errorKey] != nil {
                    context.values.removeValue(forKey: errorKey)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
    }

    private func syncToContext() {
        context.values[config.valueKey] = text
    }
}

// MARK: - Video Player View

/// Observable wrapper for AVPlayer with preloading support
@available(iOS 17.0, *)
private class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isReady = false

    private var loopObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var asset: AVAsset?

    func preload(urlString: String?) {
        guard asset == nil else { return }
        guard let urlString = urlString, let url = URL(string: urlString) else { return }

        // Create asset and start preloading playable status
        let videoAsset = AVURLAsset(url: url)
        asset = videoAsset

        // Preload essential properties asynchronously
        Task {
            do {
                // Load playable status to start buffering
                let isPlayable = try await videoAsset.load(.isPlayable)
                guard isPlayable else { return }

                await MainActor.run {
                    setupPlayer(with: videoAsset)
                }
            } catch {
                // Silently fail - video just won't play
            }
        }
    }

    @MainActor
    private func setupPlayer(with asset: AVAsset) {
        guard player == nil else { return }

        let playerItem = AVPlayerItem(asset: asset)
        // Buffer more content for smoother playback
        // 5 is in seconds; this duration provides a small pre-buffer to reduce stalls
        // while avoiding excessive memory/network usage for typical short-form content.
        playerItem.preferredForwardBufferDuration = 5

        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.isMuted = true
        avPlayer.actionAtItemEnd = .none

        // Observe when player is ready to play
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self?.isReady = true
                }
            }
        }

        // Loop the video when it ends
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak avPlayer] _ in
            avPlayer?.seek(to: .zero)
            avPlayer?.play()
        }

        player = avPlayer
        avPlayer.play()
    }

    func cleanup() {
        statusObserver?.invalidate()
        statusObserver = nil

        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
        asset = nil
        isReady = false
    }

    deinit {
        cleanup()
    }
}

/// A looping, muted video player for SDUI with preloading
@available(iOS 17.0, *)
struct SDUIVideoPlayerView: View {
    let urlString: String?
    let contentMode: SDUIContentMode

    @StateObject private var viewModel = VideoPlayerViewModel()

    var body: some View {
        ZStack {
            Color(UIColor.tertiarySystemFill)

            if let player = viewModel.player {
                VideoPlayerLayer(player: player, videoGravity: contentMode == .fill ? .resizeAspectFill : .resizeAspect)
                    .opacity(viewModel.isReady ? 1 : 0)
            }

            // Show loading indicator while buffering
            if !viewModel.isReady {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .onAppear {
            viewModel.preload(urlString: urlString)
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}

/// UIViewRepresentable wrapper for AVPlayerLayer
@available(iOS 17.0, *)
private struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context _: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        view.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context _: Context) {
        uiView.player = player
        uiView.videoGravity = videoGravity
    }
}

/// Custom UIView that hosts an AVPlayerLayer and auto-resizes it
private class PlayerContainerView: UIView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Creative Overlay Modifier

/// Paints `SDUIOverlayConfig` zones on top of a creative image. All spatial
/// values are ratios of the rendered image box so a single config renders
/// correctly on any screen size. No-op when `config == nil` so legacy
/// creatives render unchanged.
@available(iOS 17.0, *)
struct CreativeOverlayModifier: ViewModifier {
    let config: SDUIOverlayConfig?
    let context: SDUIContext

    func body(content: Content) -> some View {
        if let config {
            // Use .overlay so the creative image preserves its natural sizing.
            // Wrapping the image in a GeometryReader + ZStack changes layout
            // participation — the image collapses to minimal height inside
            // parent vStacks. .overlay attaches siblings to the image's
            // already-resolved frame without affecting the outer layout.
            content.overlay(
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(config.overlays.enumerated()), id: \.offset) { _, overlay in
                            overlayView(overlay, in: geo.size)
                        }
                    }
                }
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private func overlayView(_ overlay: SDUIOverlayZone, in size: CGSize) -> some View {
        let resolvedText = context.resolveTemplateText(overlay.template)
        let fontSize = size.width * overlay.typography.fontSizeRatio
        let frameWidth = size.width * overlay.dimensions.width
        let frameHeight = size.height * overlay.dimensions.height
        let xOffset = size.width * overlay.position.x
        let yOffset = size.height * overlay.position.y
        // lineHeight is a multiplier (1.1 = 110%); convert delta to extra
        // points the same way renderText does.
        let extraLineSpacing = max(0, ((overlay.typography.lineHeight ?? 1.0) - 1.0) * fontSize)

        Text(resolvedText)
            .font(.system(size: fontSize, weight: overlay.typography.fontWeight.fontWeight))
            .foregroundColor(context.resolveColor(overlay.typography.color) ?? Color(UIColor.label))
            .tracking(overlay.typography.letterSpacing ?? 0)
            .lineSpacing(extraLineSpacing)
            .multilineTextAlignment(overlay.alignment.textAlignment)
            .minimumScaleFactor(overlay.overflow?.minScaleFactor ?? 1.0)
            .lineLimit(overlay.overflow?.maxLines)
            .truncationMode(overlay.overflow?.truncation?.mode ?? .tail)
            .frame(width: frameWidth, height: frameHeight, alignment: overlay.alignment.frameAlignment)
            .offset(x: xOffset, y: yOffset)
    }
}

// MARK: - TemplateText

/// A SwiftUI Text view that supports template placeholder substitution.
///
/// Use `${variableName}` syntax in text to reference values from `RemoteConfig`.
/// Returns a SwiftUI `Text` view, so all text modifiers work directly.
///
/// ## Available Variables
///
/// All `RemoteConfig` fields are available:
/// - `${titleText}`, `${subtitleText}`, `${offerDescriptionText}`
/// - `${instructionsTitleText}`, `${lastStepHeaderText}`, `${lastStepDescriptionText}`
/// - `${creditClaimedTitleText}`, `${creditClaimedSubtitleText}`, `${applyCreditsButtonText}`
/// - `${accentTitleText}`, `${accentTitleColor}`, `${accentColor}`
/// - `${appearanceMode}`
/// - `${entitlementValue}`, `${entitlementUnit}`, `${appName}`
/// - `${trialValue}`, `${trialUnit}` (convenience aliases - use IAP trial if available, else native entitlement)
///
/// IAP-specific variables (from StoreKit):
/// - `${subscriptionPrice}` - e.g., "$4.99"
/// - `${subscriptionName}` - Product display name
/// - `${subscriptionPeriod}` - e.g., "/month", "/year"
/// - `${trialValue}` - e.g., "7", "1", "3" (from IAP free trial)
/// - `${trialUnit}` - e.g., "days", "month" (from IAP free trial)
/// - `${trialDuration}` - e.g., "7 days", "1 month" (formatted from IAP free trial)
///
/// Note: When IAP has a free trial, `${trialValue}` and `${trialUnit}` will use the trial duration
/// from StoreKit, overriding any native entitlement configuration.
///
/// ## Example
///
/// ```swift
/// TemplateText("Get ${value} ${unit} of ${appName}", context: offerContext)
///     .foregroundColor(.blue)
///     .font(.headline)
/// // With IAP free trial: "Get 7 days of Spotify Premium"
/// // Without IAP: "Get 1 month of Spotify Premium" (from native config)
/// ```
struct TemplateText: View {
    /// The original template string with placeholders
    let template: String

    /// The offer context providing variable values (remote config + IAP data)
    private let context: OfferContext?

    /// Creates a template text with the given template and context.
    ///
    /// - Parameters:
    ///   - template: The template string with `${variableName}` placeholders
    ///   - context: The OfferContext providing all variable values
    init(_ template: String, context: OfferContext?) {
        self.template = template
        self.context = context
    }

    /// The resolved text with all placeholders substituted.
    ///
    /// Uses `OfferContext.allVariables` to get all template variables.
    /// This includes both static values from RemoteConfig (appName, titleText, etc.)
    /// and dynamic values from IAPContext (subscriptionPrice, subscriptionName, etc.).
    ///
    /// If a placeholder references a variable that doesn't exist or is nil,
    /// the placeholder is left unchanged in the output.
    var resolved: String {
        guard let ctx = context else { return template }

        // Get all variables from context (remoteConfig + IAP)
        let variables = ctx.allVariables

        // Substitute placeholders
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    var body: some View {
        Text(resolved)
    }

    /// Returns the resolved text as a SwiftUI Text for concatenation with other Text views.
    /// Use this when you need to combine template text with other text using `+`.
    var text: Text {
        Text(resolved)
    }

    /// Returns the resolved text, or a fallback if the template is empty.
    func resolved(or fallback: String) -> String {
        let result = resolved
        return result.isEmpty ? fallback : result
    }
}

// MARK: - TemplateText Convenience Extensions

extension TemplateText: ExpressibleByStringLiteral {
    /// Creates a template text from a string literal (without context).
    /// Useful for default values that don't need substitution.
    init(stringLiteral value: String) {
        template = value
        context = nil
    }
}

extension TemplateText: CustomStringConvertible {
    var description: String {
        resolved
    }
}

// MARK: - UIValues Extension

extension UIValues {
    /// Creates a TemplateText using this configuration for variable substitution.
    ///
    /// - Parameter template: The template string with `${variableName}` placeholders
    /// - Returns: A TemplateText that will resolve placeholders using this configuration
    func text(_ template: String) -> TemplateText {
        TemplateText(template, context: OfferContext(uiValues: self))
    }

    /// Creates a TemplateText from an optional template string.
    ///
    /// - Parameters:
    ///   - template: The optional template string
    ///   - fallback: The fallback value if template is nil
    /// - Returns: A TemplateText that will resolve placeholders using this configuration
    func text(_ template: String?, or fallback: String) -> TemplateText {
        TemplateText(template ?? fallback, context: OfferContext(uiValues: self))
    }
}

// MARK: - Optional UIValues Extension

extension Optional where Wrapped == UIValues {
    /// Creates a TemplateText using this optional configuration for variable substitution.
    ///
    /// - Parameter template: The template string with `${variableName}` placeholders
    /// - Returns: A TemplateText that will resolve placeholders if configuration exists
    func text(_ template: String) -> TemplateText {
        TemplateText(template, context: OfferContext(uiValues: self))
    }

    /// Creates a TemplateText from an optional template string.
    ///
    /// - Parameters:
    ///   - template: The optional template string
    ///   - fallback: The fallback value if template is nil
    /// - Returns: A TemplateText that will resolve placeholders if configuration exists
    func text(_ template: String?, or fallback: String) -> TemplateText {
        TemplateText(template ?? fallback, context: OfferContext(uiValues: self))
    }
}

// MARK: - Font + Tracking

extension Text {
    /// Applies an `SDUIFont`'s face AND its tracking together.
    ///
    /// They have to be applied as a pair because SwiftUI models them
    /// differently: `weight`/`size` live on the `Font`, but tracking is a `Text`
    /// modifier. Applying `.font()` alone — which every call site used to do —
    /// silently dropped any authored tracking.
    func applySDUIFont(_ font: SDUIFont) -> Text {
        let sized = self.font(font.font)
        guard let tracking = font.tracking else { return sized }
        return sized.tracking(tracking)
    }
}
