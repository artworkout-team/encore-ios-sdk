// Trigger `/config` results, held in memory for the whole process and shared by every
// mounted host. `/config` records the arm assignment, so a result (a null template
// included) is asked for once per trigger, request (use case, layout, autoOpen, state,
// the Gifts Button tally), placement, user and language. Otherwise only an identity change
// (identify, reset, setLanguage) or a restart asks again.

import Foundation

@MainActor
internal final class TriggerConfigCache {
    static let shared = TriggerConfigCache()

    struct Key: Hashable {
        let trigger: String
        let request: TriggerRequest
        let placement: String?
        let identity: TriggerIdentity
    }

    /// Results by key, each a `TriggerConfigResult<Config>` of its trigger's config type.
    private var results: [Key: Any] = [:]
    /// Fetches in flight by key, shared by every host asking meanwhile.
    private var inFlight: [Key: (token: UUID, task: Any)] = [:]
    /// Bumped by `removeAll`, so a fetch from before it is not stored.
    private var epoch = 0

    /// The cached result for `key`, else one shared fetch. A failure is returned but
    /// never cached, so the next refresh asks again.
    func result<Config: Equatable & Sendable>(
        for key: Key,
        fetch: @escaping @MainActor () async -> TriggerConfigResult<Config>
    ) async -> TriggerConfigResult<Config> {
        if let cached = results[key] as? TriggerConfigResult<Config> {
            traceHit(key)
            return cached
        }
        if let running = inFlight[key]?.task as? Task<TriggerConfigResult<Config>, Never> {
            traceHit(key)
            return await running.value
        }
        let token = UUID()
        let started = epoch
        let task = Task { await fetch() }
        inFlight[key] = (token, task)
        let result = await task.value
        if inFlight[key]?.token == token { inFlight[key] = nil }
        if result != .failed, started == epoch { results[key] = result }
        return result
    }

    private func traceHit(_ key: Key) {
        #if DEBUG
        EncoreDebugTrace.record("config.cacheHit", ["trigger": key.trigger, "placement": key.placement ?? "-"])
        #endif
    }

    /// Forgets every result and fetch. Runs on every identity change.
    func removeAll() {
        results = [:]
        inFlight = [:]
        epoch += 1
    }
}

/// The one way the SDK announces a user or language change to mounted triggers.
@MainActor
internal enum TriggerIdentityChange {
    /// Drops every cached trigger variant, then tells mounted hosts to start over.
    static func post() {
        TriggerConfigCache.shared.removeAll()
        NotificationCenter.default.post(name: .encoreIdentityDidChange, object: nil)
    }
}
