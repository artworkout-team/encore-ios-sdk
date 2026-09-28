// Core/Infrastructure/Errors/Providers/SentryErrorProvider.swift
//
// Error provider that sends errors directly to Sentry via HTTP API.
// Dependency-free implementation - no Sentry SDK required.
//
// Features:
// - Background task support (completes even if app backgrounded)
// - Fingerprinting (groups errors by type, not dynamic message)
// - Raw stack traces (captured at report site)
// - User context (from EntitlementManager)
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Error provider that sends errors directly to Sentry via HTTP API.
/// Avoids SDK dependency while still getting Sentry's error tracking.
internal struct SentryErrorProvider: ErrorProvider {
    
    // MARK: - Configuration
    
    /// Sentry DSN - public key is NOT sensitive (designed for client-side use)
    private static let dsn = "https://05746dfa6683b5bb61c7e2443bd631a4@o4510731102519296.ingest.us.sentry.io/4510731104223232"
    
    // MARK: - Properties
    
    private let storeURL: URL
    private let publicKey: String
    private let session: URLSession
    
    // Cached Device Info (immutable after init)

    /// Sentry's own `platform` field, which tells Sentry how to render a
    /// stack trace. NOT the same thing as `sdk_platform` below: a web error
    /// routed through the backend arrives here as `node`, because that is the
    /// SDK that sent it, while the Encore SDK it came from is `web`.
    private let platform: String = "cocoa"

    /// Which Encore SDK produced the error, tagged for the fleet-wide query.
    /// Deliberately NOT called `platform`: that name already means something
    /// else to Sentry, and the two values genuinely differ. Named for the
    /// `sdk_version` family instead.
    ///
    /// `osName` is derived from the same condition rather than hardcoded, so a
    /// non-UIKit build cannot report `sdk_platform: macos` while its OS context
    /// still claims iOS. That pairing would be wrong in Sentry's device panel
    /// and in any filter built on it.
    #if canImport(UIKit)
    private let sdkPlatform: String = "ios"
    private let osName: String = "iOS"
    #else
    private let sdkPlatform: String = "macos"
    private let osName: String = "macOS"
    #endif

    /// Sentry's environment, so `environment:production` does not silently
    /// exclude every iOS event. Passed in from `EnvironmentConfiguration`,
    /// which is the only thing that knows it.
    private let environment: String

    /// How the report reached Sentry, tagged `report_transport`.
    ///
    /// This provider is now reached only when a POST to `/errors` fails, so
    /// `report_transport:fallback` is a POSITIVE signal that our own API was
    /// unreachable from a real device. That is worth alerting on, and it is
    /// much better than the alternative it replaces: inferring an outage from
    /// Android and web going quiet, which is indistinguishable from a slow
    /// night.
    ///
    /// Defaults to `direct` so the value stays true if anything ever wires
    /// this provider as a primary again.
    private let transport: String
    private let appBundleId: String
    private let appVersion: String?
    private let osVersion: String
    private let deviceModel: String
    
    // MARK: - Initialization
    
    init(environment: String, transport: String = "direct") {
        self.environment = environment
        self.transport = transport

        let parsed = Self.parseDSN(Self.dsn)!
        self.storeURL = parsed.storeURL
        self.publicKey = parsed.publicKey
        
        // Ephemeral session - avoids caching error payloads
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        
        // Cache static device info
        self.appBundleId = Bundle.main.bundleIdentifier ?? "unknown"
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        
        #if canImport(UIKit)
        self.osVersion = UIDevice.current.systemVersion
        self.deviceModel = Self.deviceModelIdentifier()
        #else
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.deviceModel = "macOS"
        #endif
    }
    
    // MARK: - ErrorProvider Protocol
    
    func report(
        _ error: EncoreError,
        underlying: Error?,
        context: ErrorContext,
        location: String?,
        sdkVersion: String,
        userId: String?
    ) {
        // Capture stack trace immediately (snapshot of call site)
        let stackTrace = Thread.callStackSymbols
        
        var payload = buildPayload(
            error: error,
            underlying: underlying,
            context: context,
            location: location,
            sdkVersion: sdkVersion,
            stackTrace: stackTrace
        )
        
        // Add user context if available (passed from ErrorsClient, no fetch needed)
        if let userId = userId {
            payload["user"] = ["id": userId]
        }
        
        Task.detached(priority: .utility) { [self, payload] in
            await sendToSentry(payload: payload)
        }
    }
    
    // MARK: - Payload Construction
    
