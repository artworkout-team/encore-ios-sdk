//
//  LeadEvents.swift
//  Encore
//
//  Analytics events for lead capture flow.
//

import Foundation

// MARK: - Lead Capture Events

/// Tracked when a private relay email is detected and blocked
struct LeadPrivateRelayDetectedEvent: AnalyticsEvent {
    static let eventName = "sdk_lead_private_relay_detected"

    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(presentationId: String, variantId: String?, useCase: UseCase, placementId: String?) {
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}
