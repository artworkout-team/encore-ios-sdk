// A mount's opt-out from looks that open the offer sheet by themselves. Public: the generic host and
// GiftsButton take it, and the React Native and Flutter bridges pass its raw value.

import Foundation

/// Whether a GiftsButton opens its sheet once without a tap is Encore's decision, made per look on the
/// server (only ever as an experiment arm). Pass ``off`` to forbid it; leave `autoOpen` nil (the
/// default) to let Encore decide. A look opens by itself only after its impression counted.
public enum AutoOpen: String, Sendable, Equatable, CaseIterable {
    /// Never opens the sheet by itself, whatever look Encore serves.
    case off
}
