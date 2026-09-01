// Sources/Encore/Core/Infrastructure/Outbox/OutboxJob.swift
//
// Generic job types for the reliable outbox queue.
// Domain-agnostic: specific job factories live in their respective domain modules.
// See: Canonical/User/User+Outbox.swift for User-related jobs.

import Foundation

// MARK: - Client Target

/// Which HTTP client the outbox worker should use for this job.
/// - `.oltp`: encore-api (users, identity, iap-links) — `X-API-Key` auth
/// - `.olap`: analytics-api (events, exposures) — `X-Analytics-Key` auth
internal enum ClientTarget: String, Codable, Sendable {
    case oltp
    case olap
}

// MARK: - Outbox Job

/// A job in the outbox queue. Represents a deferred HTTP request.
/// Domain-specific factories are defined as extensions in their respective modules.
internal struct OutboxJob: Sendable {
    /// Unique identifier for this job
    let id: String
    
    /// When the job was created
    let createdAt: Date
    
    /// Number of times this job has been attempted
    var attemptCount: Int
    
    /// Last error message (for debugging)
    var lastError: String?
    
    /// HTTP request details
    let request: OutboxRequest
    
    /// Which backend this job targets (defaults to `.oltp` for backwards compatibility)
    let clientTarget: ClientTarget
    
    init(request: OutboxRequest, clientTarget: ClientTarget = .oltp) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.attemptCount = 0
        self.lastError = nil
        self.request = request
        self.clientTarget = clientTarget
    }
}

// MARK: - Codable (backwards-compatible)

extension OutboxJob: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, attemptCount, lastError, request, clientTarget
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        request = try container.decode(OutboxRequest.self, forKey: .request)
        // Existing persisted jobs won't have this key — default to OLTP
        clientTarget = (try? container.decode(ClientTarget.self, forKey: .clientTarget)) ?? .oltp
    }
}

// MARK: - Outbox Request

/// HTTP request details stored in the outbox.
internal struct OutboxRequest: Codable, Sendable {
    let path: String
    let method: String
    let body: Data?
    let query: [String: String]?
    
    /// Create a request with an Encodable body (uses `JSONCoding.encoder` for correct date formatting)
    init<T: Encodable>(path: String, method: String, body: T?, query: [String: String]? = nil) {
        self.path = path
        self.method = method
        self.body = body.flatMap { try? JSONCoding.encoder.encode($0) }
        self.query = query
    }
    
    /// Create a request without a body
    init(path: String, method: String, query: [String: String]? = nil) {
        self.path = path
        self.method = method
        self.body = nil
        self.query = query
    }
}
