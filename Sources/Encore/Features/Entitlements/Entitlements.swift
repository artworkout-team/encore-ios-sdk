// Sources/Encore/Domain/Entities/Entitlement.swift
//
// Entitlement domain entities.
// Note: Response structs are manual (not DTO aliases) because the generated
// OpenAPI types use String? for dates, but we need Date? for proper parsing.
//

import Foundation

// =============================================================================
// MARK: - Public Entitlement Types
// =============================================================================

/// Unit of measurement for entitlement values
public enum EntitlementUnit: CustomStringConvertible, Sendable {
    case months
    case days
    case percent
    case dollars
    
    public var description: String {
        switch self {
        case .months: return "months"
        case .days: return "days"
        case .percent: return "percent"
        case .dollars: return "dollars"
        }
    }
}

/// Represents an entitlement with optional value and unit details
public enum Entitlement: Sendable {
    case freeTrial(value: Double? = nil, unit: EntitlementUnit? = nil)
    case discount(value: Double? = nil, unit: EntitlementUnit? = nil)
    case credit(value: Double? = nil, unit: EntitlementUnit? = nil)
}

/// Selects which entitlement set to inspect
public enum EntitlementScope: Sendable {
    case verified
    case all
}

// =============================================================================
// MARK: - Internal Response Entities
// =============================================================================

/// Free trial entitlement detail
internal struct FreeTrialEntitlement: Codable, Equatable {
    let startedAt: Date?
    let expiresAt: Date?
}

/// Discount entitlement detail
internal struct DiscountEntitlement: Codable, Equatable {
    let value: Double
    let unit: String // "percent" or "dollars"
    let expiresAt: Date?
}

/// Credits entitlement detail
internal struct CreditsEntitlement: Codable, Equatable {
    let totalAmount: Double
    let expiresAt: Date?
}

/// Entitlement details container
internal struct EntitlementDetails: Codable, Equatable {
    let freeTrial: FreeTrialEntitlement?
    let discounts: [DiscountEntitlement]?
    let credits: CreditsEntitlement?
}

/// Domain model for entitlements state.
/// Used internally by EntitlementManager - separate from API response DTO.
internal struct Entitlements: Codable, Equatable {
    let provisional: EntitlementDetails?
    let verified: EntitlementDetails?
    let all: EntitlementDetails?
    
    /// Map from API response DTO to domain model
    init(from response: EntitlementsResponse) {
        self.provisional = response.provisional
        self.verified = response.verified
        self.all = response.all
    }
    
    init(provisional: EntitlementDetails?, verified: EntitlementDetails?, all: EntitlementDetails?) {
        self.provisional = provisional
        self.verified = verified
        self.all = all
    }
}

/// Response from GET /entitlements endpoint
internal struct EntitlementsResponse: Codable {
    let success: Bool
    let provisional: EntitlementDetails?
    let verified: EntitlementDetails?
    let all: EntitlementDetails?
    let executionTimeMs: Int?
}
