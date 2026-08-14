// Sources/Encore/Core/Configuration/Remote/RemoteConfigurationManager.swift
//
// Manages remote configuration state.
// Handles latest-identity-wins coordination and exposes config to consumers.
// Storage concerns delegated to repository.

import CryptoKit
import Foundation

/// Manages remote configuration fetched from the backend.
///
/// Single source of truth for remote configuration data.
/// - Latest-identity-wins coordination (task cancellation)
/// - Delegates storage to repository
/// - Tracks config fetch analytics
/// - Thread-safe config access via Atomic wrapper
///
/// **Per-use-case caching — one cache, two ways to fill it.**
///
/// 1. The `identify()`-time `/config` response carries a prefetch block with
///    the default variant for every use case the app is **enabled** for. Those
///    land in the cache before anything is presented, so the presentation is
///    instant.
/// 2. Anything else is fetched **lazily on first presentation** and cached
///    after — slow once, fast thereafter.
///
/// The second path is not vestigial. Serving is ungated on the backend: an app
/// may present a use case it has no `app_use_cases` row for, and such a use case
/// is by definition absent from the prefetch block. Reading only from the block
/// would hand that publisher nothing — the exact dead end ungating removed.
/// Enabling the use case in the portal is the ONLY route to the fast path; it
/// also drives portal state and per-use-case analytics.
class RemoteConfigurationManager {

    // MARK: - Properties

    private let repository: RemoteConfigurationRepository

    /// How long `show()` waits on a `/config` fetch already in flight before
    /// dropping to last-known-good. Uniform across use cases. A `var` only so
    /// ceiling-expiry tests need not spend the real two seconds.
    internal static var fetchCeiling: TimeInterval = 2

    /// Where the `[INTEGRATION]` hint goes. Injected only so tests can read the
    /// message the publisher would read — `Logger` writes to `print`, so a
    /// warning is otherwise unobservable and "we log it once" is untestable.
    /// Production always takes the default.
    private let integrationWarning: (String) -> Void

    /// In-flight `/config` fetch. Cancelled when a new fetch is triggered.
    ///
    /// Atomic because `awaitInFlightFetch()` reads it off the main thread while
    /// `fetch()` and `clearCache()` write it from the facade's `@MainActor`
    /// callers.
    private let inFlightTask = Atomic<Task<Void, Never>?>(nil)

    /// In-flight lazy fetches keyed by use case, so concurrent presentations
    /// join one request instead of racing to issue several.
    private let lazyTasks = Atomic<[UseCase: Task<RemoteConfiguration?, Never>]>([:])

    /// Use cases already warned about, so the `[INTEGRATION]` hint fires once
    /// per use case rather than once per presentation.
    ///
    /// Deliberately NOT cleared by `clearCache()`. The condition it reports is a
    /// property of the INTEGRATION — this app has not enabled the use case in
    /// the portal — not of the cache, so it is just as true after a logout.
    /// Re-warning on every `reset()` would teach publishers to filter our logs,
    /// which costs us the next warning that actually matters.
    private let warnedUseCases = Atomic<Set<UseCase>>([])

    /// The identity the most recent `fetch` was issued for.
    ///
    /// Cancellation alone can't make caching safe: it is cooperative, so a
    /// response can already be decoded and on its way to the cache when the
    /// cancellation arrives, and the check-then-write is not one atomic step.
    /// A new `identify()` landing in that window would let the previous user's
    /// response cache itself under the new user's session. Comparing the
    /// identity a result was *requested* for against the current one closes the
    /// window regardless of scheduling.
    private let currentIdentity = Atomic<ConfigIdentity?>(nil)

    /// The inputs that determine which config the backend resolves.
    internal struct ConfigIdentity: Equatable, Sendable {
        let userId: String
        let language: String?
    }

    /// A cached configuration together with the identity it was resolved for.
    /// A nil identity is identity-less (the cold-start disk blob, the demoted
    /// app-facts entry) and serves any session.
    private struct StampedConfiguration {
        let configuration: RemoteConfiguration
        let identity: ConfigIdentity?
    }

