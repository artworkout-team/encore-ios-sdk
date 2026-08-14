//
//  OfferEvents.swift
//  Encore
//
//  Analytics events for offer interactions.
//

import Foundation

// MARK: - Analytics Context

/// Shared context for offer-related analytics events.
/// Captures the current state once and reuses across multiple events.
struct OfferAnalyticsContext {
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    
    // SDUI Variant tracking
    let variantId: String?

    /// Publisher placement that triggered this presentation. Multi-placement
    /// integrations are unauditable without it on every offer event.
    let placementId: String?

    /// Which use case this presentation belongs to. Lands on the events as the
    /// `use_case` property — a JSON-blob field in BigQuery, so no schema
    /// migration is needed and it prunes zero bytes on scan.
    let useCase: UseCase

    /// Create context from an Offer and current view state
    init(offer: Offer, impressionId: String, offerIndex: Int, totalOffers: Int, presentationId: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.campaignId = offer.id
        self.creativeId = offer.primaryCreative?.id
        self.advertiserName = offer.advertiserName
        self.impressionId = impressionId
        self.offerIndex = offerIndex
        self.totalOffers = totalOffers
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase
        self.placementId = placementId
    }

    /// Direct initialization for legacy/custom use
    init(campaignId: String, creativeId: String?, advertiserName: String, impressionId: String, offerIndex: Int, totalOffers: Int, presentationId: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.campaignId = campaignId
        self.creativeId = creativeId
        self.advertiserName = advertiserName
        self.impressionId = impressionId
        self.offerIndex = offerIndex
        self.totalOffers = totalOffers
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase
        self.placementId = placementId
    }
}

// MARK: - Offer Presentation Events

/// Tracked when offer presentation is triggered
struct OfferPresentationTriggeredEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_presentation_triggered"
    
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(presentationId: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}

/// Name constant for the terminal `show()` record. Built directly as an
/// outbox job (`OfferEvents+Outbox.swift`) rather than through track(), so it
/// survives process death like the other choke-point diagnostics.
enum PlacementResolvedEvent {
    static let eventName = "sdk_placement_resolved"
}

// MARK: - Presentation Diagnostic Events
//
// Taxonomy rule: `sdk_show_aborted` = exited BEFORE
// `sdk_offer_presentation_triggered` fired (preconditions and suppressions;
// the attempt never entered the funnel, and `triggered` is the funnel
// denominator). `sdk_offer_presentation_failed` = exited AFTER `triggered`
// (the funnel was attempted and did not reach presented).
// Both diagnostics carry `layer` ("native" on iOS; bridge SDKs emit their
// own) and ride the reliable outbox (see `OfferEvents+Outbox.swift`).

/// Tracked at the very top of `OfferSheetCoordinator.present()`, before any
/// gate. Proves the platform layer reached native presentation regardless of
/// any subsequent early return.
struct ShowEnteredEvent: AnalyticsEvent {
    static let eventName = "sdk_show_entered"

    let layer = "native"
    let placementId: String?
    let variantId: String?
    let useCase: String

    init(placementId: String?, variantId: String?, useCase: UseCase = .reduceChurn) {
        self.placementId = placementId
        self.variantId = variantId
        self.useCase = useCase.rawValue
    }
}

/// Reason a `show()` exited before `sdk_offer_presentation_triggered` fired.
enum ShowAbortReason: String {
    /// Duplicate `present()` while another presentation is already active.
    case alreadyPresenting = "already_presenting"
    /// Required services (analytics/entitlements/offers) were nil: SDK not configured.
    case notConfigured = "not_configured"
    /// OS below the presentation floor (iOS 17). Diagnostic reason only; the
    /// public `NotPresentedReason.unsupportedOS` wire value is unchanged.
    case unsupportedOS = "unsupported_os"
    /// NCL Ghost Trigger control cohort: pre-trigger suppression by design.
    case experimentControl = "experiment_control"
}

/// Tracked when a `show()` exits at a pre-trigger gate or suppression.
struct ShowAbortedEvent: AnalyticsEvent {
    static let eventName = "sdk_show_aborted"

    let layer = "native"
    let reason: String
    let placementId: String?
    let variantId: String?
    let useCase: String

    init(reason: ShowAbortReason, placementId: String?, variantId: String?, useCase: UseCase = .reduceChurn) {
        self.reason = reason.rawValue
        self.placementId = placementId
        self.variantId = variantId
        self.useCase = useCase.rawValue
    }
}

/// Tracked when offer presentation fails
struct OfferPresentationFailedEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_presentation_failed"
    
    let reason: String
    let iosVersion: String?
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    /// `.notPresented` reasons emit the same wire values the equivalent 1.x
    /// `DismissReason`s did (see `NotPresentedReason.wireValue`).
    init(reason: NotPresentedReason, iosVersion: String? = nil, presentationId: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.reason = reason.wireValue
        self.iosVersion = iosVersion
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}

