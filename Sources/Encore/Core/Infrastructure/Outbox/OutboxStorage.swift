// Sources/Encore/Core/Infrastructure/Outbox/OutboxStorage.swift
//
// File-based storage for the outbox queue.
// Each job is stored as a separate JSON file for memory efficiency.
// Files are named by timestamp for natural FIFO ordering.

import Foundation

// MARK: - Outbox Storage

/// File-based storage for outbox jobs.
/// - Jobs are stored as individual JSON files (zero memory footprint when not processing)
/// - File naming uses timestamp + UUID for natural FIFO ordering
/// - Automatic eviction enforces storage limits
internal final class OutboxStorage: @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Maximum number of jobs to retain (FIFO eviction beyond this)
    private let maxJobCount: Int
    
    /// Maximum age for jobs (older jobs are evicted)
    private let maxJobAge: TimeInterval
    
    // MARK: - Properties
    
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue: DispatchQueue
    
    // MARK: - Init
    
    init(
        maxJobCount: Int = 100,
        maxJobAge: TimeInterval = 7 * 24 * 60 * 60, // 7 days
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.maxJobCount = maxJobCount
        self.maxJobAge = maxJobAge
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.queue = DispatchQueue(label: "com.encore.outbox.storage", qos: .utility)
        
        // Use provided directory or default to App Support
        if let directory {
            self.directory = directory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("com.encore.sdk/outbox", isDirectory: true)
        }
        
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        Logger.debug("OutboxStorage: Initialized at: \(self.directory.path)")
    }
    
    // MARK: - Public API
    
    /// Enqueue a new job. Automatically trims old jobs if over limit.
    /// - Returns: `true` if job was persisted successfully, `false` otherwise.
    @discardableResult
    func enqueue(_ job: OutboxJob) -> Bool {
        queue.sync {
            // Generate filename: timestamp-uuid.json (for FIFO ordering)
            let timestamp = Int(job.createdAt.timeIntervalSince1970 * 1000)
            let filename = "\(timestamp)-\(job.id).json"
            let fileURL = directory.appendingPathComponent(filename)
            
            // Write atomically (temp file + move)
            do {
                let data = try encoder.encode(job)
                try data.write(to: fileURL, options: .atomic)
                Logger.debug("OutboxStorage: Enqueued job: \(job.id)")
            } catch {
                // Report to error services - disk failures are critical for data integrity
                Logger.error(
                    .transport(.persistence(error)),
                    context: .outbox
                )
                return false
            }
            
            // Evict old jobs to stay within limits
            trim()
            return true
        }
    }
    
    /// Peek at the next job without removing it.
    func peek() -> OutboxJob? {
        queue.sync {
            guard let filename = sortedFilenames().first else { return nil }
            return loadJob(filename: filename)
        }
    }
    
    /// Remove a job by ID (called after successful processing).
    func remove(jobId: String) {
        queue.sync {
            guard let filename = sortedFilenames().first(where: { $0.contains(jobId) }) else { return }
            let fileURL = directory.appendingPathComponent(filename)
            try? fileManager.removeItem(at: fileURL)
            Logger.debug("OutboxStorage: Removed job: \(jobId)")
        }
    }
    
    /// Update a job (e.g., increment attempt count, store error).
    /// - Returns: `true` if job was updated successfully, `false` otherwise.
    @discardableResult
    func update(_ job: OutboxJob) -> Bool {
        queue.sync {
            guard let filename = sortedFilenames().first(where: { $0.contains(job.id) }) else { return false }
            let fileURL = directory.appendingPathComponent(filename)
            
            do {
                let data = try encoder.encode(job)
                try data.write(to: fileURL, options: .atomic)
                return true
            } catch {
                // Report to error services - update failures could lead to stuck jobs
                Logger.error(
                    .transport(.persistence(error)),
                    context: .outbox
                )
                return false
            }
        }
    }
    
    /// Get the count of pending jobs.
    var count: Int {
        queue.sync {
            sortedFilenames().count
        }
    }
    
    /// Get all pending jobs (for debugging/monitoring).
    func allJobs() -> [OutboxJob] {
        queue.sync {
            sortedFilenames().compactMap { loadJob(filename: $0) }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Get all job filenames sorted by name (oldest first due to timestamp prefix).
    private func sortedFilenames() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasSuffix(".json") }.sorted()
    }
    
    /// Load a job from a file.
    private func loadJob(filename: String) -> OutboxJob? {
        let fileURL = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(OutboxJob.self, from: data)
    }
    
    /// Evict jobs that exceed count or age limits.
    private func trim() {
        let filenames = sortedFilenames()
        let now = Date()
        
        for (index, filename) in filenames.enumerated() {
            let fileURL = directory.appendingPathComponent(filename)
            var shouldRemove = false
            
            // Remove if over count limit (keep newest, remove oldest)
            if index < filenames.count - maxJobCount {
                shouldRemove = true
                Logger.debug("OutboxStorage: Evicting job (count limit): \(filename)")
            }
            
            // Remove if too old
            if let job = loadJob(filename: filename), now.timeIntervalSince(job.createdAt) > maxJobAge {
                shouldRemove = true
                Logger.debug("OutboxStorage: Evicting job (age limit): \(filename)")
            }
            
            if shouldRemove {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}
