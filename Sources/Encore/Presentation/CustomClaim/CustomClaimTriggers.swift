// The plug-ins behind ``EncoreClaim``: GiftsButton's and the claim reminder's gates with no look.
// The app draws the view, so no look is asked for; the handle reads its rules once (customClaim) and
// every event reports under them, as `customClaim` with layout `custom`.

import SwiftUI

/// The custom mounts' config and template: nothing, as no look is served.
internal struct CustomClaimLook: Decodable, Sendable, Equatable {}

internal enum CustomClaim {
    /// `layout` on every event from the app's own view (BCR C-1).
    static let layout = "custom"
    /// The host's height for the app's view: positive, so the host and the slot count it as drawn.
    static let drawnHeight: CGFloat = 1
    /// The reminder window every served look ships with.
    static let reminderWindow: TimeInterval = ClaimReminderConfig.defaultWindowHours * 3600
}

// MARK: - Gifts

/// What the app's gifts view draws: the offers, as gifts or (`afterComplete: .thanks`) as thanks.
internal struct CustomGiftsShown: Equatable {
    let offers: TriggerSheetOffers
    var thanks = false
    /// The pop's local day and placement, for its once-a-day claim; nil when it does not pop.
    var autoDay: String?
    var autoPlacement: String?
}

/// GiftsButton's gate behind the app's own view: shown while the sheet has offers.
@MainActor
internal struct CustomGiftsTrigger: TriggerPlugin {
    static let id = CustomClaimRules.trigger
    static let pinnableLayouts: Set<String> = []

    /// Its gate and its local days.
    let gifts: GiftsButtonTrigger
    /// The rules this handle follows (today's until its read answers), shared with its other host.
    var box = CustomClaimRulesBox()
    var rules: CustomClaimRules { box.rules }
    /// The app did not pass `autoOpen: .off`.
    var mayPop = true

    func localConfig(for settings: TriggerMountSettings) -> CustomClaimLook? { CustomClaimLook() }
    var localVariant: TriggerVariant { rules.variant }
    var notShownFields: TriggerEventFields { TriggerEventFields(layout: CustomClaim.layout) }

    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<TriggerSheetOffers> {
        await gifts.prepare(context)
    }

    func decode(_ template: CustomClaimLook) -> CustomClaimLook? { template }

    /// As GiftsButton's drawn layouts: the impression means "saw it today" for gifts, and once per
    /// completion for thanks.
    func present(_ offers: TriggerSheetOffers, config: CustomClaimLook, context: TriggerPresentContext) -> TriggerPresentation<CustomGiftsShown>? {
        guard offers.offerCount > 0 else { return nil }
        let thanks = gifts.thanksDue(TriggerPrepareContext(placement: context.placement, now: context.now, dismissed: context.dismissed, settings: context.settings))
        // Rules that open the sheet by itself: once per mount and placement per local day, only after
        // the app's view counted an impression (the host waits for it), never on thanks.
        let pops = rules.autoOpen && mayPop && !thanks && !gifts.mount.autoSettled
        var model = CustomGiftsShown(offers: offers, thanks: thanks)
        if pops { (model.autoDay, model.autoPlacement) = (gifts.dayKey(context.now), context.placement) }
        var presentation = TriggerPresentation(
            model: model, height: CustomClaim.drawnHeight,
            contentKey: thanks
                ? "\(context.placement)|thanks|\(gifts.environment.claimLog().flatMap { $0.log.thanksCompletion(userId: $0.userId, calendar: gifts.environment.calendar, now: context.now) } ?? gifts.dayKey(context.now))"
                : "\(context.placement)|\(gifts.dayKey(context.now))",
            eventFields: TriggerEventFields(layout: CustomClaim.layout), dismissible: false,
            refreshAt: gifts.nextMidnight(after: context.now), staleAt: offers.heldUntil
        )
        if pops { presentation.autoTap = GiftsButtonTrigger.autoTarget }
        return presentation
    }

    func opensSheet(_ model: CustomGiftsShown, target: String) -> Bool { true }

    /// The gifts button's once-a-day pop, shared across every mount at the placement.
    func claimAutoTap(_ model: CustomGiftsShown, target: String) -> TriggerAutoTapClaim {
        gifts.claimAutoDay(zip2(model.autoDay, model.autoPlacement))
    }

