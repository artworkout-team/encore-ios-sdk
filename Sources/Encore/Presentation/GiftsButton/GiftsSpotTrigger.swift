// GiftsButton's mount (vocab §2.8): one host, one /config. The gate holds the sheet's offers, the
// device's state (an open claim, a completion today) goes out as `state`, and the look's behavior
// on the server answers with the gifts button, its thanks look, nothing, or the claim reminder,
// which this mount draws from the claim log it can read.

import SwiftUI

/// What the gifts spot's gate found: the held offers, and the claims the reminder would show.
internal struct GiftsSpotContent {
    let offers: TriggerSheetOffers
    /// Open claims on offers the sheet holds, for a reminder answer.
    let claims: [ReminderClaim]
    let state: TriggerState?
    /// The completion `completed` stands for (its transaction, else its completion time in ms).
    let completion: String?
}

/// `ui.template` as the gifts spot reads it: a gifts button look, or the reminder's.
internal enum GiftsSpotTemplate: Decodable, Sendable {
    case gifts(GiftsButtonTemplate)
    case reminder(ClaimReminderTemplate)

    private enum CodingKeys: String, CodingKey { case trigger }
    /// ``ClaimReminderTrigger/id``, readable off the main actor while decoding.
    private static let reminderTrigger = ClaimReminderTrigger.id

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let trigger = try? container.decodeIfPresent(String.self, forKey: .trigger)
        if trigger == Self.reminderTrigger {
            self = .reminder(try ClaimReminderTemplate(from: decoder))
        } else {
            self = .gifts(try GiftsButtonTemplate(from: decoder))
        }
    }
}

internal enum GiftsSpotConfig: Equatable, Sendable {
    case gifts(GiftsButtonConfig)
    case reminder(ClaimReminderConfig)
}

internal enum GiftsSpotModel: Equatable {
    case gifts(GiftsButtonShown)
    case reminder(ClaimReminderModel)
}

@MainActor
internal struct GiftsSpotTrigger: TriggerPlugin {
    static let id = GiftsButtonTrigger.id
    static let pinnableLayouts = GiftsButtonTrigger.pinnableLayouts
    /// The reminder it draws is hidden with the reminder's own dismissals.
    static let dismissalTrigger = ClaimReminderTrigger.id
    /// A claim or a completion changes what this spot asks for.
    static let regatesOnClaimLogChange = true

    /// The gifts button look's own rules (request, pop, thanks, days).
    let gifts: GiftsButtonTrigger
    /// The reminder's rules, for a reminder answer.
    let reminder: ClaimReminderTrigger
    let spot = GiftsSpotMount()

    func request(for settings: TriggerMountSettings) -> TriggerRequest? { gifts.request(for: settings) }

    // MARK: Gate and state

    /// One gate for the spot: the bounded claim check first (its status checks run before the state
    /// is read), then the sheet's offers (nothing without them), then the reminder's filter over that
    /// same held set. An open claim wins over a completion (the shared cases' `stateWhenBoth`).
    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<GiftsSpotContent> {
        let open = await reminder.source()?.openClaims() ?? []
        let offers: TriggerSheetOffers
        switch await gifts.prepare(context) {
        case .show(let held): offers = held
        case .nothing: return .nothing
        case .notShown(let reason): return .notShown(reason: reason)
        }
        let held = Set(offers.campaignIds)
        let claims = open.filter { held.contains($0.campaignId) }
        let window = reminder.windows.window(placement: context.placement)
        if !ClaimReminderSelection.eligible(in: claims, window: window, dismissed: context.dismissed, now: context.now).isEmpty {
            return .show(GiftsSpotContent(offers: offers, claims: claims, state: .claimOpen, completion: nil))
        }
        let completion = gifts.environment.claimLog().flatMap {
            $0.log.thanksCompletion(userId: $0.userId, calendar: gifts.environment.calendar, now: context.now)
        }
        // After a completion the mount's one automatic open is spent (given up): its look is only tapped.
        if completion != nil { gifts.mount.autoSettled = true }
        return .show(GiftsSpotContent(offers: offers, claims: claims, state: completion == nil ? nil : .completed, completion: completion))
    }

    func state(_ content: GiftsSpotContent, context: TriggerPrepareContext) -> TriggerState? { content.state }

    /// The gifts button's tally, with or without a state.
    func tally(for request: TriggerRequest, placement: String, now: Date) -> TriggerTally? {
        gifts.tally(for: request, placement: placement, now: now)
    }
    func completionKey(_ content: GiftsSpotContent) -> String? { content.completion }

    // MARK: Config

    func decode(_ template: GiftsSpotTemplate) -> GiftsSpotConfig? {
        switch template {
        case .gifts(let gifts): return self.gifts.decode(gifts).map(GiftsSpotConfig.gifts)
        case .reminder(let reminder): return self.reminder.decode(reminder).map(GiftsSpotConfig.reminder)
        }
    }

