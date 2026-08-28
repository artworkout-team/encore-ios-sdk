// The 2.0 result surface: the factual record of a placement presentation.
// Two independent funnels (advertiser, publisher) + dismissal, read via
// policy readers (UnlockMode-aware) and fact readers.

import Foundation

// MARK: - Dismissal

/// How a presented offer sheet went away. The single close-reason vocabulary:
/// the result record, `trackOfferClose`, and the wire all speak this enum.
///
/// Raw values **are** the analytics wire values: the same string lands in
/// `decline_reason` on `sdk_offer_sheet_dismissed`, unmapped. 1.x carried two
/// vocabularies for one concept, a public one and an analytics one, which is
/// how they drifted apart. Values keep the analytics spelling, because a
/// warehouse column has queries written against it that a raw value does not.
public enum DismissReason: String, CaseIterable, Equatable, Sendable {
    case userTappedClose = "close_button"
    case userSwipedDown = "swipe_dismiss"
    case userCancelled = "user_cancelled"
    case lastOfferDeclined = "last_offer_declined"
    case dismissed = "dismissed"
    /// Claim rejected server-side (HTTP 409, cross-offer provisional cooldown).
    case cooldown = "provisional_cooldown"
    /// The flow finished on its own and the SDK closed the sheet.
    case flowCompleted = "flow_completed"
    /// The SDK force-ended a dead flow (structural reconciliation), not the user.
    case interrupted = "interrupted"

    // Emission-only cases. `Outcome.dismissal` never carries these: a claim is
    // advertiser-axis data (the record keeps the closing gesture), and the two
    // lifecycle interruptions fire while the sheet is still up.

    /// A claim happened this session; shadows the closing gesture on the wire,
    /// as it did in 1.x, so historical row counts keep their meaning.
    case offerClaimed = "offer_claimed"
    /// App left the foreground with the sheet still up. Not an ending.
    case appBackgrounded = "app_backgrounded"
    /// App is terminating with the sheet still up. Not an ending.
    case appTerminated = "app_terminated"
}

/// Legacy name for ``DismissReason``.
@available(*, deprecated, renamed: "DismissReason")
public typealias NotGrantedReason = DismissReason

// MARK: - Not Presented

/// Why no offer sheet ever appeared. Errors are values — `show()` never throws.
public enum NotPresentedReason: Equatable, Sendable {
    case notConfigured
    /// The builder implementation does not provide a host-owned view controller.
    case viewControllerUnavailable
    case alreadyPresenting
    /// Requires iOS 17+.
    case unsupportedOS
    /// No offers matched this user; don't retry immediately.
    case noOffers
    /// NCL control cohort — exposure logged, no UI by design.
    case experimentControl
    /// No enabled variant resolved for the requested use case; the SDK
    /// no-ops rather than falling back to the paywall sheet.
    case useCaseUnavailable
    /// Network, decoding, or integration failure.
    case error(EncoreError)
}

internal extension NotPresentedReason {
    /// The wire value for analytics. Not a second vocabulary: this is the
    /// enum's only serialization, and it cannot be a `rawValue` because
    /// `.error` carries a payload (Swift forbids raw values alongside
    /// associated values). The payload is also the point: `.error` serializes
    /// per failure type, which a case-constant raw value could never do.
    var wireValue: String {
        switch self {
        case .notConfigured:      return "not_configured"
        case .viewControllerUnavailable: return "view_controller_unavailable"
        case .alreadyPresenting:  return "already_presenting"
        case .unsupportedOS:      return "unsupported_ios"
        case .noOffers:           return "no_offer_available"
        case .experimentControl:  return "experiment_control"
        case .useCaseUnavailable: return "use_case_unavailable"
        case .error(let error):   return error.typeIdentifier
        }
    }
}

// MARK: - Funnels

/// The advertiser offer a claim ran against — the claim's factual payload.
/// `transactionId` joins the record to a later
/// ``PlacementOutcome/strictUnlockVerified(transactionId:)`` event.
public struct ClaimedOffer: Sendable, Equatable {
    /// Identifier of the claimed offer. On iOS this equals ``campaignId``
    /// (an offer *is* a campaign here); both names exist because the other
    /// SDKs expose both and the bridges line up field-for-field.
    public let offerId: String
    public let campaignId: String
    public let advertiserName: String
    public let transactionId: String?

    public init(offerId: String? = nil, campaignId: String, advertiserName: String, transactionId: String? = nil) {
        self.offerId = offerId ?? campaignId
        self.campaignId = campaignId
        self.advertiserName = advertiserName
        self.transactionId = transactionId
    }
}

