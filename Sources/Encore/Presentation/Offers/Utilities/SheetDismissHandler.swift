// Result assembly for a single sheet presentation: funnel facts are staged
// as they happen and collapsed into one PresentationResult at dismissal.

import Foundation

/// Stages funnel facts during a presentation and assembles the final
/// `PresentationResult` exactly once when the sheet ends.
@MainActor
@available(iOS 17.0, *)
class SheetDismissHandler {
    private var completion: ((Result<PresentationResult, EncoreError>) -> Void)?
    private var advertiser: AdvertiserOutcome = .notAttempted
    private var publisher: PublisherOutcome = .notAttempted
    private var dismissal: DismissReason?
    private var delivered: DismissReason?

    init(onCompletion: @escaping (Result<PresentationResult, EncoreError>) -> Void, initiallyPurchased: Bool = false) {
        self.completion = onCompletion
        if initiallyPurchased { publisher = .purchased }
    }

    /// Record advertiser-funnel progress. Monotonic: a later, lower-ranked fact
    /// (e.g. a cooldown on a second offer) never erases an earned grant.
    /// A user's confirmed completion belongs to the claim, not the stage: re-staging
    /// that claim keeps it, and a same-rank claim of another offer never replaces it.
    func stageAdvertiser(_ outcome: AdvertiserOutcome) {
        guard Self.rank(outcome) >= Self.rank(advertiser) else { return }
        if let current = advertiser.claimedOffer, current.userConfirmedCompletion,
           let incoming = outcome.claimedOffer, !incoming.userConfirmedCompletion {
            if incoming.isSameClaim(as: current) {
                advertiser = outcome.confirmingCompletion()
                return
            }
            if Self.rank(outcome) == Self.rank(advertiser) { return }
        }
        advertiser = outcome
    }

    /// Mark the staged claim as confirmed by the user. Returns false, changing
    /// nothing, when the staged outcome is not a claim of `claim`, or the sheet is
    /// closing or closed (a close during a Yes's wait fails closed).
    @discardableResult
    func markUserConfirmedCompletion(for claim: ClaimedOffer) -> Bool {
        guard !isEnding, let current = advertiser.claimedOffer, current.isSameClaim(as: claim) else { return false }
        advertiser = advertiser.confirmingCompletion()
        return true
    }

    /// Record publisher-funnel progress. Monotonic like the advertiser axis:
    /// pending must survive a later cancel (Ask-to-Buy retry).
    func stagePublisher(_ outcome: PublisherOutcome) {
        guard Self.rank(outcome) >= Self.rank(publisher) else { return }
        publisher = outcome
    }

    /// Upgrade a staged claim to verified, keeping its payload — used by the
    /// strict-mode poll, which runs after the claiming offer is out of scope.
    func upgradeClaimToVerified() {
        if case .claimed(let offer) = advertiser { advertiser = .verified(offer) }
    }

    /// Stage how the sheet is about to end (close paths set this before the
    /// dismissal animates; delivery happens in `handleOnDisappear`).
    func stageDismissal(_ reason: DismissReason) {
        // The emission-only cases (offerClaimed, appBackgrounded,
        // appTerminated) exist for `trackOfferClose`; a result record never
        // carries them. The claim lives on the advertiser axis, and the
        // lifecycle interruptions fire while the sheet is still up.
        assert(![.offerClaimed, .appBackgrounded, .appTerminated].contains(reason),
               "emission-only DismissReason staged onto a result record")
        dismissal = reason
    }

    /// How this presentation ends: the reason already delivered on the result,
    /// else the staged one, else the swipe default. Analytics reads this so
    /// `decline_reason` is always the record's `dismissal`, never a second
    /// vocabulary.
    var resolvedDismissal: DismissReason { delivered ?? dismissal ?? .userSwipedDown }

    /// The sheet was asked to close (a staged dismissal) or its result was delivered.
    var isEnding: Bool { completion == nil || dismissal != nil }

    /// Deliver on view disappearance; an unstaged ending means the user swiped.
    func handleOnDisappear() {
        deliver(resolvedDismissal)
    }

    /// Deliver immediately with an explicit ending.
    func handleImmediate(dismissal reason: DismissReason) {
        deliver(reason)
    }

    private func deliver(_ reason: DismissReason) {
        guard let completion else { return }
        self.completion = nil
        delivered = reason
        completion(.success(.presented(advertiser: advertiser, publisher: publisher, dismissal: reason)))
    }

    private static func rank(_ outcome: AdvertiserOutcome) -> Int {
        switch outcome {
        case .notAttempted: return 0
        case .failed:       return 1
        case .cooldown:     return 2
        case .claimed:      return 3
        case .verified:     return 4
        }
    }

    private static func rank(_ outcome: PublisherOutcome) -> Int {
        switch outcome {
        case .notAttempted: return 0
        case .cancelled:    return 1
        case .failed:       return 2
        case .pending:      return 3
        case .purchased:    return 4
        }
    }
}
