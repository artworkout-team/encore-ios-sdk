// Core/Infrastructure/Errors/Providers/BackendErrorProvider.swift
//
// Error provider that sends errors to the Encore backend.
// Backend then forwards to Sentry server-side (avoids client-side Sentry dep).
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Error provider that sends errors to the Encore backend API.
/// Reuses the SDK's HTTPClient for networking.
internal struct BackendErrorProvider: ErrorProvider {
    
    private let httpClient: HTTPClientProtocol
    
    // MARK: - Device Info (cached at init)
    
    private let platform: String = "ios"
    private let appBundleId: String
    private let appVersion: String?
    private let osVersion: String
    private let deviceModel: String
    
    // MARK: - Initialization
    
    init(httpClient: HTTPClientProtocol) {
        self.httpClient = httpClient
        
        // Cache device info (these don't change)
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
    
    // MARK: - ErrorProvider
    
    func report(_ error: EncoreError, underlying: Error?, context: ErrorContext, location: String?, sdkVersion: String, userId: String?) {
        // Build stack trace: source location + underlying error info
        var stackComponents: [String] = []
        if let location = location {
            stackComponents.append("at \(location)")
        }
        if let underlying = underlying {
            stackComponents.append("underlying: \(underlying)")
        }
        let stackTrace = stackComponents.isEmpty ? nil : stackComponents.joined(separator: "\n")
        
        let payload = ErrorReportPayload(
            errorType: error.typeIdentifier,
            message: error.errorDescription ?? "Unknown error",
            context: context.rawValue,
            stackTrace: stackTrace,
            underlyingError: underlying?.localizedDescription,
            severity: severity(for: error),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            platform: platform,
            sdkVersion: sdkVersion,
            appBundleId: appBundleId,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel,
            userId: userId,
            metadata: nil
        )
        
        // Fire-and-forget: wrap in Task.detached, silently drop errors
        Task.detached(priority: .utility) { [httpClient] in
            let _: EmptyResponse? = try? await httpClient.request(
                path: "errors",
                method: "POST",
                body: payload
            )
            Logger.debug("BackendErrorProvider: Error reported to backend")
        }
    }
    
    private func severity(for error: EncoreError) -> String {
        switch error {
        case .integration:
            return "warning"  // Programmer errors, not system failures
        case .transport, .protocol, .domain:
            return "error"
        }
    }
    
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

// MARK: - Payload

/// Matches the backend `ClientErrorReportRequest` schema (source omitted, added by backend).
internal struct ErrorReportPayload: Encodable {
    let errorType: String
    let message: String
    let context: String
    let stackTrace: String?
    let underlyingError: String?
    let severity: String
    let timestamp: String
    let platform: String
    let sdkVersion: String
    let appBundleId: String
    let appVersion: String?
    let osVersion: String
    let deviceModel: String
    let userId: String?
    let metadata: [String: String]?
}
