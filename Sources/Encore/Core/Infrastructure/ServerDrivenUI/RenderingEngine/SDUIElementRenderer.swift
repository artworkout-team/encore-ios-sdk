//
//  SDUIElementRenderer.swift
//  Encore
//
//  Recursive view renderer for Server-Driven UI elements
//

import SwiftUI
import AVKit

// MARK: - Main Element Renderer

/// One rendered cell of an offer `forEach`.
///
/// `display` is the position in the served list, which is what `focusedIndex`,
/// the coverflow draw order and the scroll-fade distance read. `packed` is the
/// position among the survivors, which is what the grid lays out.
struct SDUIDisplayRow {
    let display: Int
    let packed: Int
    let offer: Offer
}

@available(iOS 17.0, *)
struct SDUIElementRenderer: View {
    let element: SDUIElement
    @ObservedObject var context: SDUIContext
    var offer: Offer? = nil
    /// The `categories` chip this node sits in, nil everywhere else. Threaded
    /// to every child the way `offer` is: a chip is a button wrapping a label,
    /// and the button renders its content through a fresh renderer.
    var category: String? = nil
    /// The `instructions` step this node sits in, nil everywhere else. Threaded
    /// to every child the way `category` is.
    var instructionStep: Instruction? = nil
    var isCurrentPage: Bool = false
    /// The row of a `hostList` loop (trigger mounts); nil everywhere else.
    @Environment(\.sduiHostItem) var hostItem

    /// Observed so the tree re-renders when a logo's dominant color is
    /// extracted asynchronously, letting `{"binding": "offerDominantColor"}`
    /// update from the neutral fallback to the real brand color.
    @ObservedObject private var dominantColors = DominantColorStore.shared

    /// Set by the enclosing `scrollAlignment: center` scroll view; gates the
    /// first offer card's width measurement in `renderForEach`.
    @Environment(\.sduiMeasuresCarouselItemWidth) private var measuresCarouselItemWidth

    /// Set by `renderForEach` on the row itself. A view cannot read an
    /// environment value its own modifier sets, so the row is told directly and
    /// `body` republishes it for everything below.
    var isOfferRow: Bool = false

    /// True when an ANCESTOR is an offer row.
    @Environment(\.sduiInsideOfferRow) private var inheritedInsideOfferRow
    @Environment(\.sduiInsideControl) private var insideControl
    /// The trigger tree's scale groups; nil elsewhere, where `scaleGroup` is ignored.
    @Environment(\.sduiScaleGroups) private var scaleGroups
    @Environment(\.sduiTriggerTree) private var triggerTree
    @Environment(\.sduiFrameCaps) private var frameCaps

    /// True when this node sits inside an offer row, at any depth.
    private var isInsideOfferRow: Bool { isOfferRow || inheritedInsideOfferRow }

    var body: some View {
        renderElement(element)
            .background {
                if let backgroundElement = elementStyle?.backgroundElement {
                    SDUIElementRenderer(element: backgroundElement, context: context, offer: offer, category: category, instructionStep: instructionStep)
                }
            }
            .overlay {
                if let overlayElement = elementStyle?.overlay {
                    SDUIElementRenderer(element: overlayElement, context: context, offer: offer, category: category, instructionStep: instructionStep)
                }
            }
            // Publish the row-scoped color binding values so generic
            // ViewModifiers (border, gradientBorder, background) that have no
            // SDUIContext can still resolve `{"binding": "..."}` colors.
            .environment(\.sduiColorValues, colorValues)
            // Descendants inherit it, so a creative nested any depth inside a
            // row also stands down.
            .environment(\.sduiInsideOfferRow, isInsideOfferRow)
            // A plain VALUE, so SwiftUI tracks it. Reading the state through
            // the context reference is not tracked, and a per-state style kept
            // whatever state it mounted with.
            .environment(\.sduiCurrentState, context.currentState)
    }

    private var elementStyle: SDUIStyle? {
        switch element {
        case .text(let config): config.style
        case .systemImage(let config): config.style
        case .asyncImage(let config): config.style
        case .asyncVideo(let config): config.style
        case .appIcon(let config): config.style
        case .button(let config): config.style
        case .vStack(let config), .hStack(let config), .zStack(let config): config.style
        case .spacer(let config): config.style
        case .shape(let config): config.style
        case .gradient(let config): config.style
        case .scrollView(let config): config.style
        case .forEach(let config): config.style
        case .group(let config): config.style
        case .textField(let config): config.style
        case .toggle(let config): config.style
        case .slideButton(let config): config.style
        case .confetti(let config): config.style
        case .progress(let config): config.style
        case .marquee(let config): config.style
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
    func resolveColor(_ color: SDUIColor?) -> Color? {
        context.resolveColor(color, extraValues: colorValues)
    }
    
    @ViewBuilder
    private func renderElement(_ element: SDUIElement) -> some View {
        switch element {
        case .text(let config):
            if let group = config.scaleGroup, let scaleGroups, config.segments?.isEmpty ?? true {
                let measure = scaleMeasure(config)
                SDUIScaleGroupMember(group: group, measure: measure, alignment: config.multilineAlignment, groups: scaleGroups) { factor in
                    if let countdown = config.countdown {
                        // Its room is its widest text, so the offered width never ticks.
                        renderCountdownText(config, countdown: countdown, scale: factor, sample: factor == nil ? measure.widest : nil)
                    } else {
                        renderSingleText(config, effectiveLineSpacing: calculateLineSpacing(config), scale: factor)
                    }
                }
            } else if let countdown = config.countdown {
                renderCountdownText(config, countdown: countdown)
            } else {
                renderText(config)
            }
        case .systemImage(let config):
            renderSystemImage(config)
        case .asyncImage(let config):
            if let fallback = config.fallback {
                renderAsyncImageWithFallback(config, fallback: fallback)
            } else {
                renderAsyncImage(config)
            }
        case .asyncVideo(let config):
            renderAsyncVideo(config)
        case .appIcon(let config):
            renderAppIcon(config)
        case .button(let config):
            renderButton(config)
        case .vStack(let config):
            renderVStack(config)
        case .hStack(let config):
            renderHStack(config)
        case .zStack(let config):
            renderZStack(config)
        case .spacer(let config):
            renderSpacer(config)
        case .shape(let config):
            renderShape(config)
        case .gradient(let config):
            renderGradient(config)
        case .scrollView(let config):
            renderScrollView(config)
        case .forEach(let config):
            if config.dataSource == .hostList {
                renderHostListForEach(config)
            } else {
                renderForEach(config)
            }
        case .conditional(let config):
            renderConditional(config)
        case .group(let config):
            renderGroup(config)
        case .textField(let config):
            renderTextField(config)
        case .toggle(let config):
            renderToggle(config)
        case .slideButton(let config):
            renderSlideButton(config)
        case .compactPageIndicator(let config):
            renderCompactPageIndicator(config)
        case .confetti(let config):
            renderConfetti(config)
        case .progress(let config):
            renderProgress(config)
        case .marquee(let config):
            renderMarquee(config)
        case .empty:
            EmptyView()
        }
    }
    
    // MARK: - Text Renderer
    
    /// One key out of the row's display-properties bag, or nil when it carries none.
    ///
    /// Row-scoped: inside a `forEach` this reads THAT row. Anywhere else it reads the
    /// offer the context points at, which is the carousel's scroll position.
    func resolveOfferProperty(_ key: String) -> String? {
        (offer ?? context.currentOffer)?.displayProperties[key]
    }

    /// Resolves a text binding using the item-specific offer (for forEach loops) or falls back to context
    ///
    /// Internal, like `evaluateCondition`, so a test can drive the row path
    /// directly: a binding added to the enum and not to this switch reads the
    /// selection on every row, which nothing else observes.
    func resolveTextBinding(_ binding: SDUITextBinding) -> String {
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
                return context.strings.offerCta(itemOffer)
            case .offerQuickInstructions:
                return itemOffer.displayQuickInstructions ?? ""
            case .instructionTitle:
                return instructionStep?.title ?? ""
            case .instructionSubtitle:
                return instructionStep?.subtitle ?? ""
            case .instructionCtaText:
                return instructionStep?.ctaButtonText ?? ""
            case .instructionNumber:
                return instructionStep?.position.map(String.init) ?? ""
            case .offerNewPrice:
                return itemOffer.newPrice ?? ""
            case .offerOldPrice:
                return itemOffer.oldPrice ?? ""
            case .categoryName:
                return category.map(context.strings.giftCategory) ?? ""
            default:
                // For non-offer bindings, fall back to context
                return context.resolveText(binding)
            }
        }
        // The label is translated; conditions and filters keep the English group.
        if binding == .categoryName { return category.map(context.strings.giftCategory) ?? "" }
        // A step loop can run outside a row, where the offer is nil and the
        // switch above never ran. The step is still in scope.
        switch binding {
        case .instructionTitle: return instructionStep?.title ?? ""
        case .instructionSubtitle: return instructionStep?.subtitle ?? ""
        case .instructionCtaText: return instructionStep?.ctaButtonText ?? ""
        case .instructionNumber: return instructionStep?.position.map(String.init) ?? ""
        default: break
        }
        // No item-specific offer, use context (which uses currentOffer)
        return context.resolveText(binding)
    }
    
