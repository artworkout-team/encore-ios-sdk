// Sources/Encore/Core/Canonical/User/UsersDto.swift
//
// User domain DTOs - identity and IAP linking operations.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {
    
    /// Users Domain DTOs
    enum Users {
        
        // MARK: - Init Route (POST /publisher/sdk/v1/users)
        
        typealias InitRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_users.Input.Body.jsonPayload
        typealias InitResponse = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_users.Output.Ok.Body.jsonPayload
        typealias InitAttributes = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_users.Input.Body.jsonPayload.attributesPayload
        
        // MARK: - Identify Route (PATCH /publisher/sdk/v1/users/identify)
        
        typealias IdentifyRequest = Operations.patch_sol_publisher_sol_sdk_sol_v1_sol_users_sol_identify.Input.Body.jsonPayload
        typealias IdentifyResponse = Operations.patch_sol_publisher_sol_sdk_sol_v1_sol_users_sol_identify.Output.Ok.Body.jsonPayload
        typealias IdentifyAttributes = Operations.patch_sol_publisher_sol_sdk_sol_v1_sol_users_sol_identify.Input.Body.jsonPayload.attributesPayload
        
        // MARK: - IAP Link Route (POST /publisher/sdk/v1/iap-links)
        
        typealias LinkIAPRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_iap_hyphen_links.Input.Body.jsonPayload
        typealias LinkIAPResponse = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_iap_hyphen_links.Output.Ok.Body.jsonPayload
    }
}
