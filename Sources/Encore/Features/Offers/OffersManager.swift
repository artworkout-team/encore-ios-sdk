// Sources/Encore/Features/Offers/OffersManager.swift
//
// Domain logic for offer operations.
// Caching and prefetch concurrency are handled by OffersCache (actor).
//

import CryptoKit
import Foundation

// MARK: - OffersCache (actor)

/// Thread-safe offer cache with prefetch support.
/// Uses Swift actor isolation instead of manual locks — the compiler
/// enforces that all mutable state is accessed serially.
internal actor OffersCache {

    /// The variant's `offerDisplayOrder` for a use case, so the prefetch warms the offer shown FIRST.
    /// Injected per instance by `ServiceContainer`; nil in tests.
    private let displayOrder: @Sendable (UseCase?) -> [Int]?

    init(displayOrder: @escaping @Sendable (UseCase?) -> [Int]? = { _ in nil }) {
        self.displayOrder = displayOrder
    }

    /// Cache TTL — 5 minutes.
    ///
    /// Not raised on purpose. The server's own staleness budget is 30s for the
    /// eligible campaign set and 60s+30s for the app grant, campaigns leave the
    /// set at arbitrary instants via `endDate`, and `POST /transactions` does
    /// NOT re-validate campaign status — so a tap on an over-stale offer books a
    /// real transaction against a campaign that is no longer buying. Five
    /// minutes is what iOS and Android already ship; the amplification fix is to
    /// make this TTL actually bind, not to widen it.
    static let cacheTTL: TimeInterval = 5 * 60

    /// What `/offers/search` actually varies on.
    ///
    /// `countryCode` (geo eligibility) and `language` (creative locale) are in the
    /// key. The search reads other attributes too (`custom` flags such as the
    /// college-town boost, device signals), so a real change to them clears the
    /// cache instead (`identify`, `setUserAttributes`); re-sending the same bag
    /// on every foreground changes nothing and costs no round trip.
    private struct CacheKey: Hashable {
        let userId: String
        let variantId: String?
        /// The server resolves the surface from it when no variant is sent.
        let useCase: UseCase?
        /// Set only for a placement `/config` lists as ruled (HQ-0273).
        let placementId: String?
        let countryCode: String?
        let language: String?

        init(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase?, placementId: String?) {
            self.userId = userId
            self.variantId = variantId
            self.useCase = useCase
            self.placementId = placementId
            self.countryCode = attributes?.countryCode
            self.language = attributes?.languageTag
        }

        /// Who the set is for, apart from which surface. A prefetch for a
        /// different identity supersedes; another surface for the same one
        /// runs beside it.
        func sameIdentity(as other: CacheKey) -> Bool {
            userId == other.userId && countryCode == other.countryCode && language == other.language
        }
    }

    private struct CacheEntry {
        let key: CacheKey
        let response: OfferResponse
        let timestamp: Date
    }

    /// One entry per key, so a ruled placement's set sits beside the shared one
    /// instead of evicting it. Bounded by the TTL and the current user.
    private var entries: [CacheKey: CacheEntry] = [:]
    /// In flight per key, so a ruled placement's prefetch never cancels the
    /// shared one (or the reverse).
    private var prefetchTasks: [CacheKey: InFlight] = [:]
    /// Bumped per key by `remove` and for every key by `clear`, so a direct fetch that
    /// started before either cannot store its now-stale answer.
    private var generations: [CacheKey: Int] = [:]
    private var clearGeneration = 0

    /// Where a fetch for these arguments stands; pass it back to `store(..., generation:)`.
    func generation(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil) -> (clear: Int, key: Int) {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId)
        return (clearGeneration, generations[key] ?? 0)
    }

    private struct InFlight {
        /// Tells this run apart from a later one for the same key, so a run
        /// that finishes after `clear()` cannot drop its replacement.
        let token: UUID
        let task: Task<OfferResponse?, Never>
    }

    // MARK: - Cache reads

    /// Returns cached response if fresh and matching, otherwise nil.
    func cached(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil) -> OfferResponse? {
        cached(CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId))
    }

    /// When the live entry for these arguments stops being served, or nil when there is none.
    func expiry(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil) -> Date? {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId)
        guard let entry = entries[key], !isExpired(entry) else { return nil }
        return entry.timestamp.addingTimeInterval(Self.cacheTTL)
    }

    private func cached(_ key: CacheKey) -> OfferResponse? {
        guard let entry = entries[key], !isExpired(entry) else { return nil }
        Logger.debug(.offers, "Using prefetched offers (\(entry.response.offerCount) offers, age=\(ageMs(entry))ms)")
        return entry.response
    }

    /// Returns the in-flight prefetch task if it matches this request, otherwise nil.
    func inFlightTask(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil) -> Task<OfferResponse?, Never>? {
        inFlightTask(CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId))
    }

    private func inFlightTask(_ key: CacheKey) -> Task<OfferResponse?, Never>? {
        guard let task = prefetchTasks[key]?.task, !task.isCancelled else { return nil }
        return task
    }

    /// Stores a response in the cache.
    /// Stores only if nothing evicted this set (or cleared the cache) since `generation` was read.
    func store(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil, response: OfferResponse, generation: (clear: Int, key: Int)) {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId)
        guard generation.clear == clearGeneration, generation.key == (generations[key] ?? 0) else {
            Logger.debug(.offers, "Dropped a fetch that finished after its set was evicted")
            return
        }
        store(key, response: response)
    }

    func store(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase? = nil, placementId: String? = nil, response: OfferResponse) {
        store(CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId), response: response)
    }

    private func store(_ key: CacheKey, response: OfferResponse) {
        // A live set replaced under a mounted trigger (a fresh prize-promise search): it re-gates.
        let replacingLive = entries[key].map { !isExpired($0) } ?? false
        entries = entries.filter { $0.key.userId == key.userId && !isExpired($0.value) }
        entries[key] = CacheEntry(key: key, response: response, timestamp: Date())
        if replacingLive { TriggerHeldOffers.changed() }
    }

    /// Stores a prefetch's set only while that run is still the key's own. The
    /// check runs here, on the actor, because a clear() or a new identity can
    /// land between the search returning and this call.
    private func land(_ response: OfferResponse, key: CacheKey, token: UUID) -> Bool {
        guard prefetchTasks[key]?.token == token else { return false }
        store(key, response: response)
        return true
    }

    // MARK: - Prefetch

    #if DEBUG
    /// Runs between a prefetch's search returning and its set being stored.
    private var afterSearchForTesting: (@Sendable () async -> Void)?
    func setAfterSearchForTesting(_ hook: (@Sendable () async -> Void)?) { afterSearchForTesting = hook }
    #endif

    /// Fire-and-forget prefetch. Reuses an offer set the SDK already holds;
    /// otherwise cancels in-flight prefetches for another identity (latest
    /// identity wins) and leaves other keys of the same identity running.
    /// Returns the run it started, nil when it started none.
    @discardableResult
    func startPrefetch(
        userId: String,
        attributes: UserAttributes?,
        variantId: String?,
        useCase: UseCase? = nil,
        placementId: String? = nil,
        search: @Sendable @escaping (String, UserAttributes?, String?) async throws -> OfferResponse
    ) -> Task<OfferResponse?, Never>? {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId)

        // The whole point of a TTL: warming what we already hold is a wasted
        // round trip. configure() → identify() → setUserAttributes() all warm
        // the same set within seconds of launch.
        if cached(key) != nil {
            Logger.debug(.offers, "Prefetch skipped — fresh offers already cached")
            return nil
        }
        if inFlightTask(key) != nil {
            Logger.debug(.offers, "Prefetch skipped — one is already in flight for this identity")
            return nil
        }

        for (other, inFlight) in prefetchTasks where !other.sameIdentity(as: key) {
            inFlight.task.cancel()
            prefetchTasks[other] = nil
        }

        let token = UUID()
        #if DEBUG
        let afterSearch = afterSearchForTesting
        #endif
        let run: @Sendable () async -> OfferResponse? = { [weak self] in
            do {
                Logger.debug(.offers, "Prefetching offers for user: \(userId), variantId: \(variantId ?? "none")")
                let response = try await search(userId, attributes, variantId)
                guard !Task.isCancelled else {
                    Logger.debug(.offers, "Prefetch cancelled for user: \(userId)")
                    return nil
                }
                #if DEBUG
                await afterSearch?()
                #endif
                guard await self?.land(response, key: key, token: token) == true else {
                    Logger.debug(.offers, "Prefetch dropped for user: \(userId), the cache moved on while it ran")
                    return nil
                }
                Logger.debug(.offers, "Prefetch complete: \(response.offerCount) offers cached")

                await Self.preloadImages(from: response, displayOrder: self?.displayOrder(useCase))
                return response
            } catch is CancellationError {
                Logger.debug(.offers, "Prefetch cancelled for user: \(userId)")
                return nil
            } catch {
                Logger.warn(.offers, "Prefetch failed: \(error)")
                return nil
            }
        }
        let task = Task { [weak self] () -> OfferResponse? in
            let landed = await run()
            // Leave the map before handing the result out, so a retry right
            // behind a failed run is never skipped as already in flight.
            await self?.finished(key, token: token)
            return landed
        }
        prefetchTasks[key] = InFlight(token: token, task: task)
        return task
    }

    /// Drops a finished prefetch, unless a newer run for the key replaced it.
    private func finished(_ key: CacheKey, token: UUID) {
        guard prefetchTasks[key]?.token == token else { return }
        prefetchTasks[key] = nil
    }

    /// Drops one set and its in-flight prefetch; every other set stays.
    func remove(userId: String, variantId: String?, attributes: UserAttributes?, useCase: UseCase?, placementId: String?) {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: placementId)
        prefetchTasks[key]?.task.cancel()
        prefetchTasks[key] = nil
        entries[key] = nil
        generations[key, default: 0] += 1
    }

    /// Clears cached offers and cancels in-flight prefetches.
    func clear() {
        for inFlight in prefetchTasks.values { inFlight.task.cancel() }
        prefetchTasks = [:]
        entries = [:]
        // Per-key counts restart; the clear generation keeps pre-clear fetches out.
        generations = [:]
        clearGeneration += 1
        Logger.debug(.offers, "Cache cleared")
    }

    // MARK: - Private

    private func isExpired(_ entry: CacheEntry) -> Bool { ageMs(entry) > Int(Self.cacheTTL * 1000) }
    private func ageMs(_ entry: CacheEntry) -> Int { max(0, Int(Date().timeIntervalSince(entry.timestamp) * 1000)) }

    /// The images to prefetch: only the offer the variant DISPLAYS first, which is not the
    /// response's first when it sets `offerDisplayOrder`. Other offers load on display.
    static func prefetchImageURLs(
        in response: OfferResponse, displayOrder: [Int]? = nil, cardWidthPoints: CGFloat, scale: CGFloat
    ) -> [URL] {
        let ordered = displayOrder.map { SDUIContext.applyOfferDisplayOrder($0, to: response.offers) } ?? response.offers
        guard let offer = ordered.first else { return [] }
        return SDUIImageLoader.imageURLs(for: offer, cardWidthPoints: cardWidthPoints, scale: scale)
    }

    /// Prefetches the first displayed offer's images into the SDK image cache. Returns the URLs it schedules.
    @discardableResult
    static func preloadImages(from response: OfferResponse, displayOrder: [Int]? = nil) async -> [URL] {
        let (width, scale) = await MainActor.run { (SDUIImageLoader.defaultCardWidthPoints, SDUIImageLoader.screenScale) }
        let urls = prefetchImageURLs(in: response, displayOrder: displayOrder, cardWidthPoints: width, scale: scale)
        guard !urls.isEmpty else { return [] }
        Task.detached(priority: .utility) {
            Logger.debug(.offers, "Preloading \(urls.count) images")
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { _ = try? await SDUIImageLoader.load(url) }
                }
            }
            Logger.debug(.offers, "Image preload complete")
        }
        return urls
    }
}

