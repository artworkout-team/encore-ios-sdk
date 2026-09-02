// Sources/Encore/Encore.swift
//
// The public facade for the Encore SDK.
// Thin wrapper that delegates to domain managers.

import UIKit
import Combine
import StoreKit
import SwiftUI

// MARK: - Encore Protocol

/// Public API contract for the Encore SDK.
/// Main-actor isolated: call from UI code (button actions, `.task`) — every
/// method is synchronous or `await`-able from there, and results land on main
/// by construction.
@MainActor
public protocol EncoreProtocol: AnyObject {
    /// Controls whether the claim CTA on offer cards is tappable.
    var isClaimEnabled: Bool { get set }

    func configure(apiKey: String, purchaseController: EncorePurchaseController?, options: Encore.Options)
    func identify(userId: String, attributes: UserAttributes?)
    func setUserAttributes(_ attributes: UserAttributes)
    func reset()

    func placement(_ id: String?) -> any PlacementBuilderProtocol

    var outcomes: AsyncStream<PlacementOutcome> { get }

    func isActive(_ type: Entitlement, in scope: EntitlementScope) async -> Bool
    func isActivePublisher(for type: Entitlement, in scope: EntitlementScope) -> AnyPublisher<Bool, Never>

    func revokeEntitlements() async throws
    func revokeEntitlements(onCompletion: @escaping (Result<Void, EncoreError>) -> Void)
}

// MARK: - Encore SDK Facade

/// Main entry point for the Encore SDK.
///
/// Access via `Encore.shared`. Configure early in app lifecycle,
/// identify users after auth, then present offers via `placement(_:).show()`.
///
/// Thread Safety: The facade is `@MainActor` — invoke from a main-actor
/// context (SwiftUI button action, `.task`, UIKit handler). Off-main
/// invocation of `show()` would order the sheet arbitrarily against your
/// progressing app UI.
@MainActor
public final class Encore: EncoreProtocol {
    internal static let sdkVersion: String = "2.0.2-artworkout.1"
    // Write-once references (assigned in configure(), read pervasively from
    // nonisolated accessors). Safe: Swift reference assignment is atomic and
    // these never change after configuration.
    nonisolated(unsafe) internal var configuration: Configuration?
    nonisolated(unsafe) internal var services: ServiceContainer?
    nonisolated(unsafe) internal var lifecycle: AppLifecycle?

    public static let shared = Encore()

    /// Whether this device can present Encore offers at all — the SDK's iOS 17
    /// floor. Read it BEFORE you commit a surface to a placement: on `false`,
    /// `show()` resolves `.notPresented(.unsupportedOS)` without any UI, so the
    /// host should fall through to its own. Configuration-independent, so it is
    /// safe to read before `configure()`.
    ///
    /// ```swift
    /// guard Encore.isSupported else { showOwnPaywall(); return }
    /// let result = await Encore.placement("paywall_decline").show()
    /// ```
    public nonisolated static var isSupported: Bool {
        if #available(iOS 17.0, *) { true } else { false }
    }

    /// Controls whether the claim CTA on offer cards is tappable.
    /// Set to `false` to gray out and disable the claim button. Runtime-mutable
    /// (not an `Options` field) so hosts can gate claims mid-session.
    public var isClaimEnabled: Bool = true

    /// Purchase mechanism: your ``EncorePurchaseController`` that runs real purchases
    /// through your subscription manager and returns a normalized ``EncorePurchaseResult``.
    /// Set via `configure(apiKey:purchaseController:options:)`. Strong reference (Encore retains it).
    /// Survives `reset()` — build-time wiring, not user state.
    internal var purchaseController: EncorePurchaseController?

