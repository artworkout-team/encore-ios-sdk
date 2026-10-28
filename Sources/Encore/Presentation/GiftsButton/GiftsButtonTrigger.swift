// GiftsButton as a plug-in of the generic trigger host: a button shown only while the sheet it
// opens has offers. A look whose behavior says so also opens that sheet once by itself.

import SwiftUI

/// What a GiftsButton view draws, and the offers it would open.
internal struct GiftsButtonShown: Equatable {
    let config: GiftsButtonConfig
    let theme: TriggerTheme
    let offers: TriggerSheetOffers
    /// The pop's local day and placement, for its once-a-day claim.
    var autoDay: (day: String, placement: String)? = nil
    /// The palette for a light device when the scheme follows the device.
    var lightTheme: TriggerTheme? = nil
    /// `${icon}` and `${appIconUrl}`.
    var iconValues: [String: String] = TriggerIcon.gift.values(portal: nil)
    /// `${values.K}`: the mount's value over the look's default.
    var publisherValues: [String: String] = [:]
    /// The DEBUG demo's text edits and the app's slot text; empty otherwise.
    var stringOverrides: [String: String] = [:]
    /// The slots drawn with the app's text, sorted (S-8).
    var textSlots: [String] = []
    /// `${isNew}`: a held campaign this placement's last counted impression did not hold. Frozen as presented.
    var isNew = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.config == rhs.config && lhs.theme == rhs.theme && lhs.offers == rhs.offers
            && lhs.lightTheme == rhs.lightTheme && lhs.iconValues == rhs.iconValues && lhs.publisherValues == rhs.publisherValues
            && lhs.stringOverrides == rhs.stringOverrides && lhs.textSlots == rhs.textSlots && lhs.isNew == rhs.isNew
            && lhs.autoDay?.day == rhs.autoDay?.day && lhs.autoDay?.placement == rhs.autoDay?.placement
    }
}

/// GiftsButton's ties to the rest of the SDK, injectable for tests.
@MainActor
internal struct GiftsButtonEnvironment {
    var sheet: TriggerSheet
    /// Whether an Encore sheet is up (or loading), so an auto pop must wait.
    var sheetBusy: @MainActor () -> Bool = { false }
    /// Whether the app is active: a pop waiting behind another sheet presents only then.
    var isActive: @MainActor () -> Bool = { true }
    var storage: KeyValueStore
    var calendar: Calendar
    /// How a pop blocked behind another open sheet waits: retry every interval, up to attempts
    /// (1 s for up to 60 s on every platform), then gives up without spending the day's pop.
    var blockedRetry: (intervalNanoseconds: UInt64, attempts: Int) = (1_000_000_000, 60)
    /// The current user's claim log, for `afterComplete`. Nil: nothing hides or thanks.
    var claimLog: @MainActor () -> (log: ClaimLog, userId: String)? = { nil }
    /// The current user, whose tally is read and counted. Nil (before configure): none at all.
    var tallyOwner: @MainActor () -> GiftsButtonTally.Owner? = { nil }

    var tally: GiftsButtonTally { GiftsButtonTally(storage: storage, calendar: calendar) }
}

@MainActor
internal struct GiftsButtonTrigger: TriggerPlugin {
    static let id = "giftsButton"
    static let pinnableLayouts = Set(GiftsButtonLayout.allCases.map(\.rawValue))
    /// The gifts button look alone; the mount that may draw the reminder is ``GiftsSpotTrigger``.
    static let renders: Set<String> = []
    /// Click targets on `sdk_trigger_clicked`.
    static let buttonTarget = "button"
    static let autoTarget = "auto"

    let environment: GiftsButtonEnvironment
    /// This mount's own state; each plug-in value the registry builds is one mount.
    let mount = GiftsButtonMount()

    // MARK: Request

    /// A pinned look, else the managed look; `autoOpen: .off` rides on the request so the server
    /// never assigns a look that opens by itself. A pin never opens by itself, so it sends none.
    func request(for settings: TriggerMountSettings) -> TriggerRequest? {
        if let layout = settings.layout {
            guard Self.pinnableLayouts.contains(layout) else {
                TriggerLog.once("\(Self.id).layout.\(layout)", "\(Self.id): unknown layout '\(layout)'; rendering nothing")
                return nil
            }
            return TriggerRequest(useCase: settings.useCase, layout: layout)
        }
        return TriggerRequest(useCase: settings.useCase, autoOpenOff: settings.autoOpen == .off)
    }

