// Content keys a user dismissed on this device, one store per trigger. Never sent
// to the server. A key is dropped only once it is older than the retention.

import Foundation

internal struct TriggerDismissals: Sendable {
    /// Longer than any trigger can show one item (ClaimReminder's longest window).
    static let retention: TimeInterval = 720 * 3600

    static func storageKey(trigger: String) -> String { "encore.trigger.\(trigger).dismissed" }

    private let key: String
    private let storage: KeyValueStore

    init(trigger: String, storage: KeyValueStore) {
        self.key = Self.storageKey(trigger: trigger)
        self.storage = storage
    }

    /// Keys dismissed within the retention, as of `now`.
    func keys(now: Date) -> Set<String> {
        Set(entries(now: now).keys)
    }

    /// Records the dismissal, keeping the newest time a key was dismissed.
    func add(_ contentKey: String, now: Date) {
        var entries = entries(now: now)
        entries[contentKey] = max(entries[contentKey] ?? now, now)
        storage.save(entries, to: key)
    }

    /// Live entries as of `now`. A date in the future (the clock moved back) is stored as now
    /// the first time it is read, so it still hides and then ages out on schedule.
    private func entries(now: Date) -> [String: Date] {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let stored = stored
        let live = stored.mapValues { min($0, now) }.filter { $0.value >= cutoff }
        if stored.values.contains(where: { $0 > now }) { storage.save(live, to: key) }
        return live
    }

    private var stored: [String: Date] { storage.load(key) ?? [:] }
}

extension Notification.Name {
    /// Posted on the main actor when `identify()` switches user, `reset()` runs, or the language changes.
    static let encoreIdentityDidChange = Notification.Name("EncoreIdentityDidChange")
    /// Posted on the main actor when the same user's offer-targeting attributes change: mounted
    /// triggers re-run their gate, keeping their variants.
    static let encoreOfferTargetingDidChange = Notification.Name("EncoreOfferTargetingDidChange")
    /// Posted on the main actor when an offer set a mounted trigger may hold changed (a trigger's
    /// sheet evicted it, a fresh search replaced it, a campaign was self-reported): every
    /// mounted trigger runs its gate again.
    static let encoreTriggerHeldOffersChanged = Notification.Name("EncoreTriggerHeldOffersChanged")
    /// Posted on the main actor when an Encore sheet in its own window starts or stops showing (a
    /// sheet in an app's own controller is not announced); `userInfo["presentationId"]` names the
    /// sheet now on screen, absent when none is.
    static let encoreSheetShowingDidChange = Notification.Name("EncoreSheetShowingDidChange")
    /// Posted on the main actor when a trigger is dismissed; `userInfo["trigger"]` is its id.
    static let encoreTriggerDismissed = Notification.Name("EncoreTriggerDismissed")
}
