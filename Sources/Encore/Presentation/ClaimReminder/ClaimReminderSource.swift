// The claim reminder's view of the user's open claims, behind a small adapter so
// the trigger does not depend on the claims API's public types directly.

import Foundation

// MARK: - Reminder Claim

/// One open claim, as the reminder needs it.
internal struct ReminderClaim: Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case available
        /// Finished, ended, self-reported or unknown: never shown.
        case unavailable
    }

    let transactionId: String
    let campaignId: String
    let advertiserName: String
    let advertiserLogoUrl: URL?
    /// The latest claim time the server exposes; the reminder window starts here.
    let claimedAt: Date
    let availability: Availability
    /// The claimed offer's perk as the sheet showed it; spoken as the card's hint, never drawn.
    var perk: String? = nil
}

// MARK: - Source

/// Where the reminder reads open claims. Never throws: a failed read is an empty list.
internal protocol ClaimReminderSource: Sendable {
    func openClaims() async -> [ReminderClaim]
}

/// The bound source. Nil until the SDK's claims API ships; until then the reminder reads the
/// on-device claim log alone.
@MainActor
internal enum ClaimReminderSources {
    static var current: ClaimReminderSource?

    /// The reminder's dismissed transaction ids on this device (the host's own store).
    static func dismissed(storage: KeyValueStore = UserDefaultsStore(), now: Date = Date()) -> Set<String> {
        TriggerDismissals(trigger: ClaimReminderTrigger.id, storage: storage).keys(now: now)
    }

    /// What the live trigger reads: the bound source merged with the claim log, plus in a DEBUG
    /// build the demo's stub claims.
    static var resolved: ClaimReminderSource? {
        var extras: [ClaimReminderSource] = []
        #if DEBUG
        if let stub = debugStub() { extras.append(stub) }
        #endif
        return MergedClaimSource(
            authority: current,
            log: ClaimLogSource(
                log: .shared, userId: { Encore.shared.services?.user.currentUserId }, statusCheck: .shared,
                dismissed: { ClaimReminderSources.dismissed() }
            ),
            extras: extras,
            now: { Date() }
        )
    }
}
