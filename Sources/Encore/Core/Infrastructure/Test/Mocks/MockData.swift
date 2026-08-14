// Sources/Encore/Data/Mocks/MockData.swift
//
// Type-safe mock data builders for testing.
// Creates DTO types directly for JSON encoding (simulates server responses).
//
// Note: Wrapped in #if DEBUG to exclude from release builds.

#if DEBUG

import Foundation
internal import OpenAPIRuntime

// MARK: - Mock Data Namespace

/// Namespace for all mock data factories.
/// Usage: MockData.Offers.sample() -> Data
internal enum MockData {
    
    // MARK: - Shared Encoder
    
    /// Use production encoder to ensure mock data is compatible with production decoder
    static func encode<T: Encodable>(_ value: T) -> Data {
        // Force try is safe here - mock data should always encode
        try! JSONCoding.encoder.encode(value)
    }
}

// MARK: - Offers Mock Data

extension MockData {
    enum Offers {
        
        /// Create sample offers response with default mock campaigns
        static func sample() -> Data {
            let now = Date()
            let future = Calendar.current.date(byAdding: .year, value: 1, to: now)!
            
            let response = DTO.Offers.SearchResponse(
                success: true,
                offers: [
                    capitalOneOffer(now: now, future: future),
                    betterHelpOffer(now: now, future: future)
                ],
                metadata: DTO.Offers.SearchResponseMetadata(
                    total: 2,
                    limit: 10,
                    offset: 0,
                    hasMore: false,
                    executionTimeMs: 85.5,
                    requestId: "mock_request_\(UUID().uuidString.prefix(8))"
                )
            )
            
            return encode(response)
        }
        
        /// Create empty offers response
        static func empty() -> Data {
            let response = DTO.Offers.SearchResponse(
                success: true,
                offers: [],
                metadata: DTO.Offers.SearchResponseMetadata(
                    total: 0,
                    limit: 10,
                    offset: 0,
                    hasMore: false,
                    executionTimeMs: 12.0,
                    requestId: "mock_request_\(UUID().uuidString.prefix(8))"
                )
            )
            return encode(response)
        }
        
        // MARK: - Sample Offers (Offers are now Campaigns directly)
        
        private static func capitalOneOffer(now: Date, future: Date) -> DTO.Offers.Offer {
            DTO.Offers.Campaign(
                id: "campaign_capital_one",
                organizationId: "org_capital_one",
                name: "Capital One Shopping 🛍️",
                payoutModel: .CPA,
                payoutAmount: 15.0,
                attributionPlatform: "internal",
                targetCountries: ["US"],
                destinationUrl: "https://apps.apple.com/us/app/capital-one-shopping-save-now/id1089294040",
                startDate: now,
                endDate: future,
                status: .active,
                linkStatus: .valid,
                priority: 1,
                defaultCatalog: false,
                targetingMode: .blacklist,
                newPrice: "Free",
                oldPrice: nil,
                // The value proposition every offer card renders under the
                // advertiser name (`offerPerk`). Absent here, `offerPerk`
                // resolved to "" and every capture showed a card with its
                // bottom third empty — which reads as a broken layout rather
                // than as missing test data.
                perk: "Up to 10% cashback",
                createdAt: now,
                updatedAt: now,
                organization: DTO.Offers.Organization(
                    id: "org_capital_one",
                    name: "Capital One Shopping",
                    description: nil,
                    url: nil,
                    logoUrl: nil,
                    createdAt: now,
                    updatedAt: now
                ),
                creatives: [
                    DTO.Offers.Creative(
                        id: "creative_capital_one",
                        campaignId: "campaign_capital_one",
                        name: "Capital One Shopping Creative",
                        title: "Capital One Shopping 🛍️",
                        subtitle: nil,
                        description: "Download the Capital One Shopping app and get up to 10% cashback.",
                        primaryImageUrl: "https://storage.googleapis.com/yaw-assets/encoreCreatives/Capital%20One%20Shopping%20A.png",
                        logoUrl: "https://storage.googleapis.com/yaw-assets/encoreCreatives/Capital%20One%20Shopping%20A.png",
                        additionalImages: nil,
                        ctaText: "Claim now",
                        destinationUrl: "https://apps.apple.com/us/app/capital-one-shopping-save-now/id1089294040",
                        trackingParameters: nil,
                        weight: 100,
                        status: .active,
                        instructions: nil,
                        quickInstructions: nil,
                        minSdkVersion: nil,
                        maxSdkVersion: nil,
                        supportedPlatforms: [.ios],
                        tooltipText: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                ]
            )
        }
        
        private static func betterHelpOffer(now: Date, future: Date) -> DTO.Offers.Offer {
            DTO.Offers.Campaign(
                id: "campaign_betterhelp",
                organizationId: "org_betterhelp",
                name: "BetterHelp Therapy 🧠",
                payoutModel: .CPA,
                payoutAmount: 20.0,
                attributionPlatform: "internal",
                targetCountries: ["US"],
                destinationUrl: "https://hasofferstracking.betterhelp.com/aff_c?offer_id=40&aff_id=4561",
                startDate: now,
                endDate: future,
                status: .active,
                linkStatus: .valid,
                priority: 2,
                defaultCatalog: false,
                targetingMode: .blacklist,
                newPrice: "Free Trial",
                oldPrice: nil,
                perk: "$50 off first month",
                createdAt: now,
                updatedAt: now,
                organization: DTO.Offers.Organization(
                    id: "org_betterhelp",
                    name: "BetterHelp",
                    description: nil,
                    url: nil,
                    logoUrl: nil,
                    createdAt: now,
                    updatedAt: now
                ),
                creatives: [
                    DTO.Offers.Creative(
                        id: "creative_betterhelp",
                        campaignId: "campaign_betterhelp",
                        name: "BetterHelp Therapy Creative",
                        title: "BetterHelp Therapy 🧠",
                        subtitle: nil,
                        description: "Get professional therapy online with BetterHelp.",
                        primaryImageUrl: "https://storage.googleapis.com/yaw-assets/encoreCreatives/BetterHelp%20A.png",
                        logoUrl: "https://storage.googleapis.com/yaw-assets/encoreCreatives/BetterHelp%20A.png",
                        additionalImages: nil,
                        ctaText: "Claim now",
                        destinationUrl: "https://hasofferstracking.betterhelp.com/aff_c?offer_id=40&aff_id=4561",
                        trackingParameters: nil,
                        weight: 100,
                        status: .active,
                        instructions: nil,
                        quickInstructions: nil,
                        minSdkVersion: nil,
                        maxSdkVersion: nil,
                        supportedPlatforms: [.ios],
                        tooltipText: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                ]
            )
        }
    }
}

// MARK: - Transactions Mock Data

extension MockData {
    enum Transactions {
        
