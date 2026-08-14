import Foundation
internal import OpenAPIRuntime

extension DTO {
    /// Analytics Domain DTOs
    enum Analytics {
        // MARK: - Ingest Route (POST /v1/events)

        typealias IngestEvent = Operations.post_sol_v1_sol_events.Input.Body.jsonPayload.Value1Payload
        typealias IngestEventProperties = IngestEvent.propertiesPayload
        typealias IngestAcceptedResponse = Operations.post_sol_v1_sol_events.Output.Accepted.Body.jsonPayload
    }
}


