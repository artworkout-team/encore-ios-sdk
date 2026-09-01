// Sources/Encore/Core/Infrastructure/IAP/TransactionProviding.swift
//
// Abstraction over StoreKit's Transaction.all for testability.
// Production uses StoreKitTransactionProvider; tests inject MockTransactionProvider.

import Foundation
import StoreKit

/// Provides verified original transaction IDs from StoreKit.
/// Abstraction allows unit testing without a real StoreKit environment.
@available(iOS 15.0, *)
internal protocol TransactionProviding {
    func verifiedOriginalTransactionIds() async -> [String]
}

/// Production implementation — iterates Transaction.all, filters to .verified.
@available(iOS 15.0, *)
internal struct StoreKitTransactionProvider: TransactionProviding {
    func verifiedOriginalTransactionIds() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.all {
            if case .verified(let txn) = result {
                ids.append(String(txn.originalID))
            }
        }
        return ids
    }
}
