// Sources/Encore/Core/Canonical/User/User+Outbox.swift
//
// Domain-specific OutboxJob factories for User operations.
// Keeps infrastructure (Outbox) decoupled from domain knowledge.

import Foundation

// MARK: - User Outbox Jobs

extension OutboxJob {
    
    /// Create a job for POST /users (user init)
    static func userInit(userId: String, attributes: UserAttributes?) -> OutboxJob {
        let payload = DTO.Users.InitRequest(
            userId: userId,
            attributes: attributes.map { DTO.Users.InitAttributes(email: $0.email, name: $0.fullName) }
        )
        return OutboxJob(request: OutboxRequest(path: "users", method: "POST", body: payload))
    }
    
    /// Create a job for PATCH /users/identify
    static func userIdentify(currentUserId: String, newUserId: String, attributes: UserAttributes?) -> OutboxJob {
        let payload = DTO.Users.IdentifyRequest(
            currentUserId: currentUserId,
            newUserId: newUserId,
            attributes: attributes.map { DTO.Users.IdentifyAttributes(email: $0.email, name: $0.fullName) }
        )
        return OutboxJob(request: OutboxRequest(path: "users/identify", method: "PATCH", body: payload))
    }
}