    /// Whether a look may open the sheet by itself on this mount: not when it passed `.off` or
    /// pinned a layout. The look's behavior and the device's limits then decide.
    static func mayPop(_ settings: TriggerMountSettings) -> Bool {
        settings.layout == nil && settings.autoOpen != .off
    }

    /// The tally, on every managed request (a layout pin never nudges, so it sends none).
    func tally(for request: TriggerRequest, placement: String, now: Date) -> TriggerTally? {
        guard request.layout == nil, let owner = environment.tallyOwner() else { return nil }
        return environment.tally.request(placement: placement, owner: owner, now: now)
    }

    /// A counted impression: the day, the mount, the campaigns it held, and a nudge when the server
    /// answered with its `ifIgnored` step.
    func impressed(_ model: GiftsButtonShown, variant: TriggerVariant, placement: String, now: Date) {
        guard let owner = environment.tallyOwner() else { return }
        environment.tally.recordImpression(
            placement: placement, owner: owner, now: now, campaignIds: model.offers.campaignIds,
            nudge: variant.step == TriggerWire.Step.ifIgnored
        )
    }

    /// A look that fails the strict check.
    func unrenderable(_ config: GiftsButtonConfig, settings: TriggerMountSettings) -> TriggerUnrenderable? {
        if case .failure(let failure)? = config.look { return failure }
        return nil
    }

    // MARK: Gate

    /// Offers for the sheet this button opens. Without them nothing renders and `/config` is
    /// skipped; a sheet the server would not serve this user is reported as not shown.
    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<TriggerSheetOffers> {
        let mode = AfterComplete(settings: context.settings)
        // Read only when the mode needs it (and by the DEBUG trace).
        func completedToday() -> Bool {
            environment.claimLog().map { $0.log.completedToday(userId: $0.userId, calendar: environment.calendar, now: context.now) } ?? false
        }
        let hidden = mode == .hide && completedToday()
        #if DEBUG
        EncoreDebugTrace.record("afterComplete.decision", [
            "placement": context.placement, "mode": mode.rawValue, "completedToday": String(completedToday()),
            "result": hidden ? "hidden" : thanksDue(context) ? "thanks" : "gifts",
        ])
        #endif
        // `.hide` after a completion today: nothing, silently, and no offers search.
        if hidden { return .nothing }
        switch await environment.sheet.eligibility(context.settings.useCase, context.placement) {
        case .offers(let offers): return .show(offers)
        case .none: return .nothing
        case .sheetUnavailable: return .notShown(reason: TriggerWire.NotShownReason.sheetUnavailable)
        }
    }

    /// The thanks state, which ``EncoreClaim`` reads too.
    func thanksDue(_ context: TriggerPrepareContext) -> Bool {
        guard AfterComplete(settings: context.settings) == .thanks, let claims = environment.claimLog() else { return false }
        return claims.log.thanksDue(userId: claims.userId, calendar: environment.calendar, now: context.now)
    }

    /// The thanks look was tapped: it ends for this completion. The refresh after the sheet draws gifts.
    func thanksTapped() {
        guard let claims = environment.claimLog() else { return }
        claims.log.markThanksTapped(userId: claims.userId, calendar: environment.calendar)
    }

    func decode(_ template: GiftsButtonTemplate) -> GiftsButtonConfig? {
        GiftsButtonConfig(template: template)
    }

    // MARK: Present

