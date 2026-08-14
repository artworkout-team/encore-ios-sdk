// Sources/Encore/Features/TesterReveal/TesterRevealClient.swift
//
// Posts a single tester-reveal ping. Endpoint returns 204; we don't expect
// or decode a body. Failures are logged and swallowed — this is best-effort
// telemetry, never a host-facing error.

import Foundation

internal struct TesterRevealClient {
    private let client: HTTPClientProtocol

    init(client: HTTPClientProtocol) {
        self.client = client
    }

    func post(payload: TesterRevealRequest) async {
        do {
            let _: EmptyResponse = try await client.request(
                path: "publisher/sdk/v1/tester-reveal",
                method: "POST",
                body: payload,
                query: nil
            )
            Logger.info("TESTER-REVEAL: Posted reveal for userId=\(payload.userId)")
        } catch {
            Logger.warn("TESTER-REVEAL: Failed to post reveal: \(error)")
        }
    }
}

internal struct TesterRevealRequest: Encodable {
    let userId: String
    let appAccountId: String?
    let platform: String
    let deviceModel: String?
    let sdkVersion: String
}