    /// `internal` rather than `private` so `SentryPayloadTests` can pin the
    /// wire shape. Nothing else calls it.
    internal func buildPayload(
        error: EncoreError,
        underlying: Error?,
        context: ErrorContext,
        location: String?,
        sdkVersion: String,
        stackTrace: [String]
    ) -> [String: Any] {
        let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        var payload: [String: Any] = [
            "event_id": eventId,
            "timestamp": timestamp,
            "platform": platform,
            "environment": environment,
            "level": sentryLevel(for: error),
            "logger": "encore-swift-sdk",
            "message": [
                "formatted": error.errorDescription ?? "Unknown error"
            ],
            
            // Fingerprinting: Group by error type + location, not dynamic message
            // This prevents issue explosion from messages like "User 123 failed" vs "User 456 failed"
            "fingerprint": [error.typeIdentifier, context.rawValue],
            
            "tags": [
                "error_type": error.typeIdentifier,
                "context": context.rawValue,
                "sdk_version": sdkVersion,
                "sdk_platform": sdkPlatform,
                "report_transport": transport
            ],
            
            "contexts": [
                "device": [
                    "model": deviceModel,
                    "family": deviceModel
                ],
                "os": [
                    "name": osName,
                    "version": osVersion
                ],
                "app": [
                    "app_identifier": appBundleId,
                    "app_version": appVersion ?? "unknown"
                ]
            ],
            
            "sdk": [
                "name": "encore-swift-sdk",
                "version": sdkVersion
            ],
            
            // Extra data: raw stack trace + location
            "extra": [
                "raw_stacktrace": stackTrace,
                "location": location ?? "unknown"
            ]
        ]
        
        // Always attach an exception interface.
        //
        // Without one, Sentry has no type and no value to render, so the issue
        // page reads "(No error message)" with no culprit line and no stack
        // section. This used to happen whenever there was no underlying error,
        // which is half the issues in the production project.
        //
        // Grouping is unaffected either way, because the fingerprint above is
        // explicit and overrides Sentry's exception-based grouping.
        if let underlying = underlying {
            // Prefer the underlying type: "NSURLError" says more about a
            // timeout than "network_error" does, and the fingerprint already
            // carries the shared value.
            payload["exception"] = [
                "values": [[
                    "type": String(describing: type(of: underlying)),
                    "value": underlying.localizedDescription,
                    "module": "EncoreSDK"
                ]]
            ]
        } else {
            payload["exception"] = [
                "values": [[
                    "type": error.typeIdentifier,
                    "value": error.errorDescription ?? "Unknown error",
                    "module": "EncoreSDK"
                ]]
            ]
        }
        
        return payload
    }
    
    private func sentryLevel(for error: EncoreError) -> String {
        switch error {
        case .integration:
            return "warning"
        case .transport, .protocol, .domain:
            return "error"
        }
    }
    
    // MARK: - Networking (with Background Task)
    
    private func sendToSentry(payload: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.debug("SentryErrorProvider: Failed to serialize payload")
            return
        }
        
        var request = URLRequest(url: storeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sentryAuthHeader(), forHTTPHeaderField: "X-Sentry-Auth")
        request.httpBody = jsonData
        
        // Start background task so request completes even if app is backgrounded
        #if canImport(UIKit)
        let bgTaskID = await beginBackgroundTask()
        defer {
            Task { @MainActor in
                endBackgroundTask(bgTaskID)
            }
        }
        #endif
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    Logger.debug("SentryErrorProvider: Error reported to Sentry")
                } else {
                    Logger.debug("SentryErrorProvider: Sentry returned \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Silently drop - error reporting should never block the app
            Logger.debug("SentryErrorProvider: Network error: \(error.localizedDescription)")
        }
    }
    
    private func sentryAuthHeader() -> String {
        "Sentry sentry_version=7, sentry_key=\(publicKey), sentry_client=encore-swift-sdk/1.0"
    }
    
    // MARK: - Background Task Helpers
    
    #if canImport(UIKit)
    /// Safely get UIApplication.shared - returns nil in App Extensions (Widgets, etc.)
    /// Uses dynamic selector to avoid compile/runtime errors in extension contexts.
    @MainActor
    private var sharedApplication: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }
    
    @MainActor
    private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
        guard let app = sharedApplication else {
            // We're in an App Extension - background tasks not available
            return .invalid
        }
        
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "SentryErrorReport") {
            // Expiration handler - clean up if we run out of time
            app.endBackgroundTask(taskID)
        }
        return taskID
    }
    
    @MainActor
    private func endBackgroundTask(_ taskID: UIBackgroundTaskIdentifier) {
        guard taskID != .invalid,
              let app = sharedApplication else { return }
        app.endBackgroundTask(taskID)
    }
    #endif
    
    // MARK: - DSN Parsing
    
    private static func parseDSN(_ dsn: String) -> (storeURL: URL, publicKey: String)? {
        // DSN format: https://{PUBLIC_KEY}@{HOST}/{PROJECT_ID}
        guard let url = URL(string: dsn),
              let host = url.host,
              let publicKey = url.user,
              !url.path.isEmpty else {
            return nil
        }
        
        let projectId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = url.scheme ?? "https"
        
        // Build store URL: https://{HOST}/api/{PROJECT_ID}/store/
        guard let storeURL = URL(string: "\(scheme)://\(host)/api/\(projectId)/store/") else {
            return nil
        }
        
        return (storeURL, publicKey)
    }
    
    // MARK: - Device Model
    
    #if canImport(UIKit)
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
    #endif
}
