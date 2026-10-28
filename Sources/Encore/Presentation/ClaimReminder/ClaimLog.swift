// Claims this device saw end in an Encore sheet, per user: what the claim reminder, GiftsButton's
// after-claim slot and EncoreClaim read, right after a claim and across relaunches. On the device
// only; a bound claims source (the server's list) wins over it.

import Foundation

/// One claim a sheet ended with.
internal struct ClaimLogEntry: Codable, Equatable, Sendable {
    let transactionId: String?
    let campaignId: String
    let advertiserName: String
    let logoUrl: String?
    /// The claimed offer's perk as the sheet showed it (e.g. "3 months free"); absent when blank.
    var perk: String? = nil
    let claimedAt: Date
    let useCase: String
    let placement: String?
    /// Verified, or the user said they finished: no longer a reminder.
    var finished: Bool
    /// When the claim was completed (verified, granted or self-reported). Nil when open, or when
    /// it only ended (expired, failed); absent on rows older than the field.
    var completedAt: Date? = nil
    /// When the user tapped `afterComplete: .thanks`'s look for this completion; nil until then.
    var thanksTappedAt: Date? = nil

    /// One row per claim: its transaction, else its campaign.
    var key: String { transactionId ?? "campaign:\(campaignId)" }
}

@MainActor
internal final class ClaimLog {
    /// How long a row is kept: the longest reminder window.
    static let retention: TimeInterval = ClaimReminderConfig.maxWindowHours * 3600
    static let capacity = 50

    /// Kept out of backups: a restored device must not bring back reminders for old claims.
    static let shared = ClaimLog(storage: BackupExcludedFileStore(), now: Date.init)

    private let storage: KeyValueStore
    private let now: () -> Date

    init(storage: KeyValueStore, now: @escaping () -> Date) {
        self.storage = storage
        self.now = now
    }

    static func key(userId: String) -> String { "encore.claimLog.\(userId)" }

    /// This user's rows inside the retention window, newest first. An unreadable log reads as empty.
    func entries(userId: String) -> [ClaimLogEntry] {
        let stored: [ClaimLogEntry] = storage.load(Self.key(userId: userId)) ?? []
        let oldest = now().addingTimeInterval(-Self.retention)
        return stored.filter { $0.claimedAt >= oldest }.sorted { $0.claimedAt > $1.claimedAt }
    }

    /// Records a sheet's claim. A claim already logged keeps its first claim time; verified or
    /// self-reported marks it finished.
    func record(_ offer: ClaimedOffer, verified: Bool, logoUrl: String?, perk: String? = nil, useCase: UseCase, placement: String?, userId: String) {
        let finished = verified || offer.userConfirmedCompletion
        var rows = entries(userId: userId)
        let entry = ClaimLogEntry(
            transactionId: offer.transactionId, campaignId: offer.campaignId, advertiserName: offer.advertiserName,
            logoUrl: logoUrl, perk: perk, claimedAt: now(), useCase: useCase.rawValue, placement: placement, finished: finished,
            completedAt: finished ? now() : nil
        )
        if let index = rows.firstIndex(where: { $0.key == entry.key }) {
            rows[index].finished = rows[index].finished || finished
            if finished, rows[index].completedAt == nil { rows[index].completedAt = now() }
        } else {
            rows.insert(entry, at: 0)
        }
        save(rows, userId: userId)
        #if DEBUG
        EncoreDebugTrace.record("claim.recorded", ["transaction": offer.transactionId ?? "-", "advertiser": offer.advertiserName])
        #endif
    }

    /// What a sheet noted about the offer it staged a claim for, by campaign, until its outcome is recorded.
    private var notedOffers: [String: (logoUrl: String?, perk: String?)] = [:]