// MARK: - OffersManager

/// Domain logic for offer operations.
/// Coordinates between the repository (network) and cache (actor).
/// No locks, no @unchecked Sendable — thread safety is enforced by the compiler via OffersCache actor.
internal struct OffersManager: Sendable {
    private let repository: OffersRepository
    private let cache: OffersCache
    /// Where the per-use-case image-warm manifests live. Optional so tests can
    /// build a manager without one; with none, warming is simply never gated.
    private let storage: KeyValueStore?
    private let displayOrder: @Sendable (UseCase?) -> [Int]?

    #if DEBUG
    /// Test seam: the attributes each prefetch asks /offers with, so a test
    /// can see the host language reach the request. Fired synchronously.
    nonisolated(unsafe) internal static var prefetchAttributesObserverForTesting: ((UserAttributes?) -> Void)?
    #endif

    init(repository: OffersRepository, storage: KeyValueStore? = nil, displayOrder: @escaping @Sendable (UseCase?) -> [Int]? = { _ in nil }) {
        self.repository = repository
        self.cache = OffersCache(displayOrder: displayOrder)
        self.storage = storage
        self.displayOrder = displayOrder
    }

    // MARK: - Prefetch

    /// Fire-and-forget prefetch. Cancels any in-flight prefetch (latest identity wins).
    /// Called from `configure()` so offers are warm when `show()` fires.
    ///
    /// `placementId` is the publisher's label for the placement being warmed, if
    /// any: the launch-time warm has none, `placement(_:).prefetch()` does.
    /// `cachePlacementId` is the label a ruled placement keys the cache on, else nil.
    func prefetch(userId: String, attributes: UserAttributes?, variantId: String? = nil, placementId: String? = nil, useCase: UseCase? = nil, cachePlacementId: String? = nil) {
        #if DEBUG
        Self.prefetchAttributesObserverForTesting?(attributes)
        #endif
        let repo = repository
        Task {
            await cache.startPrefetch(
                userId: userId,
                attributes: attributes,
                variantId: variantId,
                useCase: useCase,
                placementId: cachePlacementId,
                search: { uid, attrs, vid in
                    try await repo.search(userId: uid, attributes: attrs, sdkVersion: Encore.sdkVersion, variantId: vid, placementId: placementId, useCase: useCase)
                }
            )
        }
    }

