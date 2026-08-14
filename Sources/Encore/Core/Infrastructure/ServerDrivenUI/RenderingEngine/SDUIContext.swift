//
//  SDUIContext.swift
//  Encore
//
//  Runtime context for Server-Driven UI - state management, data binding, analytics
//

import SwiftUI

// MARK: - Context for Dynamic Data

class SDUIContext: ObservableObject {
    /// Offers in DISPLAY order. Starts as the backend-returned order; if the
    /// config specifies `offerDisplayOrder`, `initializeFromConfig` reorders
    /// this list (see `applyOfferDisplayOrder`). All downstream logic — forEach
    /// rows, page-dot count, `isSelectedOffer`, `currentIndex`/`initialSelection`,
    /// per-row `offerDominantColor`, scrollFade centeredness — reads this list,
    /// so it all operates in display space automatically. Selection actions
    /// carry the actual `Offer` object, so reordering never changes which
    /// underlying offer is claimed.
    private(set) var offers: [Offer]
    @Published var currentIndex: Int?
    let offerContext: OfferContext
    var onAction: (SDUIAction, Offer?) -> Void
    var onOfferVisible: ((Int) -> Void)?
    
    // Generic state machine
    @Published var currentState: String = "default"
    @Published var values: [String: String] = [:]
    
    // Text lookup maps from config (mapName -> valueKey -> text)
    var textMaps: [String: [String: String]] = [:]
    
    // State-specific presentation detents
    var stateDetents: [String: [CGFloat]] = [:]
    var defaultDetents: [CGFloat]?
    
    // State-specific actions (onEnter, etc.)
    var stateActions: [String: SDUIStateActions] = [:]

    /// When false, claimOffer buttons are disabled and grayed out
    @Published var isClaimEnabled: Bool = true

    // MARK: - Variant Tracking
    
    /// The assigned SDUI variant ID
    var variantId: String?
    
    /// The presentation ID for this session
    var presentationId: String?

    /// Publisher placement that opened this sheet. Stamped on every SDUI event
    /// so in-sheet interactions slice by placement like the offer events do.
    var placementId: String?
    
    /// Timestamp when the current state was entered (for state transition timing)
    private var stateEnteredAt: Date = Date()
    
    /// Count of state transitions in this session
    private(set) var stateTransitionCount: Int = 0
    
    /// Count of offers claimed in this session
    private(set) var offersClaimed: Int = 0
    
    /// Returns the variant context for analytics events
    var variantContext: SDUIVariantContext {
        SDUIVariantContext(
            variantId: variantId,
            useCase: offerContext.useCase,
            placementId: placementId
        )
    }
    
    init(
        offers: [Offer],
        currentIndex: Int? = 0,
        offerContext: OfferContext,
        onAction: @escaping (SDUIAction, Offer?) -> Void
    ) {
        self.offers = offers
        self.currentIndex = currentIndex
        self.offerContext = offerContext
        self.onAction = onAction
    }
    
    /// Initialize state machine from config
    /// - Parameter config: The SDUI configuration to initialize from
    /// - Returns: The onEnter action for the initial state, if any
    @discardableResult
    func initializeFromConfig(_ config: SDUIConfig) -> SDUIAction? {
        if let initialState = config.initialState {
            self.currentState = initialState
        }
        if let initialValues = config.initialValues {
            self.values = initialValues
        }
        // Reorder the displayed offers per the variant BEFORE resolving
        // selection/centering, so `initialSelection` and `currentIndex` are
        // display-space indices over the reordered list.
        if let order = config.offerDisplayOrder {
            self.offers = Self.applyOfferDisplayOrder(order, to: self.offers)
        }
        // Pre-populate selection values + center the chosen offer so templates
        // like ${selectedAdvertiserName} resolve on first render without
        // requiring a user tap, and the carousel opens on the right card.
        // Skips analytics — this is system setup, not a user action.
        // `initialSelection` wins over the legacy `autoSelectFirstOffer`
        // (which is equivalent to `initialSelection: "first"`).
        let selection: SDUIInitialSelection? = config.initialSelection
            ?? (config.autoSelectFirstOffer == true ? .first : nil)
        if let selection,
           let index = selection.resolvedIndex(offerCount: offers.count) {
            writeSelectionValues(for: offers[index], primaryKey: "selectedOfferId")
            self.currentIndex = index
        }
        if let textMaps = config.textMaps {
            self.textMaps = textMaps
        }
        if let stateDetents = config.stateDetents {
            self.stateDetents = stateDetents
        }
        if let stateActions = config.stateActions {
            self.stateActions = stateActions
        }
        self.defaultDetents = config.presentationDetents
        self.stateEnteredAt = Date()
        
        // Return onEnter action for initial state if it exists
        return stateActions[currentState]?.onEnter
    }
    