    /// The served look, drawn. A look whose `behavior.autoOpen` is `on` also opens the sheet once by
    /// itself (the host's auto tap): one decision per mount, at most one per placement per local day
    /// (`claimAutoTap`), never on the thanks look, and the look stays drawn throughout.
    func present(_ offers: TriggerSheetOffers, config: GiftsButtonConfig, context: TriggerPresentContext) -> TriggerPresentation<GiftsButtonShown>? {
        guard offers.offerCount > 0 else { return nil }
        let themes = TriggerThemes.resolve(appearance: context.appearance, portal: context.portal, colors: config.colors, lightColors: config.lightColors)
        var shown = GiftsButtonShown(config: config, theme: themes.primary, offers: offers)
        shown.lightTheme = themes.light
        shown.iconValues = context.settings.icon.values(portal: context.portal)
        shown.publisherValues = TriggerValues.publisher(mount: context.values, defaults: config.valueDefaults)
        let text = TriggerTextSlots.overrides(slots: config.textSlots, texts: context.texts)
        shown.stringOverrides = text.strings.merging(context.stringOverrides) { _, edit in edit }
        shown.textSlots = text.drawn
        let pops = !config.isStateLook && config.autoOpen && Self.mayPop(context.settings) && !mount.autoSettled
        if pops { shown.autoDay = (dayKey(context.now), context.placement) }
        shown.isNew = isNew(offers, placement: context.placement)
        var presentation = button(shown, context: context)
        // A look that fails the strict check draws nothing, so it never pops either.
        if pops, presentation.unrenderable == nil { presentation.autoTap = Self.autoTarget }
        return presentation
    }

    /// A drawn layout. The impression means "saw it today": the key rolls at local midnight. The
    /// thanks look is keyed by the completion it thanks, so each completion's thanks counts its own
    /// impression (as on Android and EncoreClaim).
    private func button(_ shown: GiftsButtonShown, context: TriggerPresentContext) -> TriggerPresentation<GiftsButtonShown> {
        let look = shown.config.look
        var unrenderable: TriggerUnrenderable?
        if case .failure(let failure)? = look { unrenderable = failure }
        // The thanks state ends at midnight: run the gate (and its request) again then, not just re-present.
        let regateAt = shown.config.layout == .thanks ? nextMidnight(after: context.now) : nil
        return TriggerPresentation(
            model: shown, height: (try? look?.get())?.height ?? 0, maxWidth: (try? look?.get())?.maxWidth,
            contentKey: contentKey(shown, context: context),
            eventFields: TriggerEventFields(layout: shown.config.eventLayout, textSlots: shown.textSlots.isEmpty ? nil : shown.textSlots),
            dismissible: false,
            refreshAt: nextMidnight(after: context.now), regateAt: regateAt, staleAt: shown.offers.heldUntil,
            unrenderable: unrenderable
        )
    }


    /// Whether a held campaign was not in the placement's last counted impression; never on the first.
    /// Read once per held set on this mount, so the look's own impression does not flip it while drawn.
    private func isNew(_ offers: TriggerSheetOffers, placement: String) -> Bool {
        let held = Set(offers.campaignIds.map { $0.lowercased() })
        if let frozen = mount.isNew, frozen.campaignIds == held { return frozen.value }
        let shown = environment.tallyOwner().map { environment.tally.lastShownCampaignIds(placement: placement, owner: $0) } ?? []
        let last = Set(shown)
        let value = !last.isEmpty && !held.isSubset(of: last)
        mount.isNew = (held, value)
        return value
    }

    /// `placement|day`, or for thanks `placement|thanks|<completion>`.
    func contentKey(_ shown: GiftsButtonShown, context: TriggerPresentContext) -> String {
        guard shown.config.layout == .thanks else { return "\(context.placement)|\(dayKey(context.now))" }
        let completion = environment.claimLog().flatMap {
            $0.log.thanksCompletion(userId: $0.userId, calendar: environment.calendar, now: context.now)
        }
        return "\(context.placement)|thanks|\(completion ?? dayKey(context.now))"
    }

    // MARK: Tap

    func opensSheet(_ model: GiftsButtonShown, target: String) -> Bool { true }

    /// Check and reserve the day in one main-actor step, so two mounts never both pop. Only a
    /// pop whose sheet shows spends the day; one that never shows (blocked past the wait, no
    /// offers by then, an error, a user change, the view gone) gives it back.
    func claimAutoTap(_ model: GiftsButtonShown, target: String) -> TriggerAutoTapClaim {
        claimAutoDay(model.autoDay)
    }

    /// ``claimAutoTap(_:target:)`` for any mount over this button's days (the app's own view too).
    func claimAutoDay(_ autoDay: (day: String, placement: String)?) -> TriggerAutoTapClaim {
        // Popped or held, this mount never pops again: from here on the look is only tapped.
        mount.autoSettled = true
        guard let auto = autoDay else { return .held(reason: TriggerWire.NotShownReason.autoHeld) }
        let key = Self.autoDayKey(placement: auto.placement)
        let previous: String? = environment.storage.load(key)
        // Already popped today for this placement: held, and reported as such.
        guard previous != auto.day else { return .held(reason: TriggerWire.NotShownReason.autoHeld) }
        environment.storage.save(auto.day, to: key)
        mount.reservation = GiftsButtonReservation(key: key, day: auto.day, previous: previous)
        return .fire
    }

