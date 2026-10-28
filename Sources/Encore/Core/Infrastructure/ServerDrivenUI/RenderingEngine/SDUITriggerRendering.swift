//
//  SDUITriggerRendering.swift
//  Encore
//
//  Rendering for the trigger vocabulary (SDUITriggerVocabulary.swift). Every entry point here
//  is reached only by a node that uses a new key, so sheets render exactly as before.
//

import SwiftUI

// MARK: - Host item (forEach over a host list)

private struct SDUIHostItemKey: EnvironmentKey {
    static let defaultValue: [String: String]? = nil
}

extension EnvironmentValues {
    /// The row of a `hostList` loop; `${item.<field>}` reads it.
    var sduiHostItem: [String: String]? {
        get { self[SDUIHostItemKey.self] }
        set { self[SDUIHostItemKey.self] = newValue }
    }
}

// MARK: - zStack sizing (trigger trees)

/// The axes on which the nearest frame is a finite maximum: a cap ("up to"), not a size. A width
/// or an infinite maximum on an axis ends the cap there.
struct SDUIFrameCaps: Equatable {
    var horizontal = false
    var vertical = false

    init(horizontal: Bool = false, vertical: Bool = false) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    init(_ frame: SDUIFrame?, inside outer: SDUIFrameCaps) {
        self = outer
        guard let frame else { return }
        // A cap exactly as the frame modifier caps: a finite maximum with no size and no minimum.
        if frame.width != nil || frame.minWidth != nil || frame.maxWidth != nil {
            horizontal = frame.width == nil && frame.minWidth == nil && frame.maxWidthValue.map { $0.isFinite } == true
        }
        if frame.height != nil || frame.minHeight != nil || frame.maxHeight != nil {
            vertical = frame.height == nil && frame.minHeight == nil && frame.maxHeightValue.map { $0.isFinite } == true
        }
    }
}

private struct SDUIFrameCapsKey: EnvironmentKey {
    static let defaultValue = SDUIFrameCaps()
}

private struct SDUITriggerTreeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The nearest frame's capped axes.
    var sduiFrameCaps: SDUIFrameCaps {
        get { self[SDUIFrameCapsKey.self] }
        set { self[SDUIFrameCapsKey.self] = newValue }
    }

    /// Inside a trigger look (sheets keep the engine's layouts exactly as they were).
    var sduiTriggerTree: Bool {
        get { self[SDUITriggerTreeKey.self] }
        set { self[SDUITriggerTreeKey.self] = newValue }
    }
}

/// A trigger zStack on a capped axis: the content children size the stack and each frameless
/// shape or gradient takes the stack's size, so a capsule hugs its label up to the cap. On any
/// other axis it is a ZStack (a frameless shape takes all it is offered).
@available(iOS 17.0, *)
struct SDUITriggerZStackLayout: Layout {
    let alignment: Alignment
    /// Per child: a frameless shape or gradient.
    let fills: [Bool]
    let caps: SDUIFrameCaps

