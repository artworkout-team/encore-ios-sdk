// Sources/Encore/Core/Infrastructure/Outbox/OutboxWorker.swift
//
// Background worker that processes the outbox queue.
// Implements exponential backoff with jitter for retries.

import Foundation

// MARK: - Outbox Worker

/// Background worker that processes outbox jobs.
/// - Runs continuously while jobs exist
/// - Implements exponential backoff with jitter
/// - Respects network reachability (future enhancement)
internal final class OutboxWorker: @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Maximum number of retry attempts before giving up on a job
    private let maxAttempts: Int
    
    /// Base delay for exponential backoff (in seconds)
    private let baseDelay: TimeInterval
    
    /// Maximum delay cap (in seconds)
    private let maxDelay: TimeInterval
    
    // MARK: - Properties
    
    private let storage: OutboxStorage
    private let clients: [ClientTarget: HTTPClientProtocol]
    private var isRunning: Bool = false
    private var processingTask: Task<Void, Never>?
    private let lock = NSLock()
    
    // MARK: - Init
    
    init(
        storage: OutboxStorage,
        clients: [ClientTarget: HTTPClientProtocol],
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 2.0,
        maxDelay: TimeInterval = 16.0
    ) {
        self.storage = storage
        self.clients = clients
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
    
    // MARK: - Public API
    
    /// Start the worker (idempotent - safe to call multiple times).
    func start() {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isRunning else { return }
        isRunning = true
        
        processingTask = Task.detached(priority: .utility) { [weak self] in
            await self?.processLoop()
        }
        
        Logger.debug("OutboxWorker: Started")
    }
    
    /// Stop the worker.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        isRunning = false
        processingTask?.cancel()
        processingTask = nil
        
        Logger.debug("OutboxWorker: Stopped")
    }
    
    /// Trigger immediate processing (e.g., when network becomes available).
    func processNow() {
        start() // Idempotent - just ensures we're running
    }
    
    // MARK: - Processing Loop
    
    /// `isRunning` is guarded by `lock`; the loop must read it the same way
    /// `start()`/`stop()` write it. A cancelled `Task.sleep` throws
    /// immediately, so a swallowed cancellation would hot-loop until the
    /// stop is observed — exit on cancellation instead.
    private var shouldContinueProcessing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func processLoop() async {
        // Paces retry sleeps independently of attemptCount: transient
        // failures never consume an attempt, but back-to-back failures must
        // still back off rather than hot-loop.
        var consecutiveFailures = 0

        while shouldContinueProcessing, !Task.isCancelled {
            // Check for a job
            guard var job = storage.peek() else {
                // No jobs - wait and check again
                consecutiveFailures = 0
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                continue
            }

            // Check if job has exceeded max attempts
            if job.attemptCount >= maxAttempts {
                Logger.warn("OutboxWorker: Job \(job.id) exceeded max attempts, removing")
                storage.remove(jobId: job.id)
                continue
            }

            do {
                try await execute(job)
                storage.remove(jobId: job.id)
                consecutiveFailures = 0
                Logger.info("OutboxWorker: Job \(job.id) completed successfully")
            } catch {
                // Attempts are reserved for definitive rejections: replaying
                // those sends the same payload into the same wall. Transport
                // failures and 5xx are the outages this outbox exists to
                // outlive — they never consume an attempt (a multi-minute
                // outage used to destructively drain the whole queue in ~14s
                // per job); storage's maxJobAge is their only ceiling.
                if Self.isDefinitiveRejection(error) {
                    job.attemptCount += 1
                }
                job.lastError = error.localizedDescription
                storage.update(job)

                consecutiveFailures += 1
                let delay = calculateBackoff(attempt: min(consecutiveFailures, 6))
                Logger.warn("OutboxWorker: Job \(job.id) failed (attempts consumed: \(job.attemptCount)/\(maxAttempts)), retrying in \(Int(delay))s: \(error.localizedDescription)")

                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
        }
    }

    /// True when a retry can only replay the same payload into the same wall:
    /// the server understood the request and rejected it (4xx), or returned a
    /// 2xx body the SDK cannot decode. Everything else — transport failures,
    /// 5xx, unknown errors — is treated as transient and retried without
    /// consuming an attempt.
    static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard let encoreError = error as? EncoreError else { return false }
        switch encoreError {
        case .protocol(.http(let status, _)), .protocol(.api(let status, _, _)):
            return (400..<500).contains(status)
        case .protocol(.decoding):
            return true
        default:
            return false
        }
    }
    
    // MARK: - Request Execution
    
    private func execute(_ job: OutboxJob) async throws {
        guard let client = clients[job.clientTarget] else {
            Logger.warn("OutboxWorker: No client for target: \(job.clientTarget.rawValue), dropping job \(job.id)")
            return
        }
        
        let query: [String: String?]? = job.request.query?.mapValues { Optional($0) }
        
        // Execute request with pre-serialized body (no decode/re-encode)
        let _: EmptyResponse = try await client.request(
            path: job.request.path,
            method: job.request.method,
            bodyData: job.request.body,
            query: query
        )
    }
    
    // MARK: - Backoff Calculation
    
    /// Calculate exponential backoff with jitter.
    /// Formula: min(maxDelay, baseDelay * 2^attempt) + random jitter
    private func calculateBackoff(attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        let capped = min(exponential, maxDelay)
        let jitter = Double.random(in: 0...(capped * 0.1)) // 10% jitter
        return capped + jitter
    }
}

