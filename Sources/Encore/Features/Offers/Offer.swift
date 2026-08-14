// Bundles fetched offers for the presentation layer.
// The OffersRepository handles success/error checking — this just carries data.

import Foundation

/// Note: Remote configuration is now fetched via /ui-config endpoint on identify(),
/// not from the offers response.
internal struct OfferResponse {
    let offers: [Offer]

    init(dto: DTO.Offers.SearchResponse) {
        // Offers are now campaigns directly from the API
        self.offers = dto.offers.map { Campaign(dto: $0) }
    }

    /// Number of offers
    var offerCount: Int { offers.count }

    /// Alias for presentation layer compatibility
    var offerList: [Offer] { offers }
}
