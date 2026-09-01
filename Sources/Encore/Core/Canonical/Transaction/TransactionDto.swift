// Sources/Encore/Data/DTOs/Transactions.swift
//
// Transactions domain DTOs - lifecycle operations.
//

import Foundation
internal import OpenAPIRuntime

extension DTO {
    
    /// Transactions Domain DTOs
    enum Transactions {
        
        // MARK: - Start Route (POST /publisher/sdk/v1/transactions)
        
        typealias StartRequest = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_transactions.Input.Body.jsonPayload
        typealias StartResponse = Operations.post_sol_publisher_sol_sdk_sol_v1_sol_transactions.Output.Ok.Body.jsonPayload
    }
}
