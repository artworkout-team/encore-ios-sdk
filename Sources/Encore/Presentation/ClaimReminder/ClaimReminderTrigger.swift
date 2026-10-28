// The claim reminder as a plug-in of the generic trigger host: reads open claims, keeps
// those whose offer the sheet holds, shows the newest eligible one, and opens the sheet on tap.

import SwiftUI

/// The reminder's colours are the shared trigger theme.
internal typealias ClaimReminderTheme = TriggerTheme

/// What the gate found: open claims whose campaign is in the held sheet offers, and what happened
/// on the device (an open claim, else a completion today).
internal struct ClaimReminderContent: Equatable {
    let claims: [ReminderClaim]
    let offers: TriggerSheetOffers
    var state: TriggerState? = nil
    /// The completion `completed` stands for (its transaction, else its completion time in ms).
    var completion: String? = nil
}

/// The reminder's thanks look after a completion: its copy and icon only, no claim.
internal struct ClaimReminderThanksShown: Equatable {
    let config: ClaimReminderConfig
    let theme: ClaimReminderTheme
    var lightTheme: ClaimReminderTheme? = nil
    let offers: TriggerSheetOffers
    /// The completion it thanks for; its impression and dismissal key.
    let completion: String
    var iconValues: [String: String] = TriggerIcon.gift.values(portal: nil)
    var publisherValues: [String: String] = [:]
    var stringOverrides: [String: String] = [:]
}

/// What the reminder draws: a claim to finish, or its thanks look.
internal enum ClaimReminderModel: Equatable {
    case reminder(ClaimReminderShown)
    case thanks(ClaimReminderThanksShown)

    /// The claim on show; nil for thanks.
    var reminder: ClaimReminderShown? {
        if case .reminder(let shown) = self { return shown }
        return nil
    }
}

/// What the reminder card shows.
internal struct ClaimReminderShown: Equatable {
    let claim: ReminderClaim
    let config: ClaimReminderConfig
    let theme: ClaimReminderTheme
    /// When the banner hides: claim time plus the window.
    let deadline: Date
    /// Every eligible claim, newest first.
    let claims: [ReminderClaim]
    /// Logos of every eligible claim, for the marquee layout.
    let marqueeLogos: [URL]
    /// The sheet offers a tap opens.
    let offers: TriggerSheetOffers
    /// The palette for a light device when the scheme follows the device.
    var lightTheme: ClaimReminderTheme? = nil
    /// `${icon}` and `${appIconUrl}`.
    var iconValues: [String: String] = TriggerIcon.gift.values(portal: nil)
    /// `${values.K}`: the mount's value over the look's default.
    var publisherValues: [String: String] = [:]
    /// The DEBUG demo's text edits; empty otherwise.
    var stringOverrides: [String: String] = [:]
}

@MainActor
internal struct ClaimReminderTrigger: TriggerPlugin {
    nonisolated static let id = "claimReminder"
    static let pinnableLayouts = Set(ClaimReminderLayout.allCases.map(\.rawValue))
    /// A claim or a completion changes what it shows.
    static let regatesOnClaimLogChange = true
    /// The served layout of the thanks state look.
    static let thanksLayout = "thanks"

    /// Where open claims come from: the device's claim log, merged with a bound server source once
    /// the claims API ships.
    let source: @MainActor () -> ClaimReminderSource?
    let sheet: TriggerSheet
    /// Before a tap re-presents the sheet: false when the server says the tapped claim is over.
    let stillOpen: @MainActor (_ transactionId: String) async -> Bool
    /// The current user's claim log, for a completion (`state=completed`). Nil: no completion step
    /// (EncoreClaim's reminder, whose app applies its own `afterComplete`).
    let claimLog: @MainActor () -> (log: ClaimLog, userId: String)?
    let calendar: Calendar
    /// The window last served per placement: `claimOpen` asks only for a claim inside it.
    let windows: ReminderWindowStore

    init(
        source: @escaping @MainActor () -> ClaimReminderSource?, sheet: TriggerSheet,
        stillOpen: @escaping @MainActor (_ transactionId: String) async -> Bool = { _ in true },
        claimLog: @escaping @MainActor () -> (log: ClaimLog, userId: String)? = { nil },
        calendar: Calendar = .autoupdatingCurrent,
        windows: ReminderWindowStore? = nil
    ) {
        self.windows = windows ?? .shared
        self.source = source
        self.sheet = sheet
        self.stillOpen = stillOpen
        self.claimLog = claimLog
        self.calendar = calendar
    }

    static var live: Self {
        Self(source: { ClaimReminderSources.resolved }, sheet: .live, stillOpen: { id in
            guard let userId = Encore.shared.services?.user.currentUserId else { return true }
            return await ClaimStatusCheck.shared.stillOpen(id, log: .shared, userId: userId)
        }, claimLog: { Encore.shared.services.map { (ClaimLog.shared, $0.user.currentUserId) } })
    }