    func unrenderable(_ config: GiftsSpotConfig, settings: TriggerMountSettings) -> TriggerUnrenderable? {
        switch config {
        case .gifts(let gifts): return self.gifts.unrenderable(gifts, settings: settings)
        case .reminder(let reminder): return self.reminder.unrenderable(reminder, settings: settings)
        }
    }

    // MARK: Present

    func present(_ content: GiftsSpotContent, config: GiftsSpotConfig, context: TriggerPresentContext) -> TriggerPresentation<GiftsSpotModel>? {
        switch config {
        case .gifts(let look):
            spot.regatedForEmptyReminder = false
            return gifts.present(content.offers, config: look, context: context)?.map(GiftsSpotModel.gifts)
        case .reminder(let look):
            // In this spot, × hides every claim on show, so the spot goes back to the gifts button.
            var settings = context.settings
            settings.options[TriggerRegistry.slotOption] = Self.id
            let inSpot = TriggerPresentContext(
                placement: context.placement, now: context.now, dismissed: context.dismissed, appearance: context.appearance,
                settings: settings, portal: context.portal, values: context.values, stringOverrides: context.stringOverrides,
                texts: context.texts
            )
            let offers = ClaimReminderContent(claims: content.claims, offers: content.offers)
            if let shown = reminder.present(offers, config: look, context: inSpot) {
                spot.regatedForEmptyReminder = false
                // A spot that draws the reminder never opens the sheet by itself afterwards (after ×
                // or the window's end): its automatic open is spent, given up.
                gifts.mount.autoSettled = true
                return shown.map(GiftsSpotModel.reminder)
            }
            // Nothing left to remind about (dismissed, or its window ended): ask again, once, with
            // the state as it is now, so the spot shows what the server answers for it.
            guard !spot.regatedForEmptyReminder else { return nil }
            spot.regatedForEmptyReminder = true
            return TriggerPresentation(
                model: .gifts(GiftsButtonShown(config: GiftsButtonConfig(layout: .card), theme: .default, offers: content.offers)),
                height: 0, contentKey: "\(context.placement)|regate", eventFields: TriggerEventFields(), dismissible: false,
                refreshAt: nil, regateAt: context.now
            )
        }
    }

    // MARK: Tap

    func opensSheet(_ model: GiftsSpotModel, target: String) -> Bool {
        switch model {
        case .gifts(let shown): return gifts.opensSheet(shown, target: target)
        case .reminder(let shown): return reminder.opensSheet(shown, target: target)
        }
    }

    func claimAutoTap(_ model: GiftsSpotModel, target: String) -> TriggerAutoTapClaim {
        guard case .gifts(let shown) = model else { return .fire }
        return gifts.claimAutoTap(shown, target: target)
    }

    func identityChanged() { gifts.identityChanged() }

    /// Only the gifts button's own look counts; the reminder drawn in its spot does not.
    func impressed(_ model: GiftsSpotModel, variant: TriggerVariant, placement: String, now: Date) {
        if case .gifts(let shown) = model { gifts.impressed(shown, variant: variant, placement: placement, now: now) }
    }

    func autoTapAborted(_ model: GiftsSpotModel) {
        if case .gifts(let shown) = model { gifts.autoTapAborted(shown) }
    }

    func onTap(_ model: GiftsSpotModel, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        switch model {
        case .gifts(let shown): return await gifts.onTap(shown, target: target, context: context)
        case .reminder(let shown): return await reminder.onTap(shown, target: target, context: context)
        }
    }

    // MARK: Render

    @ViewBuilder
    func render(_ model: GiftsSpotModel, scope: TriggerRenderScope) -> some View {
        switch model {
        case .gifts(let shown): gifts.render(shown, scope: scope)
        case .reminder(let shown): reminder.render(shown, scope: scope)
        }
    }
}

/// What one gifts spot remembers across presentations.
@MainActor
internal final class GiftsSpotMount {
    /// The spot asked again once for a reminder with nothing left to show; until it draws again.
    var regatedForEmptyReminder = false
}

extension TriggerPresentation {
    /// The same presentation over another model.
    func map<Other: Equatable>(_ transform: (Model) -> Other) -> TriggerPresentation<Other> {
        TriggerPresentation<Other>(
            model: transform(model), height: height, maxWidth: maxWidth, contentKey: contentKey, eventFields: eventFields, dismissible: dismissible,
            refreshAt: refreshAt, regateAt: regateAt, staleAt: staleAt, autoTap: autoTap,
            unrenderable: unrenderable, dismissAlso: dismissAlso
        )
    }
}

// MARK: - Live

extension GiftsSpotTrigger {
    static var live: Self { Self(gifts: .live, reminder: .live) }
}