    /// The sheet notes the claimed offer's logo and perk, which the outcome itself does not carry.
    func noteOffer(logoUrl: String?, perk: String?, campaignId: String) {
        func present(_ value: String?) -> String? {
            value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        notedOffers[campaignId] = (present(logoUrl), present(perk))
    }

    /// Records a sheet's outcome: a claim (open) or a verified claim (finished); nothing otherwise.
    func record(outcome: AdvertiserOutcome, useCase: UseCase, placement: String?, userId: String) {
        let offer: ClaimedOffer
        let verified: Bool
        switch outcome {
        case .claimed(let claimed): offer = claimed; verified = false
        case .verified(let claimed): offer = claimed; verified = true
        case .notAttempted, .cooldown, .failed: return
        }
        let noted = notedOffers.removeValue(forKey: offer.campaignId)
        record(offer, verified: verified, logoUrl: noted?.logoUrl, perk: noted?.perk, useCase: useCase, placement: placement, userId: userId)
    }

    /// The server says this claim ended: no longer a reminder. `completed` (verified, granted) also
    /// stamps the completion; expired and failed end it without one.
    func markFinished(transactionId: String, userId: String, completed: Bool) {
        var rows = entries(userId: userId)
        guard let index = rows.firstIndex(where: { $0.transactionId == transactionId && !$0.finished }) else { return }
        rows[index].finished = true
        if completed { rows[index].completedAt = now() }
        save(rows, userId: userId)
    }

    /// `afterComplete`: a claim was completed on `now`'s local day and none was made since.
    func completedToday(userId: String, calendar: Calendar, now: Date) -> Bool {
        Self.completionToday(in: entries(userId: userId), calendar: calendar, now: now) != nil
    }

    /// `afterComplete: .thanks`: completed today, none claimed since, and that completion's thanks not tapped.
    func thanksDue(userId: String, calendar: Calendar, now: Date) -> Bool {
        let rows = entries(userId: userId)
        guard let index = Self.completionToday(in: rows, calendar: calendar, now: now) else { return false }
        return rows[index].thanksTappedAt == nil
    }

    /// Which completion the thanks look is for: its transaction (else its completion time), so each
    /// completion's thanks counts its own impression. Nil when no thanks is due.
    func thanksCompletion(userId: String, calendar: Calendar, now: Date) -> String? {
        let rows = entries(userId: userId)
        guard let index = Self.completionToday(in: rows, calendar: calendar, now: now), rows[index].thanksTappedAt == nil else { return nil }
        return rows[index].transactionId ?? rows[index].completedAt.map { String(Int($0.timeIntervalSince1970 * 1000)) }
    }

    /// The thanks look was tapped: stamps today's latest completion, so a later one thanks again.
    func markThanksTapped(userId: String, calendar: Calendar) {
        var rows = entries(userId: userId)
        guard let index = Self.completionToday(in: rows, calendar: calendar, now: now()), rows[index].thanksTappedAt == nil else { return }
        rows[index].thanksTappedAt = now()
        save(rows, userId: userId)
    }

    /// The row of the latest completion on `now`'s local day, unless a claim was made since it.
    private static func completionToday(in rows: [ClaimLogEntry], calendar: Calendar, now: Date) -> Int? {
        let today = rows.indices.filter { rows[$0].completedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        guard let index = today.max(by: { (rows[$0].completedAt ?? .distantPast) < (rows[$1].completedAt ?? .distantPast) }),
              let latest = rows[index].completedAt else { return nil }
        return rows.contains { $0.claimedAt > latest } ? nil : index
    }

    func clear(userId: String) {
        storage.remove(Self.key(userId: userId))
        NotificationCenter.default.post(name: .encoreClaimLogDidChange, object: nil)
    }

    /// An anonymous user who identifies keeps their claims, as the server moves them.
    func carryOver(from anonymous: String, to identified: String) {
        guard anonymous != identified else { return }
        let moved = entries(userId: anonymous)
        guard !moved.isEmpty else { return }
        let kept = entries(userId: identified)
        let keys = Set(kept.map(\.key))
        save(kept + moved.filter { !keys.contains($0.key) }, userId: identified)
        clear(userId: anonymous)
    }

    func save(_ rows: [ClaimLogEntry], userId: String) {
        let newest = Array(rows.sorted { $0.claimedAt > $1.claimedAt }.prefix(Self.capacity))
        storage.save(newest, to: Self.key(userId: userId))
        NotificationCenter.default.post(name: .encoreClaimLogDidChange, object: nil)
    }
}

/// The log as the reminder reads it: the current user's open claims. A row without a transaction
/// id is left out, so a reminder event never carries an invented one.
internal struct ClaimLogSource: ClaimReminderSource {
    let log: ClaimLog
    let userId: @MainActor @Sendable () -> String?
    /// Re-checks the newest open claims with the server first (the status check's bounds), so a
    /// completion that landed by postback after the sheet closed ends the reminder. Nil reads the
    /// log alone.
    var statusCheck: ClaimStatusCheck? = nil
    /// Transaction ids the user hid with ×: never asked about, since no reminder will show them.
    var dismissed: @MainActor @Sendable () -> Set<String> = { [] }

    func openClaims() async -> [ReminderClaim] {
        if let statusCheck, let asked = await MainActor.run(body: { userId().map { (user: $0, dismissed: dismissed()) } }) {
            await statusCheck.refresh(log, userId: asked.user, dismissed: asked.dismissed)
        }
        return await MainActor.run {
            guard let userId = userId() else { return [] }
            let claims = log.entries(userId: userId).compactMap { row -> ReminderClaim? in
                guard let transactionId = row.transactionId else { return nil }
                return ReminderClaim(
                    transactionId: transactionId, campaignId: row.campaignId, advertiserName: row.advertiserName,
                    advertiserLogoUrl: row.logoUrl.flatMap(URL.init(string:)), claimedAt: row.claimedAt,
                    availability: row.finished ? .unavailable : .available, perk: row.perk
                )
            }
            #if DEBUG
            EncoreDebugTrace.record("claimLog.read", ["user": userId, "open": String(claims.filter { $0.availability == .available }.count)])
            #endif
            return claims
        }
    }
}

/// The claims the reminder reads: a bound claims source (the server's list) wins for the same
/// transaction; a logged claim it does not list yet stays for 10 minutes (server lag), then goes.
/// Without a bound source the log answers alone. `extras` (the DEBUG demo's stub) only add claims.
internal struct MergedClaimSource: ClaimReminderSource {
    static let serverLag: TimeInterval = 10 * 60

    let authority: ClaimReminderSource?
    let log: ClaimLogSource
    var extras: [ClaimReminderSource] = []
    let now: @MainActor @Sendable () -> Date

    func openClaims() async -> [ReminderClaim] {
        let logged = await log.openClaims()
        var claims: [ReminderClaim]
        if let authority {
            let server = await authority.openClaims()
            let listed = Set(server.map(\.transactionId))
            let cutoff = await MainActor.run { now() }.addingTimeInterval(-Self.serverLag)
            claims = server + logged.filter { !listed.contains($0.transactionId) && $0.claimedAt >= cutoff }
        } else {
            claims = logged
        }
        for extra in extras {
            let known = Set(claims.map(\.transactionId))
            claims += await extra.openClaims().filter { !known.contains($0.transactionId) }
        }
        return claims
    }
}

/// The SDK confirms the newest open claims with the server's stored status
/// (`GET /transactions/{id}/status`, a read the conversion poller keeps within a minute), so a
/// completion that landed after the sheet closed ends the reminder. Never `verify=true`: that
/// fetches a partner's whole report per call. Bounded (S-SCALE): the newest few open claims, each
/// at most once per interval, never past its window, a pause on 429, and only when the reminder
/// looks or is tapped, never on its own timer.
@MainActor
internal final class ClaimStatusCheck {
    /// Every bound in one place.
    struct Bounds {
        var maxPerCheck = 3
        /// A claim is asked again only after this long.
        var interval: TimeInterval = 5 * 60
        /// No check once the claim is older than its longest reminder window.
        var window: TimeInterval = ClaimReminderConfig.maxWindowHours * 3600
        /// Every check pauses this long after a 429.
        var rateLimitPause: TimeInterval = 10 * 60
        /// A tap waits this long for its check, then opens the sheet anyway.
        var tapWait: TimeInterval = 1.5
        /// The reminder waits this long, in all, for the checks before it draws; later answers
        /// still land in the log.
        var refreshWait: TimeInterval = 1.5
    }

    /// The statuses that end a claim (GET /transactions/{id}/status).
    static let ended: Set<String> = ["verified", "final_granted", "expired", "failed"]
    /// The ones of those that complete it; expired and failed only end it.
    static let completed: Set<String> = ["verified", "final_granted"]

    static let shared = makeLive(transactions: { Encore.shared.services?.transactions })

    /// The live check over the configured SDK's transactions. Always the stored status: the
    /// request never carries `verify=true`.
    static func makeLive(
        transactions: @escaping @MainActor () -> TransactionsManager?, now: @escaping () -> Date = Date.init,
        storage: KeyValueStore = BackupExcludedFileStore()
    ) -> ClaimStatusCheck {
        ClaimStatusCheck(status: { id in try await transactions()?.getStatus(transactionId: id, verify: false) }, now: now, storage: storage)
    }

    /// What survives a relaunch, so a reopened app never asks again early or ignores a 429.
    struct Persisted: Codable, Equatable {
        var checkedAt: [String: Date] = [:]
        var pausedUntil: Date?
    }

    static let storageKey = "encore.claimStatusCheck"
    /// The most claims remembered: the claim log's own cap.
    static let maxRemembered = ClaimLog.capacity

    private let status: (String) async throws -> String?
    private let now: () -> Date
    private let bounds: Bounds
    private let storage: KeyValueStore?
    private var checkedAt: [String: Date] = [:]
    private var pausedUntil: Date?

    init(
        status: @escaping (String) async throws -> String?, now: @escaping () -> Date,
        storage: KeyValueStore? = nil, bounds: Bounds = Bounds()
    ) {
        self.status = status
        self.now = now
        self.storage = storage
        if let stored: Persisted = storage?.load(Self.storageKey) {
            checkedAt = stored.checkedAt
            pausedUntil = stored.pausedUntil
        }
        self.bounds = bounds
    }

    /// Before the reminder draws: the newest open claims not dismissed that are due, one after another, waited
    /// for at most `refreshWait` in all. The round is never cancelled, so a late answer still
    /// lands in the log (and the next look shows it).
    func refresh(_ log: ClaimLog, userId: String, dismissed: Set<String> = []) async {
        // A claim the user hid with × is never asked about: no reminder will show it.
        let open = log.entries(userId: userId).filter { row in
            !row.finished && row.transactionId.map { !dismissed.contains($0) && !Self.exempt($0) } ?? false
        }.prefix(bounds.maxPerCheck)
        let due = open.filter { isDue($0) }.compactMap(\.transactionId)
        guard !due.isEmpty else { return }
        // Asked now, before any suspension, so a refresh meanwhile never asks one twice.
        for id in due { checkedAt[id] = now() }
        persist()
        let round = Task {
            for id in due {
                guard await self.check(id, log: log, userId: userId) != .rateLimited else { return }
            }
        }
        _ = await Self.value(of: round, within: bounds.refreshWait)
    }

    /// Before a tap re-presents the sheet: false when the server says the claim is over. A claim
    /// not due, or a check slower than `tapWait`, counts as open; a slow check still finishes and
    /// lands in the log.
    func stillOpen(_ transactionId: String, log: ClaimLog, userId: String) async -> Bool {
        guard let row = log.entries(userId: userId).first(where: { $0.transactionId == transactionId }) else { return true }
        if row.finished { return false }
        guard !Self.exempt(transactionId), isDue(row) else { return true }
        // Asked now, before any suspension, so a refresh meanwhile never asks it twice.
        checkedAt[transactionId] = now()
        // Never cancelled: only the wait for it is bounded.
        let check = Task { await self.check(transactionId, log: log, userId: userId) }
        let outcome = await Self.value(of: check, within: bounds.tapWait)
        return outcome != .ended
    }

    /// `task`'s value, or nil once `seconds` pass first. Returns at the deadline without waiting
    /// for the task, and never cancels it, so a late answer still lands. (A task group would wait
    /// for every child before returning, and awaiting a task's value ignores cancellation.)
    private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: TimeInterval) async -> T? {
        let first = FirstAnswer<T>()
        return await withCheckedContinuation { continuation in
            first.set(continuation)
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                first.give(nil)
            }
            Task {
                let value = await task.value
                deadline.cancel()
                first.give(value)
            }
        }
    }

