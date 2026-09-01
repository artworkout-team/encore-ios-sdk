// Sources/Encore/Core/Infrastructure/Logging/Logger.swift
//
// Unified logging infrastructure for the Encore SDK.
// Provides level-based logging with automatic error reporting.
//
// Backend: Apple unified logging (`os.Logger`). One call = one structured
// console entry, so multiline payloads (e.g. pretty-printed analytics JSON)
// stay attached to their log record instead of fragmenting across stdout
// lines and breaking Xcode console filtering.
//

import Foundation
import os

// MARK: - Logger

/// Stateless logger for the Encore SDK.
/// Works before and after SDK configuration.
/// Automatically reports errors to backend when Errors service is available.
///
/// **Thread Safety:** All methods are stateless and thread-safe. The cached
/// `os.Logger` instances are built once at first use and never mutated.
internal enum Logger {

    // MARK: - Concern

    /// The SDK subsystem a log line belongs to. Raw values become `os.Logger`
    /// categories (Xcode's Category column), replacing the hand-rolled
    /// `[Analytics]` / `[IAP]` / `[ENTITLEMENTS]`-style bracket tags.
    ///
    /// Distinct from `ErrorContext`, which is the backend error-reporting wire
    /// taxonomy (snake_case, operation-scoped: `fetch_offer_data`, …). Concern
    /// is the console-filtering vocabulary (PascalCase, subsystem-scoped).
    /// `Logger.error` derives its concern from the `ErrorContext` it already
    /// receives — see `concern(for:)` — so the two vocabularies stay
    /// reconciled without widening the error API.
    internal enum Concern: String, CaseIterable {
        case core = "Core"                    // default: storage, shake, outbox internals, misc infra
        case configuration = "Configuration"  // SDK config, remote config, SDUI dev variants
        case network = "Network"              // HTTP transport
        case analytics = "Analytics"          // event emission — 1:1 console mirror of the behavioral funnel
        case iap = "IAP"                      // purchase routing, StoreKit, reconcile/link
        case entitlements = "Entitlements"    // grants, migration, optimistic unlock
        case offers = "Offers"                // offer fetch, claims, verification polling
        case presentation = "Presentation"    // sheets, placements, SDUI transitions, Safari
        case user = "User"                    // identity, attributes
        case experiments = "Experiments"      // assignment, exposure
    }

    // MARK: - Logging Methods

    /// Debug-level logging for verbose internal state.
    /// Only visible when configured log level is `>= .debug`.
    static func debug(_ message: String) {
        debug(.core, message)
    }

    /// Debug-level logging attributed to a specific concern (os.Logger category).
    static func debug(_ concern: Concern, _ message: String) {
        log(level: .debug, concern: concern, message: message)
    }

    /// Info-level logging for high-level milestones.
    /// Visible when configured log level is `>= .info`.
    static func info(_ message: String) {
        info(.core, message)
    }

    /// Info-level logging attributed to a specific concern (os.Logger category).
    static func info(_ concern: Concern, _ message: String) {
        log(level: .info, concern: concern, message: message)
    }

    /// Warning-level logging for recoverable issues.
    /// Visible when configured log level is `>= .warn`.
    /// Does NOT report to backend.
    static func warn(_ message: String) {
        warn(.core, message)
    }

    /// Warning-level logging attributed to a specific concern (os.Logger category).
    static func warn(_ concern: Concern, _ message: String) {
        log(level: .warn, concern: concern, message: message)
    }

    // MARK: - Structured-Object Logging

    // Policy: structured objects go through these `object:` overloads, rendered
    // as `message` + newline + pretty JSON; terse milestone lines with 1–2
    // scalars stay inline as `key=value`. Object dumps belong at `.debug` —
    // don't attach large payloads to info-level lines. Encoding runs only
    // after the level gate passes, so hosts at `.error` never pay encode cost
    // for dropped lines. Encoding failures fall back to `String(describing:)`
    // (see `Encodable.prettyJSON`) rather than dropping the line.

    /// Debug-level logging with a structured payload rendered as a pretty-JSON block.
    static func debug(_ concern: Concern, _ message: String, object: any Encodable) {
        guard isEnabled(.debug) else { return }
        log(level: .debug, concern: concern, message: "\(message)\n\(object.prettyJSON)")
    }

    /// Error-level logging for system failures.
    /// Always visible (unless `.none`).
    /// Automatically reports to backend via Errors service (if configured).
    static func error(
        _ error: EncoreError,
        context: ErrorContext,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        // Developer-facing: clean, actionable message
        let message = error.errorDescription ?? "Unknown error"
        log(level: .error, concern: concern(for: context), message: message)

        // Report to error services (ErrorsClient handles async dispatch internally)
        let location = formatLocation(file: file, line: line, function: function)
        errorsClient?.report(error, context: context, location: location)
    }

    // MARK: - Private

    /// Unified-logging subsystem for all SDK log entries.
    /// Matches the identifier already used for the SDK's on-disk storage
    /// (`Application Support/com.encore.sdk/…`).
    private static let subsystem = "com.encore.sdk"

    /// One cached `os.Logger` per concern. Built once from `Concern.allCases`
    /// and immutable thereafter → safe for concurrent reads.
    private static let osLoggers: [Concern: os.Logger] = Dictionary(
        uniqueKeysWithValues: Concern.allCases.map {
            ($0, os.Logger(subsystem: subsystem, category: $0.rawValue))
        }
    )

    /// Single definition of the level gate. The `object:` overloads consult it
    /// before encoding so dropped lines never pay JSON-encode cost; `log()`
    /// re-checks it (cheap) so plain-message entry points stay one-liners.
    private static func isEnabled(_ level: Encore.LogLevel) -> Bool {
        // Read configured log level if available; fall back to `.error` pre-configure.
        (configuration?.logLevel ?? .error) >= level
    }

    private static func log(level: Encore.LogLevel, concern: Concern, message: String) {
        guard isEnabled(level) else { return }

        // Defensive default: the never-crash standard outranks the
        // built-from-allCases invariant.
        let osLogger = osLoggers[concern, default: os.Logger(subsystem: subsystem, category: concern.rawValue)]

        // `.public` is deliberate: this output is gated behind the host app
        // opting into a verbose logLevel; redacted-by-default would make it useless.
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .warn:
            osLogger.warning("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        case .none:
            break // Unreachable: level-specific entry points never pass `.none`.
        }
    }

    /// Maps the backend error-reporting taxonomy onto the console category
    /// vocabulary so `Logger.error` lands in the right Xcode category without
    /// callers passing a concern alongside the context they already provide.
    private static func concern(for context: ErrorContext) -> Concern {
        switch context {
        case .configuration: return .configuration
        case .presentOfferInitialization: return .presentation
        case .fetchOfferData, .startTransaction, .verifyTransaction, .logImpression: return .offers
        case .fetchEntitlements, .grantSignal: return .entitlements
        case .apiRequest: return .network
        case .outbox: return .core
        case .analytics: return .analytics
        }
    }

    private static func formatLocation(file: String, line: Int, function: String) -> String {
        let filename = file.split(separator: "/").last.map(String.init) ?? file
        return "\(filename):\(line) \(function)"
    }
}

// MARK: - Log Level

extension Encore {
    /// Log level for SDK debug output.
    /// Higher levels include lower levels (e.g., .info shows info + warn + error).
    public enum LogLevel: Int, Comparable, Sendable {
        case none = 0    // No logging (production default)
        case error = 1   // Only errors
        case warn = 2    // Warnings and errors
        case info = 3    // Milestones, warnings, errors
        case debug = 4   // Everything (verbose)

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
