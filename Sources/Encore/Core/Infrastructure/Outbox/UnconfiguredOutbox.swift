// Sources/Encore/Core/Infrastructure/Outbox/UnconfiguredOutbox.swift
//
// Disk landing zone for diagnostics emitted before configure().
// The outbox queue is a directory, not a service: jobs written here are drained
// by the worker the next configure() starts, so a show() that ran without a
// configured SDK is still observable.

import Foundation

/// Enqueues outbox jobs when no `ServiceContainer` exists yet.
///
/// `sdk_show_aborted(not_configured)` is the one abort that is emitted while
/// `Encore.shared.services` is nil — the very condition that makes the normal
/// `services.outbox` path a no-op. Without this, the single event that
/// distinguishes "the publisher never called show()" from "show() ran before
/// configure()" could never reach the wire.
///
/// Delivery is deferred, never dropped: `OutboxStorage` persists to a fixed
/// Application Support directory with its own age/count eviction, and the
/// worker created by the next `configure()` picks the jobs up from there.
internal enum UnconfiguredOutbox {

    /// Shared handle on the same on-disk queue `OutboxManager` drains.
    private static let storage = OutboxStorage()

    #if DEBUG
    /// Redirects the queue in tests so suites never write to Application Support.
    nonisolated(unsafe) static var storageForTesting: OutboxStorage?
    #endif

    /// Persist `job` for delivery once the SDK is configured.
    @discardableResult
    static func enqueue(_ job: OutboxJob) -> Bool {
        #if DEBUG
        if let storageForTesting { return storageForTesting.enqueue(job) }
        #endif
        Logger.debug("UnconfiguredOutbox: SDK not configured — deferring \(job.request.path) until configure()")
        return storage.enqueue(job)
    }
}
