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
    /// The gift-sheet GROUP this campaign files under, nil when blank. A free
    /// string, because the grouping is the server's to edit without a release.
    /// The taxonomy name rides beside it on the wire, for web-sdk to map itself.
    let category: String?
    /// Link the user can send to someone else for this offer. Absent means the
    /// backend minted none, and the share must not fall back to another URL:
    /// an unattributed link loses the claim. Normalized by `webLink`.
    let shareUrl: String?
    /// Advertiser terms for this offer, nil when the campaign carries none or
    /// carries something this SDK cannot open. A variant gates its terms line
    /// on this, so the gate and the tap have to read the same rule.
    let termsUrl: String?
    /// Campaign-level presentation image for the gift surfaces, chosen for the
    /// deal rather than rotated like a creative. Read via `displayHeroImageUrl`.
    let heroImageUrl: String?
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
        // Blank is ABSENT, matching `distinctCategories`. Kept here rather than
        // at each reader, so one rule covers the chip strip and the operand.
        self.category = dto.categoryGroup.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Blank is ABSENT, the same rule `category` takes above, so the share
        // gate and the share action cannot disagree about one offer.
        self.termsUrl = Self.webLink(dto.termsUrl)
        self.shareUrl = Self.webLink(dto.shareUrl)
        self.heroImageUrl = dto.heroImageUrl
        self.organization = dto.organization.map { Organization(dto: $0) } ?? Organization(id: dto.organizationId, name: dto.name)
        self.creatives = dto.creatives?.map { Creative(dto: $0) } ?? []
    }
    
    /// A link this SDK can open, or nil.
    ///
    /// Blank is ABSENT, the rule `category` takes above. So is a scheme this
    /// SDK cannot open: the schema enforces none, and a variant gates a control
    /// on the field's presence, so a gate that opened on `example.com/terms`
    /// would draw a link whose tap then did nothing.
    private static func webLink(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return trimmed
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
    /// The hero if the campaign carries one, else the creative image. Two rungs,
    /// not web's three: its logo rung is reached only when a present URL fails to
    /// LOAD, which a binding cannot observe.
    var displayHeroImageUrl: String? {
        heroImageUrl.flatMap { $0.isEmpty ? nil : $0 } ?? displayPrimaryImageUrl
    }

    var displayPrimaryImageUrl: String? {
        primaryCreative?.primaryImageUrl
    }
    
    /// CTA text with fallback default
    var displayCtaText: String {
        primaryCreative?.ctaText ?? "Claim Offer"
    }
    
    /// Claim destination (for tracking URL construction). The creative value is
    /// an optional override, so a creative with no `destinationUrl` falls back
    /// to the campaign's own, which the contract makes required.
    var displayDestinationUrl: String? {
        primaryCreative?.destinationUrl ?? destinationUrl
    }
    
    /// Tracking parameters from primary creative
    var displayTrackingParameters: [String: Any]? {
        primaryCreative?.trackingParameters
    }
    
    /// Full instructions from primary creative
    var displayInstructions: [Instruction] {
        primaryCreative?.instructions ?? []
    }
    
    /// Quick instructions from the primary creative, nil when it carries none.
    ///
    /// Blank is ABSENT here rather than at each reader, so the
    /// `quickInstructions` gate and the line it draws agree. Android takes the
    /// same rule at its own seam.
    var displayQuickInstructions: String? {
        primaryCreative?.quickInstructions
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Overlay config from the primary creative, if present.
    /// Drives `CreativeOverlayModifier` in the SDUI renderer.
    var displayOverlayConfig: SDUIOverlayConfig? {
        primaryCreative?.overlayConfig
    }
}


