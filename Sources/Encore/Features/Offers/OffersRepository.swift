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
    func search(
        userId: String,
        attributes: UserAttributes?,
        sdkVersion: String,
        variantId: String? = nil,
        placementId: String? = nil,
        maxPostbackTimeMs: Int? = nil
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
            maxPostbackTimeMs: maxPostbackTimeMs
        )

        Logger.debug(.offers, "Searching offers", object: request)
        
        let dto: DTO.Offers.SearchResponse = try await client.request(
            path: "offers/search",
            method: "POST",
            body: request,
            query: nil
        )
        
        guard dto.success else {
            let errorMessage = dto.error ?? "No offers available"
            throw EncoreError.protocol(.api(status: 400, code: "search_failed", message: errorMessage))
        }
        
        return OfferResponse(dto: dto)
    }
}