    /// Reorders `offers` into display order from a list of ORIGINAL indices.
    ///
    /// The result is: `offers[idx]` for each valid, not-yet-used `idx` in
    /// `order` (out-of-range and duplicate indices are skipped), followed by
    /// every remaining original offer that wasn't listed, in original order.
    /// An empty/all-invalid `order` returns the original list unchanged.
    /// Never drops a real offer and never crashes on bad indices.
    ///
    /// Example: offers `[o0,o1,o2,o3,o4]`, order `[2,0,1]` → `[o2,o0,o1,o3,o4]`.
    static func applyOfferDisplayOrder(_ order: [Int], to offers: [Offer]) -> [Offer] {
        guard !order.isEmpty else { return offers }
        var used = Set<Int>()
        var result: [Offer] = []
        result.reserveCapacity(offers.count)
        for idx in order where offers.indices.contains(idx) && !used.contains(idx) {
            used.insert(idx)
            result.append(offers[idx])
        }
        // Append every offer not explicitly placed, preserving original order.
        for (idx, offer) in offers.enumerated() where !used.contains(idx) {
            result.append(offer)
        }
        return result
    }

    /// Set variant metadata from config manager
    func setVariantMetadata(variantId: String?, presentationId: String?, placementId: String?) {
        self.variantId = variantId
        self.presentationId = presentationId
        self.placementId = placementId
    }
    
    /// Get detents for the current state, falling back to default detents
    func currentDetents() -> [CGFloat]? {
        return stateDetents[currentState] ?? defaultDetents
    }
    
    /// Display position of the committed selection, if it is still in the list.
    var selectedOfferIndex: Int? {
        guard let id = values["selectedOfferId"] else { return nil }
        return offers.firstIndex { $0.id == id }
    }

    /// The offer the user has committed to, resolved by `selectedOfferId`
    /// against the display list.
    ///
    /// This is the durable half of the selection: it lives in `values`, so it
    /// survives scrolling, state transitions and view teardown. `currentIndex`
    /// does not.
    var selectedOffer: Offer? {
        selectedOfferIndex.map { offers[$0] }
    }

    /// The card the carousel is resting on, for everything that renders
    /// "which card is in focus": the scroll position binding, the coverflow
    /// zIndex, the page indicator, `isCurrentPage`.
    ///
    /// Live scroll position first, committed selection second. `currentIndex`
    /// is only meaningful while a carousel is mounted and has told us where it
    /// settled; re-entering a state remounts it with no position, and the raw
    /// `currentIndex ?? 0` those call sites used meant the carousel silently
    /// rewound to the first card while the highlight and the CTA still named
    /// the offer the user had picked. Falling back to the selection makes the
    /// carousel open ON that offer instead — the screen agrees with itself on
    /// entry rather than after the first scroll.
    var focusedIndex: Int? {
        currentIndex ?? selectedOfferIndex
    }

    /// The offer every offer-scoped binding and every action resolves against
    /// outside a `forEach` row.
    ///
    /// **Selection first, scroll position second.** `currentIndex` is owned by
    /// SwiftUI's `.scrollPosition(id:)` binding, which reports `nil` whenever
    /// the bound scroll view has no resolvable target — so it is a rendering
    /// artifact, not a record of what the user picked. Reading it first is what
    /// left `offerPerk`/`offerLogoImage` blank on the congrats screen and made
    /// the claim button inert after `congrats → browseOffers → congrats`: the
    /// index had been cleared, `currentOffer` went nil, and every downstream
    /// read resolved against nothing. The index fallback is kept for variants
    /// that never write a selection at all (no `initialSelection`, no
    /// `selectOffer`), where the centred card is genuinely the only signal.
    var currentOffer: Offer? {
        if let selectedOffer { return selectedOffer }
        guard let index = currentIndex, offers.indices.contains(index) else { return nil }
        return offers[index]
    }

