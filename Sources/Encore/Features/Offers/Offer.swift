// Bundles fetched offers for the presentation layer.
// The OffersRepository handles success/error checking — this just carries data.

import Foundation

/// Note: Remote configuration is now fetched via /ui-config endpoint on identify(),
/// not from the offers response.
internal struct OfferResponse {
    let offers: [Offer]
    /// The server's answer to "may this user be promised the prize now?". Nil when
    /// the search didn't ask, or the backend predates the field: no promise.
    let publisherRewardPromise: Bool?
    /// How the app pays its prize. On-yes when the server sent none or one this SDK doesn't know.
    let publisherRewardMode: PublisherRewardMode

    init(dto: DTO.Offers.SearchResponse, publisherRewardPromise: Bool? = nil,
         publisherRewardMode: PublisherRewardMode = .onYes, publisherRewardLabels: [String: String] = [:]) {
        let campaigns = dto.offers.map { offer in
            var campaign = Campaign(dto: offer)
            campaign.publisherRewardLabel = publisherRewardLabels[campaign.id]
            return campaign
        }
        let claimable = campaigns.filter(\.isClaimable)
        if claimable.count < campaigns.count {
            Logger.warn(.offers, "Dropped \(campaigns.count - claimable.count) offer(s) with no creative and no tracking")
        }
        self.offers = claimable
        self.publisherRewardPromise = publisherRewardPromise
        self.publisherRewardMode = publisherRewardMode
    }

    init(offers: [Offer], publisherRewardPromise: Bool?, publisherRewardMode: PublisherRewardMode = .onYes) {
        self.offers = offers
        self.publisherRewardPromise = publisherRewardPromise
        self.publisherRewardMode = publisherRewardMode
    }

    func withPublisherRewardPromise(_ promise: Bool?) -> OfferResponse {
        OfferResponse(offers: offers, publisherRewardPromise: promise, publisherRewardMode: publisherRewardMode)
    }

    func withOffers(_ offers: [Offer]) -> OfferResponse {
        OfferResponse(offers: offers, publisherRewardPromise: publisherRewardPromise, publisherRewardMode: publisherRewardMode)
    }

    /// Number of offers
    var offerCount: Int { offers.count }

    /// Alias for presentation layer compatibility
    var offerList: [Offer] { offers }
}