    /// The pop never ran: give the day back and let this mount decide again.
    func autoTapAborted(_ model: GiftsButtonShown) { abortPop() }

    /// ``autoTapAborted(_:)`` for any mount over this button's days.
    func abortPop() {
        if let pending = mount.reservation { release(pending) }
        mount.autoSettled = false
    }

    /// A new user gets their own pop decision; the per-placement daily cap still holds. A pop
    /// still waiting gives its day back now, before the new user's own pop is decided.
    func identityChanged() {
        mount.autoSettled = false
        mount.isNew = nil
        if let pending = mount.reservation { release(pending) }
    }

    /// Opens the sheet under the click's presentation id, then re-checks the offers.
    func onTap(_ model: GiftsButtonShown, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        if target != Self.autoTarget, let owner = environment.tallyOwner() {
            environment.tally.recordTap(placement: context.placement, owner: owner, now: context.now)
        }
        return await open(model.offers, target: target, isThanks: model.config.layout == .thanks, context: context)
    }

    /// Opens the sheet for `offers` (a pop waits behind another sheet and spends the day only once its
    /// sheet shows), then re-checks them. Shared with the app's own view (``CustomGiftsTrigger``).
    func open(_ offers: TriggerSheetOffers, target: String, isThanks: Bool, context: TriggerTapContext) async -> TriggerTapOutcome {
        // This pop's own reservation: a later one on the same mount is never released by it.
        let reservation = target == Self.autoTarget ? mount.reservation : nil
        // Once its sheet shows, the day is spent: nothing gives it back from then on.
        var showingObserver: NSObjectProtocol?
        if let reservation, let presentationId = context.presentationId {
            let mount = mount
            showingObserver = NotificationCenter.default.addObserver(forName: .encoreSheetShowingDidChange, object: nil, queue: nil) { note in
                guard note.userInfo?["presentationId"] as? String == presentationId else { return }
                MainActor.assumeIsolated {
                    if mount.reservation?.token == reservation.token { mount.reservation = nil }
                }
            }
        }
        defer { showingObserver.map(NotificationCenter.default.removeObserver) }
        // The user opened the sheet themselves (the thanks card draws before any pop): this mount's
        // pop is settled, so closing that sheet never pops a second one. The day is not spent.
        if target != Self.autoTarget { mount.autoSettled = true }
        if isThanks { thanksTapped() }
        let request = TriggerSheetRequest(placement: context.placement, useCase: offers.useCase)
        let result = target == Self.autoTarget
            ? await presentWhenFree(request, context: context)
            : await context.presentSheet(request)
        if let reservation {
            if case .notPresented = result {
                // A sheet that showed already cleared the reservation, so this releases only a pop that never showed.
                release(reservation)
            } else if mount.reservation?.token == reservation.token {
                mount.reservation = nil
            }
        }
        // The user changed while the sheet was up: its offers are not the current user's.
        guard context.isSameIdentity() else { return .keep }
        // A sheet that showed is cleaned up even when its mount has gone meanwhile.
        await environment.sheet.closed(offers)
        return context.isCurrent() ? .refresh : .keep
    }

    /// A pop blocked behind another open sheet waits for it, so this placement does not lose
    /// its pop for the day: it asks for the sheet only while none is up (a blocked ask would
    /// record an aborted show and an outcome each time), every interval up to the limit, and
    /// gives up on a user change or the view going away.
    private func presentWhenFree(_ request: TriggerSheetRequest, context: TriggerTapContext) async -> PresentationResult {
        var attempts = 0
        while true {
            if !environment.sheetBusy(), environment.isActive() {
                let result = await context.presentSheet(request)
                if result != .notPresented(.alreadyPresenting) { return result }
            }
            guard attempts < environment.blockedRetry.attempts, context.isCurrent() else { break }
            attempts += 1
            try? await Task.sleep(nanoseconds: environment.blockedRetry.intervalNanoseconds)
            guard context.isCurrent() else { break }
        }
        return .notPresented(.alreadyPresenting)
    }

