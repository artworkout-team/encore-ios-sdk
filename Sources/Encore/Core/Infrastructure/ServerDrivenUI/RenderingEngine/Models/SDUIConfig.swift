//
//  SDUIConfig.swift
//  Encore
//
//  SDUI configuration root and presentation style
//

import Foundation

// MARK: - Presentation Style

/// Presentation style for the offer sheet
enum SDUIPresentationStyle: String, Decodable {
    case sheet = "sheet"
    case fullScreenCover = "fullScreenCover"
    
    /// Default presentation style if not specified
    static var `default`: SDUIPresentationStyle { .sheet }
}

// MARK: - Offer Link Presentation

/// How the offer-claim destination link is opened when the user taps "Claim".
/// Server-driven so it can be flipped remotely without an SDK update.
///
/// - `inAppSheet`: `SFSafariViewController` as a 0.95 `.sheet`. The default
///   when the field is absent, so control variants keep the old claim UX.
/// - `inAppBrowser`: `SFSafariViewController` as a `.fullScreenCover`.
/// - `external`: the system browser via `UIApplication.shared.open`.
/// - `inAppPreload`: a native claim screen on the tap, then a WKWebView loaded
///   behind it after the transaction starts (2.3.0+).
/// - `unrecognized`: a value this build does not know. Plays as `.default`
///   instead of throwing, which would drop the whole template.
enum SDUIOfferLinkPresentation: String, Decodable {
    case external = "external"
    case inAppBrowser = "inAppBrowser"
    case inAppSheet = "inAppSheet"
    case inAppPreload = "inAppPreload"
    /// Never on the wire; `SDUIValidationTests` fails a variant that decodes to it.
    case unrecognized = "__unrecognized__"

    /// Preserve the pre-redesign behavior when the field is unset: the old
    /// in-app Safari `.sheet` (0.95 detent + drag indicator).
    static var `default`: SDUIOfferLinkPresentation { .inAppSheet }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SDUIOfferLinkPresentation(rawValue: raw).flatMap { $0 == .unrecognized ? nil : $0 } ?? .unrecognized
    }

    /// The presentation this build actually runs.
    var resolved: SDUIOfferLinkPresentation {
        self == .unrecognized ? .default : self
    }
}

// MARK: - Config Root

struct SDUIConfig: Decodable {
    let version: String
    let root: SDUIElement
    var presentationStyle: SDUIPresentationStyle?
    var presentationDetents: [CGFloat]?
    var cornerRadius: CGFloat?
    var showDragIndicator: Bool?

    /// How the offer-claim destination link is opened. Server-driven, so a
    /// remote config value flips behavior with no app update. `nil` →
    /// `SDUIOfferLinkPresentation.default` (`.inAppSheet` — the old 0.95 in-app
    /// Safari sheet), so absent-field variants keep the pre-redesign behavior.
    var offerLinkPresentation: SDUIOfferLinkPresentation?

    /// The state whose entry starts loading the selected offer's link in the hidden
    /// `inAppPreload` web view, before the Continue tap (2.4.0+). Ignored for any other
    /// presentation; a non-string value decodes as absent rather than dropping the template.
    var preloadOfferLinkOnState: SDUILenientString?

    // NEW: State machine configuration
    /// Starting state for the UI (default: "default")
    var initialState: String?
    
    /// Initial key-value pairs for the values dictionary
    var initialValues: [String: String]?
    
    /// If true, pre-populate the `selectedOfferId` / `selectedAdvertiserName`
    /// / `selectedOfferLogoUrl` / `selectedOfferDescription` context values
    /// from the first offer before first render. Lets templates like
    /// `${selectedAdvertiserName}` resolve immediately without requiring the
    /// user to tap a card first.
    ///
    /// Backward-compat alias for `initialSelection: "first"`. When both are
    /// set, `initialSelection` wins.
    var autoSelectFirstOffer: Bool?

    /// Which offer to pre-select and scroll to on first render. One of
    /// `"first"`, `"middle"`, `"last"`, or an integer index. On init this
    /// writes the selection values for that offer (so `${selectedAdvertiserName}`
    /// etc. resolve) AND sets `currentIndex` so the carousel centers it.
    /// `"middle"` resolves to `offers[count / 2]`. Operates in DISPLAY space —
    /// i.e. over the list AFTER `offerDisplayOrder` is applied.
    var initialSelection: SDUIInitialSelection?

    /// Reorders how offers are DISPLAYED in the carousel, independent of the
    /// order the backend returned them. An array of ORIGINAL offer indices:
    /// the displayed list = `offers[idx]` for each valid, unique `idx` (skipping
    /// out-of-range/duplicate indices), then every remaining original offer
    /// appended in original order. Absent/empty → original order.
    ///
    /// Example: original `[o0,o1,o2,o3,o4]`, `offerDisplayOrder: [2,0,1]` →
    /// displayed `[o2,o0,o1,o3,o4]`. Combine with `initialSelection` (display
    /// space) to center a specific offer with chosen neighbors.
    var offerDisplayOrder: [Int]?

    /// Text lookup maps: mapName -> valueKey -> text template
    /// Example: { "answerTitles": { "expensive": "Don't pay yet. Get ${value} ${unit}" } }
    var textMaps: [String: [String: String]]?
    
    /// State-specific presentation detents
    /// Example: { "question": [0.5], "offers": [0.57, 0.95] }
    var stateDetents: [String: [CGFloat]]?
    
    /// State-specific actions that fire on state entry
    /// Example: { "iap": { "onEnter": { "type": "triggerIAP", "onSuccessState": "thankYou" } } }
    var stateActions: [String: SDUIStateActions]?

