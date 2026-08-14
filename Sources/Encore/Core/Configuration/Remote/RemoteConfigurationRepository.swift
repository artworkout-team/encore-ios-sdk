// Sources/Encore/Core/Configuration/Remote/RemoteConfigurationRepository.swift
//
// Repository for remote configuration data access.
// Handles both network (remote) and local persistence.
// Owns semantic storage keys (what to store), delegates mechanism to KeyValueStore (how to store).

import Foundation

// MARK: - Remote Configuration Repository

/// Repository for remote configuration data access.
/// Provides explicit `getLocal()` and `fetchRemote()` methods so the Manager
/// can make informed decisions about caching and latest-identity-wins coordination.
internal struct RemoteConfigurationRepository: Sendable {
    private let client: HTTPClientProtocol
    private let storage: KeyValueStore
    /// Disk home of the resolved templates (rung 2 of the availability
    /// ladder). Owned here so persistence happens at the ONE place a fetch
    /// resolves, and the domain model never carries raw template bytes.
    private let templateStore: TemplateStore
    /// Scopes every key to the (environment, api key) the data was fetched
    /// under. A last-known-good config from one environment must never seed
    /// another: a cached prod `variantId` sent to a local backend joins
    /// creatives on an id with no links and filters every campaign to zero.
    /// The scope FORMAT is repository schema — callers pass raw ingredients.
    private let cacheScope: String

    // MARK: - Storage Keys (Repository owns the schema)
    private enum Keys {
        static let config = "encore.remote_config"
        static let lastEmittedConfigHash = "analytics_dedup_sdui_config_loaded_hash"
    }

    private func scoped(_ base: String) -> String {
        cacheScope.isEmpty ? base : "\(base).\(cacheScope)"
    }

    private var configKey: String { scoped(Keys.config) }
    private var lastEmittedHashKey: String { scoped(Keys.lastEmittedConfigHash) }

    init(
        client: HTTPClientProtocol,
        storage: KeyValueStore,
        templateStore: TemplateStore,
        environment: EnvironmentConfiguration? = nil,
        apiKey: String? = nil
    ) {
        self.client = client
        self.storage = storage
        self.templateStore = templateStore
        self.cacheScope = environment.map { "\($0).\(apiKey.map { String($0.suffix(8)) } ?? "")" } ?? ""
    }

    // MARK: - Local Access (Sync, Disk/Cache)

    /// Get configuration from local storage.
    /// Synchronous - returns immediately from cache.
    func getLocal() -> RemoteConfiguration? {
        storage.load(configKey)
    }

    /// Save configuration to local storage.
    func saveLocal(_ config: RemoteConfiguration) {
        storage.save(config, to: configKey)
    }

    /// Clear configuration from local storage.
    func clearLocal() {
        storage.remove(configKey)
    }

    // MARK: - Emission Dedup (per the 2026 analytics audit, #4)

    /// The config-content hash last recorded as emitted for
    /// `sdk_sdui_config_loaded`. The manager decides suppression; the
    /// repository only remembers.
    func lastEmittedConfigHash() -> String? {
        storage.load(lastEmittedHashKey)
    }

    /// Record the hash of the config the manager just emitted for.
    func recordEmittedConfigHash(_ hash: String) {
        storage.save(hash, to: lastEmittedHashKey)
    }
    
    // MARK: - Remote Access (Async, Network)
    
