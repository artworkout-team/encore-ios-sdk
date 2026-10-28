// Draws a trigger's look with the same SDUI engine as the offer sheet, inline at the root's
// frame height: no sheet chrome, no offers. The host keeps every behaviour; this only draws.

import SwiftUI
import UIKit

/// What the engine reads for one render of a trigger (vocab-contract §2).
internal struct TriggerSDUIInputs: Hashable {
    /// `${key}` values, `hasValue` and `valueEquals`. They resolve ahead of any `ui.values` key.
    var values: [String: String]
    var theme: TriggerSDUITheme
    /// The palette for a light device, when the scheme follows the device; the view picks.
    var lightTheme: TriggerSDUITheme? = nil
    /// Time keys for `countdown` and `progress`.
    var times: [String: Date] = [:]
    /// Host lists for `forEach` with `dataSource: hostList`.
    var lists: [String: [[String: String]]] = [:]
    /// A tap is in flight or a sheet is up: the tree's `busy` state (taps and styling, not motion).
    var busy = false
    /// Any part on screen and not under a sheet; loops and marquees pause otherwise.
    var onScreen = true
    var maxFontScale = TriggerLookSource.defaultMaxFontScale

    /// What the engine context is built from; the rest updates it in place.
    var contextKey: ContextKey { ContextKey(values: values, theme: theme) }

    struct ContextKey: Hashable {
        let values: [String: String]
        let theme: TriggerSDUITheme
    }

    /// A host list split into two marquee columns: even items, odd items; one item fills both.
    static func columns<Item>(_ items: [Item]) -> ([Item], [Item]) {
        guard items.count > 1 else { return (items, items) }
        let left = items.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let right = items.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        return (left, right)
    }
}

/// The trigger palette as the engine's appearance tokens (vocab-contract §2.1).
internal struct TriggerSDUITheme: Hashable {
    let background: AppearanceHex.RGBA
    let accent: AppearanceHex.RGBA
    let text: AppearanceHex.RGBA
    let onAccent: AppearanceHex.RGBA
    let inkOnAccent: AppearanceHex.RGBA
    /// The publisher's own secondary and track inks; nil keeps the tree's text-colour fallback.
    let secondary: AppearanceHex.RGBA?
    let track: AppearanceHex.RGBA?
    let backgroundEnd: AppearanceHex.RGBA?

    init(_ theme: TriggerTheme) {
        background = theme.background
        accent = theme.accent
        text = theme.text
        onAccent = theme.onAccentInk
        inkOnAccent = theme.inkOnAccent
        secondary = theme.secondary
        track = theme.track
        backgroundEnd = theme.backgroundEnd
    }

    /// Surface is the background and border the accent, as the native looks drew them.
    var appearance: Appearance {
        Appearance(
            accent: accent.color, onAccent: onAccent.color, accentTitle: accent.color,
            background: background.color, onBackground: text.color,
            surface: background.color, onSurface: text.color,
            border: accent.color, muted: text.color.opacity(0.6), error: Appearance.default.error,
            inkOnAccent: inkOnAccent.color, secondary: secondary?.color,
            track: track?.color, backgroundEnd: backgroundEnd?.color
        )
    }
}

/// A trigger's look, or nothing below iOS 17 (where Encore draws nothing at all).
internal struct TriggerLookView: View {
    let look: TriggerLook
    let inputs: TriggerSDUIInputs
    let onAction: (SDUIAction) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(iOS 17.0, *) {
            TriggerSDUIView(look: look, inputs: current, onAction: onAction)
        }
    }

    private var current: TriggerSDUIInputs { Self.inputs(inputs, colorScheme: colorScheme, scenePhase: scenePhase) }

    /// Loops stop in the background as well as off screen; a `system` scheme follows the device.
    static func inputs(_ inputs: TriggerSDUIInputs, colorScheme: ColorScheme, scenePhase: ScenePhase) -> TriggerSDUIInputs {
        var current = inputs
        current.onScreen = inputs.onScreen && scenePhase != .background
        if let light = inputs.lightTheme, colorScheme == .light { current.theme = light }
        current.lightTheme = nil
        return current
    }

    /// Routes the tree's trigger actions to the host's scope.
    static func route(_ action: SDUIAction, scope: TriggerRenderScope) {
        switch action.type {
        case .trigger: scope.tapped(action.target ?? "card")
        case .dismissTrigger: scope.dismissed()
        default: break
        }
    }
}