    /// Thread-safe cached configuration per use case.
    ///
    /// Only `.reduceChurn` is persisted to disk. Every other entry stays in-memory:
    /// a disk-restored `UIConfiguration` decodes with `template == nil` (the
    /// template is deliberately excluded from `Codable`), and a cached
    /// template-less entry would make that use case no-op forever instead of
    /// being refilled once per session.
    private let _configs = Atomic<[UseCase: StampedConfiguration]>([:])

    /// The stamp check EVERY sync read passes through: an entry resolved for
    /// a different identity is invisible, no matter how it got in. A lazy
    /// fetch that suspends across an identify is a different task from the
    /// primary the guard cancels, and its identity-checked write can race the
    /// clear, so the clear-on-change is an optimisation, never the guard.
    private func currentEntry(for useCase: UseCase) -> RemoteConfiguration? {
        guard let entry = _configs.value[useCase] else { return nil }
        if let stamp = entry.identity, stamp != currentIdentity.value { return nil }
        return entry.configuration
    }

    /// Current churn-intervention configuration snapshot (thread-safe read)
    var config: RemoteConfiguration? { currentEntry(for: .reduceChurn) }

    /// Configuration for `useCase`, or nil when it hasn't been fetched yet
    /// (or the fetch failed).
    func config(for useCase: UseCase) -> RemoteConfiguration? { currentEntry(for: useCase) }

    // MARK: - Convenience Accessors

    var ui: UIConfiguration? { config?.ui }
    var entitlements: EntitlementConfiguration? { config?.entitlements }
    var experiments: ExperimentConfiguration? { config?.experiments }
    var iapProductId: String? { entitlements?.iapProductId }
    var usesIAPMode: Bool { entitlements?.usesIAPMode ?? false }

    func ui(for useCase: UseCase) -> UIConfiguration? { config(for: useCase)?.ui }
    func entitlements(for useCase: UseCase) -> EntitlementConfiguration? { config(for: useCase)?.entitlements }
    func iapProductId(for useCase: UseCase) -> String? { entitlements(for: useCase)?.iapProductId }

    // MARK: - Initialization

    init(
        repository: RemoteConfigurationRepository,
        integrationWarning: @escaping (String) -> Void = { Logger.warn($0) }
    ) {
        self.repository = repository
        self.integrationWarning = integrationWarning

        // Load last-known-good config from disk (instant availability).
        // Identity-less: the blob is not stamped, and pre-dates the session.
        if let cached = repository.getLocal() {
            _configs.value = [.reduceChurn: StampedConfiguration(configuration: cached, identity: nil)]
            Logger.info("📦 [RemoteConfig] Loaded cached config from disk: variantId=\(cached.ui.variantId ?? "nil")")
        } else {
            Logger.debug("🔍 [RemoteConfig] No cached config on disk")
        }
    }

    // MARK: - Public Methods

    /// Fetches remote configuration. Fire-and-forget — cancels any in-flight request (latest identity wins).
    /// `language` overrides device locale on the backend when non-nil; pass
    /// `userManager.userAttributes?.language` from callers so an in-app picker
    /// is the single source of truth.
    ///
    /// Resolves **churn intervention** and caches every use case the app is
    /// enabled for from the same response's prefetch block.
    func fetch(userId: String, sdkVersion: String, language: String? = nil) {
        Logger.debug("🔄 [RemoteConfig] Starting fetch for userId=\(userId), language=\(language ?? "device"), hasExistingConfig=\(config != nil)")
        inFlightTask.value?.cancel()

        let identity = ConfigIdentity(userId: userId, language: language)
        let previousIdentity = currentIdentity.value

        // Publish the new identity BEFORE dispatching anything, so a lazy fetch
        // still in flight for the previous one is rejected at its cache step
        // rather than overwriting this identity's config.
        currentIdentity.value = identity

        // Identity or locale changed ⇒ every other use case's config is stale.
        invalidateLazyConfigs()

        // A newly identified user must not see the previous identity's arm
        // while their own fetch is in flight. Stored templates are deleted
        // (they are identity-stamped anyway, this keeps a logged-out user's
        // arm off the disk), and the served churn entry is demoted to its
        // app-level facts, so sync reads fall to the new identity's stored
        // template or the floor rather than rendering the old assignment.
        if let previousIdentity, previousIdentity != identity {
            repository.clearStoredTemplates()
            _configs.mutate { configs in
                guard let churn = configs[.reduceChurn]?.configuration else { return }
                configs[.reduceChurn] = StampedConfiguration(
                    configuration: RemoteConfiguration(
                        ui: UIConfiguration(variantId: nil, values: churn.ui.values, template: nil),
                        entitlements: churn.entitlements,
                        experiments: churn.experiments
                    ),
                    identity: nil
                )
            }
        }

        inFlightTask.value = Task {
            await load(identity: identity, sdkVersion: sdkVersion)
        }
    }

