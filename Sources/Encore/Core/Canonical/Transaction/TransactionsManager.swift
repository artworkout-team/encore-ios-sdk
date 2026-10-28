// Sources/Encore/Features/Transactions/TransactionsManager.swift
//
// Manager for transaction operations.
// Wraps TransactionsRepository and provides domain-level API.
//

import Foundation

/// Manager for transaction operations (starting transactions, etc.)
internal struct TransactionsManager: Sendable {
    private let repository: TransactionsRepository
    
    init(repository: TransactionsRepository) {
        self.repository = repository
    }
    
    // MARK: - Transaction Operations
    
    /// Starts a new transaction for a campaign.
    /// - Parameters:
    ///   - userId: The user's ID
    ///   - campaignId: The campaign ID to start a transaction for
    ///   - useCase: Surface the claim came from. Persisted on the row, which is
    ///     the only context the server-side completion and its payout ever see.
    ///   - variantId: The variant whose remote template rendered the sheet; nil on a floor render.
    ///   - intent: `.preload` reserves the id for the steps-screen preload without booking a claim.
    /// - Returns: The transaction ID
    func start(userId: String, campaignId: String, useCase: UseCase = .reduceChurn, variantId: String? = nil,
               intent: TransactionIntent = .claim) async throws -> String {
        try await repository.start(userId: userId, campaignId: campaignId, useCase: useCase, variantId: variantId, intent: intent)
    }
    /// Checks the verification status of a transaction.
    /// - Parameter verify: When true, triggers a synchronous advertiser fetch on the backend.
    func getStatus(transactionId: String, verify: Bool = false) async throws -> String {
        try await repository.getStatus(transactionId: transactionId, verify: verify)
    }

}
