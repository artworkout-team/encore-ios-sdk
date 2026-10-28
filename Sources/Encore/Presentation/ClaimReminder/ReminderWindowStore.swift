// The reminder window last served per (trigger, placement), kept on the device (excluded from backup,
// cleared by reset) so `claimOpen` asks only for a claim the reminder could show, across relaunches.

import Foundation

@MainActor
internal final class ReminderWindowStore {
    static let key = "encore.trigger.reminderWindows"
    static let shared = ReminderWindowStore(storage: BackupExcludedFileStore())

    private let storage: KeyValueStore
    /// Hours by `<trigger>|<placement>`; read once.
    private var hours: [String: Double]?

    init(storage: KeyValueStore) {
        self.storage = storage
    }

    /// The window last served at `placement`; 24 h when nothing is stored or it cannot be read.
    func window(placement: String) -> TimeInterval {
        let stored = entries[Self.entryKey(placement: placement)]
        return (stored.flatMap(Self.valid) ?? ClaimReminderConfig.defaultWindowHours) * 3600
    }

    /// Keeps the window a reminder look was served with at `placement`; an unchanged one writes nothing.
    func record(hours value: Double, placement: String) {
        let key = Self.entryKey(placement: placement)
        var next = entries
        guard next[key] != value else { return }
        next[key] = value
        hours = next
        storage.save(next, to: Self.key)
    }

    /// `reset()`: every placement goes back to the default.
    func clear() {
        hours = [:]
        storage.remove(Self.key)
    }

    private var entries: [String: Double] {
        if let hours { return hours }
        let loaded: [String: Double] = storage.load(Self.key) ?? [:]
        hours = loaded
        return loaded
    }

    /// The trigger whose look drew the reminder (always the claim reminder) and the placement as on the wire.
    private static func entryKey(placement: String) -> String {
        "\(ClaimReminderTrigger.id)|\(PlacementLabel.sanitized(placement) ?? "")"
    }

    private static func valid(_ hours: Double) -> Double? {
        hours.isFinite && hours > 0 && hours <= ClaimReminderConfig.maxWindowHours ? hours : nil
    }
}
