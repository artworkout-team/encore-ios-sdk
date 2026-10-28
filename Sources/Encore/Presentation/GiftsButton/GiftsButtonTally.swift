// The Gifts Button's device tally: per placement, which local days its button counted an impression,
// how often the user tapped it, and how often the server nudged them. Local only and capped; sent as
// small integers with each giftsButton request, so the server, never the SDK, decides on a nudge.

import Foundation

@MainActor
internal struct GiftsButtonTally {
    /// The user a tally belongs to. Never sent.
    struct Owner: Equatable, Sendable {
        let userId: String
        /// The SDK's own anonymous id: its tally follows the user to their first identify.
        let anonymous: Bool
    }

    static let storageKey = "encore.trigger.giftsButton.tally"
    static let maxPlacements = 20
    static let maxCampaignIds = 20
    static let maxSeenDays = 30
    static let maxSeenCount = 5
    static let maxTaps = 3
    static let maxNudges = 3
    static let maxDaysAgo = 60

    let storage: KeyValueStore
    /// Local days (the SDK's `autoupdatingCurrent` in the live tally).
    let calendar: Calendar

    // MARK: Read

    /// What a request at `placement` sends now. A tally that is not `owner`'s reads as empty.
    func request(placement: String, owner: Owner, now: Date) -> TriggerTally {
        guard let entry = entry(placement, owner: owner) else { return TriggerTally() }
        let today = calendar.startOfDay(for: now)
        return TriggerTally(
            seenDays: clamp(entry.seenDays, Self.maxSeenDays),
            seenCount: clamp(entry.seenCount, Self.maxSeenCount),
            taps: clamp(entry.taps, Self.maxTaps),
            firstSeenDaysAgo: daysAgo(entry.firstSeenDay, today: today) ?? 0,
            lastTapDaysAgo: daysAgo(entry.lastTapDay, today: today),
            nudges: clamp(entry.nudges, Self.maxNudges)
        )
    }

    /// The campaigns `placement`'s button held at its last counted impression, lowercased; none when never seen.
    func lastShownCampaignIds(placement: String, owner: Owner) -> [String] {
        entry(placement, owner: owner)?.lastShownCampaignIds ?? []
    }

    /// Placements on record, whoever owns them.
    var placementCount: Int { load()?.placements.count ?? 0 }

    // MARK: Record

    /// The button's impression counted (the host's dwell passed) while holding `campaignIds`.
    /// `nudge`: the look drawn was the server's `ifIgnored` answer.
    func recordImpression(placement: String, owner: Owner, now: Date, campaignIds: [String], nudge: Bool) {
        let today = dayKey(now)
        update(placement, owner: owner, now: now) { entry in
            entry.seenCount = min(max(entry.seenCount, 0) + 1, Self.maxSeenCount)
            if entry.lastSeenDay != today {
                entry.seenDays = min(max(entry.seenDays, 0) + 1, Self.maxSeenDays)
                entry.lastSeenDay = today
            }
            if entry.firstSeenDay == nil { entry.firstSeenDay = today }
            entry.lastShownCampaignIds = Array(campaignIds.prefix(Self.maxCampaignIds).map { $0.lowercased() })
            if nudge { entry.nudges = min(max(entry.nudges, 0) + 1, Self.maxNudges) }
        }
    }

    /// The user tapped the button (never the look's own pop).
    func recordTap(placement: String, owner: Owner, now: Date) {
        let today = dayKey(now)
        update(placement, owner: owner, now: now) { entry in
            entry.taps = min(max(entry.taps, 0) + 1, Self.maxTaps)
            entry.lastTapDay = today
        }
    }

    // MARK: Identity

    /// `identify()` moved the SDK from `previous` to `userId` (the same id when the app identifies with the
    /// SDK's anonymous one). The anonymous id's tally carries over to that first identify (same person,
    /// same device), owned from then on by an identified user; one belonging to anyone else is wiped.
    func identified(from previous: String, as userId: String) {
        guard var record = load() else { return }
        if record.owner == userId {
            guard record.ownerAnonymous else { return }
            record.ownerAnonymous = false
            return storage.save(record, to: Self.storageKey)
        }
        guard record.ownerAnonymous, record.owner == previous else { return clear() }
        record.owner = userId
        record.ownerAnonymous = false
        storage.save(record, to: Self.storageKey)
    }