    /// Re-prefetches offers for the current user.
    /// Sequenced behind the in-flight /config fetch so the warm-up carries the
    /// variant the server just resolved, not the previous cache (see the same
    /// note in configure()).
    ///
    /// No longer clears the cache first: the cache key carries the identity and
    /// the two attributes `/offers/search` reads functionally, so a change that
    /// moves the offer set misses on its own, and one that cannot (any other
    /// attribute) reuses the set the SDK already holds instead of buying it again.
    private func refetchOffers() {
        Task { [weak self] in
            guard let self, let services = self.services else { return }
            await services.remoteConfigManager.awaitInFlightFetch()
            services.offers.prefetch(
                userId: services.user.currentUserId,
                attributes: services.user.userAttributes,
                variantId: services.remoteConfigManager.ui?.variantId
            )
            // Same warm-up as configure() — see the note there.
            if let productId = services.remoteConfigManager.iapProductId {
                _ = await IAPClient.fetchProductInfo(productId: productId)
            }
            await Self.warmEnabledUseCases(services, userId: services.user.currentUserId)
        }
    }

    /// Disk-gated image warm for every enabled use case beyond churn, whose
    /// images ride the offers prefetch above. Concurrent per use case; runs
    /// after configure's fetch and again on the identify-time refetch, the
    /// same single path.
    private nonisolated static func warmEnabledUseCases(_ container: ServiceContainer, userId: String) async {
        await withTaskGroup(of: Void.self) { group in
            for useCase in UseCase.allCases where useCase != .reduceChurn {
                guard let ui = container.remoteConfigManager.ui(for: useCase) else { continue }
                group.addTask {
                    await container.offers.warmImagesIfNeeded(
                        useCase: useCase,
                        userId: userId,
                        attributes: container.user.userAttributes,
                        variantId: ui.variantId
                    )
                }
            }
        }
    }

    private init() {}
    
    // MARK: - Configuration

    /// Configures the SDK with your API key. Call once, early in app lifecycle.
    /// Pass your ``EncorePurchaseController`` if your app sells a product through
    /// Encore offers; with no controller, the SDK never attempts a purchase.
    public func configure(
        apiKey: String,
        purchaseController: EncorePurchaseController? = nil,
        options: Options = .init()
    ) {
        if let purchaseController {
            self.purchaseController = purchaseController
        }
        guard services == nil else {
            Logger.warn("SDK already configured. Ignoring duplicate configure() call.")
            if let purchaseController {
                Logger.info(.iap, "PurchaseController registered: \(type(of: purchaseController))")
            }
            return
        }
        guard !apiKey.isEmpty else {
            Logger.error(.integration(.invalidApiKey), context: .configuration)
            return
        }

        let config = Configuration(
            apiKey: apiKey,
            logLevel: options.logLevel,
            unlock: options.unlock
        )
        self.configuration = config
        self.lifecycle = AppLifecycle()
        let container = ServiceContainer(configuration: config)
        self.services = container
        // Late strict-unlock verification: refresh grants, then surface on outcomes.
        container.strictUnlockReconciler.onVerified = { [weak self] transactionId in
            try? await entitlementsManager?.refreshEntitlements()
            self?.yieldOutcome(.strictUnlockVerified(transactionId: transactionId))
        }
        container.strictUnlockReconciler.start()

        // Set initial userId for infrastructure (UserManager ensures userId exists)
        let initialUserId = container.user.currentUserId
        container.remoteConfigManager.fetch(
            userId: initialUserId,
            sdkVersion: Encore.sdkVersion,
            language: container.user.userAttributes.language
        )
        // Warm-up is sequenced BEHIND config resolution: prefetching with the
        // disk-cached variant races the /config fetch just dispatched above,
        // shipping a stale (or different-environment) variant id whose
        // server-side creative join can filter every campaign to zero. The
        // prefetch is background warming, so waiting one config round trip
        // costs no user-facing latency; if the fetch fails, the cached
        // variant is the correct offline fallback.
        Task { [weak container] in
            guard let container else { return }
            await container.remoteConfigManager.awaitInFlightFetch()
            container.offers.prefetch(
                userId: initialUserId,
                attributes: container.user.userAttributes,
                variantId: container.remoteConfigManager.ui?.variantId
            )
            // Warm StoreKit's product cache off the tap path: the cold first
            // lookup was the entire present-time tail, and after this the
            // bounded tap-time fetch is a cache hit that never times out.
            if let productId = container.remoteConfigManager.iapProductId {
                _ = await IAPClient.fetchProductInfo(productId: productId)
            }
            // Bootstrap image warm for every OTHER enabled use case. Disk
            // gated, so the extra /offers/search fires roughly once per device
            // rather than once per launch. Reads the CURRENT user at warm
            // time, so an identify() racing configure warms the winner.
            await Self.warmEnabledUseCases(container, userId: container.user.currentUserId)
        }
        container.analytics.identifyUser(userId: initialUserId, attributes: container.user.userAttributes)
        container.errors.setUserId(initialUserId)
        // No explicit distinctId: `sdk_initialized` resolves the same user id as
        // every other event. The bundle id stays on the event as `app_bundle_id`.
        container.analytics.track(
            SDKInitializedEvent(sdkVersion: Encore.sdkVersion, appBundleId: config.appBundleId)
        )
        Logger.info(.configuration, "SDK configured for \(config.environment) (via \(config.environmentSource)) | apiKey: \(String(config.apiKey.prefix(8)))... | baseURL: \(config.environment.apiBaseURL)")
        if let purchaseController {
            Logger.info(.iap, "PurchaseController registered: \(type(of: purchaseController))")
        }
    }