    func resolveText(_ binding: SDUITextBinding) -> String {
        switch binding {
        case .offerAdvertiserName:
            return currentOffer?.advertiserName ?? ""
        case .offerDescription:
            return currentOffer?.creativeAdvertiserDescription ?? ""
        case .offerPerk:
            return currentOffer?.perk ?? ""
        case .offerCtaText:
            return currentOffer?.displayCtaText ?? "Get"
        case .titleText:
            return offerContext.titleText ?? "Get 1 month"
        case .accentTitleText:
            return offerContext.accentTitleText ?? " for free"
        case .subtitleText:
            return offerContext.subtitleText ?? "Claim an exclusive offer and get free access to all features"
        }
    }
    
    func resolveCreativeUrl(_ binding: SDUICreativeBinding, for offer: Offer? = nil) -> String? {
        let targetOffer = offer ?? currentOffer
        switch binding {
        case .offerPrimaryCreative:
            return targetOffer?.displayPrimaryImageUrl
        case .offerLogoImage:
            return targetOffer?.displayLogoUrl
        }
    }
    
    /// Creates a TemplateText that resolves `${variableName}` placeholders.
    /// All properties on `offerContext` (RemoteConfig + IAPContext) are available as placeholders.
    ///
    /// Examples:
    /// - `"Get ${trialValue} ${trialUnit} of ${appName}"` → "Get 1 month of Tinder Plus"
    /// - `"Get ${trialValue} ${trialUnit} of ${appName}"` → "Get 1 month of Tinder Plus" (using aliases)
    /// - `"${accentTitleText}"` → " for free"
    /// - `"Subscribe - ${subscriptionPrice}/month"` → "Subscribe - $4.99/month" (from IAP product info)
    /// - `"Try ${trialDuration} free"` → "Try 7 days free" (from IAP free trial offer)
    /// - `"Get ${trialValue} ${trialUnit} free trial"` → "Get 7 days free trial" (IAP trial overrides native config)
    ///
    /// Note: When IAP has a free trial, `${value}` and `${unit}` use the trial duration from StoreKit,
    /// overriding any native entitlement configuration. If no IAP trial exists, they fall back to
    /// native entitlement values.
    func templateText(_ text: String) -> TemplateText {
        TemplateText(text, context: offerContext)
    }
    
