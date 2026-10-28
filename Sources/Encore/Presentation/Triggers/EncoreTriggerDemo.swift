// DEBUG builds only: stub claims for the demo app's trigger walkthrough until the claims API is
// bound. Read from a UserDefaults key so the demo names no SDK symbol; a release build has none of it.

#if DEBUG
import Foundation

extension ClaimReminderSources {
    /// The demo's stub-claims switch: the placement whose sheet offers become the claims.
    static let debugStubPlacementKey = "encore.debug.trigger.stubClaimsPlacement"

    /// Stub claims when the demo set ``debugStubPlacementKey``, else nil.
    static func debugStub(defaults: UserDefaults = .standard) -> ClaimReminderSource? {
        guard let placement = defaults.string(forKey: debugStubPlacementKey), !placement.isEmpty else { return nil }
        return DebugStubClaimSource(placement: placement, useCase: .rewardUsers, count: 3)
    }
}

/// `count` of the offers the sheet at `placement` would show (the lowest ids, so the same ones every
/// time), as claims made 1, 2, 3... hours
/// ago, so each is in the held offers and a tap opens a sheet that lists it. Uses the gate's own
/// search, which the gate then reuses from the offers cache.
struct DebugStubClaimSource: ClaimReminderSource {
    let placement: String
    let useCase: UseCase
    let count: Int

    func openClaims() async -> [ReminderClaim] {
        let now = Date()
        // The server shuffles the order per request: by id, the same claims every time.
        return await Self.sheetOffers(placement: placement, useCase: useCase).prefix(max(count, 0)).enumerated().map { index, offer in
            ReminderClaim(
                transactionId: "demo-\(offer.id)",
                campaignId: offer.id,
                advertiserName: offer.advertiserName,
                advertiserLogoUrl: offer.displayLogoUrl.flatMap(URL.init(string:)),
                claimedAt: now.addingTimeInterval(-Double(index + 1) * 3600),
                availability: .available,
                perk: offer.perk
            )
        }
    }

    /// The offers the sheet at `placement` would show, by id. Uses the gate's own search, which the
    /// gate then reuses from the offers cache.
    static func sheetOffers(placement: String, useCase: UseCase) async -> [Offer] {
        guard let services = await Encore.shared.services else { return [] }
        let (userId, language, attributes) = (services.user.currentUserId, services.user.language, services.user.requestAttributes)
        await services.remoteConfigManager.loadConfig(for: useCase, userId: userId, sdkVersion: Encore.sdkVersion, language: language)
        let layout = services.sduiConfigManager.presentationLayout(for: useCase, strings: SDKStrings.current)
        let label = PlacementLabel.sanitized(placement)
        let fetched = try? await services.offers.fetchOffers(
            userId: userId,
            attributes: attributes,
            variantId: layout.variantId,
            placementId: label,
            maxPostbackTimeMs: nil,
            useCase: useCase,
            cachePlacementId: services.remoteConfigManager.cachePlacement(for: label),
            purpose: OfferSearchPurpose.prefetch
        )
        return (fetched?.offerList ?? []).sorted { $0.id < $1.id }
    }
}

/// The demo's tester controls for its Gifts to Reminder screen: the demo writes a command to
/// ``key`` (it names no SDK symbol, so it still builds against the release binary) and the SDK runs
/// it, so the claim log posts its change and the slot turns at once.
@MainActor
enum ClaimLogDebugCommands {
    /// No dots: key-value observing reads a dotted key as a path, so it would never fire.
    nonisolated static let key = "EncoreDebugClaimLogCommand"
    /// A seeded claim's transaction id starts with this; the status check never asks about it (there
    /// is no such transaction, and a 404 would end it), so it stays open like a real pending claim.
    static let seedPrefix = "encore-debug-seed-"

    static func isSeeded(_ transactionId: String) -> Bool { transactionId.hasPrefix(seedPrefix) }
    private static var observer: CommandObserver?

    /// Watches only ``key`` (key-value observing), so no other UserDefaults write ever wakes it.
    static func install(defaults: UserDefaults = .standard) {
        guard observer == nil else { return }
        observer = CommandObserver(defaults: defaults)
    }

    /// The watcher on its own, for tests; ``install(defaults:)`` keeps one for the app.
    static func watch(_ defaults: UserDefaults) -> NSObject { CommandObserver(defaults: defaults) }

    private final class CommandObserver: NSObject {
        let defaults: UserDefaults

        init(defaults: UserDefaults) {
            self.defaults = defaults
            super.init()
            defaults.addObserver(self, forKeyPath: ClaimLogDebugCommands.key, options: [.new], context: nil)
        }

