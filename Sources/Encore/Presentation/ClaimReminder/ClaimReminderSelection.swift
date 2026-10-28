// Which claim the reminder shows, and when its window ends.

import Foundation

// MARK: - Selection

internal enum ClaimReminderSelection {

    /// Available, inside its window, with a named advertiser, and not dismissed.
    static func isEligible(_ claim: ReminderClaim, window: TimeInterval, dismissed: Set<String>, now: Date) -> Bool {
        claim.availability == .available
            && !claim.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dismissed.contains(claim.transactionId)
            && claim.claimedAt <= now
            && now < deadline(for: claim, window: window)
    }

    /// Whether any claim could show under the longest allowed window: available, named,
    /// not dismissed, not in the future. Gates the `/config` fetch, which assigns the arm.
    /// Inclusive at the longest window (0 <= age <= 720h); future-dated claims never count.
    static func anyAvailable(in claims: [ReminderClaim], dismissed: Set<String>, now: Date) -> Bool {
        let longest = ClaimReminderConfig.maxWindowHours * 3600
        return claims.contains { claim in
            claim.availability == .available
                && !claim.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !dismissed.contains(claim.transactionId)
                && claim.claimedAt <= now
                && now <= claim.claimedAt.addingTimeInterval(longest)
        }
    }

    /// The newest eligible claim, or nil.
    static func newestEligible(in claims: [ReminderClaim], window: TimeInterval, dismissed: Set<String>, now: Date) -> ReminderClaim? {
        eligible(in: claims, window: window, dismissed: dismissed, now: now).first
    }

    /// When the banner for `claim` hides.
    static func deadline(for claim: ReminderClaim, window: TimeInterval) -> Date {
        claim.claimedAt.addingTimeInterval(window)
    }

    /// When the first eligible claim leaves its window, e.g. a marquee logo.
    static func earliestDeadline(in claims: [ReminderClaim], window: TimeInterval, dismissed: Set<String>, now: Date) -> Date? {
        eligible(in: claims, window: window, dismissed: dismissed, now: now).map { deadline(for: $0, window: window) }.min()
    }

    /// Distinct logos of the eligible claims, newest first.
    static func marqueeLogos(in claims: [ReminderClaim], window: TimeInterval, dismissed: Set<String>, now: Date) -> [URL] {
        var seen = Set<URL>()
        return eligible(in: claims, window: window, dismissed: dismissed, now: now)
            .compactMap(\.advertiserLogoUrl)
            .filter { seen.insert($0).inserted }
    }

    /// Every eligible claim, newest first (the look's `claims` list).
    static func eligible(in claims: [ReminderClaim], window: TimeInterval, dismissed: Set<String>, now: Date) -> [ReminderClaim] {
        claims
            .filter { isEligible($0, window: window, dismissed: dismissed, now: now) }
            .sorted { $0.claimedAt > $1.claimedAt }
    }
}