    // MARK: - Bootstrap Image Warm

    /// Warms the first offer's images for `useCase` into the SDK image cache, at most daily.
    /// Skips the extra `/offers/search` when the last warm is under a day old or
    /// every URL it fetched is still cached.
    func warmImagesIfNeeded(
        useCase: UseCase,
        userId: String,
        attributes: UserAttributes?,
        variantId: String?
    ) async {
        guard !userId.isEmpty else { return }
        let key = Self.warmManifestKey(useCase, userId: userId)
        if let manifest: WarmManifest = storage?.load(key), !manifest.urls.isEmpty {
            if manifest.isFresh {
                Logger.debug(.offers, "Image warm skipped for \(useCase.rawValue), warmed \(manifest.ageHours)h ago")
                return
            }
            if manifest.urls.allSatisfy({ Self.isCached($0) }) {
                Logger.debug(.offers, "Image warm skipped for \(useCase.rawValue), already cached")
                return
            }
        }

        do {
            let response = try await repository.search(
                userId: userId,
                attributes: attributes,
                sdkVersion: Encore.sdkVersion,
                variantId: variantId,
                useCase: useCase
            )
            let urls = await OffersCache.preloadImages(from: response, displayOrder: displayOrder(useCase))
            storage?.save(WarmManifest(urls: urls.map(\.absoluteString)), to: key)
            Logger.debug(.offers, "Image warm for \(useCase.rawValue): \(urls.count) images")
        } catch {
            Logger.debug(.offers, "Image warm for \(useCase.rawValue) failed: \(error)")
        }
    }

