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

    /// Cache TTL — 5 minutes.
    ///
    /// Not raised on purpose. The server's own staleness budget is 30s for the
    /// eligible campaign set and 60s+30s for the app grant, campaigns leave the
    /// set at arbitrary instants via `endDate`, and `POST /transactions` does
    /// NOT re-validate campaign status — so a tap on an over-stale offer books a
    /// real transaction against a campaign that is no longer buying. Five
    /// minutes is what iOS and Android already ship; the amplification fix is to
    /// make this TTL actually bind, not to widen it.
    private static let cacheTTL: TimeInterval = 5 * 60

    /// Max concurrent image preload requests.
    private static let maxImageConcurrency = 6

    /// What `/offers/search` actually varies on.
    ///
    /// `countryCode` (geo eligibility) and `language` (creative locale) are the
    /// only two attributes the endpoint reads functionally — every other
    /// attribute a publisher merges leaves the eligible set byte-identical, so
    /// it must not cost a round trip. Hosts that re-`identify()` on every
    /// foreground with a churning attribute bag were refetching the same offers
    /// each time.
    private struct CacheKey: Equatable {
        let userId: String
        let variantId: String?
        let countryCode: String?
        let language: String?

        init(userId: String, variantId: String?, attributes: UserAttributes?) {
            self.userId = userId
            self.variantId = variantId
            self.countryCode = attributes?.countryCode
            self.language = attributes?.language
        }
    }

    private struct CacheEntry {
        let key: CacheKey
        let response: OfferResponse
        let timestamp: Date
    }

    private var cache: CacheEntry?
    private var prefetchTask: Task<OfferResponse?, Never>?
    private var inFlightKey: CacheKey?

    // MARK: - Cache reads

    /// Returns cached response if fresh and matching, otherwise nil.
    func cached(userId: String, variantId: String?, attributes: UserAttributes?) -> OfferResponse? {
        cached(CacheKey(userId: userId, variantId: variantId, attributes: attributes))
    }

    private func cached(_ key: CacheKey) -> OfferResponse? {
        guard let entry = cache, entry.key == key, !isExpired(entry) else { return nil }
        Logger.debug(.offers, "Using prefetched offers (\(entry.response.offerCount) offers, age=\(ageMs(entry))ms)")
        return entry.response
    }

    /// Returns the in-flight prefetch task if it matches this request, otherwise nil.
    func inFlightTask(userId: String, variantId: String?, attributes: UserAttributes?) -> Task<OfferResponse?, Never>? {
        inFlightTask(CacheKey(userId: userId, variantId: variantId, attributes: attributes))
    }

    private func inFlightTask(_ key: CacheKey) -> Task<OfferResponse?, Never>? {
        guard inFlightKey == key, let task = prefetchTask, !task.isCancelled else { return nil }
        return task
    }

    /// Stores a response in the cache.
    func store(userId: String, variantId: String?, attributes: UserAttributes?, response: OfferResponse) {
        cache = CacheEntry(
            key: CacheKey(userId: userId, variantId: variantId, attributes: attributes),
            response: response,
            timestamp: Date()
        )
    }

    // MARK: - Prefetch

    /// Fire-and-forget prefetch. Reuses an offer set the SDK already holds;
    /// otherwise cancels any in-flight prefetch (latest identity wins).
    func startPrefetch(
        userId: String,
        attributes: UserAttributes?,
        variantId: String?,
        search: @Sendable @escaping (String, UserAttributes?, String?) async throws -> OfferResponse
    ) {
        let key = CacheKey(userId: userId, variantId: variantId, attributes: attributes)

        // The whole point of a TTL: warming what we already hold is a wasted
        // round trip. configure() → identify() → setUserAttributes() all warm
        // the same set within seconds of launch.
        if cached(key) != nil {
            Logger.debug(.offers, "Prefetch skipped — fresh offers already cached")
            return
        }
        if inFlightTask(key) != nil {
            Logger.debug(.offers, "Prefetch skipped — one is already in flight for this identity")
            return
        }

        prefetchTask?.cancel()
        inFlightKey = key

        prefetchTask = Task { [weak self] in
            do {
                Logger.debug(.offers, "Prefetching offers for user: \(userId), variantId: \(variantId ?? "none")")
                let response = try await search(userId, attributes, variantId)
                guard !Task.isCancelled else {
                    Logger.debug(.offers, "Prefetch cancelled for user: \(userId)")
                    return nil
                }
                await self?.store(userId: userId, variantId: variantId, attributes: attributes, response: response)
                Logger.debug(.offers, "Prefetch complete: \(response.offerCount) offers cached")

                // Preload images in a detached task so callers aren't blocked
                Self.preloadImages(from: response)
                return response
            } catch is CancellationError {
                Logger.debug(.offers, "Prefetch cancelled for user: \(userId)")
                return nil
            } catch {
                Logger.warn(.offers, "Prefetch failed: \(error)")
                return nil
            }
        }
    }

    /// Clears cached offers and cancels in-flight prefetch.
    func clear() {
        prefetchTask?.cancel()
        prefetchTask = nil
        inFlightKey = nil
        cache = nil
        Logger.debug(.offers, "Cache cleared")
    }

    // MARK: - Private

    private func isExpired(_ entry: CacheEntry) -> Bool { ageMs(entry) > Int(Self.cacheTTL * 1000) }
    private func ageMs(_ entry: CacheEntry) -> Int { max(0, Int(Date().timeIntervalSince(entry.timestamp) * 1000)) }

    /// Every creative and logo URL a response would render.
    static func imageURLs(in response: OfferResponse) -> [URL] {
        Array(Set(
            response.offers.compactMap { offer -> [URL] in
                [offer.displayPrimaryImageUrl, offer.displayLogoUrl]
                    .compactMap { $0.flatMap { URL(string: $0) } }
            }.flatMap { $0 }
        ))
    }

    /// Preloads creative images into URLSession's shared cache (shared with AsyncImage).
    static func preloadImages(from response: OfferResponse) {
        let urls = imageURLs(in: response)
        guard !urls.isEmpty else { return }

        Task.detached(priority: .utility) {
            Logger.debug(.offers, "Preloading \(urls.count) images")
            await withTaskGroup(of: Void.self) { group in
                var launched = 0
                for url in urls {
                    if launched >= maxImageConcurrency {
                        await group.next()
                    }
                    group.addTask {
                        _ = try? await URLSession.shared.data(from: url)
                    }
                    launched += 1
                }
            }
            Logger.debug(.offers, "Image preload complete")
        }
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

    init(repository: OffersRepository, storage: KeyValueStore? = nil) {
        self.repository = repository
        self.cache = OffersCache()
        self.storage = storage
    }

    // MARK: - Prefetch

    /// Fire-and-forget prefetch. Cancels any in-flight prefetch (latest identity wins).
    /// Called from `configure()` so offers are warm when `show()` fires.
    ///
    /// `placementId` is the publisher's label for the placement being warmed, if
    /// any: the launch-time warm has none, `placement(_:).prefetch()` does.
    func prefetch(userId: String, attributes: UserAttributes?, variantId: String? = nil, placementId: String? = nil) {
        let repo = repository
        Task {
            await cache.startPrefetch(
                userId: userId,
                attributes: attributes,
                variantId: variantId,
                search: { uid, attrs, vid in
                    try await repo.search(userId: uid, attributes: attrs, sdkVersion: Encore.sdkVersion, variantId: vid, placementId: placementId)
                }
            )
        }
    }

    // MARK: - Bootstrap Image Warm

    /// Warms `useCase`'s offer images into `URLCache.shared` once per device,
    /// not once per launch.
    ///
    /// Two gates, either of which skips the extra `/offers/search`: the URLs the
    /// last warm fetched are all still in the shared cache, or the last warm was
    /// less than a day ago. The manifest alone was not enough — `URLCache.shared`
    /// is small and creatives are large, so iOS evicts them within hours and the
    /// gate then re-fetched the whole set on nearly every launch, once per
    /// enabled use case, on both `configure()` and every `identify()`. That was
    /// the single largest contributor to iOS's prefetch-to-show ratio. Re-warming
    /// at most daily is safe: this only pre-populates an image cache, the offer
    /// set it renders is fetched for real at `show()` time, and a cold image
    /// costs latency, never correctness.
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
                variantId: variantId
            )
            let urls = OffersCache.imageURLs(in: response)
            OffersCache.preloadImages(from: response)
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
        return URLCache.shared.cachedResponse(for: URLRequest(url: url)) != nil
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
    func fetchOffers(
        userId: String,
        attributes: UserAttributes?,
        variantId: String? = nil,
        placementId: String? = nil,
        maxPostbackTimeMs: Int? = nil
    ) async throws -> OfferResponse {
        guard !userId.isEmpty else {
            throw EncoreError.domain("userId cannot be empty")
        }

        // Cache/prefetch paths only apply to default (non-strict) fetches, since
        // maxPostbackTimeMs changes the eligible offer set.
        if maxPostbackTimeMs == nil {
            if let cached = await cache.cached(userId: userId, variantId: variantId, attributes: attributes) {
                return cached
            }

            if let task = await cache.inFlightTask(userId: userId, variantId: variantId, attributes: attributes) {
                Logger.debug(.offers, "Waiting for in-flight prefetch to complete")
                if let result = await task.value {
                    Logger.debug(.offers, "Using just-completed prefetch (\(result.offerCount) offers)")
                    return result
                }
            }
        }

        Logger.debug(.offers, "Fetching offers for user: \(userId), variantId: \(variantId ?? "none")")
        let response = try await repository.search(
            userId: userId,
            attributes: attributes,
            sdkVersion: Encore.sdkVersion,
            variantId: variantId,
            placementId: placementId,
            maxPostbackTimeMs: maxPostbackTimeMs
        )
        if maxPostbackTimeMs == nil {
            await cache.store(userId: userId, variantId: variantId, attributes: attributes, response: response)
        }
        Logger.info(.offers, "Received \(response.offerCount) offers")
        return response
    }

    /// Checks if there are any offers available.
    func hasOffersAvailable(userId: String, attributes: UserAttributes?, variantId: String? = nil) async -> Bool {
        do {
            let response = try await fetchOffers(userId: userId, attributes: attributes, variantId: variantId)
            return !response.offerList.isEmpty
        } catch {
            Logger.warn(.offers, "Failed to check availability: \(error)")
            return false
        }
    }

    // MARK: - Cache Management

    /// Clears cached offers. Call on reset/logout or when attributes change.
    func clearCache() {
        Task { await cache.clear() }
    }
}