    /// A frameless shape or gradient: it draws at whatever size it is given.
    static func fills(_ element: SDUIElement) -> Bool {
        switch element {
        case .shape(let shape): return shape.style?.frame == nil
        case .gradient(let gradient): return gradient.style?.frame == nil
        default: return false
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = subviews.map { $0.sizeThatFits(proposal) }
        let content = zip(subviews.indices, all).filter { !isFill($0.0) }.map(\.1)
        let widest = all.map(\.width).max() ?? 0, tallest = all.map(\.height).max() ?? 0
        guard !content.isEmpty else { return CGSize(width: widest, height: tallest) }
        return CGSize(
            width: caps.horizontal ? content.map(\.width).max() ?? 0 : widest,
            height: caps.vertical ? content.map(\.height).max() ?? 0 : tallest
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offered = ProposedViewSize(bounds.size)
        for index in subviews.indices {
            let size = isFill(index) ? bounds.size : subviews[index].sizeThatFits(offered)
            let x: CGFloat
            switch alignment.horizontal {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - size.width
            default: x = bounds.midX - size.width / 2
            }
            let y: CGFloat
            switch alignment.vertical {
            case .top: y = bounds.minY
            case .bottom: y = bounds.maxY - size.height
            default: y = bounds.midY - size.height / 2
            }
            subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        }
    }

    private func isFill(_ index: Int) -> Bool { index < fills.count && fills[index] }
}

// MARK: - hStack sizing (trigger trees)

/// How a trigger hStack sizes one child: a spacer or an infinite-width frame takes what is left
/// (at least its minimum); anything else is sized first.
struct SDUIStackRole: LayoutValueKey {
    static let defaultValue: Role? = nil

    /// A child that takes what is left: a spacer, or an infinite-width frame.
    struct Role: Equatable {
        /// What it keeps at least.
        var minimum: CGFloat
        /// A spacer is its minimum when the stack is unbounded; an infinite frame is its ideal.
        var isSpacer: Bool
    }

    /// The role of `element`; nil for a child sized first.
    static func role(_ element: SDUIElement) -> Role? {
        switch element {
        case .spacer(let spacer): return Role(minimum: spacer.minLength ?? 8, isSpacer: true)
        default:
            guard let frame = element.style?.frame, frame.width == nil, frame.maxWidthValue == .infinity else { return nil }
            return Role(minimum: 0, isSpacer: false)
        }
    }
}

/// A trigger hStack, laid out as Android's inline stack: the children that are not spacers (or
/// infinite frames) are sized first, least flexible (narrowest ideal) first, each offered an even
/// share of what is still free; then the spacers share what is left, at least their minLength.
@available(iOS 17.0, *)
struct SDUITriggerHStackLayout: Layout {
    let spacing: CGFloat
    let alignment: VerticalAlignment

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = Self.sizes(proposal: proposal, subviews: subviews, spacing: spacing)
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.sizes(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews, spacing: spacing)
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            let y: CGFloat
            switch alignment {
            case .top: y = bounds.minY
            case .bottom: y = bounds.maxY - size.height
            default: y = bounds.midY - size.height / 2
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }

    static func sizes(proposal: ProposedViewSize, subviews: Subviews, spacing: CGFloat) -> [CGSize] {
        let height = proposal.height
        let roles = subviews.map { $0[SDUIStackRole.self] }
        let minimums = roles.map { $0?.minimum }
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        guard let total = proposal.width, total.isFinite else {
            // Unbounded: every child at its ideal, a spacer at its minimum.
            for index in subviews.indices {
                let width: CGFloat? = roles[index]?.isSpacer == true ? roles[index]?.minimum : nil
                sizes[index] = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: height))
            }
            return sizes
        }
        let reserved = minimums.compactMap { $0 }.reduce(0, +)
        var pool = max(total - spacing * CGFloat(max(subviews.count - 1, 0)) - reserved, 0)
        let sized = subviews.indices.filter { minimums[$0] == nil }
            .map { ($0, subviews[$0].sizeThatFits(ProposedViewSize(width: nil, height: height)).width) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        for (n, index) in sized.enumerated() {
            sizes[index] = subviews[index].sizeThatFits(ProposedViewSize(width: pool / CGFloat(sized.count - n), height: height))
            pool = max(pool - sizes[index].width, 0)
        }
        var leftover = pool + reserved
        let greedy = subviews.indices.filter { minimums[$0] != nil }
        for (n, index) in greedy.enumerated() {
            let share = max(leftover / CGFloat(greedy.count - n), minimums[index] ?? 0)
            sizes[index] = subviews[index].sizeThatFits(ProposedViewSize(width: share, height: height))
            sizes[index].width = max(sizes[index].width, minimums[index] ?? 0)
            leftover = max(leftover - sizes[index].width, 0)
        }
        return sizes
    }
}

// MARK: - Countdown maths

enum SDUICountdownText {
    /// Whole seconds left until `deadline`, clamped at 0 (and at 0 for a nonsense span).
    static func remaining(until deadline: Date?, now: Date) -> Int {
        guard let deadline else { return 0 }
        let seconds = deadline.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds <= 10 * 365 * 86_400 else { return 0 }
        return Int(seconds.rounded(.down))
    }

    /// The text for `format`, with `units` already resolved to words.
    static func format(_ remaining: Int, _ format: SDUICountdownFormat, units: (hours: String, minutes: String, seconds: String)) -> String {
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        switch format {
        case .clock: return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        case .hoursMinutes: return String(format: "%02d:%02d", hours, minutes)
        case .hours: return String(format: "%02d", hours)
        case .minutes: return String(format: "%02d", minutes)
        case .seconds: return String(format: "%02d", seconds)
        case .largestUnit:
            if hours > 0 { return "\(hours) \(units.hours)" }
            if minutes > 0 { return "\(minutes) \(units.minutes)" }
            return "\(seconds) \(units.seconds)"
        }
    }