    /// Reads the open claims, then runs the sheet gate. Shows only claims whose campaign the
    /// sheet holds, so the tap opens a sheet with that offer in it. `/config` assigns the arm,
    /// so nothing is fetched unless one could show under the longest allowed window (720 h): the
    /// exposure includes claims older than the served window (24 h by default), which cannot draw.
    /// With no open claim, a completion today (not dismissed) passes too, still behind the sheet
    /// gate, so its thanks tap opens a sheet with offers: `state=completed` lets the look's behavior
    /// answer (hide by default, or the thanks look). No claim and no completion: nothing, no request.
    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<ClaimReminderContent> {
        guard let source = source() else { return .nothing }
        let claims = await source.openClaims()
        let claimable = ClaimReminderSelection.anyAvailable(in: claims, dismissed: context.dismissed, now: context.now)
        let completion = claimLog().flatMap { $0.log.thanksCompletion(userId: $0.userId, calendar: calendar, now: context.now) }
            .flatMap { context.dismissed.contains($0) ? nil : $0 }
        guard claimable || completion != nil else { return .nothing }
        switch await sheet.eligibility(context.settings.useCase, context.placement) {
        case .none:
            return .nothing
        case .sheetUnavailable:
            return .notShown(reason: TriggerWire.NotShownReason.sheetUnavailable)
        case .offers(let offers):
            let held = Set(offers.campaignIds)
            let inSheet = claims.filter { held.contains($0.campaignId) }
            // An open claim wins over a completion (the shared cases' `stateWhenBoth`); `claimOpen` only for
            // one inside the window last served here (the 720 h gate above still decides the request).
            if ClaimReminderSelection.anyAvailable(in: inSheet, dismissed: context.dismissed, now: context.now) {
                let inWindow = !ClaimReminderSelection.eligible(
                    in: inSheet, window: windows.window(placement: context.placement), dismissed: context.dismissed, now: context.now
                ).isEmpty
                if inWindow || completion == nil {
                    return .show(ClaimReminderContent(claims: inSheet, offers: offers, state: inWindow ? .claimOpen : nil))
                }
            }
            guard let completion else { return .nothing }
            return .show(ClaimReminderContent(claims: inSheet, offers: offers, state: .completed, completion: completion))
        }
    }

    func state(_ content: ClaimReminderContent, context: TriggerPrepareContext) -> TriggerState? { content.state }
    func completionKey(_ content: ClaimReminderContent) -> String? { content.completion }

    func decode(_ template: ClaimReminderTemplate) -> ClaimReminderConfig? {
        ClaimReminderConfig(template: template)
    }

    /// The thanks look for a completion, else the newest eligible claim under this variant's window.
    func present(
        _ content: ClaimReminderContent,
        config: ClaimReminderConfig,
        context: TriggerPresentContext
    ) -> TriggerPresentation<ClaimReminderModel>? {
        if config.eventLayout == Self.thanksLayout {
            return presentThanks(content, config: config, context: context)?.map(ClaimReminderModel.thanks)
        }
        // A reminder look's window is kept for this placement, so the next `claimOpen` (after a relaunch
        // too) asks only for a claim it could show.
        windows.record(hours: config.windowHours, placement: context.placement)
        return presentReminder(content, config: config, context: context)?.map(ClaimReminderModel.reminder)
    }