    private enum Outcome: Sendable { case open, ended, rateLimited }

    /// Never asked about: a DEBUG demo's seeded claim (no such transaction). Nothing in Release.
    private static func exempt(_ transactionId: String) -> Bool {
        #if DEBUG
        return ClaimLogDebugCommands.isSeeded(transactionId)
        #else
        return false
        #endif
    }

    private func isDue(_ row: ClaimLogEntry) -> Bool {
        let at = now()
        clampFutureDates(at)
        if let pausedUntil, at < pausedUntil { return skip(row, "paused") }
        guard at.timeIntervalSince(row.claimedAt) < bounds.window, let id = row.transactionId else { return skip(row, "window") }
        let due = checkedAt[id].map { at.timeIntervalSince($0) >= bounds.interval } ?? true
        return due || skip(row, "notDue")
    }

    /// Not due, for `reason`; traced in DEBUG.
    private func skip(_ row: ClaimLogEntry, _ reason: String) -> Bool {
        #if DEBUG
        EncoreDebugTrace.record("status.skip", ["transaction": row.transactionId ?? "-", "reason": reason])
        #endif
        return false
    }

    /// A clock moved forward and back again leaves stamps in the future: a check counts as made
    /// now and a pause runs at most its own length from now, so neither blocks for longer.
    private func clampFutureDates(_ at: Date) {
        var changed = false
        for (id, date) in checkedAt where date > at {
            checkedAt[id] = at
            changed = true
        }
        if let paused = pausedUntil, paused > at.addingTimeInterval(bounds.rateLimitPause) {
            pausedUntil = at.addingTimeInterval(bounds.rateLimitPause)
            changed = true
        }
        if changed { persist() }
    }