    // MARK: - User Identity
    
    /// Associates a user ID with SDK events and entitlements.
    public func identify(userId: String, attributes: UserAttributes? = nil) {
        // An empty id would otherwise PERSIST: "" is non-nil, so it defeats
        // the anonymous fallback and every event's distinct_id becomes "" —
        // collapsing the publisher's whole install base into one identity.
        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.warn("[INTEGRATION] identify called with an empty userId — ignored; keeping the previous identity. Pass a real user id, or call reset() to return to anonymous.")
            return
        }
        guard let userManager = userManager,
              let entitlementsManager = entitlementsManager,
              let remoteConfigManager = remoteConfigManager,
              let analyticsClient = analyticsClient,
              let errorsClient = errorsClient else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            return
        }
        
        let previousUserId = userManager.currentUserId
        let changed = userManager.identify(userId: userId, attributes: attributes)
        guard changed else { return }

        remoteConfigManager.fetch(
            userId: userId,
            sdkVersion: Encore.sdkVersion,
            language: userManager.userAttributes.language
        )
        if previousUserId != userId || attributes != nil {
            refetchOffers()
        }
        if previousUserId != userId {
            entitlementsManager.reset(thenRefresh: true)
            // A pending strict claim belongs to the previous user.
            strictUnlockReconciler?.clearPending()
        }
        analyticsClient.identifyUser(userId: userManager.currentUserId, attributes: userManager.userAttributes)
        errorsClient.setUserId(userManager.currentUserId)
    }
    
    /// Merges new attributes into the current user's profile.
    public func setUserAttributes(_ attributes: UserAttributes) {
        guard let userManager = userManager,
              let analyticsClient = analyticsClient else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            return
        }

        let previousLanguage = userManager.userAttributes.language
        guard let mergedAttributes = userManager.setAttributes(attributes) else { return }
        analyticsClient.identifyUser(userId: userManager.currentUserId, attributes: mergedAttributes)

        // Re-fetch /config and /offers when the language attribute changes so
        // both paywall copy + SDUI variant text and offer cards reflect the
        // new locale on next presentation. No-op when language is unchanged.
        if attributes.language != nil && attributes.language != previousLanguage,
           let remoteConfigManager = remoteConfigManager {
            remoteConfigManager.fetch(
                userId: userManager.currentUserId,
                sdkVersion: Encore.sdkVersion,
                language: mergedAttributes.language
            )
            refetchOffers()
        }
    }
    
    /// Clears user data and generates a new anonymous ID. Call on logout.
    ///
    /// The registered ``EncorePurchaseController`` and purchase-complete
    /// handler survive reset — they're build-time wiring, not user state.
    public func reset() {
        guard let userManager = userManager,
              let remoteConfigManager = remoteConfigManager,
              let analyticsClient = analyticsClient,
              let errorsClient = errorsClient,
              let entitlementsManager = entitlementsManager else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            return
        }
        
        remoteConfigManager.clearCache()
        sduiConfigManager?.clearForcedFallback()
        services?.offers.clearCache()
        entitlementsManager.reset()
        // A pending strict claim must not follow the next user.
        strictUnlockReconciler?.clearPending()
        let newUserId = userManager.reset()

        // Reset clears stored attributes too, so language reverts to nil here —
        // the next fetch falls back to the device's Accept-Language header.
        remoteConfigManager.fetch(
            userId: newUserId,
            sdkVersion: Encore.sdkVersion,
            language: userManager.userAttributes.language
        )
        analyticsClient.identifyUser(userId: newUserId, attributes: UserAttributes())
        errorsClient.setUserId(newUserId)
    }
    
    // MARK: - Outcomes Stream

    /// Active outcome-stream subscribers. A bare AsyncStream is
    /// single-consumer, so each `outcomes` access registers its own
    /// continuation and every event fans out to all of them.
    private var outcomeContinuations: [UUID: AsyncStream<PlacementOutcome>.Continuation] = [:]

    /// Every resolved placement outcome — plus late events like cross-launch
    /// strict-unlock verification — as an async sequence.
    ///
    /// Each access returns an independent stream, so any number of observers
    /// can listen concurrently. This is the observation channel; use the
    /// value returned by `show()` for control flow at the callsite.
    ///
    /// ```swift
    /// Task {
    ///     for await outcome in Encore.shared.outcomes {
    ///         appState.apply(outcome)
    ///     }
    /// }
    /// ```
    public var outcomes: AsyncStream<PlacementOutcome> {
        AsyncStream { continuation in
            let id = UUID()
            outcomeContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.outcomeContinuations[id] = nil
                }
            }
        }
    }

    /// Fan an event out to every active `outcomes` subscriber.
    internal func yieldOutcome(_ outcome: PlacementOutcome) {
        for continuation in outcomeContinuations.values {
            continuation.yield(outcome)
        }
    }

    // MARK: - Placements

    /// Creates a placement builder for presenting offers.
    public func placement(_ id: String? = nil) -> any PlacementBuilderProtocol {
        // The generated id is LOCAL identity only (the outcomes stream, the
        // host's PurchaseRequest) — it never goes on the wire (2026-08-14
        // reversal): analytics and /offers/search carry only a publisher-chosen
        // label, absent otherwise. The server folds absence into '(unlabeled)'
        // at read time, and presentation_id correlates a presentation's events.
        PlacementBuilder(
            id: id ?? "placement_\(UUID().uuidString.prefix(8))",
            label: PlacementLabel.sanitized(id)
        )
    }

    /// Warm the offer set for `placementLabel` so the sheet opens without a
    /// network round trip. Reuses a set already held (see `OffersCache.cacheTTL`).
    ///
    /// `useCase` is the use case the builder will present under. The warm must
    /// resolve the variant for THAT use case — `show()` reads
    /// `variantId(for: useCase)`, and the variant is part of the cache key, so
    /// warming under the churn default filled a set a reward presentation
    /// could never hit whenever the two variants differ.
    internal func prefetchOffers(placementLabel: String?, useCase: UseCase = .reduceChurn) {
        guard services != nil else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            return
        }
        #if DEBUG
        Self.prefetchObserverForTesting?(placementLabel, useCase)
        #endif
        Task { [weak self] in
            guard let self, let services = self.services else { return }
            // Same sequencing as configure(): warming ahead of the /config
            // answer ships a variant the server may be about to replace.
            await services.remoteConfigManager.awaitInFlightFetch()
            // Resolve this use case's config the same way show() will (the
            // availability ladder, then `variantId(for:)`). For an enabled use
            // case the config is already cached and this returns immediately;
            // otherwise it moves the one-time lazy /config fetch off the tap
            // path, which is exactly where a warm-up wants it.
            await services.remoteConfigManager.loadConfig(
                for: useCase,
                userId: services.user.currentUserId,
                sdkVersion: Encore.sdkVersion,
                language: services.user.userAttributes.language
            )
            services.offers.prefetch(
                userId: services.user.currentUserId,
                attributes: services.user.userAttributes,
                variantId: services.sduiConfigManager.variantId(for: useCase),
                placementId: placementLabel
            )
        }
    }

    #if DEBUG
    /// Test seam: observes every warm `prefetchOffers` dispatches, with the
    /// label and use case it was asked to resolve. Fired synchronously so
    /// wiring tests need no async coordination.
    internal static var prefetchObserverForTesting: ((String?, UseCase) -> Void)?
    #endif
    
    /// Static convenience for `Encore.shared.placement(_:)`.
    public static func placement(_ id: String? = nil) -> any PlacementBuilderProtocol {
        shared.placement(id)
    }

    // MARK: - Entitlement Queries
    
    /// Checks if an entitlement is active. Auto-refreshes from server if needed.
    public func isActive(_ type: Entitlement, in scope: EntitlementScope = .all) async -> Bool {
        guard let entitlementsManager = entitlementsManager else { 
            Logger.error(.integration(.notConfigured), context: .configuration)
            return false 
        }
        await entitlementsManager.smartRefresh(for: type, scope: scope, entitlements: entitlementsManager.entitlements)
        guard let entitlements = entitlementsManager.entitlements else { return false }
        return EntitlementManager.isActive(type, scope: scope, in: entitlements)
    }
    
    /// Publisher that emits when entitlement state changes.
    public func isActivePublisher(for type: Entitlement, in scope: EntitlementScope = .all) -> AnyPublisher<Bool, Never> {
        guard let manager = entitlementsManager else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            return Just(false).eraseToAnyPublisher()
        }
        
        return manager.$entitlements
            .receive(on: DispatchQueue.main)
            .map { entitlements in
                guard let entitlements else { return false }
                return EntitlementManager.isActive(type, scope: scope, in: entitlements)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    
    // MARK: - Entitlement Management
    
    /// Revokes all entitlements for the current user. Admin/debug only.
    public func revokeEntitlements() async throws {
        guard let manager = entitlementsManager else {
            Logger.error(.integration(.notConfigured), context: .configuration)
            throw EncoreError.integration(.notConfigured)
        }
        try await manager.revokeEntitlements()
    }
    
    /// Callback variant of `revokeEntitlements()`.
    public func revokeEntitlements(onCompletion: @escaping (Result<Void, EncoreError>) -> Void) {
        Task {
            do {
                try await revokeEntitlements()
                onCompletion(.success(()))
            } catch let error as EncoreError {
                onCompletion(.failure(error))
            } catch {
                onCompletion(.failure(.transport(.network(error))))
            }
        }
    }
}

// MARK: - Options

extension Encore {
    /// Configuration options for the Encore SDK.
    public struct Options: Sendable {
        /// Logging verbosity level.
        public var logLevel: LogLevel

        /// Controls when the SDK grants entitlements after an offer flow.
        public var unlock: UnlockMode

        public init(
            logLevel: LogLevel = .none,
            unlock: UnlockMode = .optimistic
        ) {
            self.logLevel = logLevel
            self.unlock = unlock
        }
    }
}