        deinit { defaults.removeObserver(self, forKeyPath: ClaimLogDebugCommands.key) }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            // A hop, never a wait: the writer may hold its own lock. UserDefaults is thread-safe.
            nonisolated(unsafe) let defaults = defaults
            Task { @MainActor in ClaimLogDebugCommands.run(defaults: defaults) }
        }
    }

    /// Runs a pending command. Its own removal of ``key`` wakes it again, so with no command it
    /// touches nothing (reading the user id may write).
    static func run(defaults: UserDefaults, log: ClaimLog? = nil, userId: (@MainActor () -> String?)? = nil) {
        let log = log ?? .shared
        let userId = userId ?? { Encore.shared.services?.user.currentUserId }
        guard let command = defaults.string(forKey: key) else { return }
        defaults.removeObject(forKey: key)
        guard let userId = userId() else { return }
        // "Age claims N h": every open claim is backdated by N hours, to walk a reminder's window.
        if command.hasPrefix("ageHours:") {
            guard let hours = Double(command.dropFirst("ageHours:".count)), hours.isFinite else { return }
            let rows = log.entries(userId: userId)
            log.save(rows.map { row in
                guard !row.finished else { return row }
                var aged = ClaimLogEntry(transactionId: row.transactionId, campaignId: row.campaignId, advertiserName: row.advertiserName,
                                         logoUrl: row.logoUrl, perk: row.perk, claimedAt: row.claimedAt.addingTimeInterval(-hours * 3600),
                                         useCase: row.useCase, placement: row.placement, finished: row.finished, completedAt: row.completedAt)
                aged.thanksTappedAt = row.thanksTappedAt
                return aged
            }, userId: userId)
            return
        }
        if command.hasPrefix("seed:") {
            let placement = String(command.dropFirst("seed:".count))
            Task { @MainActor in await seed(placement: placement, log: log, userId: userId) }
            return
        }
        switch command {
        case "reset":
            // The screen's state: the log, the reminder's dismissals and today's automatic opens.
            log.clear(userId: userId)
            defaults.removeObject(forKey: TriggerDismissals.storageKey(trigger: ClaimReminderTrigger.id))
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("encore.trigger.giftsButton.autoPopped.") {
                defaults.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .encoreTriggerDismissed, object: nil, userInfo: ["trigger": ClaimReminderTrigger.id])
        case "endWindow":
            // Past the longest window, so every reminder ends as its real window would.
            let rows = log.entries(userId: userId)
            log.save(rows.map { row in
                ClaimLogEntry(transactionId: row.transactionId, campaignId: row.campaignId, advertiserName: row.advertiserName,
                              logoUrl: row.logoUrl, perk: row.perk, claimedAt: row.claimedAt.addingTimeInterval(-ClaimLog.retention - 1),
                              useCase: row.useCase, placement: row.placement, finished: row.finished, completedAt: row.completedAt)
            }, userId: userId)
        case "markFinished":
            var rows = log.entries(userId: userId)
            // As a completion (afterComplete: .hide reads it), not an expiry.
            if let newest = rows.firstIndex(where: { !$0.finished }) {
                rows[newest].finished = true
                rows[newest].completedAt = Date()
            }
            log.save(rows, userId: userId)
        default:
            break
        }
    }

    /// Records an open claim on the first offer (by id) the reward sheet at `placement` holds, so the
    /// reminder's sheet filter passes, then tells mounted triggers to look again. Each seed is a new
    /// claim, so one seeded after a dismissed seed shows.
    static func seed(placement: String, log: ClaimLog, userId: String,
                     offers: (String) async -> [Offer] = { await DebugStubClaimSource.sheetOffers(placement: $0, useCase: .rewardUsers) }) async {
        guard let offer = await offers(placement).first else { return }
        log.record(
            ClaimedOffer(campaignId: offer.id, advertiserName: offer.advertiserName,
                         transactionId: "\(seedPrefix)\(offer.id)-\(UUID().uuidString.prefix(8))", userConfirmedCompletion: false),
            verified: false, logoUrl: offer.displayLogoUrl, perk: offer.perk, useCase: .rewardUsers, placement: placement, userId: userId
        )
        TriggerHeldOffers.changed()
    }
}
#endif

#if DEBUG
import Foundation

/// The demo's on-device text editor: per-placement overrides of a look's strings (`title`, `cta`,
/// ...), written by the demo to ``key`` as `[placement: [stringKey: text]]`, so it names no SDK
/// symbol. Hosts apply them before the one-pass fill and redraw in place; nothing is sent anywhere.
@MainActor
enum TriggerDebugStrings {
    /// No dots: key-value observing reads a dotted key as a path.
    nonisolated static let key = "EncoreDebugStringOverrides"
    private static var observer: Watcher?

    /// The overrides for `placement`, as the demo passed it.
    static func overrides(placement: String, defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: key)?[placement] as? [String: String]) ?? [:]
    }

    /// Tells mounted hosts to redraw with the current overrides.
    static func changed() {
        NotificationCenter.default.post(name: .encoreTriggerDebugStringsChanged, object: nil)
    }

    static func install(defaults: UserDefaults = .standard) {
        guard observer == nil else { return }
        observer = Watcher(defaults: defaults)
    }

    /// The watcher on its own, for tests.
    static func watch(_ defaults: UserDefaults) -> NSObject { Watcher(defaults: defaults) }

    private final class Watcher: NSObject {
        let defaults: UserDefaults

        init(defaults: UserDefaults) {
            self.defaults = defaults
            super.init()
            defaults.addObserver(self, forKeyPath: TriggerDebugStrings.key, options: [.new], context: nil)
        }

        deinit { defaults.removeObserver(self, forKeyPath: TriggerDebugStrings.key) }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            Task { @MainActor in TriggerDebugStrings.changed() }
        }
    }
}

extension Notification.Name {
    /// DEBUG: the demo changed a string override.
    static let encoreTriggerDebugStringsChanged = Notification.Name("EncoreTriggerDebugStringsChanged")
}
#endif
