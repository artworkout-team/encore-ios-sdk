// Sources/Encore/Features/Offers/Data/OffersRepository.swift
//
// Repository for offer-related network operations.
// Wraps HTTPClient with offer-specific request/response handling.
//

import Foundation

internal struct OffersRepository: Sendable {
    private let client: HTTPClientProtocol
    
    init(client: HTTPClientProtocol) {
        self.client = client
    }
    
    // MARK: - Search Offers
    
    /// Searches for available offers for a user
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - attributes: Optional targeting attributes
    ///   - sdkVersion: SDK version string
    ///   - variantId: Optional SDUI variant ID for filtering creatives
    ///   - placementId: Publisher-supplied placement label. Stamped onto the
    ///     backend's `sdk_offer_requested` event so publisher analytics can break
    ///     the funnel out by placement. Pass it through `PlacementLabel.sanitized`.
    ///   - maxPostbackTimeMs: Optional filter to restrict offers to campaigns with postback latency
    ///     below this threshold (ms). Omit for no filtering (optimistic default).
    ///   - useCase: The surface being filled. The server resolves the variant from it
    ///     only when no `variantId` is sent; absent means churn, as today.
    ///   - publisherRewardDailyLimit: Asks the server whether the prize may be promised
    ///     (`publisherRewardPromise` on the response). Send only for an identified user with a prize.
    ///   - purpose: `purpose: "prefetch"` marks a search the SDK runs before any sheet is shown.
    ///     Its result may later back the sheet the user opens with a tap, so it is a served
    ///     request like any other, not an impression.
    func search(
        userId: String,
        attributes: UserAttributes?,
        sdkVersion: String,
        variantId: String? = nil,
        placementId: String? = nil,
        maxPostbackTimeMs: Int? = nil,
        useCase: UseCase? = nil,
        publisherRewardDailyLimit: Int? = nil,
        purpose: String? = nil
    ) async throws -> OfferResponse {
        let request = DTO.Offers.SearchRequest(
            userId: userId,
            attributes: attributes?.asDTO,
            limit: 50,
            offset: 0,
            sdkVersion: sdkVersion,
            platform: .ios,
            variantId: variantId,
            placementId: placementId,
            useCase: useCase.flatMap { DTO.Offers.SearchRequest.useCasePayload(rawValue: $0.rawValue) },
            maxPostbackTimeMs: maxPostbackTimeMs,
            purpose: purpose
        )

        Logger.debug(.offers, "Searching offers", object: request)
        
        let envelope: PromiseSearchResponse = try await client.request(
            path: "offers/search",
            method: "POST",
            body: PromiseSearchRequest(base: request, publisherRewardDailyLimit: publisherRewardDailyLimit),
            query: nil
        )
        let dto = envelope.base

        guard dto.success else {
            let errorMessage = dto.error ?? "No offers available"
            throw EncoreError.protocol(.api(status: 400, code: "search_failed", message: errorMessage))
        }
        
        return envelope.offerResponse
    }
}

// The prize fields ride beside the generated search types, each read on its own so
// a malformed one is dropped instead of failing the search. `sync_contract.sh` keeps
// the mode and the per-offer value out of the generated types for that reason.

private struct PromiseSearchRequest: Encodable {
    let base: DTO.Offers.SearchRequest
    let publisherRewardDailyLimit: Int?

    private enum CodingKeys: String, CodingKey { case publisherRewardDailyLimit }

    func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(publisherRewardDailyLimit, forKey: .publisherRewardDailyLimit)
    }
}

/// `/offers/search` `purpose` values.
internal enum OfferSearchPurpose {
    /// `purpose: "prefetch"` marks a search the SDK runs before any sheet is shown. Its result may
    /// later back the sheet the user opens with a tap, so it is a served request like any other,
    /// not an impression.
    static let prefetch = "prefetch"
}

/// The search response with the prize fields read beside the generated type.
struct PromiseSearchResponse: Decodable {
    let base: DTO.Offers.SearchResponse
    let publisherRewardPromise: Bool?
    let publisherRewardMode: String?
    /// Offer id → its prize label, for the offers that carry a well-formed value.
    let publisherRewardLabels: [String: String]

    private enum CodingKeys: String, CodingKey { case publisherRewardPromise, publisherRewardMode, offers }

    init(from decoder: Decoder) throws {
        base = try DTO.Offers.SearchResponse(from: decoder)
        // A malformed value is treated as absent: no promise, never a failed search.
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        publisherRewardPromise = try? container?.decodeIfPresent(Bool.self, forKey: .publisherRewardPromise)
        publisherRewardMode = try? container?.decodeIfPresent(String.self, forKey: .publisherRewardMode)
        let offers = (try? container?.decodeIfPresent([OfferRewardValue].self, forKey: .offers)) ?? []
        publisherRewardLabels = Dictionary(
            offers.compactMap { offer in offer.id.flatMap { id in offer.label.map { (id, $0) } } },
            uniquingKeysWith: { first, _ in first }
        )
    }
    var offerResponse: OfferResponse {
        OfferResponse(
            dto: base,
            publisherRewardPromise: publisherRewardPromise,
            publisherRewardMode: PublisherRewardMode(wire: publisherRewardMode),
            publisherRewardLabels: publisherRewardLabels
        )
    }
}

/// One offer's `publisherRewardValue`, never throwing: a missing or wrong-typed
/// `label` or `amount` leaves `label` nil, which reads as no value. `amount` must be a
/// whole number in 0...Int32.max in any JSON number form (`1500.0` and `1.5e3` are 1500),
/// the same bound Android's `Int` sets, so both platforms keep and drop the same values.
private struct OfferRewardValue: Decodable {
    let id: String?
    let label: String?

    private enum CodingKeys: String, CodingKey { case id, publisherRewardValue }
    private enum ValueKeys: String, CodingKey { case amount, label }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = try? container?.decode(String.self, forKey: .id)
        guard let value = try? container?.nestedContainer(keyedBy: ValueKeys.self, forKey: .publisherRewardValue),
              let amount = try? value.decode(Int.self, forKey: .amount), (0...Int(Int32.max)).contains(amount),
              let raw = try? value.decode(String.self, forKey: .label) else {
            label = nil
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        label = Campaign.isDisplayPropertyBlank(trimmed) ? nil : trimmed
    }
}
