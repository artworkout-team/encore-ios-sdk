// Sources/Encore/Core/Canonical/Leads/Leads+Outbox.swift
//
// OutboxJob factory for lead submission to POST /leads.
// Backend processes the lead: updates user, sends welcome email,
// schedules trial-end reminder, emits analytics.
//

import Foundation

extension OutboxJob {

    /// Create a job for POST /leads (lead submission).
    ///
    /// `transactionId` is the eager client-issued UUID v4 captured at the
    /// user's first Activate-tap in the session. The backend uses it to
    /// atomically materialize the matching `transactions` row inside the
    /// /leads handler, then substitutes it into `campaigns.destination_url`
    /// at email-send time so the affiliate platform can attribute the
    /// resulting click. See
    /// `docs/architecture/variants/asyncAdvertiserVerticalList.md`.
    ///
    /// `language` is the served locale of the sheet the email was captured
    /// in, so the lead email and its reminders match it. Absent when blank.
    /// Required, so a call site cannot drop it.
    static func submitLead(
        userId: String,
        campaignId: String,
        email: String,
        trialDurationDays: Int?,
        transactionId: String,
        language: String?
    ) -> OutboxJob {
        let payload = DTO.Leads.SubmitRequest(
            userId: userId,
            campaignId: campaignId,
            email: email,
            language: language.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            trialDurationDays: trialDurationDays,
            transactionId: transactionId
        )
        return OutboxJob(request: OutboxRequest(path: "leads", method: "POST", body: payload))
    }
}