    /// Fetch configuration from remote server.
    ///
    /// Asynchronous - hits network. Does NOT auto-save to local storage;
    /// Manager controls persistence due to latest-identity-wins coordination.
    ///
    /// - Parameters:
    ///   - userId: User ID for deterministic variant assignment
    ///   - sdkVersion: SDK version for compatibility filtering
    ///   - language: Optional ISO 639-1 language code from `UserAttributes.language`.
    ///     When non-nil, takes precedence over the device's `Accept-Language`
    ///     header in the backend's locale resolver. Lets host apps with their
    ///     own in-app language picker drive `/config` localization without
    ///     flipping the device locale.
    ///   - useCase: Which use case's variant to **resolve** — experiments and
    ///     all. The parameter is **omitted** for `.reduceChurn` so the
    ///     request stays byte-identical to what every already-shipped SDK
    ///     sends; the backend defaults to churn intervention when it's absent.
    ///     Every *other* enabled use case comes back in the same response's
    ///     prefetch block as its default variant, so asking for one explicitly
    ///     is only needed when its experiment assignment must be resolved.
    /// - Returns: The resolved configuration plus the default configuration for
    ///   every other use case the app is enabled for.
    func fetchRemote(
        userId: String,
        sdkVersion: String,
        language: String?,
        useCase: UseCase = .reduceChurn
    ) async throws -> RemoteConfigurationBundle {
        var query: [String: String?] = ["userId": userId, "sdkVersion": sdkVersion]
        if let language, !language.isEmpty {
            query["language"] = language
        }
        if useCase.needsConfigQueryParameter {
            query["useCase"] = useCase.rawValue
        }
        let dto: DTO.RemoteConfig.ConfigResponseEnvelope = try await client.request(
            path: "config",
            method: "GET",
            query: query
        )
        let bundle = RemoteConfigurationBundle(from: dto, requestedFor: useCase)
        persistResolvedTemplates(bundle, dto: dto, userId: userId, language: language)
        return bundle
    }

    // MARK: - Stored Templates (rung 2 of the availability ladder)

    /// The last-known-good template stored for `useCase`, or nil when absent
    /// or stamped for a different identity.
    func storedTemplate(for useCase: UseCase, userId: String, language: String?) -> StoredTemplate? {
        templateStore.load(useCase: useCase, userId: userId, language: language)
    }

    /// Deletes every stored template. Called on logout/reset and on identity
    /// change.
    func clearStoredTemplates() {
        templateStore.deleteAll()
    }

    /// Persists what this response resolved: a stored template for every use
    /// case that resolved one, a deletion for every use case the server
    /// explicitly resolved to nothing (a stored template must never outlive a
    /// publisher disabling the surface).
    ///
    /// Runs before the caller can save the config blob, so a torn write
    /// leaves a template without a blob, which rung 2 reads as absent: the
    /// safe direction to be torn in.
    private func persistResolvedTemplates(
        _ bundle: RemoteConfigurationBundle,
        dto: DTO.RemoteConfig.ConfigResponseEnvelope,
        userId: String,
        language: String?
    ) {
        // `ui` always persists: it carries the requested use case's ASSIGNED
        // arm on every request shape.
        persist(bundle.useCase, ui: bundle.configuration.ui, raw: rawTemplateData(dto.ui.template), userId: userId, language: language)

        // The prefetch block carries DEFAULT arms. Persisting it from a
        // by-name (?useCase=) fetch would overwrite the user's assigned arms
        // for OTHER use cases (or delete them on a null entry), so the block
        // persists only on the primary request.
        guard !bundle.useCase.needsConfigQueryParameter else { return }
        for (useCase, configuration) in bundle.prefetched {
            let raw = rawTemplateData(dto.useCases?[useCase.rawValue]?.template)
            persist(useCase, ui: configuration.ui, raw: raw, userId: userId, language: language)
        }
    }

    private func persist(_ useCase: UseCase, ui: UIConfiguration, raw: Data?, userId: String, language: String?) {
        guard let raw, ui.template != nil else {
            templateStore.delete(useCase: useCase)
            return
        }
        templateStore.save(StoredTemplate(
            useCase: useCase,
            variantId: ui.variantId,
            variantName: ui.variantName,
            uiValues: ui.values,
            template: raw,
            userId: userId,
            language: language
        ))
    }

    /// Raw wire bytes of a template, for storage: byte-stable, and re-parsed
    /// by the never-throws parser at read time. Never throws outward.
    private func rawTemplateData(_ template: DTO.RemoteConfig.UITemplate?) -> Data? {
        guard let template else { return nil }
        do {
            return try JSONEncoder().encode(template)
        } catch {
            Logger.warn(.configuration, "Failed to encode SDUI template for storage: \(error)")
            return nil
        }
    }
}