    /// The pop never presented: give the day back, unless another pop has taken it since.
    private func release(_ reservation: GiftsButtonReservation) {
        guard mount.reservation?.token == reservation.token else { return }
        mount.reservation = nil
        guard (environment.storage.load(reservation.key) as String?) == reservation.day else { return }
        if let previous = reservation.previous {
            environment.storage.save(previous, to: reservation.key)
        } else {
            environment.storage.remove(reservation.key)
        }
    }

    // MARK: Render

    @ViewBuilder
    func render(_ model: GiftsButtonShown, scope: TriggerRenderScope) -> some View {
        if case .success(let look)? = model.config.look {
            TriggerLookView(look: look, inputs: Self.inputs(model, scope: scope)) { TriggerLookView.route($0, scope: scope) }
        }
    }

    /// GiftsButton hands its look copy, the held offers (count, perk, isNew) and their logos; no times
    /// (vocab-contract §2). A perk or isNew it does not have is absent, so `hasValue` reads false.
    static func inputs(_ model: GiftsButtonShown, scope: TriggerRenderScope) -> TriggerSDUIInputs {
        let logos = model.offers.logos.prefix(TriggerSheetOffers.maxLogos).map { logo in
            ["logoUrl": logo.logoUrl, "advertiserName": logo.advertiserName,
             "advertiserInitial": logo.advertiserName.first.map { String($0).uppercased() } ?? "", "perk": logo.perk]
        }
        let columns = TriggerSDUIInputs.columns(Array(logos))
        var offers = ["offerCount": String(model.offers.offerCount)]
        if let perk = model.offers.perk { offers["perk"] = perk }
        if model.isNew { offers["isNew"] = "1" }
        return TriggerSDUIInputs(
            values: model.config.strings.values(layout: model.config.layout, publisher: model.publisherValues, overrides: model.stringOverrides)
                .merging(model.iconValues) { _, icon in icon }
                .merging(offers) { _, held in held },
            theme: TriggerSDUITheme(model.theme),
            lightTheme: model.lightTheme.map(TriggerSDUITheme.init),
            lists: ["offerLogos": Array(logos), "offerLogosA": columns.0, "offerLogosB": columns.1],
            busy: scope.busy,
            onScreen: scope.onScreen,
            maxFontScale: model.config.maxFontScale
        )
    }

    // MARK: Days

    /// Keyed on the placement as sent on the wire, so " streak " and "streak" share a day.
    static func autoDayKey(placement: String) -> String {
        "encore.trigger.giftsButton.autoPopped.\(PlacementLabel.sanitized(placement) ?? "")"
    }

    /// The local calendar day, e.g. `2026-10-02`.
    func dayKey(_ date: Date) -> String {
        let parts = environment.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func nextMidnight(after date: Date) -> Date? {
        environment.calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
    }
}

/// What one mounted GiftsButton remembers across presentations.
@MainActor
internal final class GiftsButtonMount {
    /// This mount already popped for this user, or was held by today's pop elsewhere.
    var autoSettled = false
    /// The day this mount's pop reserved, until the pop presents or gives it back.
    var reservation: GiftsButtonReservation?
    /// `isNew` as read for the held campaigns on show (lowercased, as a set).
    var isNew: (campaignIds: Set<String>, value: Bool)?
}

/// A day one pop reserved, and what the store held before it.
internal struct GiftsButtonReservation {
    let token = UUID()
    let key: String
    let day: String
    let previous: String?
}

// MARK: - Live

extension GiftsButtonTrigger {
    static var live: Self {
        Self(environment: GiftsButtonEnvironment(
            sheet: .live,
            sheetBusy: { OfferSheetCoordinator.isPresenting },
            isActive: { UIApplication.shared.applicationState == .active },
            storage: UserDefaultsStore(),
            // Follows time zone changes in a long-lived process.
            calendar: .autoupdatingCurrent,
            claimLog: { Encore.shared.services.map { (ClaimLog.shared, $0.user.currentUserId) } },
            tallyOwner: { Encore.shared.services.map { GiftsButtonTally.Owner(userId: $0.user.currentUserId, anonymous: !$0.user.isIdentified) } }
        ))
    }
}
