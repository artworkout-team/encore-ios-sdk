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
/// - `inAppSheet`: present the link in an in-app browser
///   (`SFSafariViewController`) shown as a `.sheet` at a `0.95` detent with a
///   visible drag indicator. This is the historical (pre-redesign) behavior and
///   the default when the field is ABSENT — so existing/control variants that
///   never set the field keep the old claim UX, completion timing, and Safari
///   analytics.
/// - `inAppBrowser`: present the link in an in-app browser as a full-screen
///   `.fullScreenCover` (no detent / drag indicator) — an opt-in.
/// - `external`: open the user's actual (system) browser via
///   `UIApplication.shared.open`.
///
/// Decodes from the strings `"external"` / `"inAppBrowser"` / `"inAppSheet"`.
enum SDUIOfferLinkPresentation: String, Decodable {
    case external = "external"
    case inAppBrowser = "inAppBrowser"
    case inAppSheet = "inAppSheet"

    /// Preserve the pre-redesign behavior when the field is unset: the old
    /// in-app Safari `.sheet` (0.95 detent + drag indicator).
    static var `default`: SDUIOfferLinkPresentation { .inAppSheet }
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
