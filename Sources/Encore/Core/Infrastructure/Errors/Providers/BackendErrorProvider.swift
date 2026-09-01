// Core/Infrastructure/Errors/Providers/BackendErrorProvider.swift
//
// Error provider that sends errors to the Encore backend.
// Backend then forwards to Sentry server-side (avoids client-side Sentry dep).
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Field limits, mirroring `ClientErrorReportSchema` in
/// `backend/packages/core/src/infrastructure/errors/schema.ts`, which is the
/// source of truth.
///
/// These are NOT cosmetic. The endpoint validates every field and **rejects the
/// whole report on one violation**, and a 400 is not retried or re-routed, so an unbounded
/// field does not truncate a report, it loses it. It also loses exactly the
/// reports worth having: a deep stack from a release build is both the most
/// likely to exceed a limit and the hardest to reproduce.
internal enum ErrorReportLimits {
    static let errorType = 100
    static let message = 2000
    static let context = 200
    static let stackTrace = 10_000
    static let underlyingError = 2000
    static let appBundleId = 200
    static let appVersion = 50
    static let osVersion = 50
    static let deviceModel = 100
    static let userId = 200

    static let truncationMarker = "... [truncated]"
}

extension String {
    /// Clips to `limit`, keeping the **start** of the value.
    ///
    /// For a stack trace the start is the frames nearest the throw, which is the
    /// diagnostic half. The cut is marked so a reader does not take a clipped
    /// trace for a shallow one.
    internal func bounded(_ limit: Int) -> String {
        guard count > limit else { return self }
        let marker = ErrorReportLimits.truncationMarker
        return String(prefix(limit - marker.count)) + marker
    }
}

/// Error provider that sends errors to the Encore backend API.
/// Reuses the SDK's HTTPClient for networking.
internal struct BackendErrorProvider: ErrorProvider {
    
    private let httpClient: HTTPClientProtocol

    /// Used only when the POST fails.
    ///
    /// The backend transport is the right default: only the route can attach
    /// appId and organizationId, and only it reaches Cloud Logging. But it
    /// makes our own API a single point of failure for the reports that matter
    /// most, because the outage that stops the report IS the incident. This
    /// keeps one path that survives it.
    ///
    /// Fires only after a failed POST, so nothing is ever reported twice.
    private let fallback: ErrorProvider?
    
    // MARK: - Device Info (cached at init)
    
    private let platform: String = "ios"
    private let appBundleId: String
    private let appVersion: String?
    private let osVersion: String
    private let deviceModel: String
    
    // MARK: - Initialization
    
    init(httpClient: HTTPClientProtocol, fallback: ErrorProvider? = nil) {
        self.httpClient = httpClient
        self.fallback = fallback
        
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
        // Captured here, at the report site, so the frames still describe the
        // failure rather than the detached Task below.
        let callStack = Thread.callStackSymbols

        let payload = buildPayload(
            error: error,
            underlying: underlying,
            context: context,
            location: location,
            sdkVersion: sdkVersion,
            userId: userId,
            callStack: callStack
        )
        
        // Fire and forget. The work itself lives in `send` so a test can await
        // it directly: waiting on this detached task instead means asserting on
        // the scheduler, and a `.utility` task is starved for seconds under a
        // full parallel suite, which is a flake rather than a signal.
        Task.detached(priority: .utility) { [self] in
            await send(
                payload: payload,
                error: error,
                underlying: underlying,
                context: context,
                location: location,
                sdkVersion: sdkVersion,
                userId: userId
            )
        }
    }

    /// The POST and its fallback. `internal` so the tests can drive it without
    /// depending on when the detached task above happens to run.
    internal func send(
        payload: ErrorReportPayload,
        error: EncoreError,
        underlying: Error?,
        context: ErrorContext,
        location: String?,
        sdkVersion: String,
        userId: String?
    ) async {
        // A failed POST is worth reacting to only when it means our API is
        // UNREACHABLE. See `shouldFallBack`.
        do {
            let _: EmptyResponse = try await httpClient.request(
                path: "errors",
                method: "POST",
                body: payload
            )
            Logger.debug("BackendErrorProvider: Error reported to backend")
        } catch let postFailure {
            // Named, so it does not shadow the EncoreError being reported.
            guard shouldFallBack(after: postFailure) else {
                Logger.debug("BackendErrorProvider: Report rejected (\(postFailure)), not falling back")
                return
            }
            Logger.debug("BackendErrorProvider: Backend unreachable (\(postFailure)), trying the fallback")
            fallback?.report(
                error,
                underlying: underlying,
                context: context,
                location: location,
                sdkVersion: sdkVersion,
                userId: userId
            )
        }
    }