    /// What the last image warm fetched, and when. The timestamp is what makes
    /// the gate hold across `URLCache` evictions.
    internal struct WarmManifest: Codable, Sendable {
        /// Minimum spacing between two warms for the same use case and user.
        static let interval: TimeInterval = 24 * 60 * 60

        let urls: [String]
        let warmedAtMs: Int64

        init(urls: [String], warmedAt: Date = Date()) {
            self.urls = urls
            self.warmedAtMs = Int64(warmedAt.timeIntervalSince1970 * 1000)
        }

        var age: TimeInterval { max(0, Date().timeIntervalSince1970 - Double(warmedAtMs) / 1000) }
        var ageHours: Int { Int(age / 3600) }
        var isFresh: Bool { age < Self.interval }
    }

    /// Identity-scoped (hashed, matching Android): user A's warmed set must
    /// not gate user B's warm.
    internal static func warmManifestKey(_ useCase: UseCase, userId: String) -> String {
        let user = SHA256.hash(data: Data(userId.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "encore.image_warm_manifest.\(useCase.rawValue).\(user)"
    }

    private static func isCached(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // Presence, not `cachedData`: that one is ladder-only, and before the host switch
        // every URL is a bucket URL, so this gate would never fire.
        return SDUIImageLoader.isCached(url)
    }

    // MARK: - Fetch Offers

    /// Fetches available offers for the current user.
    /// Returns cached offers if fresh, joins in-flight prefetch if matching, or fetches fresh.
    /// - Parameters:
    ///   - userId: The user identifier.
    ///   - attributes: Optional targeting attributes.
    ///   - variantId: Optional SDUI variant ID for filtering creatives by variant assignment.
    ///   - placementId: Publisher's label for the placement this fetch serves. Reaches
    ///     the wire only when this call actually hits the network — a cache or
    ///     prefetch hit means the placement was already stamped (or not) on the
    ///     request that filled the cache.
    ///   - maxPostbackTimeMs: Optional filter restricting offers to campaigns whose postback
    ///     latency fits within this window. Passed for strict unlock mode.
    ///   - useCase: The surface being filled; part of the cache key.
    ///   - cachePlacementId: Set only for a placement `/config` lists as ruled, which
    ///     then gets its own cache entry; nil reuses the shared set, as today.
    ///   - purpose: Sent only when this call reaches the network; see `OffersRepository.search`.
    func fetchOffers(
        userId: String,
        attributes: UserAttributes?,
        variantId: String? = nil,
        placementId: String? = nil,
        maxPostbackTimeMs: Int? = nil,
        useCase: UseCase? = nil,
        cachePlacementId: String? = nil,
        publisherRewardDailyLimit: Int? = nil,
        purpose: String? = nil
    ) async throws -> OfferResponse {
        guard !userId.isEmpty else {
            throw EncoreError.domain("userId cannot be empty")
        }

        // Cache/prefetch paths only apply to default (non-strict) fetches, since
        // maxPostbackTimeMs changes the eligible offer set. A prize promise must be
        // the server's current answer, and a cached list never asked for one.
        if maxPostbackTimeMs == nil, publisherRewardDailyLimit == nil {
            if let cached = await cache.cached(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId) {
                return cached
            }

            if let task = await cache.inFlightTask(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId) {
                Logger.debug(.offers, "Waiting for in-flight prefetch to complete")
                if let result = await task.value {
                    Logger.debug(.offers, "Using just-completed prefetch (\(result.offerCount) offers)")
                    return result
                }
            }
        }

        Logger.debug(.offers, "Fetching offers for user: \(userId), variantId: \(variantId ?? "none")")
        let generation = await cache.generation(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId)
        let response = try await repository.search(
            userId: userId,
            attributes: attributes,
            sdkVersion: Encore.sdkVersion,
            variantId: variantId,
            placementId: placementId,
            maxPostbackTimeMs: maxPostbackTimeMs,
            useCase: useCase,
            publisherRewardDailyLimit: publisherRewardDailyLimit,
            purpose: purpose
        )
        if maxPostbackTimeMs == nil {
            // The list is reusable; the promise is only ever read fresh.
            await cache.store(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId,
                              response: response.withPublisherRewardPromise(nil), generation: generation)
        }
        Logger.info(.offers, "Received \(response.offerCount) offers")
        return response
    }

    // MARK: - Cache Management

    /// Clears cached offers. Call on reset/logout or when attributes change.
    func clearCache() {
        Task { await cache.clear() }
    }

    /// When the cached set `fetchOffers` would read for these arguments expires, or nil if none is held.
    func cacheExpiry(userId: String, attributes: UserAttributes?, variantId: String?, useCase: UseCase?, cachePlacementId: String?) async -> Date? {
        await cache.expiry(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId)
    }

    /// Drops the one cached set `fetchOffers` would read for these arguments, so the next
    /// fetch for them searches again. Other use cases and placements keep theirs.
    func evict(userId: String, attributes: UserAttributes?, variantId: String?, useCase: UseCase?, cachePlacementId: String?) async {
        await cache.remove(userId: userId, variantId: variantId, attributes: attributes, useCase: useCase, placementId: cachePlacementId)
    }
}