/// Encore's funnel: how far the claim got. Written identically in every unlock
/// mode — the configured ``UnlockMode`` only affects policy readers.
public enum AdvertiserOutcome: Sendable, Equatable {
    case notAttempted
    /// Claim flow completed on-device; server verification not (yet) observed.
    case claimed(ClaimedOffer)
    /// Server-level confirmation observed in-session.
    case verified(ClaimedOffer)
    /// Claim rejected server-side (cross-offer provisional cooldown).
    case cooldown
    /// Claim errored — the SDK-side failure the host never saw.
    case failed(EncoreError)
}

/// The host's funnel: what their purchase code reported back.
public enum PublisherOutcome: Sendable, Equatable {
    case notAttempted
    case purchased
    case cancelled
    /// Deferred (Ask to Buy / SCA); may complete later via the App Store.
    case pending
    case failed
}

// MARK: - Presentation Result

/// The complete factual record of a placement presentation.
/// Two states: the interaction never started, or it ran to completion.
public enum PresentationResult: Sendable, Equatable {
    /// Nothing appeared; the reason says why (errors included, as values).
    case notPresented(NotPresentedReason)
    /// The sheet appeared; both funnels plus how it ended.
    case presented(Outcome)

    /// The record of a presented flow. Fields are independent axes; `.notAttempted`
    /// is a real value ("funnel open, nothing entered it"), never nil.
    public struct Outcome: Sendable, Equatable {
        public let advertiser: AdvertiserOutcome
        public let publisher: PublisherOutcome
        public let dismissal: DismissReason

        public init(
            advertiser: AdvertiserOutcome = .notAttempted,
            publisher: PublisherOutcome = .notAttempted,
            dismissal: DismissReason
        ) {
            self.advertiser = advertiser
            self.publisher = publisher
            self.dismissal = dismissal
        }
    }
}

// MARK: Fact readers

// The record carries facts only — there is no policy projection. 1.x-style
// "did this unlock" questions are answered by the host from the raw axes:
// the flow that ran is the variant's own rule set, and any SDK-computed
// verdict over global config could contradict it (e.g. a strict-configured
// app served an async-advertiser flow that grants optimistically).

public extension PresentationResult {
    /// The offer the user claimed, when the advertiser funnel got that far.
    var claim: ClaimedOffer? {
        switch advertiser {
        case .claimed(let offer), .verified(let offer): return offer
        default: return nil
        }
    }

    /// nil ⇔ never presented; `.notAttempted` ⇔ presented, funnel untouched.
    var advertiser: AdvertiserOutcome? {
        if case .presented(let o) = self { return o.advertiser }
        return nil
    }

    var publisher: PublisherOutcome? {
        if case .presented(let o) = self { return o.publisher }
        return nil
    }

    var dismissal: DismissReason? {
        if case .presented(let o) = self { return o.dismissal }
        return nil
    }

    /// The presentation-level failure, when that's why nothing appeared.
    var error: EncoreError? {
        if case .notPresented(.error(let e)) = self { return e }
        return nil
    }
}

internal extension PresentationResult {
    /// Construction shorthand for coordinator paths.
    static func presented(
        advertiser: AdvertiserOutcome = .notAttempted,
        publisher: PublisherOutcome = .notAttempted,
        dismissal: DismissReason
    ) -> PresentationResult {
        .presented(Outcome(advertiser: advertiser, publisher: publisher, dismissal: dismissal))
    }
}

// MARK: Analytics wire values

// Canonical axis vocabulary for `sdk_placement_resolved` — ported SDKs
// mirror these strings 1:1, so they are frozen like enum raw values.
internal extension AdvertiserOutcome {
    var wireValue: String {
        switch self {
        case .notAttempted: return "not_attempted"
        case .claimed:      return "claimed"
        case .verified:     return "verified"
        case .cooldown:     return "cooldown"
        case .failed:       return "failed"
        }
    }
}

internal extension PublisherOutcome {
    var wireValue: String {
        switch self {
        case .notAttempted: return "not_attempted"
        case .purchased:    return "purchased"
        case .cancelled:    return "cancelled"
        case .pending:      return "pending"
        case .failed:       return "failed"
        }
    }
}

/// Legacy name for ``PresentationResult``.
@available(*, deprecated, renamed: "PresentationResult")
public typealias EncorePresentationResult = PresentationResult
