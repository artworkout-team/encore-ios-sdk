// Sources/Encore/Core/Canonical/Transaction/TransactionsRepository.swift
//
// Repository for transaction-related network operations.
//

import Foundation

internal struct TransactionsRepository {
    private let client: HTTPClientProtocol
    
    init(client: HTTPClientProtocol) {
        self.client = client
    }
    
    // MARK: - Start Transaction
    
    /// Starts a new transaction for a campaign
    ///
    /// `useCase` is OMITTED for churn intervention (the backend default) so the
    /// paywall claim stays byte-identical to every pre-use-case SDK — the same
    /// convention the `/config` query param uses.
    /// `variantId` is the variant whose remote template rendered the sheet: the server freezes a
    /// per-offer reward only for one that shows it. Nil (a floor render) leaves the field out.
    /// `intent` `.preload` posts the same body to `transactions/preload`, which reserves the id
    /// without booking a claim; the claim's later POST returns that id. The claim's request is unchanged.
    /// - Returns: The transaction ID
    func start(userId: String, campaignId: String, useCase: UseCase = .reduceChurn, variantId: String? = nil,
               intent: TransactionIntent = .claim) async throws -> String {
        // Switched rather than mapped through `rawValue`: a use case added to
        // the SDK must fail to compile here instead of silently claiming as
        // churn intervention, which is unrecoverable once the row is written.
        let wireUseCase: DTO.Transactions.StartRequest.useCasePayload?
        switch useCase {
        case .reduceChurn: wireUseCase = nil
        case .rewardUsers: wireUseCase = .post_hyphen_action_hyphen_reward
        }

        let request = DTO.Transactions.StartRequest(
            campaignId: campaignId,
            userId: userId,
            useCase: wireUseCase,
            variantId: variantId
        )

        Logger.debug(.iap, "Starting transaction for campaign: \(campaignId)\(intent == .preload ? " (preload)" : "")")

        let dto: DTO.Transactions.StartResponse
        switch intent {
        case .claim:
            dto = try await client.request(path: "transactions", method: "POST", body: request, query: nil)
        case .preload:
            // Only an exact 200 is a reservation: any other answer means no preload.
            let (answer, status): (DTO.Transactions.StartResponse, Int) = try await client.requestWithStatus(
                path: "transactions/preload", method: "POST", body: request, query: nil, headers: [:]
            )
            guard status == 200 else {
                throw EncoreError.protocol(.api(status: status, code: "preload_not_reserved", message: "Preload answered \(status)"))
            }
            dto = answer
        }
        
        guard dto.success, let transactionId = dto.transactionId else {
            let errorMessage = dto.error ?? "Transaction start failed"
            throw EncoreError.protocol(.api(status: 400, code: "transaction_failed", message: errorMessage))
        }
        
        return transactionId
    }

    // MARK: - Transaction Status

    /// Checks the verification status of a transaction.
    /// - Parameter verify: When true, backend performs a synchronous advertiser fetch
    ///   before returning status (falls back to DB state on upstream failure).
    func getStatus(transactionId: String, verify: Bool = false) async throws -> String {
        struct StatusResponse: Codable {
            let success: Bool
            let status: String?
            let error: String?
        }

        Logger.debug(.iap, "Checking status for transaction: \(transactionId), verify: \(verify)")

        let dto: StatusResponse = try await client.request(
            path: "transactions/\(transactionId)/status",
            method: "GET",
            body: nil,
            query: verify ? ["verify": "true"] : nil
        )

        guard dto.success, let status = dto.status else {
            let errorMessage = dto.error ?? "Status check failed"
            throw EncoreError.protocol(.api(status: 400, code: "status_failed", message: errorMessage))
        }

        return status
    }

}

/// Why a transaction is started: a claim, or the steps-screen preload's reservation.
enum TransactionIntent: Sendable {
    case claim
    case preload
}
