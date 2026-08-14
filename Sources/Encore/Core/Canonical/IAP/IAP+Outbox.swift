// Sources/Encore/Core/Canonical/IAP/IAP+Outbox.swift
//
// Outbox job factory for IAP link operations.
// Links appAccountId (person-level) to originalTransactionId (subscription chain).
// Routes through POST /iap-links (encore-api → Postgres).

import Foundation

extension OutboxJob {
    
    /// Create an outbox job for POST /iap-links.
    /// Links person-level identity to subscription chain for NCL attribution.
    static func iapLink(
        appAccountId: String,
        originalTransactionId: String
    ) -> OutboxJob {
        let payload = DTO.Users.LinkIAPRequest(
            appTransactionId: appAccountId,
            originalTransactionId: originalTransactionId
        )
        return OutboxJob(request: OutboxRequest(path: "iap-links", method: "POST", body: payload))
    }
}