    /// Whether the SDUI content tree is inset by the device safe area by
    /// default (status bar / Dynamic Island / home indicator). Default `true`.
    /// Backgrounds that explicitly set `style.ignoresSafeArea = true` still
    /// extend edge-to-edge — the padding is applied at the content root, and
    /// per-element `ignoresSafeArea` breaks back out of it. Set `false` for
    /// layouts that manage their own insets.
    var respectsSafeArea: Bool?

    // MARK: - IAP-First Flow
    
    /// If true, trigger IAP immediately before showing any UI.
    /// On success, present the offer sheet with `initialState`.
    /// On cancel, dismiss without showing anything.
    var triggerIAPFirst: Bool?
}

// MARK: - Lenient String

/// A string field that decodes any other JSON type as absent, so a malformed
/// optional key costs that feature only, never the whole template.
struct SDUILenientString: Decodable, Equatable {
    let value: String?

    init(_ value: String?) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

// MARK: - Initial Selection

/// Which offer to pre-select on first render. Decodes from either a keyword
/// string (`"first"` / `"middle"` / `"last"`) or an integer index.
enum SDUIInitialSelection: Decodable {
    case first
    case middle
    case last
    case index(Int)

    /// Resolves to a concrete offer index, clamped to a valid range. Returns
    /// nil when there are no offers.
    func resolvedIndex(offerCount: Int) -> Int? {
        guard offerCount > 0 else { return nil }
        switch self {
        case .first: return 0
        case .middle: return offerCount / 2
        case .last: return offerCount - 1
        case .index(let i): return max(0, min(i, offerCount - 1))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .index(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            switch stringValue {
            case "first": self = .first
            case "middle": self = .middle
            case "last": self = .last
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "initialSelection must be 'first', 'middle', 'last', or an integer")
            }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "initialSelection must be a string keyword or integer index")
        }
    }
}

// MARK: - State Actions

/// Actions that can be triggered for a state
struct SDUIStateActions: Decodable {
    /// Action to execute when entering this state
    var onEnter: SDUIAction?
}

// MARK: - Action Lookup

extension SDUIConfig {
    /// Whether any button or state `onEnter` in this variant dispatches `type`.
    func containsAction(_ type: SDUIActionType) -> Bool {
        root.containsAction(type)
            || (stateActions?.values.contains { $0.onEnter?.type == type } ?? false)
    }

    /// A sheet's `trigger` or `dismissTrigger` is a dead button, so the variant validator fails it.
    var containsTriggerOnlyAction: Bool {
        containsAction(.trigger) || containsAction(.dismissTrigger)
    }

    /// The states that ask "Did you finish?": a `reportCompletion` button sits in
    /// that state's `stateEquals` branch. An `onEnter` never counts, since it fires
    /// with no tap. The prize is promised only in a variant that has one.
    var questionStates: Set<String> {
        var states = Set<String>()
        root.collectStates(firing: .reportCompletion, inState: nil, into: &states)
        return states
    }
}

extension SDUIElement {
    func containsAction(_ type: SDUIActionType) -> Bool {
        if ownAction?.type == type { return true }
        return children.contains { $0.containsAction(type) }
    }

    /// Records the enclosing `stateEquals` state of every button firing `type`.
    func collectStates(firing type: SDUIActionType, inState state: String?, into states: inout Set<String>) {
        if ownAction?.type == type, let state { states.insert(state) }
        if case .conditional(let conditional) = self {
            if case .stateEquals(let named) = conditional.condition {
                conditional.ifTrue.collectStates(firing: type, inState: named, into: &states)
                conditional.ifFalse?.collectStates(firing: type, inState: state, into: &states)
                return
            }
        }
        for child in children {
            child.collectStates(firing: type, inState: state, into: &states)
        }
    }

    private var ownAction: SDUIAction? {
        switch self {
        case .button(let button): return button.action
        case .slideButton(let button): return button.action
        default: return nil
        }
    }

    /// Every element rendered inside this one, including a style's overlay and
    /// background, which can hold buttons too.
    var children: [SDUIElement] {
        var result: [SDUIElement]
        switch self {
        case .button(let button): result = [button.content]
        case .vStack(let stack), .hStack(let stack), .zStack(let stack): result = stack.children
        case .scrollView(let scroll): result = [scroll.content]
        case .conditional(let conditional): result = [conditional.ifTrue] + (conditional.ifFalse.map { [$0] } ?? [])
        case .forEach(let forEach): result = [forEach.itemTemplate]
        case .group(let group): result = [group.content]
        case .toggle(let toggle): result = [toggle.label]
        case .marquee(let marquee): result = [marquee.content]
        case .asyncImage(let image): result = image.fallback.map { [$0] } ?? []
        default: result = []
        }
        if let style {
            result += [style.overlay, style.backgroundElement].compactMap { $0 }
        }
        return result
    }

    /// The element's own style, for the case that carries one.
    var style: SDUIStyle? {
        switch self {
        case .text(let e): return e.style
        case .systemImage(let e): return e.style
        case .asyncImage(let e): return e.style
        case .asyncVideo(let e): return e.style
        case .appIcon(let e): return e.style
        case .button(let e): return e.style
        case .vStack(let e), .hStack(let e), .zStack(let e): return e.style
        case .spacer(let e): return e.style
        case .shape(let e): return e.style
        case .gradient(let e): return e.style
        case .scrollView(let e): return e.style
        case .forEach(let e): return e.style
        case .group(let e): return e.style
        case .textField(let e): return e.style
        case .toggle(let e): return e.style
        case .slideButton(let e): return e.style
        case .confetti(let e): return e.style
        case .progress(let e): return e.style
        case .marquee(let e): return e.style
        case .conditional, .compactPageIndicator, .empty: return nil
        }
    }
}
