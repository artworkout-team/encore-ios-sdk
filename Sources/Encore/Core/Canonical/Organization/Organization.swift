// Sources/Encore/Domain/Entities/Organization.swift
//
// Organization domain entity.
//

import Foundation

// =============================================================================
// MARK: - Organization
// =============================================================================

/// Organization/advertiser information
internal struct Organization {
    let id: String
    let name: String
    let description: String?
    let url: String?
    let logoUrl: String?
    
    init(dto: DTO.Offers.Organization) {
        self.id = dto.id
        self.name = dto.name
        self.description = dto.description
        self.url = dto.url
        self.logoUrl = dto.logoUrl
    }
    
    /// Fallback initializer when organization data is missing
    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.description = nil
        self.url = nil
        self.logoUrl = nil
    }
}