    /// `(to - now) / (to - from)`, clamped to 0...1.
    static func fraction(from start: Date?, to end: Date?, now: Date) -> Double {
        guard let start, let end else { return 0 }
        let span = end.timeIntervalSince(start)
        guard span.isFinite, span > 0 else { return 0 }
        return min(max(end.timeIntervalSince(now) / span, 0), 1)
    }
}

// MARK: - Renderer branches

@available(iOS 17.0, *)
extension SDUIElementRenderer {
    /// `${item.<field>}` from the enclosing host-list row; other text untouched.
    func substituteHostItem(_ text: String) -> String {
        guard let hostItem, text.contains("${item.") else { return text }
        var result = text
        for (field, value) in hostItem {
            result = result.replacingOccurrences(of: "${item.\(field)}", with: value)
        }
        return result
    }

    /// Ticking text: re-renders once a second, only this node.
    @ViewBuilder
    /// `scale` is a scale group's factor: the font is drawn at it and never shrinks further.
    /// `sample` replaces the ticking text (a scale-group member's room).
    func renderCountdownText(_ config: SDUIText, countdown: SDUICountdown, scale: CGFloat? = nil, sample: String? = nil) -> some View {
        let deadline = context.triggerTimes[countdown.to]
        let units = (
            hours: context.resolveTemplateText(countdown.units?.hours ?? ""),
            minutes: context.resolveTemplateText(countdown.units?.minutes ?? ""),
            seconds: context.resolveTemplateText(countdown.units?.seconds ?? "")
        )
        let color = resolveColor(config.color) ?? context.appearance.semanticColor(.label)
        let font = scale.map { (config.font ?? .unstyled).scaled($0) } ?? config.font
        return TimelineView(.periodic(from: context.triggerClock(), by: 1)) { timeline in
            let remaining = SDUICountdownText.remaining(until: deadline, now: timeline.date)
            let string = sample ?? SDUICountdownText.format(remaining, countdown.format, units: units)
            #if DEBUG
            let _ = font.map { if scale != nil { SDUIScaleGroups.recordDrawn(key: SDUIScaleGroups.countdownKey, text: string, size: $0.size) } }
            #endif
            Self.countdownText(string, font: font)
                .foregroundColor(color)
                .lineLimit(config.lineLimit ?? 1)
                .minimumScaleFactor(scale == nil ? (config.minimumScaleFactor ?? 1) : 1)
        }
        .modifier(SDUIStyleModifier(style: config.style))
    }

    private static func countdownText(_ string: String, font: SDUIFont?) -> Text {
        let text = Text(verbatim: string)
        guard let font else { return text }
        return text.applySDUIFont(font)
    }

