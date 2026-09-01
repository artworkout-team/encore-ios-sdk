// Sources/Encore/Domain/Entities/Creative.swift
//
// Creative domain entity.
//

import Foundation

// =============================================================================
// MARK: - Creative
// =============================================================================

/// Creative asset for display
internal struct Creative {
    let id: String
    let name: String
    let title: String?
    let subtitle: String?
    let description: String?
    let primaryImageUrl: String?
    let logoUrl: String?
    let ctaText: String?
    let destinationUrl: String?
    let weight: Int
    let isActive: Bool
    let instructions: [Instruction]
    let quickInstructions: String?
    let tooltipText: String?
    let trackingParameters: [String: Any]?
    /// Optional overlay config for rendering dynamic text on top of
    /// `primaryImageUrl`. Nil on legacy creatives - renderer is a no-op.
    let overlayConfig: SDUIOverlayConfig?

    init(dto: DTO.Offers.Creative) {
        self.id = dto.id
        self.name = dto.name
        self.title = dto.title
        self.subtitle = dto.subtitle
        self.description = dto.description
        self.primaryImageUrl = dto.primaryImageUrl
        self.logoUrl = dto.logoUrl
        self.ctaText = dto.ctaText
        self.destinationUrl = dto.destinationUrl
        self.weight = dto.weight ?? 100
        self.isActive = dto.status == .active
        self.instructions = dto.instructions?.map { Instruction(dto: $0) } ?? []
        self.quickInstructions = dto.quickInstructions
        self.tooltipText = dto.tooltipText
        self.trackingParameters = dto.trackingParameters?.additionalProperties.asDict
        self.overlayConfig = Self.decodeOverlayConfig(dto.overlayConfig)
    }

    /// Bridge the generated DTO's nested overlay struct into the SDUI
    /// renderer's `SDUIOverlayConfig`. Same shape — re-encode and decode
    /// rather than hand-mapping every nested field.
    private static func decodeOverlayConfig(
        _ dto: DTO.Offers.Creative.overlayConfigPayload?
    ) -> SDUIOverlayConfig? {
        guard let dto else { return nil }
        do {
            let data = try JSONCoding.encoder.encode(dto)
            return try JSONCoding.decoder.decode(SDUIOverlayConfig.self, from: data)
        } catch {
            Logger.warn(.presentation, "Failed to decode overlayConfig: \(error)")
            return nil
        }
    }
}

// =============================================================================
// MARK: - Instruction
// =============================================================================

/// Instruction step for offer flow
internal struct Instruction {
    let title: String
    let subtitle: String
    let ctaButtonText: String?
    
    /// Direct initializer for programmatic construction
    init(title: String, subtitle: String, ctaButtonText: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.ctaButtonText = ctaButtonText
    }
    
    /// Initialize from DTO
    init(dto: DTO.Offers.Instruction) {
        self.title = dto.title
        self.subtitle = dto.subtitle
        self.ctaButtonText = dto.ctaButtonText
    }
}