    /// Resolves the configuration a presentation should render, as the
    /// three-rung availability ladder, uniform across use cases.
    ///
    /// 1. **FRESH**: join a `/config` fetch already in flight, bounded by
    ///    `fetchCeiling`. Only waits when one is actually in flight, so offline
    ///    never regresses from instant-render to ceiling-then-render. A use case
    ///    the app has no `app_use_cases` row for is fetched here once (serving
    ///    is ungated, so it must still be resolvable) under the same ceiling.
    /// 2. **LAST KNOWN GOOD**: the stored template for this use case (an
    ///    atomic variant-and-template unit), married with the persisted config
    ///    blob at read time.
    /// 3. **FLOOR**: nothing to install; the SDUI layer renders this use
    ///    case's own embedded floor. A server fresh-null is NOT this case: the
    ///    fresh config stays installed and the presentation declines.
    @discardableResult
    func loadConfig(
        for useCase: UseCase,
        userId: String,
        sdkVersion: String,
        language: String?
    ) async -> RemoteConfiguration? {
        // Rung 1. Nothing can be called "not prefetched" until the `/config`
        // response that would have carried it has landed. Waiting here keeps
        // that true for every caller, and stops a presentation racing startup
        // from both refetching and being warned for an integration that is in
        // fact correct. Bounded, so a slow network costs at most the ceiling.
        await awaitInFlightFetch(timeout: Self.fetchCeiling)

        if let cached = config(for: useCase), cached.ui.template != nil || cached.ui.fromNetwork {
            return cached
        }

        if useCase != .reduceChurn, let fetched = await lazilyFetch(
            useCase: useCase, userId: userId, sdkVersion: sdkVersion, language: language
        ) {
            return fetched
        }

        // Rung 2. Stored reads are identity-stamped, but this CALL may itself
        // carry a superseded identity (the detached warm-up window), and the
        // repository persists at the fetch itself, so a superseded caller can
        // have just stored its OWN old identity's template. Rung 2 therefore
        // requires an established session identity matching the caller's:
        // nil (post-reset, pre-fetch) serves nothing, and a superseded caller
        // cannot install what it just stored. Every production launch passes
        // through `fetch` before any presentation, so this costs nothing.
        let requestedFor = ConfigIdentity(userId: userId, language: language)
        let callerIsCurrent = currentIdentity.value == requestedFor
        if callerIsCurrent, let stored = storedConfiguration(for: useCase, userId: userId, language: language) {
            _configs.mutate { $0[useCase] = StampedConfiguration(configuration: stored, identity: requestedFor) }
            Logger.info("📦 [RemoteConfig] Rung 2 for \(useCase.rawValue): rendering the stored template (variantId=\(stored.ui.variantId ?? "nil"))")
            return stored
        }

        // Rung 3 is the SDUI layer's floor, so there is nothing to install here.
        return config(for: useCase)
    }

