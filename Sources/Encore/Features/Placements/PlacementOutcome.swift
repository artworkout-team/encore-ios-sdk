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

    /// A presentation flow resolved. Yielded for every presentation — including
    /// `.notPresented` outcomes — with the same result `show()` or `resume` delivers.
    /// The one exception: a trigger's auto-open aborted before it showed, which is nothing happening.
    /// Grant a ``PublisherReward`` from that result, not from here too.
    case presentation(placementId: String, result: PresentationResult)

    /// A strict-unlock verification completed **after** its flow ended —
    /// possibly on a later launch (the pending transaction is persisted and
    /// reconciled on launch/foreground). Entitlements have already been
    /// refreshed; gate on ``Encore/isActive(_:in:)`` or
    /// ``Encore/isActivePublisher(for:in:)`` for the concrete grant.
    case strictUnlockVerified(transactionId: String)
}