    /// Internal, like `evaluateCondition` and `resolveTextBinding`, so a test can drive
    /// the row path directly rather than the lookup helper this calls.
    func resolveText(_ config: SDUIText) -> String {
        // Offer property first: it is the most specific source and never a template.
        if let key = config.propertyKey {
            return resolveOfferProperty(key) ?? ""
        }

        // First, check for valueKey (direct read from context.values)
        if let valueKey = config.valueKey, let value = context.textValues(row: offer)[valueKey] {
            return context.resolveTemplateText(value, row: offer)
        }

        // Check for textMapKey (dynamic text from text maps)
        if let mapKey = config.textMapKey {
            let valueKey = config.textMapValueKey ?? mapKey
            if let resolvedText = context.resolveTextMap(mapKey: mapKey, valueKey: valueKey, row: offer) {
                return resolvedText
            }
            // Fall back to static text if map lookup fails
        }
        
        // Check for text binding
        if let binding = config.textBinding {
            return resolveTextBinding(binding)
        }
        
        // Resolve template placeholders (${variableName}) in the text
        return context.resolveTemplateText(substituteHostItem(config.text), row: offer)
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

    /// `scale` is a scale group's factor: the font is drawn at it and never shrinks further.
    private func renderSingleText(_ config: SDUIText, effectiveLineSpacing: CGFloat, scale: CGFloat? = nil) -> some View {
        let resolved = resolveText(config)
        let font = scale.map { (config.font ?? .unstyled).scaled($0) } ?? config.font
        #if DEBUG
        if let font, scale != nil { SDUIScaleGroups.recordDrawn(key: resolved, text: resolved, size: font.size) }
        #endif
        let baseColor = resolveColor(config.color) ?? context.appearance.semanticColor(.label)

        // A `*marked*` run only becomes a separate run when the author asked for
        // a highlight color; otherwise the markers stay literal and this is the
        // same single `Text` it always was.
        var text: Text
        if let highlight = config.highlightColor.flatMap({ resolveColor($0) }) {
            text = Self.highlightedText(
                resolved,
                font: font,
                baseColor: baseColor,
                highlightColor: highlight
            )
        } else {
            text = Text(resolved)
        }

        if let font {
            text = text.applySDUIFont(font)
        }
        if config.strikethrough == true {
            text = text.strikethrough(true, color: baseColor)
        }
        if config.underline == true {
            text = text.underline(true, color: baseColor)
        }

        return text
            .foregroundColor(baseColor)
            .lineSpacing(effectiveLineSpacing)
            .lineLimit(config.lineLimit)
            .multilineTextAlignment(config.multilineAlignment?.textAlignment ?? .leading)
            .modifier(SDUIMinimumScaleFactor(factor: scale == nil ? config.minimumScaleFactor : nil))
            .modifier(SDUIStyleModifier(style: config.style))
    }

    /// What a scale-group member must fit: its text, or a countdown's widest.
    private func scaleMeasure(_ config: SDUIText) -> SDUIScaleMeasure {
        let texts: [String]
        if let countdown = config.countdown {
            let units = (
                hours: context.resolveTemplateText(countdown.units?.hours ?? ""),
                minutes: context.resolveTemplateText(countdown.units?.minutes ?? ""),
                seconds: context.resolveTemplateText(countdown.units?.seconds ?? "")
            )
            texts = SDUIScaleMeasure.widestCountdownTexts(countdown.format, units: units)
        } else {
            let resolved = resolveText(config)
            texts = [config.highlightColor == nil ? resolved : SDUIInlineMarkup.parse(resolved).map(\.text).joined()]
        }
        let lineLimit = config.countdown != nil ? (config.lineLimit ?? 1) : config.lineLimit
        let padding = config.style?.padding?.edgeInsets
        return SDUIScaleMeasure(texts: texts, font: config.font ?? .unstyled, lineLimit: lineLimit, floor: config.minimumScaleFactor,
                                inset: (padding?.leading ?? 0) + (padding?.trailing ?? 0))
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
        SDUIInlineMarkup.parse(resolved).reduce(Text(verbatim: "")) { accumulated, run in
            var piece = Text(run.text)
            if let font { piece = piece.applySDUIFont(font) }
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
        let defaultColor = resolveColor(config.color) ?? context.appearance.semanticColor(.label)

        var result = TemplateText("", context: context.offerContext).text

        for segment in segments {
            let segmentText = resolveSegmentText(segment)
            let font = segment.font ?? defaultFont
            let color = resolveColor(segment.color) ?? defaultColor

            // A property value is never templated, the same rule `resolveText` takes and
            // the same one Android takes. It is admin-authored copy, so a `${...}` in it
            // is a literal the admin typed, not a variable this SDK should resolve, and
            // resolving it here would make the two platforms render the value differently.
            var piece = segment.propertyKey == nil
                ? TemplateText(segmentText, context: context.offerContext).text
                : Text(segmentText)
            if let font { piece = piece.applySDUIFont(font) } else { piece = piece.font(.body) }
            result = result + piece.foregroundColor(color)
        }
        
        return result
    }
    
    /// Resolves text from a segment, checking for bindings and substituting template
    /// placeholders. A `propertyKey` value is returned as-is and is NOT templated by the
    /// caller either. Internal for the same reason as `resolveText`.
    func resolveSegmentText(_ segment: SDUITextSegment) -> String {
        if let key = segment.propertyKey {
            return resolveOfferProperty(key) ?? ""
        }
        if let binding = segment.textBinding {
            return resolveTextBinding(binding)
        }
        // Resolve template placeholders (${variableName}) in the text
        return context.resolveTemplateText(segment.text, row: offer)
    }
    
    // MARK: - System Image Renderer
    
    @ViewBuilder
    private func renderSystemImage(_ config: SDUISystemImage) -> some View {
        let image = Image(systemName: config.systemName)
            .flipsForRightToLeftLayoutDirection(SDUISymbolDirection.mirrorsInRightToLeft(config.systemName))
            .font(config.font?.font)
            .foregroundColor(resolveColor(config.color))
            .modifier(SDUIStyleModifier(style: config.style))
            .accessibilityHidden(Self.systemImageIsDecorative(insideControl: insideControl))

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
    
    /// Internal so a test can drive the step branch directly.
    func resolveImageUrl(_ config: SDUIAsyncImage) -> String? {
        if config.urlBinding == .instructionImage { return instructionStep?.imageUrl }
        if let binding = config.urlBinding {
            return context.resolveCreativeUrl(binding, for: offer)
        }
        // Resolve template variables in static URLs (e.g., "${selectedOfferLogoUrl}")
        if let url = config.url {
            let resolved = context.resolveTemplateText(substituteHostItem(url))
            return resolved.contains("${") ? nil : resolved  // unresolved placeholder → no URL
        }
        return nil
    }
    
    @ViewBuilder
    private func renderAsyncImage(_ config: SDUIAsyncImage) -> some View {
        let targetOffer = offer ?? context.currentOffer
        let plan = SDUIImageSlotPlan(
            binding: config.urlBinding,
            imageUrl: resolveImageUrl(config),
            tileLogoUrl: targetOffer?.tileLogoUrl,
            isInsideOfferRow: isInsideOfferRow)
        let contentMode = config.contentMode?.contentMode ?? .fit
        let placeholderColor = resolveColor(config.placeholderColor) ?? context.appearance.semanticColor(.tertiarySystemFill)

        // The primary creative is the offer's *ad image* — when this view
        // enters the screen, the user has been shown the ad.
        // Other bindings (logoImage, static URLs) are decorative chrome and
        // don't represent the ad itself, so they don't fire impressions or
        // carry overlay config.
        let isPrimaryCreative = config.urlBinding == .offerPrimaryCreative

        let overlayConfig: SDUIOverlayConfig? = isPrimaryCreative ? targetOffer?.displayOverlayConfig : nil

        // Placeholder-only aspect ratio. Priority: creative (authoritative) →
        // variant-level hint (existing DSL contract) → default. Once the image
        // loads, SwiftUI's natural aspect ratio from the bitmap takes over.
        let placeholderAspectRatio: CGFloat? = overlayConfig?.aspectRatio
            ?? config.aspectRatio
            ?? 1412.0/596.0

        // Fallback impression source, only for a featured offer outside a row:
        // the LOADED primary creative, or the logo tile of an offer with no
        // picture, ≥ 50% visible. The viewModel owns the dedup ledger.
        let reportImpression: (() -> Void)? = plan.probe == .none ? nil : {
            let resolvedOffer = offer ?? context.currentOffer
            guard let resolvedOffer,
                  let idx = context.offers.firstIndex(where: { $0.id == resolvedOffer.id })
            else { return }
            context.onOfferVisible?(resolvedOffer, idx, .creative)
        }

        // A creative that fails to load is reported, not swallowed. It used to
        // read as "never shown", which understates the denominator of every
        // rate built on impressions.
        //
        // Deduped and offline-filtered by the reporter, because a row remounts
        // on every scroll recycle and the errors service batches nothing.
        let onLoadFailed: ((SDUIImageLoadFailure) -> Void)? = isPrimaryCreative ? { failure in
            SDUICreativeFailureReporter.report(failure)
        } : nil

        // The logo tile stands in for the picture, so it carries the same name.
        let accessibilityLabel = Self.imageAccessibilityLabel(
            binding: config.urlBinding, offer: targetOffer, strings: context.strings)

        // Identity follows the OFFER as well as the url, matching Android's
        // latch key. With creatives prewarmed the cache hit lands in the same
        // update that cleared the image, so the probed view kept its identity
        // and `onVisible` never re-ran: focus moving to a second featured gift
        // reported nothing at all.
        switch plan.content {
        case .image(let url):
            CachedAsyncImage(
                url: url,
                contentMode: contentMode,
                placeholder: { placeholderColor.aspectRatio(placeholderAspectRatio, contentMode: contentMode) },
                onLoadedVisible: plan.probe == .loadedImage ? reportImpression : nil,
                onLoadFailed: onLoadFailed,
                // Variants also draw the logo through the static `${selectedOfferLogoUrl}` template.
                widthPoints: config.urlBinding == .offerLogoImage || config.url == "${selectedOfferLogoUrl}"
                    ? SDUIImageLoader.logoWidthPoints : nil
            )
            .modifier(SDUIImageAccessibility(label: accessibilityLabel))
            .id(SDUIFeaturedProbeIdentity(offerId: targetOffer?.id, url: url))
            .modifier(SDUIStyleModifier(style: config.style))
            .modifier(CreativeOverlayModifier(config: overlayConfig, context: context))
        case .logoTile(let logoURL):
            SDUILogoTile(
                logoURL: logoURL,
                // The variant's placeholder colour when it sets one, as Android
                // does, else the surface colour web's card uses.
                background: resolveColor(config.placeholderColor)
                    ?? context.appearance.semanticColor(.secondarySystemBackground),
                aspectRatio: placeholderAspectRatio,
                contentMode: contentMode,
                onVisible: plan.probe == .tile ? reportImpression : nil
            )
            .modifier(SDUIImageAccessibility(label: accessibilityLabel))
            .id(SDUIFeaturedProbeIdentity(offerId: targetOffer?.id, url: logoURL))
            .modifier(SDUIStyleModifier(style: config.style))
            .modifier(CreativeOverlayModifier(config: overlayConfig, context: context))
        }
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
                .modifier(SDUIImageAccessibility(label: Self.appIconAccessibilityLabel(context.offerContext.allVariables)))
                .modifier(SDUIStyleModifier(style: config.style))
        }
        #endif
    }

    // MARK: - Button Renderer
    
    @ViewBuilder
    private func renderButton(_ config: SDUIButton) -> some View {
        if let holdDuration = config.resolvedHoldDuration {
            SDUIHoldButton(
                config: config,
                duration: holdDuration,
                context: context,
                label: SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep)
                    .modifier(SDUIStyleModifier(style: config.style))
                    .contentShape(Rectangle())
                    .environment(\.sduiInsideControl, true),
                perform: { handleAction(config.action) }
            )
            .disabled((config.disabled ?? false)
                || (config.action.type == .claimOffer && !context.isClaimEnabled)
                || !context.allowsAction(config.action.type))
            // Same dimming the tap button applies. Without it a blocked claim
            // button looks live and does nothing when held.
            .opacity(Self.claimDisabledOpacity(
                for: config.action.type, isClaimEnabled: context.isClaimEnabled))
            .accessibilityIdentifier(Self.uiTestIdentifier(for: config.action.type))
            .modifier(SDUIAccessibilityLabel(text: Self.iconOnlyAccessibilityLabel(for: config, strings: context.strings)))
        } else {
            renderTapButton(config)
        }
    }

    private func renderTapButton(_ config: SDUIButton) -> some View {
        let isClaimDisabled = config.action.type == .claimOffer && !context.isClaimEnabled
        let isDisabled = (config.disabled ?? false) || isClaimDisabled || !context.allowsAction(config.action.type)

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
            SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep)
                .modifier(SDUIStyleModifier(style: config.style))
                .contentShape(Rectangle())
                .environment(\.sduiInsideControl, true)
        }
        .modifier(SDUIButtonPressModifier(pressed: config.pressedStyle))
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .opacity(Self.claimDisabledOpacity(
            for: config.action.type, isClaimEnabled: context.isClaimEnabled))
        // UI-test hooks: every claim button (one per carousel card) carries a
        // per-card id so XCUITest can target a specific card's CTA and assert
        // non-leading cards are tappable (regression guard for #2); the sheet's
        // close button carries the documented id the demo UI suite asserts.
        .accessibilityIdentifier(Self.uiTestIdentifier(for: config.action.type))
        .modifier(SDUIAccessibilityLabel(text: authoredAccessibilityText(config.accessibilityLabel)
            ?? Self.iconOnlyAccessibilityLabel(for: config, strings: context.strings)))
        .modifier(SDUIAccessibilityHint(text: authoredAccessibilityText(config.accessibilityHint)))
        .modifier(SDUINestedAccessibilityActions(actions: nestedAccessibilityActions(config), perform: handleAction))
    }

    /// The buttons a tap could fire inside `element` (a card's arrow and x), depth first: only a
    /// conditional's branch on show, never a forEach row's (each row is its own element), and never
    /// a disabled, hold or (claims off) claim button, which a tap would not fire either.
    func nestedButtons(in element: SDUIElement) -> [SDUIButton] {
        switch element {
        case .conditional(let conditional):
            let shown = evaluateCondition(conditional.condition) ? conditional.ifTrue : conditional.ifFalse
            return shown.map { nestedButtons(inChild: $0) } ?? []
        case .forEach:
            return []
        default:
            return element.children.flatMap { nestedButtons(inChild: $0) }
        }
    }

    private func nestedButtons(inChild child: SDUIElement) -> [SDUIButton] {
        guard case .button(let button) = child else { return nestedButtons(in: child) }
        let live = !(button.disabled ?? false) && !button.isHoldButton
            && !(button.action.type == .claimOffer && !context.isClaimEnabled)
            && context.allowsAction(button.action.type)
        return (live ? [button] : []) + nestedButtons(in: button.content)
    }

    /// A button's content reads to VoiceOver as one element, so the buttons inside it are its custom
    /// actions, each named as the look names it (its spoken label, else an icon's built-in name).
    func nestedAccessibilityActions(_ config: SDUIButton) -> [(label: String, action: SDUIAction)] {
        nestedButtons(in: config.content).compactMap { button in
            let label = authoredAccessibilityText(button.accessibilityLabel) ?? Self.iconOnlyAccessibilityLabel(for: button, strings: context.strings)
            guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (label, button.action)
        }
    }

    /// An authored a11y label or hint with `${...}` resolved, against this button's own offer row
    /// as its drawn text is; nil when not authored.
    func authoredAccessibilityText(_ text: String?) -> String? {
        guard let text else { return nil }
        return context.resolveTemplateText(substituteHostItem(text), row: offer)
    }

    /// The spoken name of an icon-only close, share, back or panel-close button;
    /// nil for a button that shows text, which names itself. A state change is
    /// named by its first glyph only, as on Android: any other glyph is left alone.
    static func iconOnlyAccessibilityLabel(for config: SDUIButton, strings: SDKStrings) -> String? {
        guard !containsText(config.content) else { return nil }
        switch config.action.type {
        case .close: return strings[.modalClose]
        case .share: return strings[.shareButton]
        case .setState:
            switch systemImageNames(config.content).first.flatMap(stateGlyph) {
            case "xmark": return strings[.panelClose]
            case .some: return strings[.navBack]
            case nil: return nil
            }
        default: return nil
        }
    }

    /// An offer-bound image's spoken name (`card.image` with the advertiser's name);
    /// nil for static artwork and a step's image, which are decorative. Same rule as Android.
    static func imageAccessibilityLabel(binding: SDUICreativeBinding?, offer: Offer?, strings: SDKStrings) -> String? {
        guard let binding, binding != .instructionImage,
              let name = offer?.advertiserName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return strings.format(.cardImage, ["offerName": name])
    }

    /// A glyph outside a button is decorative, as on Android: VoiceOver would
    /// otherwise read its English symbol name beside served copy. Inside a
    /// button it stays, since it may be an unnamed icon-only button's name.
    static func systemImageIsDecorative(insideControl: Bool) -> Bool {
        !insideControl
    }

    /// The host app icon's spoken name: the dashboard `appName`.
    static func appIconAccessibilityLabel(_ variables: [String: String]) -> String? {
        variables["appName"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static let stateGlyphs: Set<String> = ["chevron.left", "chevron.backward", "xmark"]

    /// `name` or its nearest parent in `stateGlyphs`, trimming one SF Symbol modifier at a time.
    private static func stateGlyph(_ name: String) -> String? {
        var candidate = Substring(name)
        while !stateGlyphs.contains(String(candidate)) {
            guard let cut = candidate.lastIndex(of: "."), cut > candidate.startIndex else { return nil }
            candidate = candidate[..<cut]
        }
        return String(candidate)
    }

    private static func systemImageNames(_ element: SDUIElement) -> [String] {
        let own: [String] = if case .systemImage(let image) = element { [image.systemName] } else { [] }
        return own + element.children.flatMap(systemImageNames)
    }

    private static func containsText(_ element: SDUIElement) -> Bool {
        if case .text = element { return true }
        return element.children.contains(where: containsText)
    }
    
    /// Selects `selected` for a `selectOffer` action. Shared by the generic
    /// action dispatch and the direct carousel card button, so both paths
    /// promote, animate and write the selection identically.
    private func selectOffer(_ selected: Offer, action: SDUIAction) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Promote BEFORE selecting, so `selectOffer` resolves `currentIndex`
        // against the list the user will see rather than the one it is
        // replacing. The reorder itself is not animated: SwiftUI's default
        // cross-fade on selection-dependent conditional views reads as flicker.
        if let promoteToIndex = action.promoteToIndex {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                context.promoteOffer(selected, to: promoteToIndex)
            }
        }
        // Animated so the carousel scrolls to a tapped card instead of jumping.
        withAnimation(.easeInOut(duration: 0.25)) {
            context.selectOffer(selected, primaryKey: action.targetKey ?? "selectedOfferId")
        }
    }

    /// How far a button is dimmed when the host has blocked claiming.
    ///
    /// Shared by the tap and hold paths. It was duplicated, and the hold path
    /// simply omitted it, so a blocked claim button looked live while doing
    /// nothing.
    static func claimDisabledOpacity(for action: SDUIActionType, isClaimEnabled: Bool) -> Double {
        action == .claimOffer && !isClaimEnabled ? 0.4 : 1.0
    }

    /// Accessibility identifier for a button by its action, the stable
    /// contract the demo UI test suite drives the sheet through.
    static func uiTestIdentifier(for action: SDUIActionType) -> String {
        switch action {
        case .claimOffer: "encore_claim_offer_button"
        case .close: "encore_offer_close_button"
        default: ""
        }
    }

    /// Handle button actions - state machine actions are handled internally, others are delegated
    ///
    /// `internal` so a test can drive the real dispatch directly. Hosting a
    /// button per case and tapping it is what made the SDUI suite flaky:
    /// window churn, not the code under test. Same reason `evaluateCondition`
    /// and `resolveValueRef` are internal.
    func handleAction(_ action: SDUIAction) {
        guard context.allowsAction(action.type) else {
            Logger.debug("[SDUI] \(action.type) ignored: a Yes is waiting for the server")
            return
        }
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
            // A ref wins over the literal, so a chip writes the category it is
            // iterating. Nothing is written when the ref resolves to nothing.
            if let key = action.setValueKey,
               let value = action.setValueRef.map({ resolveValueRef($0) }) ?? action.setValueValue {
                context.setValue(key: key, value: value)
            }
        case .selectOffer:
            // Row-aware: write the current forEach offer's id into the target key.
            // `offer` is the forEach iteration binding; falls back to
            // context.currentOffer if the action is fired outside a row.
            // Analytics: the tap is captured by `trackButtonTap` above; each
            // field write emits `SDUIValueSetEvent` via `context.selectOffer`.
            if let selected = (offer ?? context.currentOffer) {
                selectOffer(selected, action: action)
            }
        case .setOfferIndex:
            // Moves what the sheet is focused on. Resolved against the DISPLAY
            // list, so it agrees with `offerDisplayOrder`, the row probe and
            // `offerIndexEquals`, all of which are display-ordered too.
            let count = context.offers.count
            if let target = action.resolvedOfferIndex(focused: context.focusedIndex, count: count) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                context.setOfferIndex(target, primaryKey: action.targetKey ?? "selectedOfferId")
            }
        case .claimOffer:
            // Increment offers claimed counter for analytics
            context.incrementOffersClaimed()
            // Delegate to external handler
            context.onAction(action, offer ?? context.currentOffer)
        case .close, .openUrl, .triggerIAP, .submitLead, .share, .reportCompletion:
            // Delegate to external handler
            context.onAction(action, offer ?? context.currentOffer)
        case .trigger, .dismissTrigger:
            // The trigger host acts on these; a sheet's handler treats them as a no-op.
            context.onAction(action, nil)
        case .unknown:
            Logger.warn("[SDUI] Unknown action type on a button; ignoring the tap")
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
                    SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        } else {
            VStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
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
              case .forEach(let loop) = config.children[0]
        else { return nil }
        guard case .offers = loop.dataSource,
              loop.resolvedColumns == nil
        else { return nil }
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
                        SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                    }
                }
                .scrollTargetLayout()
                .modifier(SDUIStyleModifier(style: config.style))
            } else {
                LazyHStack(alignment: alignment, spacing: spacing) {
                    ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                        SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                    }
                }
                .modifier(SDUIStyleModifier(style: config.style))
            }
        } else if hasScrollTargetLayout {
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                }
            }
            .scrollTargetLayout()
            .modifier(SDUIStyleModifier(style: config.style))
        } else if triggerTree {
            // Sized before its spacers, as Android's inline stack: a shrinkable title keeps its room.
            SDUITriggerHStackLayout(spacing: spacing, alignment: alignment) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                        .layoutValue(key: SDUIStackRole.self, value: SDUIStackRole.role(child))
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
                    SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
                }
            }
            .modifier(SDUIStyleModifier(style: config.style))
        }
    }
    
    @ViewBuilder
    private func renderZStack(_ config: SDUIStack) -> some View {
        let alignment = config.alignment?.alignment ?? .center
        let children = ForEach(Array(config.children.enumerated()), id: \.offset) { _, child in
            SDUIElementRenderer(element: child, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
        }
        // A trigger zStack under a capped frame hugs its content; its own frame, if any, sets the
        // caps for its children, so the stack reads the ones around it.
        if triggerTree, frameCaps.horizontal || frameCaps.vertical {
            SDUITriggerZStackLayout(alignment: alignment, fills: config.children.map(SDUITriggerZStackLayout.fills), caps: frameCaps) { children }
                .modifier(SDUIStyleModifier(style: config.style))
        } else {
            ZStack(alignment: alignment) { children }
                .modifier(SDUIStyleModifier(style: config.style))
        }
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
            Rectangle().fill(fillColor)
                .modifier(SDUIStrokeModifier(shape: Rectangle(), color: resolveColor(config.strokeColor), width: config.strokeWidth))
                .modifier(SDUIStyleModifier(style: config.style))
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: config.cornerRadius ?? 0).fill(fillColor)
                .modifier(SDUIStrokeModifier(shape: RoundedRectangle(cornerRadius: config.cornerRadius ?? 0), color: resolveColor(config.strokeColor), width: config.strokeWidth))
                .modifier(SDUIStyleModifier(style: config.style))
        case .circle:
            Circle().fill(fillColor)
                .modifier(SDUIStrokeModifier(shape: Circle(), color: resolveColor(config.strokeColor), width: config.strokeWidth))
                .modifier(SDUIStyleModifier(style: config.style))
        case .capsule:
            Capsule().fill(fillColor)
                .modifier(SDUIStrokeModifier(shape: Capsule(), color: resolveColor(config.strokeColor), width: config.strokeWidth))
                .modifier(SDUIStyleModifier(style: config.style))
        case .ellipse:
            Ellipse().fill(fillColor).modifier(SDUIStrokeModifier(shape: Ellipse(), color: resolveColor(config.strokeColor), width: config.strokeWidth))
                .modifier(SDUIStyleModifier(style: config.style))
        }
    }
    
    // MARK: - Gradient Renderer
    
    @ViewBuilder
    private func renderGradient(_ config: SDUIGradient) -> some View {
        let colors = config.colors.map { stop in
            (resolveColor(stop.color) ?? .clear).opacity(stop.opacity ?? 1.0)
        }
        
        if config.type == .radial {
            RadialGradient(colors: colors, center: .center, startRadius: config.startRadius ?? 0, endRadius: config.endRadius ?? 0)
                .modifier(SDUIStyleModifier(style: config.style))
                .allowsHitTesting(false)
        } else {
            LinearGradient(
                colors: colors,
                startPoint: config.direction.startPoint,
                endPoint: config.direction.endPoint
            )
            .modifier(SDUIStyleModifier(style: config.style))
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - ScrollView Renderer
    
    @ViewBuilder
    private func renderScrollView(_ config: SDUIScrollView) -> some View {
        if #available(iOS 18.0, *) {
            SDUISemanticScrollViewRenderer(
                config: config,
                context: context,
                offer: offer,
                category: category,
                instructionStep: instructionStep
            )
        } else {
            SDUIScrollViewRenderer(
                config: config,
                context: context,
                offer: offer,
                category: category,
                instructionStep: instructionStep
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

    /// Whether this scroll view centers each snapped card in its viewport
    /// (`scrollAlignment: center`). Horizontal + snapping only: a vertical
    /// scroller or a free-scrolling strip has no "snapped card" to center, so
    /// the key is ignored there.
    static func centersSnappedItems(_ config: SDUIScrollView) -> Bool {
        config.scrollAlignment == .center
            && (config.axis ?? .vertical) == .horizontal
            && tracksCarouselPosition(config)
    }

    // MARK: - ForEach Renderer
    
    @ViewBuilder
    private func renderForEach(_ config: SDUIForEach) -> some View {
        switch config.dataSource {
        case .offers:
            // `offset` then `limit`, then the filter. The window is a slice of
            // the served list; the filter narrows what that slice shows. It runs
            // BEFORE the grid packs, or a rejected offer keeps its cell and the
            // survivors scatter across holes instead of filling left to right.
            let rows = displayRows(config)

            // When the card carries a `scrollTransition` (coverflow), drive each
            // card's zIndex by its distance from the centered index so the
            // focused card draws ON TOP of both neighbors. `.scrollTransition`'s
            // closure can't set zIndex (it returns a VisualEffect, not a View),
            // and with negative HStack spacing the later sibling (right
            // neighbor) would otherwise overlap the focused card. Applying
            // `.zIndex` on the ForEach's direct child reorders the stack's draw
            // order. `currentIndex` tracks the centered card via viewAligned
            // snapping. No-op for non-coverflow lists (zIndex stays 0).
            let usesCoverflowZIndex = Self.elementHasScrollTransition(config.itemTemplate)
            let centeredIndex = context.focusedIndex ?? 0
            // The row is the probe. It is the only node guaranteed to exist for
            // every offer a variant renders, so instrumenting the creative
            // instead zeroes the metric the moment a row stops showing one.
            //
            // A grid is the SAME cells in a different arrangement, so both
            // branches build them through one function. The probe wiring is the
            // part that must not drift between the two.
            if let columns = config.resolvedColumns {
                let spacing = config.gridSpacing ?? 0
                let rowStarts = Array(stride(from: 0, to: rows.count, by: columns))
                VStack(spacing: spacing) {
                    ForEach(rowStarts, id: \.self) { rowStart in
                        let rowEnd = min(rowStart + columns, rows.count)
                        HStack(spacing: spacing) {
                            // Keyed by OFFER, like the flat run. Keyed by
                            // position, the cell in a slot kept its identity and
                            // its frame across a reorder, so `onVisible` never
                            // re-ran and a promoted offer reported nothing.
                            ForEach(rows[rowStart..<rowEnd], id: \.offer.id) { row in
                                offerCell(config, row: row, isFirstCell: row.packed == 0,
                                          usesCoverflowZIndex: usesCoverflowZIndex,
                                          centeredIndex: centeredIndex)
                                    .frame(maxWidth: .infinity)
                            }
                            // Pad the final row, so three cards in two columns
                            // leave an empty cell instead of stretching the odd
                            // one across the full width.
                            ForEach(Array(rowEnd..<(rowStart + columns)), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                // The loop's style belongs to the CELLS, applied in
                // `offerCell`, so a grid and a flat run style identically.
            } else {
                ForEach(rows, id: \.offer.id) { row in
                    offerCell(config, row: row, isFirstCell: row.packed == 0,
                              usesCoverflowZIndex: usesCoverflowZIndex,
                              centeredIndex: centeredIndex)
                }
            }
        case .categories:
            // The same window as the rows, so a strip authored beside an
            // `offset: 3` sheet names only the categories that sheet shows.
            ForEach(Self.distinctCategories(config.window(context.offers)), id: \.self) { name in
                SDUIElementRenderer(
                    element: config.itemTemplate,
                    context: context,
                    offer: nil,
                    category: name,
                    isCurrentPage: false,
                    isOfferRow: Self.claimsImpression(config)
                )
                .modifier(SDUIStyleModifier(style: config.style))
            }
        case .instructions:
            // The steps of the offer in scope, in authored order. Nothing when
            // the creative carries none, which is the right answer: there is no
            // step to draw.
            let steps = (offer ?? context.currentOffer)?.displayInstructions ?? []
            ForEach(Array(config.window(steps).enumerated()), id: \.offset) { _, step in
                SDUIElementRenderer(
                    element: config.itemTemplate,
                    context: context,
                    offer: offer,
                    category: category,
                    instructionStep: step,
                    isCurrentPage: false,
                    isOfferRow: Self.claimsImpression(config)
                )
                .modifier(SDUIStyleModifier(style: config.style))
            }
        case .pageIndicators:
            ForEach(0..<context.offers.count, id: \.self) { index in
                SDUIElementRenderer(
                    element: config.itemTemplate,
                    context: context,
                    offer: nil,
                    category: category, instructionStep: instructionStep,
                    isCurrentPage: context.focusedIndex == index,
                    isOfferRow: Self.claimsImpression(config)
                )
                // Each item, for the same reason a row gets it.
                .modifier(SDUIStyleModifier(style: config.style))
            }
        case .hostList:
            // Reached only through `renderHostListForEach`; kept for exhaustiveness.
            renderHostListForEach(config)
        }
    }

    /// A flat offer loop's cells as the direct dynamic content of a carousel
    /// `HStack`, so each card is its own scroll target.
    private func renderOfferItems(_ config: SDUIForEach) -> some View {
        let rows = displayRows(config)
        let usesCoverflowZIndex = Self.elementHasScrollTransition(config.itemTemplate)
        let centeredIndex = context.focusedIndex ?? 0
        return ForEach(rows, id: \.offer.id) { row in
            offerCell(config, row: row, isFirstCell: row.packed == 0,
                      usesCoverflowZIndex: usesCoverflowZIndex,
                      centeredIndex: centeredIndex)
        }
    }

    /// One offer card. A plain `selectOffer` card renders as a direct `Button`
    /// so it is the carousel's scroll target and its tap animates the scroll
    /// (iOS 17 and 18 drop taps on the nested generic button inside a
    /// `scrollClipDisabled` carousel). Everything else uses the generic
    /// renderer.
    @ViewBuilder
    private func renderOfferItem(_ config: SDUIForEach, offer: Offer, index: Int) -> some View {
        let template = config.itemTemplate
        let isOfferRow = Self.claimsImpression(config)
        if case .button(let buttonConfig) = template,
           buttonConfig.action.type == .selectOffer,
           buttonConfig.resolvedHoldDuration == nil {
            Button {
                context.trackButtonTap(actionType: buttonConfig.action.type)
                selectOffer(offer, action: buttonConfig.action)
            } label: {
                SDUIElementRenderer(
                    element: buttonConfig.content,
                    context: context,
                    offer: offer,
                    category: category, instructionStep: instructionStep,
                    isCurrentPage: context.focusedIndex == index,
                    isOfferRow: isOfferRow
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(buttonConfig.disabled ?? false)
            .modifier(SDUIStyleModifier(style: buttonConfig.style))
            .contentShape(Rectangle())
        } else {
            SDUIElementRenderer(
                element: template,
                context: context,
                offer: offer,
                // A loop nested inside a chip is still inside that chip.
                category: category, instructionStep: instructionStep,
                isCurrentPage: context.focusedIndex == index,
                isOfferRow: isOfferRow
            )
        }
    }

    /// The offers a `forEach`'s filter accepts, each evaluated with itself in
    /// scope. No filter means every offer, which is what every shipped variant
    /// and every older SDK does.
    /// Internal alias for tests, for the same reason `evaluateCondition` is
    /// internal: the filter decides what renders, and hosting a grid to observe
    /// it is the churn this suite avoids.
    func filteredForTest(_ offers: [Offer], by config: SDUIForEach) -> [Offer] {
        filtered(offers, by: config)
    }

    /// The rows a loop renders, as the cells it packs. Internal for the same
    /// reason as `filteredForTest`.
    func displayRowsForTest(_ config: SDUIForEach) -> [SDUIDisplayRow] {
        displayRows(config)
    }

    /// The window's rows, each carrying the display index it held BEFORE the
    /// filter and the position it packs at AFTER it.
    ///
    /// The two differ the moment a filter rejects an offer, and both are needed.
    /// `focusedIndex`, the coverflow draw order and the scroll-fade distance
    /// read display space over the unfiltered list, so compacting that index
    /// would point the selection at a hidden offer. Packing must compact, or the
    /// survivors scatter across the holes the rejected cells left.
    private func displayRows(_ config: SDUIForEach) -> [SDUIDisplayRow] {
        var packed = 0
        return config.window(context.offers).enumerated().compactMap { windowIndex, offer in
            guard accepts(offer, by: config) else { return nil }
            defer { packed += 1 }
            return SDUIDisplayRow(
                display: config.displayIndex(ofRowAt: windowIndex),
                packed: packed,
                offer: offer
            )
        }
    }

    private func filtered(_ offers: [Offer], by config: SDUIForEach) -> [Offer] {
        offers.filter { accepts($0, by: config) }
    }

    private func accepts(_ offer: Offer, by config: SDUIForEach) -> Bool {
        guard let condition = config.filter else { return true }
        // `isCurrentPage` is passed in where `currentOfferIndex` is derived from
        // the offer, so it does not follow on its own. Left at its default a
        // filter using `isCurrentPageBinding` read false for every candidate.
        let index = context.offers.firstIndex(where: { $0.id == offer.id })
        return SDUIElementRenderer(
            element: .empty, context: context, offer: offer, category: category, instructionStep: instructionStep,
            isCurrentPage: index != nil && context.focusedIndex == index
        ).evaluateCondition(condition)
    }

    /// The categories present, in first-appearance order, without duplicates.
    /// An offer carrying none contributes nothing, so no chip is unlabelled.
    ///
    /// Empty below two categories holding two offers each: a chip over one gift
    /// reads as a filter that does nothing. web-sdk's `sheetCategories` rule,
    /// over the same population, the offers this loop actually lists.
    static func distinctCategories(_ offers: [Offer]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for offer in offers {
            guard let name = offer.category, !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        guard counts.values.filter({ $0 >= minOffersPerChip }).count >= minChippedCategories else {
            return []
        }
        return order
    }

    /// web-sdk's `MIN_OFFERS_PER_TAB` and `MIN_TABBED_GROUPS`, by their own names.
    private static let minOffersPerChip = 2
    private static let minChippedCategories = 2

    /// Whether a `forEach` item claims the offer impression, so a creative
    /// inside it stands down. A row and a category CHIP always claim it: a chip
    /// is never an offer, so a creative inside one must never report whichever
    /// offer happens to be selected. A page indicator claims it only when
    /// `impressionProbe: "none"` silenced the loop, because `none` covers
    /// creatives too. A STEP does not claim it: the steps belong to the offer on
    /// screen, so a creative inside one is that offer's.
    static func claimsImpression(_ config: SDUIForEach) -> Bool {
        config.dataSource == .offers || config.dataSource == .categories || config.impressionProbe == .off
    }

    /// One offer cell, identical in a flat run and in a grid.
    ///
    /// Shared deliberately: the impression probe lives here, and a grid that
    /// built its own cells would be one refactor away from silently not
    /// reporting.
    @ViewBuilder
    private func offerCell(
        _ config: SDUIForEach,
        row: SDUIDisplayRow,
        isFirstCell: Bool,
        usesCoverflowZIndex: Bool,
        centeredIndex: Int
    ) -> some View {
        let offerItem = row.offer
        // Display-space, not window-space. See `displayIndex(ofRowAt:)`.
        let index = row.display
        renderOfferItem(config, offer: offerItem, index: index)
        // Reports the card's on-screen center so the iOS 17 carousel renderer
        // can follow the centered card without a scroll-position binding.
        .background {
            GeometryReader { geometryProxy in
                Color.clear.preference(
                    key: SDUIOfferCenterPreferenceKey.self,
                    value: [index: geometryProxy.frame(in: .global).midX]
                )
            }
            .allowsHitTesting(false)
        }
        .id(index)
        // The position is resolved when the probe FIRES, not when the row is
        // built. `offerDisplayOrder` is applied by `initializeFromConfig` in
        // the root's `.onAppear`, and `promoteOffer` reorders at runtime, so a
        // captured index is stale twice over. The OFFER's id is what stays
        // stable across both, not this view's `.id(index)`, so the lookup is by
        // campaign. Same resolution the creative probe does.
        .modifier(OptionallyOnVisible(
            action: config.impressionProbe == .off
                ? nil
                : {
                    guard let displayIndex = context.offers
                        .firstIndex(where: { $0.id == offerItem.id })
                    else { return }
                    context.onOfferVisible?(context.offers[displayIndex], displayIndex, .row)
                }
        ))
        // The first card reports its laid-out width so a
        // `scrollAlignment: center` scroll view can derive the margin that
        // centers it. The PACKED position, not `index`: this asks which card
        // renders first, which is a layout fact about this loop, not a position.
        .background(
            isFirstCell && measuresCarouselItemWidth
                ? GeometryReader { proxy in
                    Color.clear.preference(key: SDUICarouselItemWidthKey.self, value: proxy.size.width)
                }
                : nil
        )
        .zIndex(usesCoverflowZIndex ? Double(-abs(index - centeredIndex)) : 0)
        // Publish this card's distance from the centered card so descendant
        // `scrollFade` layers fade reliably by selection state.
        .environment(\.sduiScrollFadeDistance, Double(abs(index - centeredIndex)))
        // A `forEach` is a FRAGMENT, so its own style applies to each item it
        // produces. Android has applied it that way since its SDUI port; iOS
        // decoded the field and applied it nowhere.
        .modifier(SDUIStyleModifier(style: config.style))
    }

    /// Whether the (top-level) style of an item template carries a
    /// `scrollTransition` — the signal that a carousel item wants coverflow
    /// behavior (and thus centeredness-based zIndex). Checks the wrapping
    /// element's own style; the offer card is a `button`, but this also covers
    /// group/stack wrappers that hold the scrollTransition.
    private static func elementHasScrollTransition(_ element: SDUIElement) -> Bool {
        switch element {
        case .button(let c): return c.style?.scrollTransition != nil
        case .group(let c): return c.style?.scrollTransition != nil
        case .vStack(let c), .hStack(let c), .zStack(let c): return c.style?.scrollTransition != nil
        case .shape(let c): return c.style?.scrollTransition != nil
        case .asyncImage(let c): return c.style?.scrollTransition != nil
        default: return false
        }
    }

    // MARK: - Compact Page Indicator Renderer

    @ViewBuilder
    private func renderCompactPageIndicator(_ config: SDUICompactPageIndicator) -> some View {
        CompactPageIndicator(
            totalPages: context.offers.count,
            currentPage: context.focusedIndex ?? 0,
            activeColor: resolveColor(config.activeColor) ?? context.appearance.accent,
            inactiveColor: resolveColor(config.inactiveColor) ?? context.appearance.semanticColor(.tertiaryLabel)
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

    /// Internal rather than private so tests can drive the REAL evaluator.
    ///
    /// The alternative was hosting a view per case to observe which branch
    /// rendered, which is both slow and, at this suite's scale, enough to kill
    /// the test process. `SDUIDataDrivenTests` previously kept a hand-copied
    /// mirror of this logic, which could agree with itself while the renderer
    /// was wrong.
    func evaluateCondition(_ condition: SDUICondition) -> Bool {
        switch condition {
        case .hasMultipleOffers:
            return context.offers.count > 1
        case .isCurrentPage(let index):
            return context.focusedIndex == index
        case .isCurrentPageBinding:
            return isCurrentPage
        // NEW: Generic state machine conditions
        case .stateEquals(let state):
            return context.isState(state)
        // Row-aware, like the text: a card's own value (or its hidden prize) gates its lines.
        case .valueEquals(let key, let value):
            return context.textValues(row: offer)[key] == value
        case .hasValue(let key):
            return context.textValues(row: offer)[key] != nil
        case .hasIntroOffer:
            return context.offerContext.iap.hasIntroOffer
        case .hasFreeTrial:
            return context.offerContext.iap.hasFreeTrial
        case .isSelectedOffer(let targetKey):
            // Row-aware: true when the current forEach offer's id matches
            // the stored selection. Used by list-style layouts to render
            // per-card selection state without row-binding literals.
            guard let current = (offer ?? context.currentOffer) else { return false }
            let key = targetKey ?? "selectedOfferId"
            return context.values[key] == current.id

        // Generic boolean combinators
        case .and(let conditions):
            return conditions.allSatisfy { evaluateCondition($0) }
        case .or(let conditions):
            return conditions.contains { evaluateCondition($0) }
        case .not(let condition):
            return !evaluateCondition(condition)
        case .hasOfferAttribute(let attribute):
            return resolveOfferAttribute(attribute) != nil
        case .hasOfferProperty(let key):
            // Campaign drops blanks at decode, so presence here means renderable.
            return resolveOfferProperty(key) != nil
        case .hasInstructionSubtitle:
            guard let step = instructionStep else { return false }
            let subtitle = step.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // lowercased(), not caseInsensitiveCompare: Android compares the same way.
            return !subtitle.isEmpty && subtitle.lowercased() != title.lowercased()
        case .hasInstructionImage:
            return instructionStep?.imageUrl != nil
        case .listCountAtLeast(let list, let min):
            return hostListHasAtLeast(list, min)
        case .equals(let lhs, let rhs):
            // Two UNSET operands are not a match. `offerAttribute` made that the
            // common case: most campaigns carry no badge, so comparing a row's
            // badge against an unwritten binding would be true on exactly the
            // rows that have no badge.
            let left = resolveValueRef(lhs)
            return left != nil && left == resolveValueRef(rhs)

        // Offer-position predicates (row-aware)
        case .isFirstOffer:
            return currentOfferIndex == 0
        case .isLastOffer:
            guard let idx = currentOfferIndex else { return false }
            return idx == context.offers.count - 1
        case .isMiddleOffer:
            guard let idx = currentOfferIndex, context.offers.count > 0 else { return false }
            return idx == context.offers.count / 2
        case .offerIndexEquals(let target):
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
    func resolveValueRef(_ ref: SDUIValueRef) -> String? {
        switch ref {
        case .literal(let value):
            return value
        case .binding(let key):
            return context.textValues(row: offer)[key]
        case .state:
            return context.currentState
        case .offerIndex:
            return currentOfferIndex.map(String.init)
        case .offerAttribute(let attribute):
            return resolveOfferAttribute(attribute)
        case .categoryName:
            return category
        }
    }

    /// An attribute of the row's own campaign, or nil outside a row with no
    /// current offer. Nil rather than "" so `equals` against a literal is false
    /// instead of matching an empty authored string.
    private func resolveOfferAttribute(_ attribute: SDUIOfferAttribute) -> String? {
        guard let scoped = offer ?? context.currentOffer else { return nil }
        switch attribute {
        case .badgeLabel: return scoped.badgeLabel?.rawValue
        case .perk: return scoped.perk
        case .advertiserName: return scoped.advertiserName
        case .description: return scoped.displayDescription
        case .category: return scoped.category
        case .shareUrl: return scoped.shareUrl
        case .termsUrl: return scoped.termsUrl
        case .quickInstructions: return scoped.displayQuickInstructions
        case .instructions:
            let steps = scoped.displayInstructions
            return steps.isEmpty ? nil : String(steps.count)
        }
    }
    
    @ViewBuilder
    private func renderConditional(_ config: SDUIConditional) -> some View {
        Group {
            if evaluateCondition(config.condition) {
                SDUIElementRenderer(element: config.ifTrue, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
            } else if let ifFalse = config.ifFalse {
                SDUIElementRenderer(element: ifFalse, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
            }
        }
        // Keep state-branch replacement free of an inherited crossfade without
        // clearing animation transactions for interactive descendants such as
        // a carousel's explicit tap-to-scroll animation.
        .transition(.identity)
    }
    
    // MARK: - Group Renderer

    private func renderGroup(_ config: SDUIGroup) -> some View {
        Group {
            SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep, isCurrentPage: isCurrentPage)
        }
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
                    .foregroundColor(isOn ? context.appearance.accent : context.appearance.semanticColor(.tertiaryLabel))
                    .font(.title3)
                SDUIElementRenderer(element: config.label, context: context, offer: offer, category: category, instructionStep: instructionStep)
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

/// iOS 18+ scroll-position path. `ScrollPosition` separates the live scroll
/// target from the shared offer selection, so a context update cannot restore
/// an old card while SwiftUI is resolving the end of a drag.
@available(iOS 18.0, *)
private struct SDUISemanticScrollViewRenderer: View {
    let config: SDUIScrollView
    @ObservedObject var context: SDUIContext
    let offer: Offer?
    let category: String?
    let instructionStep: Instruction?

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

    init(
        config: SDUIScrollView,
        context: SDUIContext,
        offer: Offer?,
        category: String?,
        instructionStep: Instruction?
    ) {
        self.config = config
        self.context = context
        self.offer = offer
        self.category = category
        self.instructionStep = instructionStep
        _position = State(initialValue: ScrollPosition(
            id: context.focusedIndex ?? 0,
            anchor: config.scrollAlignment?.unitPoint
        ))
    }

    var body: some View {
        Group {
            if usesCenteredGeometry {
                GeometryReader { geometryProxy in
                    scrollView(contentMargin: SDUIScrollLayout.centeredContentMargin(
                        for: config,
                        viewportWidth: geometryProxy.size.width
                    ))
                }
            } else {
                scrollView(contentMargin: resolvedContentMargin)
            }
        }
        .modifier(SDUIStyleModifier(style: config.style))
    }

    @ViewBuilder
    private func scrollView(contentMargin: CGFloat?) -> some View {
        let scrollView = ScrollView(axis, showsIndicators: config.showsIndicators ?? true) {
            SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep)
        }
        .applyScrollTargetBehavior(config.scrollTargetBehavior)
        .applyContentMargin(contentMargin, axis: axis)
        .scrollClipDisabled(true)

        if hasScrollTarget {
            scrollView
                .scrollPosition($position, anchor: config.scrollAlignment?.unitPoint)
                .onChange(of: position.viewID(type: Int.self)) { _, newIndex in
                    commitScrolledPosition(newIndex)
                }
                .onChange(of: context.focusedIndex) { _, newIndex in
                    animateContextSelection(newIndex)
                }
        } else {
            scrollView
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
    let category: String?
    let instructionStep: Instruction?

    @State private var userDrivenSelection: Int?

    private var axis: Axis.Set {
        config.axis?.axis ?? .vertical
    }

    private var scrollAxis: SDUIScrollAxis {
        config.axis ?? .vertical
    }

    init(
        config: SDUIScrollView,
        context: SDUIContext,
        offer: Offer?,
        category: String?,
        instructionStep: Instruction?
    ) {
        self.config = config
        self.context = context
        self.offer = offer
        self.category = category
        self.instructionStep = instructionStep
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
                        scrollView(
                            contentMargin: SDUIScrollLayout.centeredContentMargin(
                                for: config,
                                viewportWidth: geometryProxy.size.width
                            ),
                            viewportWidth: geometryProxy.size.width
                        )
                        .onPreferenceChange(SDUIOfferCenterPreferenceKey.self) { offerCenters in
                            updateVisibleOffer(
                                from: offerCenters,
                                viewportCenter: geometryProxy.frame(in: .global).midX
                            )
                        }
                    }
                    .modifier(SDUIStyleModifier(style: config.style))
                } else {
                    scrollView(contentMargin: resolvedContentMargin, viewportWidth: nil)
                        .modifier(SDUIStyleModifier(style: config.style))
                }
            }
            .onAppear {
                scrollToContextSelection(using: scrollProxy, animated: false)
            }
            .onChange(of: context.focusedIndex) { _, newIndex in
                if userDrivenSelection == newIndex {
                    userDrivenSelection = nil
                    return
                }
                scrollToContextSelection(using: scrollProxy, animated: true)
            }
        }
    }

    private func scrollView(contentMargin: CGFloat?, viewportWidth: CGFloat?) -> some View {
        ScrollView(axis, showsIndicators: config.showsIndicators ?? true) {
            scrollContent(centeredPadding: usesCenteredGeometry ? contentMargin : nil)
                .environment(\.sduiCarouselViewportWidth, viewportWidth)
        }
        .applyScrollTargetBehavior(config.scrollTargetBehavior)
        .applyContentMargin(usesCenteredGeometry ? nil : contentMargin, axis: axis)
        .scrollClipDisabled(true)
    }

    @ViewBuilder
    private func scrollContent(centeredPadding: CGFloat?) -> some View {
        if let centeredPadding {
            SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep)
                .padding(.horizontal, centeredPadding)
        } else {
            SDUIElementRenderer(element: config.content, context: context, offer: offer, category: category, instructionStep: instructionStep)
        }
    }

    private func scrollToContextSelection(using scrollProxy: ScrollViewProxy, animated: Bool) {
        guard let index = context.focusedIndex else { return }
        let scroll = {
            scrollProxy.scrollTo(index, anchor: config.scrollAlignment?.unitPoint)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { scroll() }
        } else {
            scroll()
        }
    }

    private func updateVisibleOffer(from offerCenters: [Int: CGFloat], viewportCenter: CGFloat) {
        guard let visibleOffer = offerCenters.min(by: {
            abs($0.value - viewportCenter) < abs($1.value - viewportCenter)
        }),
            visibleOffer.key != context.currentIndex
        else { return }

        userDrivenSelection = visibleOffer.key
        context.currentIndex = visibleOffer.key
        context.selectCenteredOffer(at: visibleOffer.key)
        context.trackScroll(axis: scrollAxis, position: visibleOffer.key)
    }
}

/// Fixed-width centering used by the iOS 17 and iOS 18 carousel renderers.
extension SDUIScrollLayout {
    static func centeredContentMargin(for config: SDUIScrollView, viewportWidth: CGFloat) -> CGFloat? {
        guard let itemWidth = offerItemWidth(for: config) else { return nil }
        let authoredMargin = config.contentMargins?.edgeInsets.leading ?? 0
        return max(authoredMargin, (viewportWidth - itemWidth) / 2)
    }

    static func offerItemWidth(for config: SDUIScrollView) -> CGFloat? {
        guard case .hStack(let stack) = config.content,
              stack.children.count == 1,
              case .forEach(let loop) = stack.children[0],
              case .offers = loop.dataSource,
              let itemWidth = fixedWidth(of: loop.itemTemplate)
        else { return nil }
        return itemWidth
    }

    private static func fixedWidth(of element: SDUIElement) -> CGFloat? {
        switch element {
        case .button(let config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case .group(let config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case .vStack(let config), .hStack(let config), .zStack(let config):
            if let width = config.style?.frame?.width {
                return width
            }
            return config.children.lazy.compactMap(fixedWidth(of:)).first
        default:
            return nil
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
    @Environment(\.layoutDirection) private var layoutDirection
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
            let thumbColor = context.resolveColor(config.thumbColor) ?? Color(hex: "#6743F5")
            let textColor = context.resolveColor(config.textColor) ?? context.appearance.semanticColor(.secondaryLabel)

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(context.resolveColor(config.trackColor) ?? context.appearance.semanticColor(.tertiarySystemFill))
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
                        .foregroundColor(context.appearance.semanticColor(.tertiaryLabel))
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
                                        .init(color: .clear, location: 1.0)
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
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isDisabled ? Color(UIColor.systemGray2) : .white)
                    )
                    .shadow(color: (isDisabled ? Color.clear : thumbColor).opacity(0.3), radius: 4, y: 2)
                    .offset(x: inset + dragOffset + bounceOffset)
                    // `offset(x:)` already mirrors under RTL; the drag is read in
                    // global (physical) space so its sign is explicit too.
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                // Blocked while a Yes waits: the thumb never moves, so it can't latch.
                                guard !isCompleted, !isDisabled, context.allowsAction(config.action.type) else { return }
                                bounceOffset = 0 // Stop bounce hint on interaction
                                let forward = ForwardDrag.distance(value.translation.width, in: layoutDirection)
                                dragOffset = min(max(0, forward), maxDrag)
                            }
                            .onEnded { _ in
                                guard !isCompleted, !isDisabled, context.allowsAction(config.action.type) else { return }
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
        self.asset = videoAsset
        
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
        
        self.player = avPlayer
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
    
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        view.videoGravity = videoGravity
        return view
    }
    
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
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
    
    required init?(coder: NSCoder) {
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
            .foregroundColor(context.resolveColor(overlay.typography.color) ?? context.appearance.semanticColor(.label))
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
internal struct TemplateText: View {
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
        self.template = value
        self.context = nil
    }
}

extension TemplateText: CustomStringConvertible {
    var description: String { resolved }
}

// MARK: - UIValues Extension

extension UIValues {
    /// Creates a TemplateText using this configuration for variable substitution.
    ///
    /// - Parameter template: The template string with `${variableName}` placeholders
    /// - Returns: A TemplateText that will resolve placeholders using this configuration
    func text(_ template: String) -> TemplateText {
        TemplateText(template, context: OfferContext(uiValues: self, servedLocale: nil))
    }
    
    /// Creates a TemplateText from an optional template string.
    ///
    /// - Parameters:
    ///   - template: The optional template string
    ///   - fallback: The fallback value if template is nil
    /// - Returns: A TemplateText that will resolve placeholders using this configuration
    func text(_ template: String?, or fallback: String) -> TemplateText {
        TemplateText(template ?? fallback, context: OfferContext(uiValues: self, servedLocale: nil))
    }
}

// MARK: - Optional UIValues Extension

extension Optional where Wrapped == UIValues {
    /// Creates a TemplateText using this optional configuration for variable substitution.
    ///
    /// - Parameter template: The template string with `${variableName}` placeholders
    /// - Returns: A TemplateText that will resolve placeholders if configuration exists
    func text(_ template: String) -> TemplateText {
        TemplateText(template, context: OfferContext(uiValues: self, servedLocale: nil))
    }
    
    /// Creates a TemplateText from an optional template string.
    ///
    /// - Parameters:
    ///   - template: The optional template string
    ///   - fallback: The fallback value if template is nil
    /// - Returns: A TemplateText that will resolve placeholders if configuration exists
    func text(_ template: String?, or fallback: String) -> TemplateText {
        TemplateText(template ?? fallback, context: OfferContext(uiValues: self, servedLocale: nil))
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
        let sized = self.font(font.monospacedDigits == true ? font.font.monospacedDigit() : font.font)
        guard let tracking = font.tracking else { return sized }
        return sized.tracking(tracking)
    }
}

/// A button that fires only after the finger has been DOWN for `duration`.
///
/// Three decisions are the contract here.
///
/// An abandoned hold fires NOTHING. These buttons claim offers and open gift
/// boxes, so a partial press must leave nothing behind. `slideButton`, the
/// nearest shipped gesture, makes the same promise about an incomplete drag.
///
/// It also REVERTS. If the template named an `onHoldState`, letting go returns
/// to whichever state the press interrupted, so a half-lifted lid falls shut.
/// The state that was current at press time is captured then, not read at
/// release, because the action itself may have moved it.
///
/// The two state transitions are BOTH emitted, including on an abandoned hold.
/// A user who started to open the box and stopped did something worth seeing,
/// and suppressing the pair would make the funnel claim they never pressed.
@available(iOS 17.0, *)
private struct SDUIHoldButton<Label: View>: View {
    let config: SDUIButton
    let duration: Double
    @ObservedObject var context: SDUIContext
    let label: Label
    let perform: () -> Void

    /// The state the press interrupted, captured at press time.
    @State private var stateBeforeHold: String?

    var body: some View {
        label
            .onLongPressGesture(minimumDuration: duration) {
                // Completed. The success tick lands before the action, so the
                // confirmation is felt at the moment the hold is earned rather
                // than after whatever the action opens.
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                stateBeforeHold = nil
                perform()
            } onPressingChanged: { isPressing in
                if isPressing {
                    beginHold()
                } else {
                    cancelHold()
                }
            }
            // A long press is not reachable with VoiceOver or Switch Control,
            // and on the gift-box variant the hold IS the claim, so without
            // these the offer cannot be claimed with assistive tech at all. The
            // tap path gets both free from `Button`; this path is a raw view.
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text(verbatim: context.strings[.holdToActivateHint]))
            .accessibilityAction { perform() }
    }

    private func beginHold() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        guard let holdState = config.onHoldState, context.allowsAction(config.action.type) else { return }
        stateBeforeHold = context.currentState
        context.setState(holdState)
    }

    /// Runs on release AND on cancellation, and after completion too — which is
    /// why it is a no-op once `stateBeforeHold` has been cleared. Reverting
    /// after a completed hold would undo the action's own transition.
    private func cancelHold() {
        guard let previous = stateBeforeHold else { return }
        stateBeforeHold = nil
        context.setState(previous)
    }
}

/// Identity for a featured creative: the offer it is bound to AND its url.
///
/// The url alone is not enough, because two campaigns can share one creative.
@available(iOS 17.0, *)
struct SDUIFeaturedProbeIdentity: Hashable {
    let offerId: String?
    let url: URL?
}

/// Names a meaningful image; hides a decorative one (no label) from VoiceOver.
private struct SDUIImageAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The buttons inside a button, as its VoiceOver custom actions (none: unchanged).
private struct SDUINestedAccessibilityActions: ViewModifier {
    let actions: [(label: String, action: SDUIAction)]
    let perform: (SDUIAction) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            actions.reduce(AnyView(content)) { view, entry in
                AnyView(view.accessibilityAction(named: Text(verbatim: entry.label)) { perform(entry.action) })
            }
        }
    }
}

/// Sets an accessibility label only when there is one to set.
private struct SDUIAccessibilityLabel: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.accessibilityLabel(Text(verbatim: text))
        } else {
            content
        }
    }
}