    /// A capsule bar; a time-remaining value drains once a second.
    @ViewBuilder
    func renderProgress(_ config: SDUIProgress) -> some View {
        let fill = resolveColor(config.fillColor) ?? context.appearance.color(for: .accent)
        let track = resolveColor(config.trackColor) ?? context.appearance.color(for: .border)
        TimelineView(.periodic(from: context.triggerClock(), by: 1)) { timeline in
            let value: Double = {
                switch config.value {
                case .literal(let literal): return min(max(literal, 0), 1)
                case .timeRemaining(let from, let to):
                    return SDUICountdownText.fraction(from: context.triggerTimes[from], to: context.triggerTimes[to], now: timeline.date)
                }
            }()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(fill).frame(width: proxy.size.width * value)
                }
            }
        }
        .modifier(SDUIStyleModifier(style: config.style))
    }

    /// A `forEach` over a list the trigger host supplies; each row sets `${item.*}`.
    @ViewBuilder
    func renderHostListForEach(_ config: SDUIForEach) -> some View {
        let items = Array((context.hostLists[config.list ?? ""] ?? []).dropFirst(max(config.offset ?? 0, 0)))
        let shown = config.limit.map { Array(items.prefix(max($0, 0))) } ?? items
        ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
            SDUIElementRenderer(element: config.itemTemplate, context: context, offer: offer, isCurrentPage: isCurrentPage)
                .environment(\.sduiHostItem, item)
        }
    }

    /// The authored fallback is the waiting state, so it never shimmers: a logo that fails to load
    /// leaves the still fallback (a letter tile), as `SDUILogoTile` does, whatever Reduce Motion
    /// or the trigger's pause says.
    static let fallbackImageShimmers = false

    /// An image with a fallback element: shown while loading, when the url is empty, and on failure.
    @ViewBuilder
    func renderAsyncImageWithFallback(_ config: SDUIAsyncImage, fallback: SDUIElement) -> some View {
        let fallbackView = SDUIElementRenderer(element: fallback, context: context, offer: offer, isCurrentPage: isCurrentPage)
        if let url = resolveImageUrl(config).flatMap({ $0.isEmpty ? nil : URL(string: $0) }) {
            CachedAsyncImage(url: url, contentMode: config.contentMode?.contentMode ?? .fit, placeholder: { fallbackView },
                             shimmers: Self.fallbackImageShimmers)
                .modifier(SDUIStyleModifier(style: config.style))
        } else {
            fallbackView.modifier(SDUIStyleModifier(style: config.style))
        }
    }

    /// Content laid along an axis that scrolls on a loop, or sits still centred.
    @ViewBuilder
    func renderMarquee(_ config: SDUIMarquee) -> some View {
        let animates = (config.animateWhen.map { evaluateCondition($0) } ?? true) && !context.motionPaused
        SDUIMarqueeView(config: config, animates: animates, content: { repeats in
            ForEach(0..<repeats, id: \.self) { _ in
                SDUIElementRenderer(element: config.content, context: context, offer: offer, isCurrentPage: isCurrentPage)
            }
        })
        .modifier(SDUIStyleModifier(style: config.style))
    }

    /// `listCountAtLeast`: the host list has at least `min` items.
    func hostListHasAtLeast(_ list: String, _ min: Int) -> Bool {
        (context.hostLists[list]?.count ?? 0) >= min
    }
}

// MARK: - Marquee view

/// How far a marquee or loop has run: running time only, so a pause (a sheet over it, off screen,
/// the background) holds the position and a resume carries on from it, never from the start.
internal struct SDUIMotionClock: Equatable {
    /// Running time before the current run.
    private(set) var banked: TimeInterval = 0
    /// When the current run began; nil while paused.
    private(set) var runningSince: Date?

    /// Has it ever moved? Before that, a paused marquee shows the still pose.
    var hasRun: Bool { banked > 0 || runningSince != nil }

    mutating func resume(at now: Date) {
        if runningSince == nil { runningSince = now }
    }

    mutating func pause(at now: Date) {
        guard let since = runningSince else { return }
        banked += max(0, now.timeIntervalSince(since))
        runningSince = nil
    }

    /// The share of a cycle scrolled, 0 up to 1.
    func phase(at now: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let elapsed = banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        return (elapsed / duration).truncatingRemainder(dividingBy: 1)
    }
}

/// Repeats its content along the axis and moves it one cycle per `duration`, linearly. Moving, it
/// repeats enough to fill the window plus one cycle (vocab-contract §3.4), so it never shows a gap.
/// Paused after it has moved, it holds where it is; it sits still and centred only before it has
/// ever moved, or under Reduce Motion.
@available(iOS 17.0, *)
internal struct SDUIMarqueeView<Content: View>: View {
    let config: SDUIMarquee
    let animates: Bool
    @ViewBuilder let content: (_ repeats: Int) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cycleLength: CGFloat = 0
    @State private var clock = SDUIMotionClock()

    /// The most copies a marquee draws. A served look's content that measures almost nothing must
    /// not multiply into thousands of views; a shipped strip needs a dozen at most.
    static var maxRepeats: Int { 64 }

    /// Copies that cover `viewport` at every point of the scroll: the window plus one cycle, at
    /// most ``maxRepeats``. A cycle under a point is not measured yet.
    static func repeats(viewport: CGFloat, cycle: CGFloat) -> Int {
        guard cycle >= 1, viewport.isFinite else { return 1 }
        let copies = (Double(viewport) / Double(cycle)).rounded(.up) + 1
        return Int(min(Double(maxRepeats), max(2, copies)))
    }

    /// One cycle of `repeats` copies measuring `length` along the axis: the content once plus the
    /// gap before it repeats. Zero when the content draws nothing, or the cycle is under a point,
    /// so the gap alone is never taken for a cycle (which would feed back into more copies).
    static func cycle(length: CGFloat, spacing: CGFloat, repeats: Int) -> CGFloat {
        guard length > 0, repeats > 0 else { return 0 }
        let cycle = (length + spacing) / CGFloat(repeats)
        return cycle.isFinite && cycle >= 1 ? cycle : 0
    }

