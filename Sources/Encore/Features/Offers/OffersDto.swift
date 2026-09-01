// Sources/Encore/Data/DTOs/Offers.swift
//
// Offers domain DTOs - search, display, and campaign operations.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {
    
    /// Offers Domain DTOs
    enum Offers {
        
        // MARK: - Search Route (POST /publisher/sdk/v1/offers/search)
        
        // Request only types
        typealias SearchRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_offers_sol_search.Input.Body.jsonPayload
        
        // Response only types
        typealias SearchResponse = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_offers_sol_search.Output.Ok.Body.jsonPayload
        typealias SearchResponseMetadata = SearchResponse.metadataPayload
        
        // MARK: - Entities
        // Note: Offers are now Campaign objects directly (no wrapper)
        
        typealias Offer = SearchResponse.offersPayloadPayload
        typealias Campaign = Offer
        typealias Creative = Campaign.creativesPayloadPayload
        typealias Organization = Campaign.organizationPayload
        typealias Instruction = Creative.instructionsPayloadPayload
        typealias UserAttributes = SearchRequest.attributesPayload
        
        // MARK: - Enums
        
        typealias Platform = SearchRequest.platformPayload
        typealias PayoutModel = Campaign.payoutModelPayload
        typealias CampaignStatus = Campaign.statusPayload
        
        // Legacy alias - Offer is now just a Campaign
        typealias CreativeStatus = Creative.statusPayload
        typealias SupportedPlatform = Creative.supportedPlatformsPayloadPayload
    }
}

// MARK: - Convenience Extensions

extension DTO.Offers.Platform {
    /// Default platform for iOS SDK
    static var current: Self { .ios }
}
