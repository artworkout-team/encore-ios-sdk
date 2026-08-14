// Sources/Encore/Core/Infrastructure/Experiments/Extensions/Experiment+Outbox.swift
//
// Outbox job factory for experiment exposure events.
// Routes through POST /events (analytics-api → BigQuery) with reliable outbox delivery.

import Foundation

extension OutboxJob {

    /// Create an outbox job for experiment exposure tracking.
    /// `distinctId` is the resolved user id (never `appAccountId`), so exposure
    /// lands in the same namespace as the rest of the funnel; `appAccountId`
    /// still ships as its own property whenever it has resolved.
    static func experimentExposure(
        distinctId: String,
        appAccountId: String?,
        experiment: String,
        cohort: Cohort,
        assignmentVersion: Int,
        variantId: String?,
        useCase: UseCase = .reduceChurn,
        placementId: String? = nil
    ) -> OutboxJob {
        let timestamp = Date()
        let eventName = ExperimentExposureEvent.eventName
        let eventId = EventEnvelope.generateEventId(eventName: eventName, distinctId: distinctId, timestamp: timestamp)

        var properties: [String: Any] = [
            "experiment": experiment,
            "cohort": cohort.rawValue,
            "assignment_version": assignmentVersion,
            "use_case": useCase.rawValue,
            "sdk_version": Encore.sdkVersion,
            "app_bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "platform": "ios"
        ]
        if let appAccountId { properties["app_account_id"] = appAccountId }
        if let variantId { properties["variant_id"] = variantId }
        if let placementId { properties["placement_id"] = placementId }

        let body = DTO.Analytics.IngestEvent(
            event_id: eventId,
            event_name: eventName,
            event_timestamp: timestamp,
            distinct_id: distinctId,
            properties: properties.nonEmpty.map { .init(additionalProperties: $0.asOpenAPIProperties) }
        )

        // Console parity with track() — see the same note in OfferEvents+Outbox.
        Logger.debug(.analytics, eventName, object: body)

        return OutboxJob(request: OutboxRequest(path: "events", method: "POST", body: body), clientTarget: .olap)
    }
}