        /// Create start transaction response
        static func start(transactionId: String? = nil) -> Data {
            let id = transactionId ?? "mock_txn_\(UUID().uuidString.prefix(8))"
            let response = DTO.Transactions.StartResponse(
                success: true,
                transactionId: id,
                error: nil
            )
            return encode(response)
        }
    }
}

// MARK: - Entitlements Mock Data

extension MockData {
    enum Entitlements {
        
        /// Create sample entitlements with credits
        static func withCredits(provisional: Double = 50.0, verified: Double = 25.0) -> Data {
            let now = Date()
            let future = Calendar.current.date(byAdding: .month, value: 1, to: now)!
            
            let response = EntitlementsResponse(
                success: true,
                provisional: EntitlementDetails(
                    freeTrial: nil,
                    discounts: nil,
                    credits: CreditsEntitlement(totalAmount: provisional, expiresAt: future)
                ),
                verified: EntitlementDetails(
                    freeTrial: nil,
                    discounts: nil,
                    credits: CreditsEntitlement(totalAmount: verified, expiresAt: future)
                ),
                all: EntitlementDetails(
                    freeTrial: nil,
                    discounts: nil,
                    credits: CreditsEntitlement(totalAmount: provisional + verified, expiresAt: future)
                ),
                executionTimeMs: 45
            )
            return encode(response)
        }
        
        /// Create sample entitlements with free trial
        static func withFreeTrial(provisional: Bool = true, verified: Bool = false, expired: Bool = false) -> Data {
            let now = Date()
            let expiresAt = expired 
                ? Calendar.current.date(byAdding: .day, value: -1, to: now)!
                : Calendar.current.date(byAdding: .day, value: 7, to: now)!
            
            let response = EntitlementsResponse(
                success: true,
                provisional: provisional ? EntitlementDetails(
                    freeTrial: FreeTrialEntitlement(startedAt: now, expiresAt: expiresAt),
                    discounts: nil,
                    credits: nil
                ) : nil,
                verified: verified ? EntitlementDetails(
                    freeTrial: FreeTrialEntitlement(startedAt: now, expiresAt: expiresAt),
                    discounts: nil,
                    credits: nil
                ) : nil,
                all: EntitlementDetails(
                    freeTrial: FreeTrialEntitlement(startedAt: now, expiresAt: expiresAt),
                    discounts: nil,
                    credits: nil
                ),
                executionTimeMs: 30
            )
            return encode(response)
        }
        
        /// Create empty entitlements
        static func empty() -> Data {
            let response = EntitlementsResponse(
                success: true,
                provisional: nil,
                verified: nil,
                all: nil,
                executionTimeMs: 10
            )
            return encode(response)
        }
    }
}

#endif