    /// `reset()`: the tally goes with the user.
    func clear() {
        storage.remove(Self.storageKey)
    }

    // MARK: Store

    private func load() -> Record? {
        storage.load(Self.storageKey)
    }

    private func entry(_ placement: String, owner: Owner) -> Entry? {
        guard let record = load(), record.owner == owner.userId else { return nil }
        return record.placements[Self.key(placement)]
    }

    /// Changes one placement's entry, starting the record over when it is another user's, then keeps
    /// the ``maxPlacements`` most recently touched.
    private func update(_ placement: String, owner: Owner, now: Date, _ change: (inout Entry) -> Void) {
        var record = load().flatMap { $0.owner == owner.userId ? $0 : nil }
            ?? Record(owner: owner.userId, ownerAnonymous: owner.anonymous, placements: [:])
        record.ownerAnonymous = owner.anonymous
        let key = Self.key(placement)
        var entry = record.placements[key] ?? Entry()
        change(&entry)
        entry.touchedAt = now.timeIntervalSince1970
        record.placements[key] = entry
        if record.placements.count > Self.maxPlacements {
            let kept = record.placements.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(Self.maxPlacements)
            record.placements = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        storage.save(record, to: Self.storageKey)
    }

    /// The placement as sent on the wire, like the pop's day key.
    private static func key(_ placement: String) -> String {
        PlacementLabel.sanitized(placement) ?? ""
    }

    // MARK: Days

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Local calendar days from `day` (`yyyy-MM-dd`) to `today`, 0 to ``maxDaysAgo``; nil without a day.
    private func daysAgo(_ day: String?, today: Date) -> Int? {
        guard let day else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day else { return 0 }
        return min(max(days, 0), Self.maxDaysAgo)
    }

    private func clamp(_ value: Int, _ cap: Int) -> Int { min(max(value, 0), cap) }
}

// MARK: - Stored shape

/// The one stored record. Every field decodes leniently: a malformed one reads as its zero.
private struct Record: Codable {
    var owner: String
    var ownerAnonymous: Bool
    var placements: [String: Entry]
}

private struct Entry: Codable {
    var firstSeenDay: String?
    var lastSeenDay: String?
    var seenDays = 0
    var seenCount = 0
    var taps = 0
    var lastTapDay: String?
    var nudges = 0
    var lastShownCampaignIds: [String] = []
    /// Epoch seconds of the last record, for eviction.
    var touchedAt: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case firstSeenDay, lastSeenDay, seenDays, seenCount, taps, lastTapDay, nudges, lastShownCampaignIds, touchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstSeenDay = (try? container.decodeIfPresent(String.self, forKey: .firstSeenDay)) ?? nil
        lastSeenDay = (try? container.decodeIfPresent(String.self, forKey: .lastSeenDay)) ?? nil
        seenDays = (try? container.decodeIfPresent(Int.self, forKey: .seenDays)) ?? 0
        seenCount = (try? container.decodeIfPresent(Int.self, forKey: .seenCount)) ?? 0
        taps = (try? container.decodeIfPresent(Int.self, forKey: .taps)) ?? 0
        lastTapDay = (try? container.decodeIfPresent(String.self, forKey: .lastTapDay)) ?? nil
        nudges = (try? container.decodeIfPresent(Int.self, forKey: .nudges)) ?? 0
        lastShownCampaignIds = (try? container.decodeIfPresent([String].self, forKey: .lastShownCampaignIds)) ?? []
        touchedAt = (try? container.decodeIfPresent(Double.self, forKey: .touchedAt)) ?? 0
    }
}

extension GiftsButtonTally {
    /// The live tally, on the SDK's own store and the device's calendar.
    static var live: Self { Self(storage: UserDefaultsStore(), calendar: .autoupdatingCurrent) }
}
