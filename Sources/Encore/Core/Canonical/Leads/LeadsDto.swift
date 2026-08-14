// Sources/Encore/Core/Canonical/Leads/LeadsDto.swift
//
// Leads domain DTOs - email capture + IAP-gated lead submission.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {

    /// Leads Domain DTOs
    enum Leads {

        // MARK: - Submit Route (POST /publisher/sdk/v1/leads)

        typealias SubmitRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_leads.Input.Body.jsonPayload
    }
}
