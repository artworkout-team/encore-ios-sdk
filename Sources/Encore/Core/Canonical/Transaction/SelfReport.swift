// "Yes, I finished" reaches the server: POST /transactions/{id}/self-report. The
// server records the Yes (hiding the offer from this user everywhere) and alone
// decides whether the app's prize is granted. No answer means no prize.

import Foundation

// MARK: - Wire

/// One Yes, as sent. `reportId` is minted per Yes and reused on every retry, so a
/// retry of a granted report is granted again and a second device's Yes is not.
struct SelfReport: Sendable, Equatable {
    let transactionId: String
    /// The Encore user id when the report is sent.
    let userId: String
    let reportId: String
    /// Present only when the prize was promised.
    let publisherRewardId: String?
    /// Sent with `publisherRewardId`; the server clamps it to 1...10.
    let dailyLimit: Int?

    fileprivate var body: Body {
        Body(userId: userId, reportId: reportId, publisherRewardId: publisherRewardId, dailyLimit: dailyLimit)
    }

    // Hand-written until the backend route lands in the contract; replace with the
    // generated types on the next `make sync-contract`.
    fileprivate struct Body: Encodable {
        let userId: String
        let reportId: String
        let publisherRewardId: String?
        let dailyLimit: Int?
    }

    fileprivate struct Response: Decodable {
        let success: Bool
        let granted: Bool
        let reason: String?
    }

    fileprivate var path: String { "transactions/\(transactionId)/self-report" }
}

/// What the server said about a Yes.
enum SelfReportAnswer: Sendable, Equatable {
    case granted
    case notGranted(PublisherRewardIneligibility)
    /// Offline, timed out, a 5xx, a 404 from an older backend, or an unreadable body.
    case noAnswer
}

// MARK: - Sending

protocol SelfReportSending: Sendable {
    /// Queues `report` on the persistent FIFO outbox, in the caller's turn, so it is
    /// sent before any identify() queued after it. Retried until the server answers.
    @MainActor func record(_ report: SelfReport)
    /// Asks the server directly for this report's answer, waiting at most `timeout`.
    /// Duplicates the queued send on purpose: the same `reportId` gets the same answer.
    func answer(for report: SelfReport, waitingUpTo timeout: TimeInterval) async -> SelfReportAnswer
}

/// Records every report on the outbox and, for a promised Yes, asks for the answer.
struct SelfReporter: SelfReportSending {
    private let client: @MainActor @Sendable () -> HTTPClientProtocol?
    private let outbox: @MainActor @Sendable () -> OutboxManaging?

    init(client: @escaping @MainActor @Sendable () -> HTTPClientProtocol?, outbox: @escaping @MainActor @Sendable () -> OutboxManaging?) {
        self.client = client
        self.outbox = outbox
    }

    /// The configured SDK's API client and outbox, read at send time.
    static let live = SelfReporter(
        client: { Encore.shared.services?.oltpClient },
        outbox: { Encore.shared.services?.outbox }
    )

    @MainActor func record(_ report: SelfReport) {
        guard let outbox = outbox() else {
            Logger.warn(.offers, "Self-report not queued: SDK not configured")
            return
        }
        outbox.enqueue(.selfReport(report))
    }

    func answer(for report: SelfReport, waitingUpTo timeout: TimeInterval) async -> SelfReportAnswer {
        // Not a child task: a Yes that stops waiting must not cancel the request.
        let request = Task { await ask(report) }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await request.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.resume(.noAnswer)
            }
        }
    }

    /// Any failure is `.noAnswer`: the queued copy is what the server will record. A 404
    /// is not resent under a newer user id: the queued copy reaches the server before any
    /// later identify(), and the sheet drops an answer that arrives after a user change.
    private func ask(_ report: SelfReport) async -> SelfReportAnswer {
        guard let client = await client() else { return .noAnswer }
        do {
            let response: SelfReport.Response = try await client.request(path: report.path, method: "POST", body: report.body, query: nil)
            // A 2xx envelope that reports a failure is no answer, like the other repositories.
            guard response.success else { return .noAnswer }
            let reason = response.reason.flatMap(PublisherRewardIneligibility.init(rawValue:))
            // Paid when the brand confirms, never on a Yes, whatever `granted` says.
            if response.granted && reason != .paysOnVerification { return .granted }
            return .notGranted(reason ?? .unverified)
        } catch {
            Logger.info(.offers, "No answer to the self-report; no prize: \(error)")
            return .noAnswer
        }
    }
}

extension OutboxJob {
    /// The report, sent in queue order and retried until a response; always the same `reportId`.
    static func selfReport(_ report: SelfReport) -> OutboxJob {
        OutboxJob(request: OutboxRequest(path: report.path, method: "POST", body: report.body))
    }
}

/// Resumes a continuation with the first value only; later calls do nothing.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SelfReportAnswer, Never>?

    init(_ continuation: CheckedContinuation<SelfReportAnswer, Never>) { self.continuation = continuation }

    func resume(_ answer: SelfReportAnswer) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: answer)
    }
}
