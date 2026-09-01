// Sources/Encore/Features/Offers/VerificationPoller.swift
//
// Polls transaction status during strict unlock mode.
// Uses exponential backoff (0.5s → 1 → 2 → 4 → 8s) within a 15s window.

import Foundation

internal enum VerificationPollResult {
    case verified
    case timedOut
}

@MainActor
@available(iOS 17.0, *)
internal final class VerificationPoller {
    private let transactionId: String
    private let timeout: TimeInterval
    private var pollTask: Task<VerificationPollResult, Error>?

    init(transactionId: String, timeout: TimeInterval = StrictUnlock.verificationTimeout) {
        self.transactionId = transactionId
        self.timeout = timeout
    }

    func poll() async throws -> VerificationPollResult {
        guard let transactions = transactionsManager else {
            throw EncoreError.integration(.notConfigured)
        }

        let task = Task<VerificationPollResult, Error> { [transactionId, timeout, transactions] in
            let deadline = Date().addingTimeInterval(timeout)
            var interval: TimeInterval = 0.5

            while true {
                try Task.checkCancellation()
                let status = try await transactions.getStatus(transactionId: transactionId, verify: true)

                if status == "verified" || status == "final_granted" {
                    Logger.debug(.offers, "Transaction \(transactionId) verified")
                    return .verified
                }

                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }

                let sleepDuration = min(interval, remaining)
                Logger.debug(.offers, "Status: \(status), retrying in \(String(format: "%.1f", sleepDuration))s")
                try await Task.sleep(for: .seconds(sleepDuration))
                interval = min(interval * 2, 8)
            }

            Logger.debug(.offers, "Timed out for \(transactionId)")
            return .timedOut
        }

        self.pollTask = task
        return try await task.value
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }
}
