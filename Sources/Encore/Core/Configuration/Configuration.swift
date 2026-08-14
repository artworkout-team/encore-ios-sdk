// Sources/Encore/Internal/Core/Configuration.swift
//
// Environment detection and SDK configuration logic.
// Extracted from Encore.swift to reduce God Object size.
//

import Foundation

// MARK: - Configuration

/// The fully resolved, immutable context for the current SDK session.
/// Captured once at `configure()` and used throughout the service graph.
internal struct Configuration: Sendable {
    // MARK: - App Context (Host App Identity)
    let apiKey: String
    let appBundleId: String
    
    // MARK: - SDK Context (Runtime Behavior)
    let environment: EnvironmentConfiguration
    /// Human-readable provenance of `environment` (which detection branch won).
    /// Detection runs before the log level is known — Logger drops everything
    /// pre-configure — so the reason is carried here and logged by `configure()`
    /// once the gate is open.
    let environmentSource: String
    let logLevel: Encore.LogLevel
    let unlock: UnlockMode

    init(
        apiKey: String,
        logLevel: Encore.LogLevel = .error,
        unlock: UnlockMode = .optimistic,
        environment: EnvironmentConfiguration? = nil
    ) {
        // App Context
        self.apiKey = apiKey
        self.appBundleId = Bundle.main.bundleIdentifier ?? "unknown"

        // SDK Context
        if let environment {
            self.environment = environment
            self.environmentSource = "explicit override"
        } else {
            let detection = EnvironmentDetector.detect()
            self.environment = detection.environment
            self.environmentSource = detection.source
        }
        self.logLevel = logLevel
        self.unlock = unlock
    }
}

// MARK: - Environment Configuration

/// Represents the SDK's runtime environment.
/// Single source of truth for all environment-specific configuration.
internal enum EnvironmentConfiguration: CustomStringConvertible, Equatable, Sendable {
    case local
    case development
    case staging
    case production
    case mock(MockScenario)
    
    // MARK: - URLs
    
    var apiBaseURL: URL {
        let urlString: String = switch self {
        case .local:       "http://localhost:4000/publisher/sdk/v1"
        case .development: "https://api.dev.encorekit.com/publisher/sdk/v1"
        case .staging:     "https://api.staging.encorekit.com/publisher/sdk/v1"
        case .production:  "https://api.encorekit.com/encore/publisher/sdk/v1"
        case .mock:        "https://mock.api.encorekit.com"
        }
        return safeURL(urlString)
    }
    
    var analyticsBaseURL: URL {
        let urlString: String = switch self {
        case .local:       "http://localhost:8081/v1"
        case .development: "https://api.dev.encorekit.com/analytics/v1"
        case .staging:     "https://api.staging.encorekit.com/analytics/v1"
        case .production:  "https://api.encorekit.com/analytics/v1"
        case .mock:        "https://mock.api.encorekit.com/analytics/v1"
        }
        return safeURL(urlString)
    }
    
    // MARK: - Infrastructure Builders
    
    /// Returns the analytics sinks for this environment.
    func analyticsSinks(httpClient: HTTPClientProtocol) -> [AnalyticsSink] {
        switch self {
        case .mock:
            [ConsoleSink()]
        case .local:
            [BackendAnalyticsSink(httpClient: httpClient)]
        case .development, .staging, .production:
            [PostHogSink(), BackendAnalyticsSink(httpClient: httpClient)]
        }
    }
    
    /// Returns the error providers for this environment.
    func errorProviders(httpClient: HTTPClientProtocol) -> [ErrorProvider] {
        switch self {
        case .mock:
            []
        case .local:
            [BackendErrorProvider(httpClient: httpClient)]
        case .development, .staging, .production:
            [SentryErrorProvider()]
        }
    }
    
    // MARK: - Helpers
    
    var isMock: Bool { if case .mock = self { true } else { false } }
    
    var description: String {
        switch self {
        case .local: "local"
        case .development: "development"
        case .staging: "staging"
        case .production: "production"
        case .mock(let scenario): "mock(\(scenario))"
        }
    }
}

// MARK: - Environment Detection

/// Detects the appropriate environment based on build configuration.
///
/// **Security Note**: Non-production environments are ONLY available in DEBUG builds.
/// Release builds of the SDK (distributed to clients) will ALWAYS use production,
/// regardless of any environment variables or Info.plist settings.
internal struct EnvironmentDetector {

    /// The resolved environment plus which detection branch produced it.
    /// No logging here: detection runs pre-configure, where Logger drops
    /// every line. The caller logs `source` once the log level is known.
    struct Detection {
        let environment: EnvironmentConfiguration
        let source: String
    }

    /// Determines the appropriate environment configuration.
    static func detect() -> Detection {
        #if DEBUG
        // Development builds: allow environment overrides for testing
        return detectDevelopmentEnvironment()
        #else
        // Release builds: ALWAYS production - no overrides allowed
        return Detection(environment: .production, source: "release build — overrides disabled")
        #endif
    }

    #if DEBUG
    /// Only available in DEBUG builds - detects environment from config.
    /// Defaults to production if no override is set (defense in depth).
    private static func detectDevelopmentEnvironment() -> Detection {
        // Priority 1: Process Environment (Launch Arguments/Schemes)
        if let processEnv = ProcessInfo.processInfo.environment["EncoreEnvironment"] {
            guard let env = parse(processEnv) else {
                return Detection(environment: .production, source: "unknown value '\(processEnv)' in EncoreEnvironment process variable → production")
            }
            return Detection(environment: env, source: "EncoreEnvironment process variable")
        }

        // Priority 2: Info.plist (xcconfig)
        if let buildConfigEnv = Bundle.main.object(forInfoDictionaryKey: "EncoreEnvironment") as? String {
            guard let env = parse(buildConfigEnv) else {
                return Detection(environment: .production, source: "unknown value '\(buildConfigEnv)' in Info.plist EncoreEnvironment → production")
            }
            return Detection(environment: env, source: "Info.plist EncoreEnvironment key")
        }

        // Priority 3: Default to production (defense in depth - if DEBUG flag leaks to release, use production)
        return Detection(environment: .production, source: "no override found (process env / Info.plist) → default production")
    }

    private static func parse(_ value: String) -> EnvironmentConfiguration? {
        switch value.lowercased() {
        case "local":
            return .local
        case "development":
            return .development
        case "staging":
            return .staging
        case "production":
            return .production
        case "mock":
            return .mock(.successWithOffer)
        default:
            return nil
        }
    }
    #endif
}

// MARK: - Unlock Mode

/// Controls when the SDK grants entitlements after an offer flow.
public enum UnlockMode: Sendable {
    /// Grants immediately when user returns from Safari (default).
    case optimistic
    /// Waits for advertiser postback verification before granting.
    case strict
}