/// Tracked when offer presentation succeeds
struct OfferPresentationSuccessEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_presentation_success"
    
    let presentationId: String
    let offerCount: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(presentationId: String, offerCount: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.presentationId = presentationId
        self.offerCount = offerCount
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}

/// Tracked when an offer is presented to the user
struct OfferPresentedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_presented"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationTrigger: String
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, trigger: String) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.presentationTrigger = trigger
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when a user claims an offer
struct OfferClaimedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_claimed"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let transactionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, transactionId: String) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.transactionId = transactionId
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked at the claim tap itself, before any guard can fail: the direct
/// offer-tap handler and the lead-flow activate. The advertiser-funnel
/// denominator; `transaction_id` is the eagerly minted client id.
struct OfferClaimTappedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_claim_tapped"

    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let transactionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, transactionId: String) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.transactionId = transactionId
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when the user comes back from the advertiser (in-app Safari dismiss
/// or external-browser return), exactly where the result record stages
/// `AdvertiserOutcome.claimed`.
struct OfferClaimReturnedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_claim_returned"

    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let transactionId: String?
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, transactionId: String?) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.transactionId = transactionId
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when the server confirms the conversion: the in-sheet strict poll
/// success (full context) or the cross-launch reconciler (no sheet, so only
/// `transaction_id`; absent context fields stay absent, never fabricated).
struct OfferVerifiedEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_verified"

    let campaignId: String?
    let creativeId: String?
    let advertiserName: String?
    let impressionId: String?
    let transactionId: String
    let offerIndex: Int?
    let totalOffers: Int?
    let presentationId: String?
    let variantId: String?
    let useCase: String?
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, transactionId: String) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.transactionId = transactionId
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }

    /// Cross-launch reconciliation: no sheet survives, so the only context is
    /// what the claim persisted beside the transaction id. `placementId` and
    /// `useCase` come from that record and stay nil when it predates them —
    /// the remaining per-impression fields are never fabricated.
    init(transactionId: String, placementId: String? = nil, useCase: UseCase? = nil) {
        self.campaignId = nil
        self.creativeId = nil
        self.advertiserName = nil
        self.impressionId = nil
        self.offerIndex = nil
        self.totalOffers = nil
        self.presentationId = nil
        self.transactionId = transactionId
        self.variantId = nil
        self.useCase = useCase?.rawValue
        self.placementId = placementId
    }
}

// MARK: - Claim Failure

/// Why a Claim tap failed to open the offer webview. Each case maps to a
/// distinct early-return in `handleOfferTap`; the enum exists so the funnel
/// can tell "claim never opened" apart from "claim opened but page failed"
/// and so we can alert per-reason rather than inferring failure from a
/// *missing* `sdk_offer_claimed`.
enum ClaimFailureReason: String {
    /// The transactions manager wasn't wired (SDK misconfiguration / teardown race).
    case managerUnavailable = "manager_unavailable"
    /// The backend `transactions.start` call threw (network or a server-side
    /// reject, e.g. the historical "Campaign domain not configured").
    case transactionStartFailed = "transaction_start_failed"
    /// The transaction started but the offer carried no destination URL.
    case missingDestinationUrl = "missing_destination_url"
    /// The transaction started but the resolved destination URL didn't parse.
    case invalidDestinationUrl = "invalid_destination_url"
}

/// Tracked whenever a Claim tap fails to reach the webview. This is the
/// failure twin of `OfferClaimedEvent`: together they make every claim
/// outcome observable end-to-end, so a regression like a silently-rejected
/// transaction surfaces in telemetry instead of looking like a user who
/// simply didn't tap.
struct OfferClaimFailedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_claim_failed"

    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let reason: String
    /// Present only for `transactionStartFailed` — the thrown error's
    /// description, to disambiguate network vs server-side rejects.
    let errorDescription: String?
    /// Present when the transaction was created before the failure (the URL
    /// branches), so the failed claim can still join the backend row.
    let transactionId: String?
    let variantId: String?
    let useCase: String
    let placementId: String?

    init(_ ctx: OfferAnalyticsContext, reason: ClaimFailureReason, errorDescription: String? = nil, transactionId: String? = nil) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.reason = reason.rawValue
        self.errorDescription = errorDescription
        self.transactionId = transactionId
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

// MARK: - Dismiss Reasons

