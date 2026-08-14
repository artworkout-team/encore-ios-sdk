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
    private let platform: String = "cocoa"
    private let appBundleId: String
    private let appVersion: String?
    private let osVersion: String
    private let deviceModel: String
    
    // MARK: - Initialization
    
    init() {
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
    
    private func buildPayload(
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
                "sdk_version": sdkVersion
            ],
            
            "contexts": [
                "device": [
                    "model": deviceModel,
                    "family": deviceModel
                ],
                "os": [
                    "name": "iOS",
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
        
        // Add exception interface if we have underlying error
        if let underlying = underlying {
            payload["exception"] = [
                "values": [[
                    "type": String(describing: type(of: underlying)),
                    "value": underlying.localizedDescription,
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