    var body: some View {
        let canMove = !reduceMotion && config.duration > 0
        let running = animates && canMove
        GeometryReader { proxy in
            let vertical = config.axis == .vertical
            let viewport = vertical ? proxy.size.height : proxy.size.width
            if canMove, cycleLength > 0, running || clock.hasRun {
                let repeats = Self.repeats(viewport: viewport, cycle: cycleLength)
                TimelineView(.animation(minimumInterval: nil, paused: !running)) { timeline in
                    let phase = clock.phase(at: timeline.date, duration: config.duration)
                    let progress = (config.reverse ?? false) ? 1 - phase : phase
                    let shift = -CGFloat(progress) * cycleLength
                    measured(stack(vertical: vertical, repeats: repeats), vertical: vertical, repeats: repeats)
                        .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: vertical ? .top : .leading)
            } else {
                measured(stack(vertical: vertical, repeats: 1), vertical: vertical, repeats: 1)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        // A marquee is a window onto its content: tiles scrolling past either end stay inside it.
        .clipped()
        .onPreferenceChange(SDUIMarqueeLengthKey.self) { length in
            if length > 0, length != cycleLength { cycleLength = length }
        }
        .onAppear { if running, cycleLength > 0 { clock.resume(at: Date()) } }
        .onChange(of: running && cycleLength > 0) { _, run in
            if run { clock.resume(at: Date()) } else { clock.pause(at: Date()) }
        }
    }

    /// Reports one cycle (the content once plus the gap before it repeats), whatever the copies,
    /// so a list that changes while moving is measured again.
    private func measured(_ view: some View, vertical: Bool, repeats: Int) -> some View {
        view.background(GeometryReader { inner in
            let length = vertical ? inner.size.height : inner.size.width
            Color.clear.preference(key: SDUIMarqueeLengthKey.self, value: Self.cycle(length: length, spacing: config.spacing ?? 0, repeats: repeats))
        })
    }

    @ViewBuilder
    private func stack(vertical: Bool, repeats: Int) -> some View {
        if vertical {
            VStack(spacing: config.spacing ?? 0) { content(repeats) }
        } else {
            HStack(spacing: config.spacing ?? 0) { content(repeats) }
        }
    }
}

private struct SDUIMarqueeLengthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Small modifiers (each a no-op when its key is absent)

struct SDUIMinimumScaleFactor: ViewModifier {
    let factor: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let factor { content.minimumScaleFactor(factor) } else { content }
    }
}

/// A stroke drawn inside the shape's frame.
struct SDUIStrokeModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color?
    let width: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color { content.overlay(shape.strokeBorder(color, lineWidth: width ?? 1)) } else { content }
    }
}

/// `.plain`, exactly as before, unless the button asks for press feedback.
struct SDUIButtonPressModifier: ViewModifier {
    let pressed: SDUIPressedStyle?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let pressed {
            content.buttonStyle(SDUIPressedButtonStyle(scale: pressed.scale ?? 1, duration: pressed.duration ?? 0.12))
        } else {
            content.buttonStyle(.plain)
        }
    }
}

private struct SDUIPressedButtonStyle: ButtonStyle {
    let scale: CGFloat
    let duration: Double

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: duration), value: configuration.isPressed)
    }
}

struct SDUIAccessibilityHint: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.accessibilityHint(Text(verbatim: text)) } else { content }
    }
}

struct SDUILayoutDirectionModifier: ViewModifier {
    let direction: SDUILayoutDirection?

    @ViewBuilder
    func body(content: Content) -> some View {
        if direction == .ltr { content.environment(\.layoutDirection, .leftToRight) } else { content }
    }
}

struct SDUIAccessibilityHiddenModifier: ViewModifier {
    let hidden: Bool?

    @ViewBuilder
    func body(content: Content) -> some View {
        if hidden == true { content.accessibilityHidden(true) } else { content }
    }
}

// MARK: - Loop (G3)

private struct SDUIMotionPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by a trigger mount: offscreen or backgrounded. Loops hold the pose they reached.
    var sduiMotionPaused: Bool {
        get { self[SDUIMotionPausedKey.self] }
        set { self[SDUIMotionPausedKey.self] = newValue }
    }
}