    /// Forgets every check and pause (``Encore/reset()``).
    func clear() {
        checkedAt = [:]
        pausedUntil = nil
        storage?.remove(Self.storageKey)
    }

    /// Saves what a relaunch needs: the recent checks (none past the window, at most the claim
    /// log's cap) and the pause.
    private func persist() {
        guard let storage else { return }
        let oldest = now().addingTimeInterval(-bounds.window)
        let kept = checkedAt.filter { $0.value >= oldest }.sorted { $0.value > $1.value }.prefix(Self.maxRemembered)
        checkedAt = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        storage.save(Persisted(checkedAt: checkedAt, pausedUntil: pausedUntil), to: Self.storageKey)
    }

    private func check(_ id: String, log: ClaimLog, userId: String) async -> Outcome {
        checkedAt[id] = now()
        persist()
        func traced(_ outcome: Outcome, _ result: String) -> Outcome {
            #if DEBUG
            EncoreDebugTrace.record("status.check", ["transaction": id, "result": result])
            #endif
            return outcome
        }
        do {
            guard let value = try await status(id), Self.ended.contains(value) else { return traced(.open, "pending") }
            let completed = Self.completed.contains(value)
            log.markFinished(transactionId: id, userId: userId, completed: completed)
            return traced(.ended, completed ? "completed" : "ended")
        } catch where Self.isGone(error) {
            // The server has no such transaction (a claim from another environment, say): it is
            // over, without a completion, rather than asked about every interval until 720 h.
            log.markFinished(transactionId: id, userId: userId, completed: false)
            return traced(.ended, "gone")
        } catch where Self.isRateLimited(error) {
            pausedUntil = now().addingTimeInterval(bounds.rateLimitPause)
            persist()
            return traced(.rateLimited, "rateLimited")
        } catch {
            return traced(.open, "failed")
        }
    }

    /// A 404: the server has no such transaction.
    static func isGone(_ error: Error) -> Bool {
        switch error {
        case EncoreError.protocol(.api(status: 404, _, _)), EncoreError.protocol(.http(status: 404, _)): return true
        default: return false
        }
    }

    /// A 429, with Encore's JSON error body or without one (a proxy's or load balancer's page).
    static func isRateLimited(_ error: Error) -> Bool {
        switch error {
        case EncoreError.protocol(.api(status: 429, _, _)), EncoreError.protocol(.http(status: 429, _)): return true
        default: return false
        }
    }
}

/// Resumes a continuation with whichever answer comes first; later ones are ignored.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func set(_ continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func give(_ value: T?) {
        let waiting = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
