// Sources/Encore/Features/Offers/StrictUnlock.swift
//
// Shared constants for strict unlock mode. Single source of truth so the
// verification poll window and the max postback time filter can't drift.

import Foundation

internal enum StrictUnlock {
    /// Window for VerificationPoller to await backend confirmation.
    static let verificationTimeout: TimeInterval = 15.0

    /// Millisecond value sent to offers/search `maxPostbackTimeMs` filter.
    /// Restricts offers to campaigns whose postback latency fits within the verification window.
    static var maxPostbackTimeMs: Int { Int(verificationTimeout * 1000) }
}