/// One frame of a loop: transforms applied on top of the element's own.
struct SDUILoopFrame: Equatable {
    var scale: CGFloat = 1
    var opacity: Double = 1
    var rotation: Double = 0
    var x: CGFloat = 0
    var y: CGFloat = 0

    /// The pose at `progress` (0...1 of a cycle), each segment eased by `curve`.
    static func at(_ progress: Double, keyframes: [SDUILoopKeyframe], curve: SDUIAnimationCurve?) -> SDUILoopFrame {
        guard let first = keyframes.first else { return SDUILoopFrame() }
        guard keyframes.count > 1 else { return frame(first) }
        let p = min(max(progress, 0), 1)
        var lower = first
        var upper = keyframes[keyframes.count - 1]
        for (index, keyframe) in keyframes.enumerated() where index + 1 < keyframes.count {
            if p >= keyframe.at, p <= keyframes[index + 1].at {
                lower = keyframe
                upper = keyframes[index + 1]
                break
            }
        }
        let span = upper.at - lower.at
        let t = eased(span > 0 ? (p - lower.at) / span : 0, curve)
        let a = frame(lower), b = frame(upper)
        return SDUILoopFrame(
            scale: a.scale + (b.scale - a.scale) * t,
            opacity: a.opacity + (b.opacity - a.opacity) * Double(t),
            rotation: a.rotation + (b.rotation - a.rotation) * Double(t),
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }

    /// A keyframe's pose; a property it leaves out holds the element's own value.
    static func frame(_ keyframe: SDUILoopKeyframe) -> SDUILoopFrame {
        SDUILoopFrame(
            scale: keyframe.scale ?? 1,
            opacity: keyframe.opacity ?? 1,
            rotation: keyframe.rotation ?? 0,
            x: keyframe.offset?.x ?? 0,
            y: keyframe.offset?.y ?? 0
        )
    }

    static func pose(_ pose: SDUILoopPose) -> SDUILoopFrame {
        SDUILoopFrame(scale: pose.scale ?? 1, opacity: pose.opacity ?? 1, rotation: pose.rotation ?? 0,
                      x: pose.offset?.x ?? 0, y: pose.offset?.y ?? 0)
    }

    static func eased(_ t: Double, _ curve: SDUIAnimationCurve?) -> CGFloat {
        let t = min(max(t, 0), 1)
        switch curve ?? .linear {
        case .linear, .spring: return CGFloat(t)
        case .easeIn: return CGFloat(t * t)
        case .easeOut: return CGFloat(1 - (1 - t) * (1 - t))
        case .easeInOut: return CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        }
    }
}

struct SDUILoopModifier: ViewModifier {
    let loop: SDUILoop?
    @Environment(\.sduiMotionPaused) private var paused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SDUIMotionClock()

    /// Where the loop sits: `phaseOffset` cycles in, plus the running time (vocab-contract §3.3).
    static func progress(_ clock: SDUIMotionClock, at date: Date, loop: SDUILoop) -> Double {
        let cycles = (loop.phaseOffset ?? 0) + clock.phase(at: date, duration: loop.duration)
        return cycles - cycles.rounded(.down)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let loop {
            if reduceMotion {
                apply(content, Self.reducedFrame(loop))
            } else {
                // Paused (off screen, under a sheet, the background): it holds its pose; before it
                // has ever run, that is the phaseOffset pose.
                TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
                    apply(content, SDUILoopFrame.at(Self.progress(clock, at: timeline.date, loop: loop), keyframes: loop.keyframes, curve: loop.curve))
                }
                .onAppear { if !paused { clock.resume(at: Date()) } }
                .onChange(of: paused) { isPaused in
                    if isPaused { clock.pause(at: Date()) } else { clock.resume(at: Date()) }
                }
            }
        } else {
            content
        }
    }

    /// Under reduce motion: the authored pose, else the `phaseOffset` pose.
    static func reducedFrame(_ loop: SDUILoop) -> SDUILoopFrame {
        if let pose = loop.reducedMotion { return SDUILoopFrame.pose(pose) }
        return SDUILoopFrame.at(loop.phaseOffset ?? 0, keyframes: loop.keyframes, curve: loop.curve)
    }

    private func apply(_ content: Content, _ frame: SDUILoopFrame) -> some View {
        content
            .scaleEffect(frame.scale)
            .rotationEffect(.degrees(frame.rotation))
            .offset(x: frame.x, y: frame.y)
            .opacity(frame.opacity)
    }
}
