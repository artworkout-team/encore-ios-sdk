// Sources/Encore/Features/Placements/PlacementLabel.swift
//
// Wire rules for the publisher-supplied placement label carried on
// /offers/search. Analytics context only — never worth risking a rejected
// offers request, so the label is normalized to what the contract accepts.

import Foundation

/// The `placementId` field of `/offers/search`, as the contract accepts it.
///
/// Normalization is the ratified fleet rule (2026-08-14, matching the web
/// SDK's shipped behavior): trim surrounding whitespace, treat a blank label
/// as absent, and truncate past the cap — trim FIRST, then truncate, so the
/// same padded over-long label buckets identically on every platform.
///
/// Only a label the publisher actually chose travels: the contract folds
/// auto-generated `placement_<8 hex>` ids into '(unlabeled)' at read time, so
/// sending one adds nothing.
internal enum PlacementLabel {

    /// Contract limit on `placementId` (`Types.swift`: "Max 64 chars").
    static let maxLength = 64

    /// The label to send, or nil when there is nothing worth sending.
    static func sanitized(_ id: String?) -> String? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Measured and cut in unicode scalars: the contract's maxLength counts
        // code points, and 64 Characters (grapheme clusters) can exceed it —
        // a rejected request would cost the user their offers to win an
        // analytics dimension.
        guard trimmed.unicodeScalars.count > maxLength else { return trimmed }
        Logger.warn("[INTEGRATION] placement id is \(trimmed.unicodeScalars.count) chars (max \(maxLength)) — truncating it to the first \(maxLength) on the offers request. Choose a shorter label to control the exact bucket.")
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxLength)))
    }
}