/// Tracked when the offer sheet is dismissed
struct OfferSheetDismissedEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_sheet_dismissed"
    
    let presentationId: String
    let totalTimeSpentSeconds: Double
    let totalTimeSpentFormatted: String
    let declineReason: String
    let totalOffers: Int
    let offersViewed: Int
    let finalOfferIndex: Int
    let finalOfferCampaignId: String?
    let finalOfferCreativeId: String?
    let finalOfferAdvertiserName: String?
    let variantId: String?

    let useCase: String
    let placementId: String?

    init(presentationId: String, totalTime: Double, reason: DismissReason, totalOffers: Int, offersViewed: Int, finalIndex: Int, finalCampaignId: String?, finalCreativeId: String?, finalAdvertiserName: String?, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.presentationId = presentationId
        self.totalTimeSpentSeconds = totalTime
        self.totalTimeSpentFormatted = String(format: "%.1fs", totalTime)
        self.declineReason = reason.rawValue
        self.totalOffers = totalOffers
        self.offersViewed = offersViewed
        self.finalOfferIndex = finalIndex
        self.finalOfferCampaignId = finalCampaignId
        self.finalOfferCreativeId = finalCreativeId
        self.finalOfferAdvertiserName = finalAdvertiserName
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}

/// Tracked for time spent on an offer
struct OfferTimeSpentEvent: AnalyticsEvent {
    static let eventName = "sdk_offer_time_spent"
    
    let campaignId: String
    let advertiserName: String
    let creativeId: String?
    let offerIndex: Int
    let timeSpentSeconds: Double
    let timeSpentFormatted: String
    let viewCount: Int
    let totalOffers: Int
    let totalSheetTimeSeconds: Double
    let dismissReason: String
    let presentationId: String
    let variantId: String?
    
    let useCase: String
    let placementId: String?

    init(offer: Offer, index: Int, timeSpent: Double, viewCount: Int, totalOffers: Int, sheetTime: Double, reason: DismissReason, presentationId: String, variantId: String? = nil, useCase: UseCase = .reduceChurn, placementId: String? = nil) {
        self.campaignId = offer.id
        self.advertiserName = offer.advertiserName
        self.creativeId = offer.primaryCreative?.id
        self.offerIndex = index
        self.timeSpentSeconds = timeSpent
        self.timeSpentFormatted = String(format: "%.1fs", timeSpent)
        self.viewCount = viewCount
        self.totalOffers = totalOffers
        self.totalSheetTimeSeconds = sheetTime
        self.dismissReason = reason.rawValue
        self.presentationId = presentationId
        self.variantId = variantId
        self.useCase = useCase.rawValue
        self.placementId = placementId
    }
}

// MARK: - WebView Events

/// Tracked when attempting to open webview
struct OfferWebviewAttemptingOpenEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_attempting_open"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let url: String
    let urlHost: String
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, url: URL) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.url = url.absoluteString
        self.urlHost = url.host ?? ""
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when webview is opened
struct OfferWebviewOpenedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_opened"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let url: String
    let urlHost: String
    let openedAt: String
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, url: URL, openedAt: Date) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.url = url.absoluteString
        self.urlHost = url.host ?? ""
        self.openedAt = ISO8601DateFormatter().string(from: openedAt)
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when webview load succeeds
struct OfferWebviewLoadSuccessEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_load_success"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let url: String
    let urlHost: String
    let loadSuccess: Bool = true
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, url: URL) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.url = url.absoluteString
        self.urlHost = url.host ?? ""
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when webview load fails
struct OfferWebviewLoadFailedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_load_failed"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let url: String
    let urlHost: String
    let loadSuccess: Bool = false
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, url: URL) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.url = url.absoluteString
        self.urlHost = url.host ?? ""
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when webview initial redirect occurs
struct OfferWebviewInitialRedirectEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_initial_redirect"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let fromUrl: String
    let toUrl: String
    let fromHost: String
    let toHost: String
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, from: URL, to: URL) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.fromUrl = from.absoluteString
        self.toUrl = to.absoluteString
        self.fromHost = from.host ?? ""
        self.toHost = to.host ?? ""
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}

/// Tracked when webview is dismissed (SwiftUI)
struct OfferWebviewDismissedEvent: OfferContextEvent {
    static let eventName = "sdk_offer_webview_dismissed"
    
    let campaignId: String
    let creativeId: String?
    let advertiserName: String
    let impressionId: String
    let offerIndex: Int
    let totalOffers: Int
    let presentationId: String
    let timeSpentSeconds: Double
    let timeSpentFormatted: String
    let variantId: String?
    let useCase: String
    let placementId: String?
    
    init(_ ctx: OfferAnalyticsContext, timeSpent: Double) {
        self.campaignId = ctx.campaignId
        self.creativeId = ctx.creativeId
        self.advertiserName = ctx.advertiserName
        self.impressionId = ctx.impressionId
        self.offerIndex = ctx.offerIndex
        self.totalOffers = ctx.totalOffers
        self.presentationId = ctx.presentationId
        self.timeSpentSeconds = timeSpent
        self.timeSpentFormatted = String(format: "%.1fs", timeSpent)
        self.variantId = ctx.variantId
        self.useCase = ctx.useCase.rawValue
        self.placementId = ctx.placementId
    }
}