    func identityChanged() { gifts.identityChanged() }

    func autoTapAborted(_ model: CustomGiftsShown) { gifts.abortPop() }

    /// As the gifts button's: a thanks tap ends the thanks; a pop waits behind another sheet.
    func onTap(_ model: CustomGiftsShown, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        await gifts.open(model.offers, target: target, isThanks: model.thanks, context: context)
    }

    func render(_ model: CustomGiftsShown, scope: TriggerRenderScope) -> EmptyView { EmptyView() }
}

// MARK: - Reminder

/// What the app's reminder draws.
internal struct CustomReminderShown: Equatable {
    let claim: ReminderClaim
    let deadline: Date
    /// Eligible claims on show, this one included.
    let claimCount: Int
    let offers: TriggerSheetOffers
}

/// The claim reminder's gate behind the app's own view: the newest open claim the sheet holds.
@MainActor
internal struct CustomReminderTrigger: TriggerPlugin {
    static let id = CustomClaimRules.trigger
    static let pinnableLayouts: Set<String> = []
    /// Its dismissals are the claim reminder's: a claim hidden here is hidden there.
    static var dismissalTrigger: String { ClaimReminderTrigger.id }

    /// Its gate: the claim log (re-checked with the server) against the sheet's held offers.
    let reminder: ClaimReminderTrigger
    /// The rules this handle follows; events report under their ids.
    var box = CustomClaimRulesBox()
    var rules: CustomClaimRules { box.rules }

    func localConfig(for settings: TriggerMountSettings) -> CustomClaimLook? { CustomClaimLook() }
    var localVariant: TriggerVariant { rules.variant }
    var notShownFields: TriggerEventFields { TriggerEventFields(layout: CustomClaim.layout) }

    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<ClaimReminderContent> {
        await reminder.prepare(context)
    }

    func decode(_ template: CustomClaimLook) -> CustomClaimLook? { template }

    /// × hides every claim on show, so a dismiss goes back to gifts.
    func present(_ content: ClaimReminderContent, config: CustomClaimLook, context: TriggerPresentContext) -> TriggerPresentation<CustomReminderShown>? {
        let window = CustomClaim.reminderWindow
        let eligible = ClaimReminderSelection.eligible(in: content.claims, window: window, dismissed: context.dismissed, now: context.now)
        guard let claim = eligible.first else { return nil }
        let deadline = ClaimReminderSelection.deadline(for: claim, window: window)
        return TriggerPresentation(
            model: CustomReminderShown(claim: claim, deadline: deadline, claimCount: eligible.count, offers: content.offers),
            height: CustomClaim.drawnHeight,
            contentKey: claim.transactionId,
            eventFields: TriggerEventFields(transactionId: claim.transactionId, campaignId: claim.campaignId, layout: CustomClaim.layout),
            dismissible: true,
            // The count drops when the first claim leaves its window.
            refreshAt: ClaimReminderSelection.earliestDeadline(in: content.claims, window: window, dismissed: context.dismissed, now: context.now) ?? deadline,
            staleAt: content.offers.heldUntil,
            dismissAlso: eligible.map(\.transactionId).filter { $0 != claim.transactionId }
        )
    }

    func opensSheet(_ model: CustomReminderShown, target: String) -> Bool { true }

    func onTap(_ model: CustomReminderShown, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        await CustomClaim.openSheet(model.offers, context: context, sheet: reminder.sheet)
    }

    func render(_ model: CustomReminderShown, scope: TriggerRenderScope) -> EmptyView { EmptyView() }
}

extension CustomClaim {
    /// Opens the sheet for the held offers under the click's presentation id, then re-gates.
    @MainActor
    static func openSheet(_ offers: TriggerSheetOffers, context: TriggerTapContext, sheet: TriggerSheet) async -> TriggerTapOutcome {
        let request = TriggerSheetRequest(placement: context.placement, useCase: offers.useCase)
        _ = await context.presentSheet(request)
        // The user changed while the sheet was up: its offers are not the current user's.
        guard context.isSameIdentity() else { return .keep }
        await sheet.closed(offers)
        return context.isCurrent() ? .refresh : .keep
    }
}

/// Both values, or nil.
private func zip2(_ day: String?, _ placement: String?) -> (day: String, placement: String)? {
    guard let day, let placement else { return nil }
    return (day, placement)
}