    /// The lazy `?useCase=` fetch, bounded by the same ceiling as rung 1.
    /// Concurrent presentations join one request instead of racing to issue
    /// several; a request that outruns the ceiling still caches when it lands.
    private func lazilyFetch(
        useCase: UseCase,
        userId: String,
        sdkVersion: String,
        language: String?
    ) async -> RemoteConfiguration? {
        warnPrefetchWasMissed(useCase)

        let requestedFor = ConfigIdentity(userId: userId, language: language)
        let repository = self.repository
        let task: Task<RemoteConfiguration?, Never> = lazyTasks.mutate { tasks in
            if let existing = tasks[useCase] { return existing }
            // The in-flight task caches its result before clearing itself, so a
            // straggler that raced the clear finds the config here and joins a
            // resolved value instead of issuing a duplicate request.
            if let cached = self.config(for: useCase) {
                return Task { cached }
            }
            let created = Task<RemoteConfiguration?, Never> { [weak self] in
                defer { self?.lazyTasks.mutate { $0[useCase] = nil } }
                do {
                    // Requested explicitly, so this resolves the use case
                    // properly — experiments included — rather than taking the
                    // default variant the prefetch block would have carried.
                    let result = try await repository.fetchRemote(
                        userId: userId,
                        sdkVersion: sdkVersion,
                        language: language,
                        useCase: useCase
                    )
                    guard !Task.isCancelled else {
                        Logger.info("🔄 [RemoteConfig] Discarding stale \(useCase.rawValue) result (newer identity)")
                        return nil
                    }
                    // Cache only if the identity this was requested for is still
                    // current. Covers the detached warm-up window described on
                    // `currentIdentity`, and a result that lands between a
                    // cancellation check and this write.
                    guard self?.currentIdentity.value == requestedFor else {
                        Logger.info("🔄 [RemoteConfig] Discarding \(useCase.rawValue) config for a superseded identity")
                        return nil
                    }
                    // The repository already persisted what this response
                    // resolved, at the fetch itself.
                    self?._configs.mutate {
                        $0[useCase] = StampedConfiguration(configuration: result.configuration, identity: requestedFor)
                    }
                    Logger.info("✅ [RemoteConfig] Fetched \(useCase.rawValue): variantId=\(result.configuration.ui.variantId ?? "none")")
                    return result.configuration
                } catch {
                    Logger.warn("⚠️ [RemoteConfig] \(useCase.rawValue) fetch failed: \(error.localizedDescription)")
                    return nil
                }
            }
            tasks[useCase] = created
            return created
        }

        // Outer nil: the ceiling expired. Inner nil: the fetch finished empty.
        let joined = await withCeiling(Self.fetchCeiling) { await task.value }
        return joined ?? nil
    }

    /// Rung 2: the stored template married with the persisted config blob.
    ///
    /// The stored template supplies everything the surface renders: variant
    /// identity, template, and its own `uiValues` snapshot (only churn's blob
    /// persists, so borrowing the blob's values would lose every other use
    /// case's dashboard copy). The identity and template travel as an atomic
    /// pair, so a stored claim can always render, and on a variantId
    /// disagreement with the blob the stored side wins. The blob supplies the
    /// app-level facts, entitlements and experiments; a stored template with
    /// no blob is treated as absent.
    private func storedConfiguration(
        for useCase: UseCase,
        userId: String,
        language: String?
    ) -> RemoteConfiguration? {
        guard let stored = repository.storedTemplate(for: useCase, userId: userId, language: language),
              let blob = repository.getLocal(),
              let template = UIConfiguration.parseTemplate(stored.template) else { return nil }

        let ui = UIConfiguration(
            variantId: stored.variantId,
            variantName: stored.variantName,
            values: stored.uiValues,
            template: template
        )
        return RemoteConfiguration(ui: ui, entitlements: blob.entitlements, experiments: blob.experiments)
    }

