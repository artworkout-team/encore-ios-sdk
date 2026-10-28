// What an SDUI image slot draws and where its impression probe sits, decided
// apart from SwiftUI so it can be unit tested without rendering.

import Foundation

/// An offer with no picture draws its logo on a tile, as the web SDK does, and a
/// featured one keeps its impression probe on that tile.
struct SDUIImageSlotPlan: Equatable {

    enum Content: Equatable {
        /// Load this url. nil (a present url that does not parse, or a non-offer
        /// slot with none) shows the placeholder.
        case image(URL?)
        /// The offer has no picture. nil logo draws the bare tile.
        case logoTile(URL?)
    }

    enum Probe: Equatable {
        case none
        /// Reports once the image has LOADED; a failed load never bills.
        case loadedImage
        /// Reports once the tile is on screen: the tile is the ad.
        case tile
    }

    let content: Content
    let probe: Probe

    init(binding: SDUICreativeBinding?, imageUrl: String?, tileLogoUrl: String?, isInsideOfferRow: Bool) {
        // Inside a row the row reports, whether or not this slot drew anything.
        let probes = binding == .offerPrimaryCreative && !isInsideOfferRow
        let isOfferPicture = binding == .offerPrimaryCreative || binding == .offerHeroImage

        if isOfferPicture, Self.nonBlank(imageUrl) == nil {
            content = .logoTile(Self.nonBlank(tileLogoUrl).flatMap(URL.init(string:)))
            probe = probes ? .tile : .none
        } else {
            content = .image(URL(string: imageUrl ?? ""))
            probe = probes ? .loadedImage : .none
        }
    }

    static func nonBlank(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}