    /// Resolves template placeholders in the given text.
    ///
    /// Resolution order: `offerContext.allVariables` first (remote config +
    /// IAP data), then falls back to `context.values` (state machine values
    /// like `selectedAdvertiserName`). This lets variant authors write
    /// `${selectedAdvertiserName}` in bottom-copy text and have it update
    /// dynamically when the user taps a different offer card.
    func resolveTemplateText(_ text: String) -> String {
        let firstPass = templateText(text).resolved
        // Most templates resolve fully on the first pass; bail before a
        // second O(|values|) scan unless ${...} tokens actually remain.
        guard firstPass.contains("${") else { return firstPass }

        var result = firstPass
        for (key, value) in values {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }
    
    // MARK: - State Machine Methods
    
    /// Resolve text from a text map based on a stored value
    /// - Parameters:
    ///   - mapKey: The name of the text map to use (e.g., "answerTitles")
    ///   - valueKey: The key in the values dictionary to look up (defaults to mapKey if not specified)
    /// - Returns: The resolved text with template placeholders substituted, or nil if not found
    func resolveTextMap(mapKey: String, valueKey: String? = nil) -> String? {
        let lookupKey = valueKey ?? mapKey
        guard let storedValue = values[lookupKey],
              let map = textMaps[mapKey],
              let text = map[storedValue] else {
            return nil
        }
        return resolveTemplateText(text)
    }
    
    /// Set the current state with analytics tracking
    /// Transition to a new state
    /// - Parameter newState: The state to transition to
    /// - Returns: The onEnter action for the new state, if any
    @discardableResult
    func setState(_ newState: String) -> SDUIAction? {
        let previousState = currentState
        let timeInPreviousState = Date().timeIntervalSince(stateEnteredAt) * 1000 // Convert to ms
        
        currentState = newState
        stateEnteredAt = Date()
        stateTransitionCount += 1
        
        // `SDUIStateTransitionEvent` is the canonical screen-view signal — it
        // carries `fromState`, `toState`, and `timeInPreviousStateMs`, which
        // lets downstream funnel analysis filter on `variantId` and derive the
        // screen-viewed event without a duplicate.
        trackStateTransition(from: previousState, to: newState, timeInPreviousStateMs: timeInPreviousState)

        return stateActions[newState]?.onEnter
    }
    
    /// Set a value in the values dictionary with analytics tracking
    func setValue(key: String, value: String) {
        values[key] = value

        // Track value set
        trackValueSet(key: key, value: value)
    }

    /// User-initiated offer selection. Emits a single `SDUIValueSetEvent`
    /// on the primary key (carries the campaignId — the one fact analytics
    /// needs to answer "which offer did the user pick"). The derivative
    /// fields are template-rendering conveniences — written to `values` so
    /// `${selectedAdvertiserName}` etc. resolve, but not instrumented; the
    /// campaignId on the primary event is enough to join them downstream.
    func selectOffer(_ offer: Offer, primaryKey: String = "selectedOfferId") {
        writeSelectionValues(for: offer, primaryKey: primaryKey)
        // Move the carousel onto the tapped card. Without this a tap wrote the
        // selection while `currentIndex` stayed on whatever was centred, so the
        // CTA named one advertiser and the claim button targeted another.
        if let index = offers.firstIndex(where: { $0.id == offer.id }) {
            currentIndex = index
        }
        trackValueSet(key: primaryKey, value: offer.id)
    }

    /// Publishes the COMPLETE selection snapshot for `offer`. Direct writes
    /// without analytics — used by `initializeFromConfig` to pre-seed selection
    /// state before `presentationId` is even set, and by `selectOffer` /
    /// `selectCenteredOffer`, so all three paths publish the same key set.
    ///
    /// Every key is written or REMOVED, never left behind: assigning `nil` to a
    /// Swift dictionary subscript deletes the entry. Writing only `if let` (as
    /// this did) left the previous advertiser's logo and description in
    /// `values` when the newly selected offer had none — a stale brand on
    /// screen, which is worse than a placeholder.
    func writeSelectionValues(for offer: Offer, primaryKey: String) {
        values[primaryKey] = offer.id
        values["selectedAdvertiserName"] = offer.organization.name
        values["selectedOfferLogoUrl"] = offer.displayLogoUrl
        values["selectedOfferDescription"] = offer.creativeAdvertiserDescription
        values["selectedOfferPerk"] = offer.perk
        // Variants gate free-trial copy ("free month", "$0 today", "no payment
        // now") on this key. It had no producer in either SDK, so the gate could
        // never match and every offer — including flat discounts — rendered the
        // free-trial branch. A missing `badgeLabel` means the backend did not
        // label this offer a free trial, so it publishes "false": never promise
        // a free month the offer doesn't carry.
        values["selectedOfferIsFreeTrial"] = offer.isFreeTrialOffer ? "true" : "false"
    }

    /// Sync the SELECTED offer to the card the carousel has settled on, so the
    /// centered card is always the selected offer. Called when `currentIndex`
    /// changes via the `.scrollPosition(id:)` binding — the user swiped rather
    /// than tapped. Uses the direct, NON-analytics write (`writeSelectionValues`)
    /// because a scroll must not emit a per-card `SDUIValueSetEvent`; the only
    /// scroll signal is `trackScroll`. Indexes into `offers`, the reordered
    /// display list (same order the carousel renders and `currentOffer` reads),
    /// and is a no-op for an out-of-range index or empty list.
    func selectCenteredOffer(at index: Int, primaryKey: String = "selectedOfferId") {
        guard offers.indices.contains(index) else { return }
        writeSelectionValues(for: offers[index], primaryKey: primaryKey)
    }

    /// The logo URL of the currently-selected offer (by `selectedOfferId`),
    /// used to resolve `selectedOfferDominantColor` bindings at render time.
    /// Falls back to the carousel's current offer when nothing is selected.
    var selectedOfferLogoUrl: String? {
        if let selectedOffer { return selectedOffer.displayLogoUrl }
        return values["selectedOfferLogoUrl"] ?? currentOffer?.displayLogoUrl
    }
    
    /// Get a value from the values dictionary
    func getValue(key: String) -> String? {
        return values[key]
    }
    
    /// Check if the current state matches the given state
    func isState(_ state: String) -> Bool {
        return currentState == state
    }
    
    /// Check if a value equals a specific value
    func valueEquals(key: String, value: String) -> Bool {
        return values[key] == value
    }
    
    /// Check if a value exists for the given key
    func hasValue(key: String) -> Bool {
        return values[key] != nil
    }
    
    /// Increment the offers claimed counter
    func incrementOffersClaimed() {
        offersClaimed += 1
    }
    
    // MARK: - Analytics Tracking Methods
    
    /// Track a state transition event
    private func trackStateTransition(from: String, to: String, timeInPreviousStateMs: Double) {
        guard let presentationId = presentationId else { return }
        
        let event = SDUIStateTransitionEvent(
            variant: variantContext,
            fromState: from,
            toState: to,
            presentationId: presentationId,
            timeInPreviousStateMs: timeInPreviousStateMs
        )
        analyticsClient?.track(event)
    }
    
    /// Track a value set event
    private func trackValueSet(key: String, value: String) {
        guard let presentationId = presentationId else { return }
        
        let event = SDUIValueSetEvent(
            variant: variantContext,
            key: key,
            value: value,
            presentationId: presentationId
        )
        analyticsClient?.track(event)
    }
    
    /// Track a button tap event
    func trackButtonTap(actionType: SDUIActionType) {
        guard let presentationId = presentationId else { return }
        
        let event = SDUIButtonTappedEvent(
            variant: variantContext,
            actionType: actionType.rawValue,
            presentationId: presentationId,
            currentState: currentState
        )
        analyticsClient?.track(event)
    }
    
    /// Track a scroll event
    func trackScroll(axis: SDUIScrollAxis, position: Int) {
        guard let presentationId = presentationId else { return }
        
        let event = SDUIScrollEvent(
            variant: variantContext,
            scrollAxis: axis.rawValue,
            scrollPosition: position,
            presentationId: presentationId
        )
        analyticsClient?.track(event)
    }

    // MARK: - Appearance

    /// Current app appearance, built once from the session's immutable
    /// `UIValues`. Use this from imperative renderer paths
    /// (`SDUIElementRenderer`) where SwiftUI's `@Environment(\.sduiAppearance)`
    /// isn't available. `ViewModifier`s continue reading from the environment
    /// for consistency and to pick up any env-level overrides.
    lazy var appearance: Appearance = Appearance(from: offerContext.uiValues)

    /// Resolves an optional `SDUIColor` against the current appearance and the
    /// state-machine values dictionary (so `{"binding": "..."}` colors resolve).
    /// Convenience wrapper for terse call sites:
    /// `context.resolveColor(config.color) ?? fallback`.
    ///
    /// - Parameter extraValues: per-render overrides merged on top of `values`
    ///   (e.g. row-scoped `offerDominantColor` / `selectedOfferDominantColor`).
    func resolveColor(_ color: SDUIColor?, extraValues: [String: String]? = nil) -> Color? {
        guard let color else { return nil }
        let merged: [String: String]
        if let extraValues, !extraValues.isEmpty {
            merged = values.merging(extraValues) { _, new in new }
        } else {
            merged = values
        }
        return color.resolved(in: appearance, values: merged)
    }
}