@available(iOS 17.0, *)
internal struct TriggerSDUIView: View {
    let look: TriggerLook
    let inputs: TriggerSDUIInputs
    /// An action the tree fired (a tap, a dismiss), handed to the host.
    let onAction: (SDUIAction) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.encoreTriggerAlignment) private var alignment
    @Environment(\.encoreTriggerAppDirection) private var appDirection
    @Environment(\.layoutDirection) private var lookDirection
    @State private var appeared = false

    var body: some View {
        let scale = Self.fontScale(dynamicTypeSize, cap: inputs.maxFontScale)
        if let element = Self.decodeElement(Self.scaledFonts(look.root, by: scale)) {
            TriggerSDUIContextHost(element: element, inputs: inputs, onAction: onAction)
                .id(inputs.contextKey)
                // The host takes the container's width and places the look (capped by its root's
                // maxWidth) at the mount's alignment.
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment.horizontal(app: appDirection, look: lookDirection), vertical: .center))
                .frame(height: look.height)
                // The host fades the look in on first appearance; it is not authored.
                .opacity(appeared ? 1 : 0)
                .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
        }
    }

    /// The checked tree, decoded by the engine's own decoder (a failure draws nothing; the check
    /// already refused a tree that does not decode).
    static func decodeElement(_ root: JSONValue) -> SDUIElement? {
        TriggerLookCheck.decodeElement(root)
    }

    /// The user's text size as a factor of the default, capped at `cap`. The engine sizes text
    /// in fixed points, so this is the only scaling it gets, and the height never grows.
    static func fontScale(_ size: DynamicTypeSize, cap: Double) -> Double {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
        return min(scale, cap)
    }

    /// Every `font.size` in the tree times `scale`.
    static func scaledFonts(_ value: JSONValue, by scale: Double) -> JSONValue {
        guard scale != 1 else { return value }
        switch value {
        case .object(let fields):
            var scaled = fields.mapValues { scaledFonts($0, by: scale) }
            if case .object(var font)? = fields["font"], case .number(let size)? = font["size"] {
                font["size"] = .number(size * scale)
                scaled["font"] = .object(font.mapValues { scaledFonts($0, by: scale) })
            }
            return .object(scaled)
        case .array(let items):
            return .array(items.map { scaledFonts($0, by: scale) })
        default:
            return value
        }
    }

    /// An offer-less context whose `${...}` values come from the host first.
    @MainActor
    static func makeContext(_ inputs: TriggerSDUIInputs, onAction: @escaping (SDUIAction) -> Void) -> SDUIContext {
        let offerContext = OfferContext(uiValues: nil, copyOverrides: inputs.values, appearance: nil, servedLocale: nil)
        let context = SDUIContext(offers: [], currentIndex: nil, offerContext: offerContext) { action, _ in onAction(action) }
        context.appearance = inputs.theme.appearance
        context.values = inputs.values
        update(context, with: inputs)
        return context
    }

    /// What changes without rebuilding the context: the clock's keys, lists, state and motion.
    @MainActor
    static func update(_ context: SDUIContext, with inputs: TriggerSDUIInputs) {
        if context.triggerTimes != inputs.times { context.triggerTimes = inputs.times }
        if context.hostLists != inputs.lists { context.hostLists = inputs.lists }
        let state = inputs.busy ? "busy" : "idle"
        if context.currentState != state { context.currentState = state }
        // Motion runs through a tap: busy drives the busy styling only. It pauses off screen (a
        // sheet over the trigger counts) and in the background (vocab-contract §2.6).
        let paused = !inputs.onScreen
        if context.motionPaused != paused { context.motionPaused = paused }
    }
}

/// Owns the context for one set of values and palette (another claim, new copy rebuilds it).
@available(iOS 17.0, *)
private struct TriggerSDUIContextHost: View {
    let element: SDUIElement
    let inputs: TriggerSDUIInputs
    @StateObject private var context: SDUIContext
    /// Scale groups are scoped to this one tree.
    @StateObject private var scaleGroups = SDUIScaleGroups()

    init(element: SDUIElement, inputs: TriggerSDUIInputs, onAction: @escaping (SDUIAction) -> Void) {
        self.element = element
        self.inputs = inputs
        _context = StateObject(wrappedValue: TriggerSDUIView.makeContext(inputs, onAction: onAction))
    }

    var body: some View {
        SDUIElementRenderer(element: element, context: context, offer: nil, isCurrentPage: true)
            .environment(\.sduiAppearance, context.appearance)
            .environment(\.sduiMotionPaused, context.motionPaused)
            .environment(\.sduiScaleGroups, scaleGroups)
            .environment(\.sduiTriggerTree, true)
            .onChange(of: inputs) { _, next in TriggerSDUIView.update(context, with: next) }
    }
}
