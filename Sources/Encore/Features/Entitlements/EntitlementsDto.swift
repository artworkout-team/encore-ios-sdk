// Sources/Encore/Data/DTOs/Entitlements.swift
//
// Entitlements domain DTOs - query and revocation operations.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {
    
    /// Entitlements Domain DTOs
    enum Entitlements {
        
        // MARK: - List Route (GET /publisher/sdk/v1/entitlements)
        
        typealias ListResponse = Operations.get_sol_publisher_sol_sdk_sol_v1_sol_entitlements.Output.Ok.Body.jsonPayload
        
        // MARK: - Revoke Route (POST /publisher/sdk/v1/entitlements/revoke)
        
        typealias RevokeRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_entitlements_sol_revoke.Input.Body.jsonPayload
        typealias RevokeResponse = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_entitlements_sol_revoke.Output.Ok.Body.jsonPayload
    }
}
