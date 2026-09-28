// Sources/Encore/Core/Canonical/Analytics/Models/OfferEvents+Outbox.swift
//
// Outbox job factories for presentation diagnostic events.
// Routes through POST /events (analytics-api → BigQuery) with reliable outbox
// delivery, mirroring `Experiment+Outbox.swift`. Used by
// `OfferSheetCoordinator` to guarantee delivery of native-entry and
// abort-reason signals even across early returns and process death.

import Foundation

extension OutboxJob {

    /// Create an outbox job for the `sdk_show_entered` diagnostic.
    /// Proves native `present()` was reached regardless of any later early return.
    static func showEntered(
        placementId: String?,
        distinctId: String,
        variantId: String?,
        useCase: UseCase = .reduceChurn,
        presentationId: String? = nil
    ) -> OutboxJob {
        var extra: [String: Any] = ["layer": "native", "use_case": useCase.rawValue]
        if let placementId { extra["placement_id"] = placementId }
        if let variantId { extra["variant_id"] = variantId }
        if let presentationId { extra["presentation_id"] = presentationId }
        return analyticsDiagnostic(
            eventName: ShowEnteredEvent.eventName,
            distinctId: distinctId,
            extraProperties: extra
        )
    }

    /// Create an outbox job for the `sdk_show_aborted` diagnostic: a pre-trigger
    /// exit (`sdk_offer_presentation_triggered` never fired) with its reason.
    static func showAborted(
        reason: ShowAbortReason,
        placementId: String?,
        distinctId: String,
        variantId: String?,
        useCase: UseCase = .reduceChurn,
        presentationId: String? = nil,
        iosVersion: String? = nil
    ) -> OutboxJob {
        var extra: [String: Any] = ["reason": reason.rawValue, "layer": "native", "use_case": useCase.rawValue]
        if let placementId { extra["placement_id"] = placementId }
        if let variantId { extra["variant_id"] = variantId }
        if let presentationId { extra["presentation_id"] = presentationId }
        if let iosVersion { extra["ios_version"] = iosVersion }
        return analyticsDiagnostic(
            eventName: ShowAbortedEvent.eventName,
            distinctId: distinctId,
            extraProperties: extra
        )
    }

    /// Terminal record of one `show()` call — the full `PresentationResult`
    /// on the wire, emitted at the coordinator's single resolution choke
    /// point. The SDK already computed this record; before this event it was
    /// thrown away, leaving integrations unvalidatable from the stream.
    static func placementResolved(
        result: PresentationResult,
        placementId: String?,
        presentationId: String,
        useCase: UseCase,
        presentationTarget: String,
        variantId: String?,
        unlockMode: UnlockMode,
        distinctId: String
    ) -> OutboxJob {
        var extra: [String: Any] = [
            "presentation_id": presentationId,
            "use_case": useCase.rawValue,
            "unlock_mode": unlockMode == .strict ? "strict" : "optimistic",
            // Tells a host-owned placement from one the SDK presented in its own
            // window. Without it the two are indistinguishable in the stream.
            "presentation_target": presentationTarget,
        ]
        // Included only when the publisher chose the label (2026-08-14
        // reversal): a minted placement_<8hex> id never goes on the wire —
        // absent folds to '(unlabeled)' at read time, and presentation_id is
        // the record's correlation key.
        if let placementId { extra["placement_id"] = placementId }
        if let variantId { extra["variant_id"] = variantId }

        switch result {
        case .notPresented(let reason):
            extra["resolution"] = "not_presented"
            extra["not_presented_reason"] = reason.wireValue
        case .presented(let outcome):
            extra["resolution"] = "presented"
            extra["advertiser_outcome"] = outcome.advertiser.wireValue
            extra["publisher_outcome"] = outcome.publisher.wireValue
            extra["dismissal"] = outcome.dismissal.rawValue
            if let claim = result.claim {
                extra["campaign_id"] = claim.campaignId
                if let transactionId = claim.transactionId {
                    extra["transaction_id"] = transactionId
                }
            }
        }

        return analyticsDiagnostic(
            eventName: PlacementResolvedEvent.eventName,
            distinctId: distinctId,
            extraProperties: extra
        )
    }

    // MARK: - Shared builder

    /// Builds an analytics-api (`.olap`) outbox job for a diagnostic event,
    /// matching the `/events` envelope produced by `AnalyticsClient.track`
    /// and `Experiment+Outbox.swift` (same metadata keys, deterministic event id).
    private static func analyticsDiagnostic(
        eventName: String,
        distinctId: String,
        extraProperties: [String: Any]
    ) -> OutboxJob {
        let timestamp = Date()
        let eventId = EventEnvelope.generateEventId(eventName: eventName, distinctId: distinctId, timestamp: timestamp)

        var properties: [String: Any] = [
            "sdk_version": Encore.sdkVersion,
            "app_bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "platform": "ios"
        ]
        if let appAccountId = userManager?.appAccountId {
            properties["app_account_id"] = appAccountId
        }
        for (key, value) in extraProperties {
            properties[key] = value
        }

        let body = DTO.Analytics.IngestEvent(
            event_id: eventId,
            event_name: eventName,
            event_timestamp: timestamp,
            distinct_id: distinctId,
            properties: properties.nonEmpty.map { .init(additionalProperties: $0.asOpenAPIProperties) }
        )

        // Console parity with track(): outbox-delivered events never pass the
        // AnalyticsClient logger, which made the terminal record the ONE event
        // invisible in the log stream during validation (2026-08-11 finding).
        // Delivery stays on the outbox — this is observability, not routing.
        Logger.debug(.analytics, eventName, object: body)

        return OutboxJob(request: OutboxRequest(path: "events", method: "POST", body: body), clientTarget: .olap)
    }
}
