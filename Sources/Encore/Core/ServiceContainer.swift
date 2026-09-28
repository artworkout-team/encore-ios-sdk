// Sources/Encore/Core/ServiceContainer.swift
//
// Manual Dependency Injection container.
// This is the "Composition Root" - the single place where dependencies are created and connected.
//

import Foundation

// MARK: - Service Container

/// Container that holds all SDK domain services. Created during `Encore.configure()`.
///
/// **Thread Safety:**
/// - `@unchecked Sendable`: Safe because all `let` properties, initialized once, read-only after
/// - All managers are regular classes (no actor isolation)
/// - UI presentation code guarantees main thread execution
internal final class ServiceContainer: @unchecked Sendable {
    
    // MARK: - Infrastructure (Configuration-Scoped)
    let configuration: Configuration
    let errors: ErrorsClient
    let analytics: AnalyticsClient
    let outbox: OutboxManager
    // Note: AppLifecycle is process-scoped (static on Encore, not here)
    
    // MARK: - Domain Services (Configuration-Scoped)
    let user: UserManager
    let offers: OffersManager
    let entitlements: EntitlementManager
    let transactions: TransactionsManager
    
    // MARK: - UI Services (Configuration-Scoped)
    /// Remote configuration manager (fetching, caching, latest-identity-wins coordination)
    let remoteConfigManager: RemoteConfigurationManager
    /// SDUI configuration manager for parsing, caching, and UI configurations
    let sduiConfigManager: SDUIConfigurationManager
    
    // MARK: - Experiment Infrastructure (Configuration-Scoped)
    /// Experiment manager for A/B testing (NCL cohort assignment)
    let experimentManager: ExperimentManager
    
    // MARK: - IAP Infrastructure (Configuration-Scoped)
    /// Transaction observer for NCL identity mapping — reconciles Transaction.all with iap_links
    var iapObserver: IAPTransactionObserver?
    /// Re-polls persisted strict-unlock transactions on launch/foreground and
    /// surfaces late verification through `Encore.shared.outcomes`.
    /// Started from `Encore.configure()` (needs the main actor).
    let strictUnlockReconciler: StrictUnlockReconciler
    
    init(configuration: Configuration) {
        self.configuration = configuration
        let env = configuration.environment
        
        // Infrastructure
        // HTTP Client - mock only possible in DEBUG (EnvironmentDetector guarantees production in release)
        // Accept-Language is captured at init time from the device's preferred languages so the backend
        // can serve localized copy. Hosts that need to override the locale should pass `attributes.language`
        // via `identify(...)` — the backend prefers the explicit attribute over the header.
        let acceptLanguage = LocaleHeader.preferredAcceptLanguage()
        let olapHttpClient = HTTPClient(baseURL: env.analyticsBaseURL, headers: ["X-Analytics-Key": configuration.apiKey, "X-Platform": "ios"])
        var oltpHeaders: [String: String] = ["X-API-Key": configuration.apiKey, "X-Platform": "ios"]
        if let acceptLanguage { oltpHeaders["Accept-Language"] = acceptLanguage }
        var oltpHttpClient: HTTPClientProtocol = HTTPClient(baseURL: env.apiBaseURL, headers: oltpHeaders)
        #if DEBUG
        if case .mock(let scenario) = env {
            oltpHttpClient = MockHTTPClient(scenario: scenario)
        }
        #endif
        
        let storage = UserDefaultsStore()
        self.errors = ErrorsClient(providers: env.errorProviders(httpClient: oltpHttpClient), sdkVersion: Encore.sdkVersion)
        self.analytics = AnalyticsClient(
            sinks: env.analyticsSinks(httpClient: olapHttpClient),
            sdkVersion: Encore.sdkVersion,
            appBundleId: configuration.appBundleId,
            dedupStorage: storage
        )
        self.outbox = OutboxManager(oltpClient: oltpHttpClient, olapClient: olapHttpClient)
        
        // Data Repositories
        let offersRepository = OffersRepository(client: oltpHttpClient)
        let entitlementsRepository = EntitlementsRepository(client: oltpHttpClient, storage: storage)
        let userRepository = UserRepository(storage: storage, outbox: self.outbox)
        let transactionsRepository = TransactionsRepository(client: oltpHttpClient)
        let experimentRepository = ExperimentRepository(storage: storage)
        
        // Domain Services (Configuration-Scoped)
        // UserManager must be initialized first (ensures userId exists)
        let userManager = UserManager(repository: userRepository)
        userManager.configure()
        self.user = userManager

        self.offers = OffersManager(repository: offersRepository, storage: storage)
        self.entitlements = EntitlementManager(entitlementsRepository: entitlementsRepository, userRepository: userRepository)
        self.transactions = TransactionsManager(repository: transactionsRepository)
        
        // UI Services - remote config fetching and SDUI management.
        // Stored templates are env-scoped exactly like the config blob's key:
        // a template from one environment must never serve another.
        let remoteConfigRepository = RemoteConfigurationRepository(
            client: oltpHttpClient,
            storage: storage,
            templateStore: TemplateStore(
                environment: configuration.environment,
                apiKey: configuration.apiKey
            ),
            environment: configuration.environment,
            apiKey: configuration.apiKey
        )
        self.remoteConfigManager = RemoteConfigurationManager(repository: remoteConfigRepository)
        self.sduiConfigManager = SDUIConfigurationManager()
        self.experimentManager = ExperimentManager(repository: experimentRepository)
        

        // IAP Transaction Observer - reconciles Transaction.all with iap_links for NCL.
        // Runs for BOTH cohorts (control users purchase organically) unless the host opted out.
        if configuration.transactionLinking {
            let observer = IAPTransactionObserver(outbox: self.outbox)
            observer.start()
            self.iapObserver = observer
        } else {
            Logger.info(.iap, "Transaction linking disabled by Options — no iap-links will be sent")
        }

        self.strictUnlockReconciler = StrictUnlockReconciler(storage: storage)

        Logger.info("Initialized: \(env)")
    }
    
    // MARK: - Factory
    
    #if DEBUG
    static func mock(scenario: MockScenario = .successWithOffer) -> ServiceContainer {
        ServiceContainer(configuration: Configuration(apiKey: "mock-api-key", logLevel: .debug, environment: .mock(scenario)))
    }
    #endif
    
    var isMock: Bool { configuration.environment.isMock }
}
