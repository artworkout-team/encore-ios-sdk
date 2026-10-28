// Placements the server says carry a rule or a pinned variant, from /config.
// Only these get their own offers cache entry (HQ-0273).

import Foundation

/// Labels normalised by `PlacementLabel.sanitized`, the same rule the show applies.
internal struct RuledPlacements: Sendable, Equatable {
    let labels: Set<String>

    init(_ raw: [String]) {
        labels = Set(raw.compactMap { PlacementLabel.sanitized($0) })
    }

    /// The label to key the offers cache on, or nil to reuse the shared set.
    func cacheLabel(for label: String?) -> String? {
        guard let label = PlacementLabel.sanitized(label), labels.contains(label) else { return nil }
        return label
    }

    /// Nil `ruled` is an older server: never key on placement, as today.
    static func cacheLabel(for label: String?, in ruled: RuledPlacements?) -> String? {
        ruled?.cacheLabel(for: label)
    }
}
