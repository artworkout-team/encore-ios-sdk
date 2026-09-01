// Outcome events for the Encore.shared.outcomes stream.
// Observation channel for results that already resolved elsewhere — including
// events that arrive after the presenting flow (or even the process) ended.

import Foundation

/// An event on ``Encore/outcomes``.
///
/// The stream is for **passive observers** (analytics forwarding, app-owned
/// state objects, debugging overlays). Control flow belongs at the callsite:
/// `switch await show()`.
public enum PlacementOutcome: Sendable {

    /// A presentation flow resolved. Yielded for every `show()` — including
    /// `.notPresented` outcomes — with the placement that triggered it.
    case presentation(placementId: String, result: PresentationResult)

    /// A strict-unlock verification completed **after** its flow ended —
    /// possibly on a later launch (the pending transaction is persisted and
    /// reconciled on launch/foreground). Entitlements have already been
    /// refreshed; gate on ``Encore/isActive(_:in:)`` or
    /// ``Encore/isActivePublisher(for:in:)`` for the concrete grant.
    case strictUnlockVerified(transactionId: String)
}