    /// The thanks look, keyed by the completion it thanks for, until the next local day (or its tap,
    /// the next claim, or ×).
    private func presentThanks(
        _ content: ClaimReminderContent, config: ClaimReminderConfig, context: TriggerPresentContext
    ) -> TriggerPresentation<ClaimReminderThanksShown>? {
        guard let completion = content.completion, !context.dismissed.contains(completion) else { return nil }
        let themes = TriggerThemes.resolve(appearance: context.appearance, portal: context.portal, colors: config.colors, lightColors: config.lightColors)
        var shown = ClaimReminderThanksShown(config: config, theme: themes.primary, offers: content.offers, completion: completion)
        shown.lightTheme = themes.light
        shown.iconValues = context.settings.icon.values(portal: context.portal)
        shown.publisherValues = TriggerValues.publisher(mount: context.values, defaults: config.valueDefaults)
        let text = TriggerTextSlots.overrides(slots: config.textSlots, texts: context.texts)
        shown.stringOverrides = text.strings.merging(context.stringOverrides) { _, edit in edit }
        let midnight = calendar.nextDate(after: context.now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        return TriggerPresentation(
            model: shown,
            height: (try? config.look.get())?.height ?? 0,
            maxWidth: (try? config.look.get())?.maxWidth,
            contentKey: completion,
            eventFields: TriggerEventFields(layout: config.eventLayout, textSlots: text.drawn.isEmpty ? nil : text.drawn),
            dismissible: config.dismissible,
            refreshAt: midnight,
            regateAt: midnight,
            staleAt: content.offers.heldUntil,
            unrenderable: { if case .failure(let failure) = config.look { return failure } else { return nil } }()
        )
    }

    /// The newest eligible claim under this variant's window.
    func presentReminder(
        _ content: ClaimReminderContent,
        config: ClaimReminderConfig,
        context: TriggerPresentContext
    ) -> TriggerPresentation<ClaimReminderShown>? {
        let claims = content.claims
        guard let claim = ClaimReminderSelection.newestEligible(
            in: claims, window: config.window, dismissed: context.dismissed, now: context.now
        ) else { return nil }
        let deadline = ClaimReminderSelection.deadline(for: claim, window: config.window)
        // The marquee shows every eligible claim's logo, so it re-presents when the first one leaves.
        let refreshAt = config.layout == .logoMarquee
            ? ClaimReminderSelection.earliestDeadline(in: claims, window: config.window, dismissed: context.dismissed, now: context.now) ?? deadline
            : deadline
        let themes = TriggerThemes.resolve(appearance: context.appearance, portal: context.portal, colors: config.colors, lightColors: config.lightColors)
        var shown = ClaimReminderShown(
            claim: claim,
            config: config,
            theme: themes.primary,
            deadline: deadline,
            claims: ClaimReminderSelection.eligible(in: claims, window: config.window, dismissed: context.dismissed, now: context.now),
            marqueeLogos: ClaimReminderSelection.marqueeLogos(in: claims, window: config.window, dismissed: context.dismissed, now: context.now),
            offers: content.offers
        )
        shown.lightTheme = themes.light
        shown.iconValues = context.settings.icon.values(portal: context.portal)
        shown.publisherValues = TriggerValues.publisher(mount: context.values, defaults: config.valueDefaults)
        var text = TriggerTextSlots.overrides(slots: config.textSlots, texts: context.texts)
        shown.stringOverrides = text.strings.merging(context.stringOverrides) { _, edit in edit }
        text.drawn = ClaimReminderStrings.drawnSlots(
            text.drawn, textSlots: config.textSlots, layout: config.layout, claimCount: shown.claims.count,
            hasAdvertiser: !claim.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        return TriggerPresentation(
            model: shown,
            height: (try? config.look.get())?.height ?? 0,
            maxWidth: (try? config.look.get())?.maxWidth,
            contentKey: claim.transactionId,
            eventFields: TriggerEventFields(
                transactionId: claim.transactionId, campaignId: claim.campaignId, layout: config.eventLayout,
                textSlots: text.drawn.isEmpty ? nil : text.drawn
            ),
            dismissible: config.dismissible,
            refreshAt: refreshAt,
            staleAt: content.offers.heldUntil,
            unrenderable: { if case .failure(let failure) = config.look { return failure } else { return nil } }(),
            // In GiftsButton's slot, × goes back to the gifts button: every claim on show now is hidden.
            dismissAlso: context.settings.options[TriggerRegistry.slotOption] == nil
                ? []
                : shown.claims.map(\.transactionId).filter { $0 != claim.transactionId }
        )
    }

    func opensSheet(_ model: ClaimReminderModel, target: String) -> Bool { true }

    /// A look that fails the strict check.
    func unrenderable(_ config: ClaimReminderConfig, settings: TriggerMountSettings) -> TriggerUnrenderable? {
        if case .failure(let failure) = config.look { return failure }
        return nil
    }

    /// Opens the sheet for the mount's use case under the click's presentation id, then re-reads. A
    /// tap on a claim the server says just ended keeps its click (with that presentation id: it
    /// was a real tap) but opens no sheet.
    func onTap(_ model: ClaimReminderModel, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        switch model {
        case .reminder(let shown): return await onTap(shown, target: target, context: context)
        case .thanks(let shown): return await onThanksTap(shown, context: context)
        }
    }

    /// Opens the use case's sheet and ends the thanks once that sheet is up (one that never shows ends
    /// nothing), then reads again.
    private func onThanksTap(_ model: ClaimReminderThanksShown, context: TriggerTapContext) async -> TriggerTapOutcome {
        var observer: NSObjectProtocol?
        if let presentationId = context.presentationId, let claims = claimLog() {
            let (log, userId, calendar) = (claims.log, claims.userId, calendar)
            let stamp = ThanksStamp()
            observer = NotificationCenter.default.addObserver(forName: .encoreSheetShowingDidChange, object: nil, queue: nil) { note in
                guard note.userInfo?["presentationId"] as? String == presentationId else { return }
                MainActor.assumeIsolated {
                    guard !stamp.done else { return }
                    stamp.done = true
                    log.markThanksTapped(userId: userId, calendar: calendar)
                }
            }
        }
        defer { observer.map(NotificationCenter.default.removeObserver) }
        let request = TriggerSheetRequest(placement: context.placement, useCase: model.offers.useCase)
        _ = await context.presentSheet(request)
        guard context.isSameIdentity() else { return .keep }
        await sheet.closed(model.offers)
        return context.isCurrent() ? .refresh : .keep
    }

    private func onTap(_ model: ClaimReminderShown, target: String, context: TriggerTapContext) async -> TriggerTapOutcome {
        // The claim finished meanwhile (a postback): no sheet; the reminder looks again and moves on.
        guard await stillOpen(model.claim.transactionId) else { return context.isCurrent() ? .refresh : .keep }
        // The user changed during that check (up to its tap wait): this claim is not theirs to open.
        guard context.isCurrent() else { return .keep }
        let request = TriggerSheetRequest(placement: context.placement, useCase: model.offers.useCase)
        _ = await context.presentSheet(request)
        // The user changed while the sheet was up: its offers are not the current user's.
        guard context.isSameIdentity() else { return .keep }
        // A sheet that showed is cleaned up even when its mount has gone meanwhile.
        await sheet.closed(model.offers)
        return context.isCurrent() ? .refresh : .keep
    }

    @ViewBuilder
    func render(_ model: ClaimReminderModel, scope: TriggerRenderScope) -> some View {
        switch model {
        case .reminder(let shown):
            if case .success(let look) = shown.config.look {
                TriggerLookView(look: look, inputs: Self.inputs(shown, scope: scope)) { TriggerLookView.route($0, scope: scope) }
            }
        case .thanks(let shown):
            if case .success(let look) = shown.config.look {
                TriggerLookView(look: look, inputs: Self.inputs(shown, scope: scope)) { TriggerLookView.route($0, scope: scope) }
            }
        }
    }

    /// The thanks look's copy and icon; no claim, times or lists.
    static func inputs(_ model: ClaimReminderThanksShown, scope: TriggerRenderScope) -> TriggerSDUIInputs {
        TriggerSDUIInputs(
            values: model.config.strings.values(publisher: model.publisherValues, overrides: model.stringOverrides)
                .merging(model.iconValues) { _, icon in icon }
                .merging(["layout": model.config.eventLayout]) { _, served in served },
            theme: TriggerSDUITheme(model.theme),
            lightTheme: model.lightTheme.map(TriggerSDUITheme.init),
            busy: scope.busy,
            onScreen: scope.onScreen,
            maxFontScale: model.config.maxFontScale
        )
    }

    /// Most logos a marquee carries.
    static let maxMarqueeLogos = 8

    /// The reminder's values, its claim window and its lists (vocab-contract §2.2 to §2.5).
    static func inputs(_ model: ClaimReminderShown, scope: TriggerRenderScope) -> TriggerSDUIInputs {
        let logos = Array(model.marqueeLogos.prefix(maxMarqueeLogos)).map { ["logoUrl": $0.absoluteString] }
        let (left, right) = TriggerSDUIInputs.columns(logos)
        return TriggerSDUIInputs(
            values: model.config.strings.values(
                for: model.claim, layout: model.config.layout, claimCount: model.claims.count, publisher: model.publisherValues,
                overrides: model.stringOverrides, headlineKey: model.config.textSlots[.headline]
            )
                .merging(model.iconValues) { _, icon in icon }
                .merging(["layout": model.config.eventLayout]) { _, served in served },
            theme: TriggerSDUITheme(model.theme),
            lightTheme: model.lightTheme.map(TriggerSDUITheme.init),
            times: ["start": model.claim.claimedAt, "deadline": model.deadline],
            lists: [
                "claims": model.claims.map { claim in
                    // Trimmed as the reminder's own values are, so a padded name never draws a blank letter.
                    let name = claim.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines)
                    var item = ["transactionId": claim.transactionId, "advertiserName": name,
                                "advertiserInitial": name.first.map { String($0).uppercased() } ?? ""]
                    item["advertiserLogoUrl"] = claim.advertiserLogoUrl?.absoluteString
                    return item
                },
                "marqueeLogos": logos, "marqueeLogosA": left, "marqueeLogosB": right,
            ],
            busy: scope.busy,
            onScreen: scope.onScreen,
            maxFontScale: model.config.maxFontScale
        )
    }

}

/// Whether a thanks tap already stamped its completion (the sheet announces itself more than once).
@MainActor
private final class ThanksStamp {
    var done = false
}