    /// Performs one `/config` round trip for `identity` and caches what it
    /// returns — the resolved use case plus every use case it prefetched —
    /// provided `identity` is still current when the response lands.
    ///
    /// Returns the resolved configuration, or nil when the request failed or
    /// its result was discarded as stale.
    ///
    /// Exposed beyond `fetch` so the superseded-identity path can be exercised
    /// directly: reproducing the real scheduling race would be timing-dependent,
    /// while a response that carries a *previous* identity's parameters models
    /// the same window deterministically.
    @discardableResult
    internal func load(identity: ConfigIdentity, sdkVersion: String) async -> RemoteConfiguration? {
        let startTime = Date()
        var loadSource = "remote"
        var resolved: RemoteConfiguration?

        do {
            let bundle = try await repository.fetchRemote(
                userId: identity.userId,
                sdkVersion: sdkVersion,
                language: identity.language
            )

            guard currentIdentity.value == identity else {
                Logger.info("🔄 [RemoteConfig] Discarding stale result (newer identity)")
                return nil
            }

            _configs.mutate { configs in
                configs[bundle.useCase] = StampedConfiguration(configuration: bundle.configuration, identity: identity)
                for (useCase, configuration) in bundle.prefetched {
                    configs[useCase] = StampedConfiguration(configuration: configuration, identity: identity)
                }
            }
            // The repository persisted the resolved templates inside the
            // fetch itself, so they land before this blob save: a torn write
            // leaves a template without a blob, which rung 2 reads as absent.
            // The blob holds churn intervention only (see `_configs`).
            repository.saveLocal(bundle.configuration)
            resolved = bundle.configuration
            Logger.info("✅ [RemoteConfig] Fetched: variantId=\(bundle.configuration.ui.variantId ?? "none"), prefetched=\(bundle.prefetched.keys.map(\.rawValue).sorted())")
        } catch {
            if Task.isCancelled {
                Logger.info("🔄 [RemoteConfig] Fetch cancelled (newer identity)")
                return nil
            }
            if case EncoreError.protocol(.decoding(let underlying)) = error {
                // Strict-by-design: a response that fails the contract is a
                // deploy-ordering bug to SURFACE, not paper over. Contracts are
                // synced against the deployed backend as a release step.
                Logger.warn("""
                [CONTRACT] /config response failed to decode — the backend is likely \
                behind this SDK's contract (missing/renamed required fields). \
                Local dev: pull + restart the backend. Release: the backend contract \
                must be deployed BEFORE this SDK version ships. Until then this \
                session renders last-known-good or the embedded fallback. \
                Underlying: \(underlying)
                """)
            } else {
                Logger.warn("⚠️ [RemoteConfig] Fetch failed: \(error.localizedDescription)")
            }
            loadSource = config != nil ? "cache" : "fallback"
        }

        // Track analytics
        let duration = Date().timeIntervalSince(startTime) * 1000
        trackConfigLoaded(loadSource: loadSource, loadDurationMs: duration)
        return resolved
    }

    /// Awaits the `/config` request already in flight, if any.
    ///
    /// An enabled use case is cached the moment that response lands, so a
    /// presentation racing startup would otherwise see an empty cache, fetch a
    /// config that was already on its way, and get warned for an integration
    /// that is in fact correct. Awaiting the request already running settles
    /// which of the two fill paths actually applies. Returns immediately once
    /// the fetch has finished, and when none was ever started.
    ///
    /// Unbounded: for background warm-up, where waiting costs no user-facing
    /// latency. Presentations use the `timeout:` overload.
    func awaitInFlightFetch() async {
        await inFlightTask.value?.value
    }

    /// Awaits the in-flight `/config` fetch for at most `timeout` seconds.
    /// Returns immediately when none is in flight, so offline never regresses
    /// from instant-render to ceiling-then-render.
    func awaitInFlightFetch(timeout: TimeInterval) async {
        guard let task = inFlightTask.value else { return }
        _ = await withCeiling(timeout) { await task.value }
    }

