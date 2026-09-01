// Sources/Encore/Domain/Entities/Campaign.swift
//
// Campaign domain entity.
//

import Foundation

// =============================================================================
// MARK: - Campaign
// =============================================================================


/// Offer is now a Campaign directly - represents an eligible campaign for this user.
internal typealias Offer = Campaign

/// Campaign information
internal struct Campaign {
    let id: String
    let name: String
    let payoutAmount: Double?
    let targetCountries: [String]?
    let destinationUrl: String
    let startDate: Date
    let endDate: Date?
    let priority: Int?
    let newPrice: String?
    let oldPrice: String?
    /// User-facing value proposition, e.g. "3 months of Hulu free". Surfaced as the `offerPerk` SDUI text binding.
    let perk: String?
    /// Promo badge class from the offers payload. `nil` means the backend
    /// attached no badge — the offer is not labelled a free trial.
    let badgeLabel: BadgeLabel?
    let organization: Organization
    let creatives: [Creative]

    /// Constrained promo badge for in-app offer cards. Mirrors the contract
    /// enum; kept as a local type so the SDUI layer never imports a generated
    /// `Operations.…` nested type.
    enum BadgeLabel: String {
        case freeTrial = "free_trial"
        case discount
    }

    init(dto: DTO.Offers.Campaign) {
        self.id = dto.id
        self.name = dto.name
        self.payoutAmount = dto.payoutAmount
        self.targetCountries = dto.targetCountries
        self.destinationUrl = dto.destinationUrl
        self.startDate = dto.startDate
        self.endDate = dto.endDate
        self.priority = dto.priority
        self.newPrice = dto.newPrice
        self.oldPrice = dto.oldPrice
        self.perk = dto.perk
        self.badgeLabel = dto.badgeLabel.flatMap { BadgeLabel(rawValue: $0.rawValue) }
        self.organization = dto.organization.map { Organization(dto: $0) } ?? Organization(id: dto.organizationId, name: dto.name)
        self.creatives = dto.creatives?.map { Creative(dto: $0) } ?? []
    }
    
    // MARK: - Business Logic
    
    /// Primary active creative (first active in list)
    var primaryCreative: Creative? {
        creatives.first { $0.isActive }
    }
    
    /// Advertiser name (shorthand for organization.name)
    var advertiserName: String {
        organization.name
    }

    /// Whether this offer is advertised as a free trial, as opposed to a
    /// discount or no promo at all. Published to the SDUI state machine as
    /// `selectedOfferIsFreeTrial` so variants can branch their copy. Anything
    /// other than an explicit `free_trial` badge is false — an unlabelled offer
    /// must not render "free month" / "$0 today" copy.
    var isFreeTrialOffer: Bool {
        badgeLabel == .freeTrial
    }
    
    /// Display title from primary creative, fallback to campaign name
    var displayTitle: String {
        primaryCreative?.title ?? name
    }
    
    /// Description from primary creative
    var displayDescription: String? {
        primaryCreative?.description
    }
    
    /// Advertiser description (alias for displayDescription, legacy compatibility)
    var creativeAdvertiserDescription: String? {
        displayDescription
    }
    
    /// Logo URL from primary creative
    var displayLogoUrl: String? {
        primaryCreative?.logoUrl
    }
    
    /// Primary image URL from primary creative
    var displayPrimaryImageUrl: String? {
        primaryCreative?.primaryImageUrl
    }
    
    /// CTA text with fallback default
    var displayCtaText: String {
        primaryCreative?.ctaText ?? "Claim Offer"
    }
    
    /// Destination URL from primary creative (for tracking URL construction)
    var displayDestinationUrl: String? {
        primaryCreative?.destinationUrl
    }
    
    /// Tracking parameters from primary creative
    var displayTrackingParameters: [String: Any]? {
        primaryCreative?.trackingParameters
    }
    
    /// Full instructions from primary creative
    var displayInstructions: [Instruction] {
        primaryCreative?.instructions ?? []
    }
    
    /// Quick instructions from primary creative
    var displayQuickInstructions: String? {
        primaryCreative?.quickInstructions
    }

    /// Overlay config from the primary creative, if present.
    /// Drives `CreativeOverlayModifier` in the SDUI renderer.
    var displayOverlayConfig: SDUIOverlayConfig? {
        primaryCreative?.overlayConfig
    }
}