    /// Whether a failed POST means the backend is UNREACHABLE, which is the
    /// only case the fallback exists for.
    ///
    /// Falling back on every failure looks harmless and is not. A 4xx is the
    /// backend *answering*, and re-sending that report straight to Sentry
    /// defeats the answer:
    ///
    /// - **429.** The rate limit exists to bound report volume during a storm.
    ///   Re-routing the overflow to Sentry unthrottled removes the bound at
    ///   exactly the moment it is doing its job.
    /// - **400.** The payload was rejected on its merits. The backend already
    ///   logs schema rejections to Cloud Logging with field-level detail, so
    ///   the report stays visible; sending the same rejected payload to Sentry
    ///   adds noise, not information.
    /// - **The alert.** `report_transport: fallback` is meant to mean "our API
    ///   was unreachable from a real device". If a 429 or a 400 also produced
    ///   it, the tag would mean "something went wrong somewhere", which is not
    ///   worth alerting on.
    ///
    /// 5xx counts as unreachable: the backend is failing to serve rather than
    /// declining to.
    private func shouldFallBack(after failure: Error) -> Bool {
        // Teardown, not a failure. Reporting during cancellation would outlive
        // the scope that asked for it.
        if failure is CancellationError { return false }
        if let urlError = failure as? URLError, urlError.code == .cancelled { return false }

        guard let encoreError = failure as? EncoreError else {
            // Not one of ours, so it never reached a response. Unreachable.
            return true
        }

        switch encoreError {
        case .transport:
            return true
        case .protocol(.http(let status, _)), .protocol(.api(let status, _, _)):
            return status >= 500
        case .protocol(.decoding), .integration, .domain:
            // A 2xx we could not parse still means the report was accepted.
            return false
        }
    }
    
    /// `internal` rather than `private` so `BackendErrorPayloadTests` can pin the
    /// wire shape and the field bounds. Nothing else calls it.
    internal func buildPayload(
        error: EncoreError,
        underlying: Error?,
        context: ErrorContext,
        location: String?,
        sdkVersion: String,
        userId: String?,
        callStack: [String]
    ) -> ErrorReportPayload {
        // Source location, then the underlying error, then the real frames.
        // The Sentry-direct path sent `Thread.callStackSymbols` as its
        // `raw_stacktrace`, and losing it would have been the one genuine
        // downgrade in moving to this transport.
        var stackComponents: [String] = []
        if let location = location {
            stackComponents.append("at \(location)")
        }
        if let underlying = underlying {
            stackComponents.append("underlying: \(underlying)")
        }
        stackComponents.append(contentsOf: callStack)
        let stackTrace = stackComponents.isEmpty
            ? nil
            : stackComponents.joined(separator: "\n").bounded(ErrorReportLimits.stackTrace)

        return ErrorReportPayload(
            errorType: error.typeIdentifier.bounded(ErrorReportLimits.errorType),
            message: (error.errorDescription ?? "Unknown error").bounded(ErrorReportLimits.message),
            context: context.rawValue.bounded(ErrorReportLimits.context),
            stackTrace: stackTrace,
            underlyingError: underlying?.localizedDescription.bounded(ErrorReportLimits.underlyingError),
            severity: severity(for: error),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            platform: platform,
            sdkVersion: sdkVersion,
            appBundleId: appBundleId.bounded(ErrorReportLimits.appBundleId),
            appVersion: appVersion?.bounded(ErrorReportLimits.appVersion),
            osVersion: osVersion.bounded(ErrorReportLimits.osVersion),
            deviceModel: deviceModel.bounded(ErrorReportLimits.deviceModel),
            userId: userId?.bounded(ErrorReportLimits.userId),
            metadata: nil
        )
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