    /// Runs `work` under a deadline, abandoning it (not cancelling the work it
    /// awaits) on expiry.
    ///
    /// Deliberately unstructured, the same shape and for the same reason as
    /// `IAPClient.fetchProductInfo`: a task group would keep awaiting a child
    /// that may not observe cancellation, reinstating the stall the bound
    /// exists to prevent. The loser here is only the *wait*: the fetch itself
    /// keeps running and still caches when it lands.
    private func withCeiling<T: Sendable>(
        _ timeout: TimeInterval,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let resumed = Atomic<Bool>(false)
        func claim() -> Bool {
            resumed.mutate { (flag: inout Bool) -> Bool in
                if flag { return false }
                flag = true
                return true
            }
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let timeoutTask = Atomic<Task<Void, Never>?>(nil)
            let waiter = Task {
                let value = await work()
                if claim() {
                    // Cancel the loser: an uncancelled sleeper would stay live
                    // for the full ceiling on every bounded wait.
                    timeoutTask.value?.cancel()
                    continuation.resume(returning: value)
                }
            }
            timeoutTask.value = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if claim() {
                    waiter.cancel()
                    Logger.info("⏱️ [RemoteConfig] Config wait hit the \(Int(timeout))s ceiling, rendering last-known-good")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Clears all cached configuration (memory + disk). Called on user logout/reset.
    func clearCache() {
        inFlightTask.mutate { task in
            task?.cancel()
            task = nil
        }
        // No identity ⇒ nothing in flight may cache. The `fetch` that follows a
        // reset republishes the new one.
        currentIdentity.value = nil
        invalidateLazyConfigs()
        _configs.value = [:]
        repository.clearLocal()
        repository.clearStoredTemplates()
        Logger.info("🗑️ [RemoteConfig] Cache cleared (memory + disk)")
    }

    // MARK: - Private

    /// Drops every other use case's config and cancels their in-flight fetches.
    /// The churn-intervention entry survives (demoted to app-level facts on an
    /// identity change, see `fetch`) so entitlements and copy keep serving
    /// while the new identity's fetch is in flight.
    private func invalidateLazyConfigs() {
        lazyTasks.mutate { tasks in
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }
        _configs.mutate { configs in
            configs = configs.filter { $0.key == .reduceChurn }
        }
    }

    /// The `[INTEGRATION]` hint: this presentation paid for a `/config` request
    /// it did not have to.
    ///
    /// Deliberately NOT an error and worded so nobody files a bug against a
    /// working integration — the sheet still shows, it was just slower once.
    /// Names the ONE remedy there is: enabling the use case in the portal. There
    /// is deliberately no code-level prefetch API on any SDK, so offering a
    /// second route here would be advice a publisher cannot take.
    ///
    /// Wording is kept in step with Android's `warnNotPrefetched` on purpose: a
    /// cross-platform publisher hitting this on both SDKs should read the same
    /// sentence, not two descriptions of one problem.
    private func warnPrefetchWasMissed(_ useCase: UseCase) {
        let isFirst = warnedUseCases.mutate { warned -> Bool in warned.insert(useCase).inserted }
        guard isFirst else { return }

        integrationWarning("""
        [INTEGRATION] Presented '\(useCase.rawValue)' before its config was cached, so this presentation \
        waited on a /config request. It worked — this is a speed hint, not an error, and it is logged once. \
        To make it instant: enable '\(useCase.rawValue)' for this app in the Encore portal — it also \
        drives your setup state and analytics.
        """)
    }

    // MARK: - Analytics

    private func trackConfigLoaded(loadSource: String, loadDurationMs: Double) {
        // Suppress emits when the loaded config matches what we already
        // reported. Audit (Apr 2026, #4) showed this event was firing on
        // every fetch regardless of whether the content actually changed,
        // contributing 9.6% of total event volume for zero product signal.
        //
        // Dedup is by CONTENT hash, and it has to be: variantId is an
        // assignment identity, not a content identity. Templates are edited in
        // git under a stable id (the portal cannot mint a new one for changed
        // content), so keying this on variantId would miss every republish.
        //
        // A failed load (no config → nil hash) dedupes under a sentinel:
        // before this, every failed fetch re-emitted while successes deduped,
        // overstating "% of loads that fell back" by an unbounded factor.
        let dedupKey = currentConfigHash() ?? "no_config_\(loadSource)"
        if shouldSuppressLoadedEvent(hash: dedupKey) {
            return
        }

        // `load()` fetches `/config` with no `?useCase=`, so the entry it
        // resolves — the one `config`, the variant id and the dedup hash above
        // all read — is churn intervention. Stamping the key it was read under
        // keeps the three from ever describing different configurations. The
        // lazy per-use-case fetch does not emit this event at all.
        let resolvedUseCase = UseCase.reduceChurn
        analyticsClient?.track(SDUIConfigLoadedEvent(
            variant: SDUIVariantContext(variantId: config(for: resolvedUseCase)?.ui.variantId, useCase: resolvedUseCase),
            loadSource: loadSource,
            loadDurationMs: loadDurationMs
        ))
    }

    /// SHA-256 of the current churn-intervention `RemoteConfiguration` JSON
    /// encoding. Stable across runs because we use a sorted-keys encoder.
    /// Returns nil when no config is loaded (no event to dedup against in that
    /// case).
    private func currentConfigHash() -> String? {
        guard let config else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true when the new hash matches the last-emitted one, in which
    /// case the event is dropped. On a hash change (or first load), records
    /// the new hash and returns false. Fail-open if storage is unavailable.
    private func shouldSuppressLoadedEvent(hash: String) -> Bool {
        if repository.lastEmittedConfigHash() == hash {
            return true
        }
        repository.recordEmittedConfigHash(hash)
        return false
    }
}
