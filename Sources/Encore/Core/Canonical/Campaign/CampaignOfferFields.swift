// Campaign-level offer fields: the copy, logo and tracking a campaign carries
// itself, read ONLY when the offer arrives with no active creative.

import Foundation

/// Offer fields carried on the campaign. Blank text, an empty list and an empty
/// tracking bag are ABSENT, so no reader can build a claim link from nothing.
internal struct CampaignOfferFields {
    let description: String?
    let ctaText: String?
    /// A campaign override; readers fall back to the organization's logo.
    let logoUrl: String?
    let instructions: [Instruction]
    let quickInstructions: String?
    let trackingParameters: [String: Any]?

    static let none = CampaignOfferFields()

    init(
        description: String? = nil,
        ctaText: String? = nil,
        logoUrl: String? = nil,
        instructions: [Instruction]? = nil,
        quickInstructions: String? = nil,
        trackingParameters: [String: Any]? = nil
    ) {
        self.description = Self.present(description)
        self.ctaText = Self.present(ctaText)
        self.logoUrl = Self.present(logoUrl)
        self.instructions = instructions ?? []
        self.quickInstructions = Self.present(quickInstructions)
        self.trackingParameters = trackingParameters.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Title, subtitle and tooltip are on the wire but unread: nothing displays them.
    init(dto: DTO.Offers.Campaign) {
        self.init(
            description: dto.description,
            ctaText: dto.ctaText,
            logoUrl: dto.logoUrl,
            instructions: dto.instructions?.map {
                Instruction(title: $0.title, subtitle: $0.subtitle, ctaButtonText: $0.ctaButtonText, imageUrl: $0.imageUrl)
            },
            quickInstructions: dto.quickInstructions,
            trackingParameters: dto.trackingParameters?.additionalProperties.asDict
        )
    }

    private static func present(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}
