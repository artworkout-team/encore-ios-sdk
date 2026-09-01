// Sources/Encore/Core/Infrastructure/Outbox/OutboxManager.swift
//
// Public facade for the reliable outbox.
// Provides a simple API for enqueueing jobs that must eventually succeed.

import Foundation

// MARK: - Outbox Protocol

/// Protocol for outbox operations. Enables testing with mocks.
internal protocol OutboxManaging: AnyObject, Sendable {
    @discardableResult
    func enqueue(_ job: OutboxJob) -> Bool
    var pendingCount: Int { get }
}

// MARK: - Outbox Manager

/// Reliable outbox for deferred HTTP requests.
///
/// The outbox guarantees eventual delivery of requests, surviving:
/// - Network failures (retries with exponential backoff)
/// - App termination (jobs persisted to disk)
/// - Process death (jobs resume on next launch)
///
/// Jobs are routed to the correct backend via `ClientTarget`:
/// - `.oltp` → encore-api (users, identity, iap-links)
/// - `.olap` → analytics-api (events, experiment exposures)
///
/// Usage:
/// ```swift
/// outbox.enqueue(.userInit(userId: "abc", attributes: nil))           // → oltp
/// outbox.enqueue(.experimentExposure(distinctId: "abc", ...))         // → olap
/// ```
internal final class OutboxManager: OutboxManaging, @unchecked Sendable {
    
    // MARK: - Properties
    
    private let storage: OutboxStorage
    private let worker: OutboxWorker
    
    // MARK: - Init
    
    init(oltpClient: HTTPClientProtocol, olapClient: HTTPClientProtocol) {
        self.storage = OutboxStorage()
        self.worker = OutboxWorker(storage: storage, clients: [
            .oltp: oltpClient,
            .olap: olapClient,
        ])
        
        // Start processing any pending jobs from previous sessions
        worker.start()
        
        let pendingCount = storage.count
        if pendingCount > 0 {
            Logger.info("OutboxManager: Initialized with \(pendingCount) pending job(s)")
        } else {
            Logger.debug("OutboxManager: Initialized (empty)")
        }
    }
    
    // MARK: - Public API
    
    /// Enqueue a job for eventual delivery.
    /// - Returns: `true` if job was persisted successfully, `false` if disk write failed.
    /// Processing happens in background regardless.
    @discardableResult
    func enqueue(_ job: OutboxJob) -> Bool {
        let success = storage.enqueue(job)
        if success {
            worker.processNow() // Trigger immediate processing attempt
        }
        return success
    }
    
    /// Get the number of pending jobs (for monitoring/debugging).
    var pendingCount: Int {
        storage.count
    }
    
    /// Get all pending jobs (for debugging/monitoring).
    func pendingJobs() -> [OutboxJob] {
        storage.allJobs()
    }
    
    // MARK: - Lifecycle
    
    /// Stop the background worker (call on app termination if needed).
    func stop() {
        worker.stop()
    }
}
