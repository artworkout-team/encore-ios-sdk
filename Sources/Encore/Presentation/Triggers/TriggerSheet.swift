// The sheet gate every sheet-opening trigger runs before `/config`: would the sheet for
// (use case, placement) show offers right now? Searched the way the sheet presents, so the
// offers it holds are the ones a tap opens, except with a `publisherReward` for an identified
// user: that sheet asks `/offers/search` again on tap, because the prize promise must be the
// server's current answer (a second search).

import Foundation

/// What the sheet would show: offers for this use case and placement.
internal struct TriggerSheetOffers: Sendable, Equatable {
    let useCase: UseCase
    /// The held offers' campaign ids, in the sheet's order.
    let campaignIds: [String]
    /// The offers cache entry the gate filled, evicted exactly once the sheet closes.
    let cacheKey: TriggerSheetCacheKey
    /// When that entry stops being served from the cache. The trigger marks its item stale then
    /// (no request), and its next appear, foreground or tap runs the gate first, so a tap opens a
    /// held set (a `publisherReward` sheet for an identified user still searches again for its
    /// prize promise). Nil: held until the next gate.
    var heldUntil: Date? = nil
    /// The held offers' advertisers with a usable logo, distinct, in the sheet's order.
    var logos: [TriggerSheetOfferLogo] = []
    /// The first held offer's perk that is not blank, in the sheet's order; nil when none has one.
    var perk: String? = nil

    var offerCount: Int { campaignIds.count }

    static let maxLogos = 8

    /// ``perk`` for `offers`, trimmed.
    static func perk(of offers: [Offer]) -> String? {
        offers.lazy.compactMap { nonBlank($0.perk) }.first
    }

    /// One logo per advertiser (the sheet tile's logo, an http(s) URL), at most ``maxLogos``, each with
    /// that advertiser's first held offer's perk ("" when blank).
    static func logos(of offers: [Offer]) -> [TriggerSheetOfferLogo] {
        var perks: [String: String] = [:]
        for offer in offers where perks[offer.organization.id] == nil { perks[offer.organization.id] = nonBlank(offer.perk) ?? "" }
        var seen = Set<String>()
        var logos: [TriggerSheetOfferLogo] = []
        for offer in offers where logos.count < maxLogos {
            guard let logo = offer.tileLogoUrl, let url = URL(string: logo),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(offer.organization.id).inserted else { continue }
            logos.append(TriggerSheetOfferLogo(logoUrl: logo, advertiserName: offer.advertiserName, perk: perks[offer.organization.id] ?? ""))
        }
        return logos
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// One held offer's advertiser, as GiftsButton's logo strip draws it.
internal struct TriggerSheetOfferLogo: Sendable, Equatable {
    let logoUrl: String
    let advertiserName: String
    /// The advertiser's first held offer's perk; "" when it has none.
    var perk: String = ""
}

/// What the sheet would do if opened now.
internal enum TriggerSheetEligibility: Sendable, Equatable {
    case offers(TriggerSheetOffers)
    /// No offers, the trial limit or offline: nothing, silently.
    case none
    /// The server resolved no sheet for this user: the sheet would show nothing.
    case sheetUnavailable
}

/// The offers cache key a gate search used, apart from its use case.
internal struct TriggerSheetCacheKey: Sendable, Equatable {
    let userId: String
    let attributes: UserAttributes?
    let variantId: String?
    let cachePlacementId: String?
}

/// A trigger's ties to the sheet, injectable for tests.
@MainActor
internal struct TriggerSheet {
    /// What the sheet would do for (use case, placement), checked the way it presents.
    var eligibility: @MainActor (_ useCase: UseCase, _ placement: String) async -> TriggerSheetEligibility
    /// A sheet a trigger opened has closed: the offers the gate held for it are stale.
    var closed: @MainActor (_ held: TriggerSheetOffers) async -> Void
}

/// Everything that makes two eligibility searches the same search.
internal struct TriggerSheetSearchKey: Hashable, Sendable {
    let userId: String
    let variantId: String?
    let useCase: UseCase
    let placement: String?
    let cachePlacementId: String?
    let countryCode: String?
    let language: String?
    let strict: Bool
}

/// Shares one eligibility search among mounts checking the same set at once.
@MainActor
internal final class TriggerSheetSearchCoalescer {
    static let shared = TriggerSheetSearchCoalescer()

    private var running: [TriggerSheetSearchKey: Task<TriggerSheetOffers?, Never>] = [:]

    func run(key: TriggerSheetSearchKey, _ work: @escaping @MainActor () async -> TriggerSheetOffers?) async -> TriggerSheetOffers? {
        #if DEBUG
        EncoreDebugTrace.record("offers.search", ["placement": key.placement ?? "-", "coalesced": String(running[key] != nil)])
        #endif
        if let task = running[key] { return await task.value }
        let task = Task { await work() }
        running[key] = task
        let result = await task.value
        running[key] = nil
        return result
    }
}

extension TriggerSheet {
    /// When a set that leaves the cache at `expiry` counts as stale: a margin before it, or the
    /// expiry itself once inside the margin, so a tap on a nearly expired set gates once it has
    /// gone (a fresh search) instead of over and over while it lingers.
    static func regateTime(forExpiry expiry: Date, now: Date) -> Date {
        let early = expiry.addingTimeInterval(-15)
        return early > now ? early : expiry
    }
}

/// The one way the SDK tells mounted triggers that an offer set they may hold changed.
internal enum TriggerHeldOffers {
    /// Safe from any context: posts on the main actor.
    static func changed() {
        Task { @MainActor in NotificationCenter.default.post(name: .encoreTriggerHeldOffersChanged, object: nil) }
    }
}

// MARK: - Live

extension TriggerSheet {
    /// The sheet's own path: its `/config` (cached, or fetched once per identity), the
    /// layout it would render, then `/offers/search` with that variant, marked as a
    /// prefetch. The result lands in the offers cache the sheet reads on tap.
    static var live: Self {
        Self(
            eligibility: { useCase, placement in
                // The sheet's own gates, in its order (OfferSheetCoordinator.makeAttempt, then
                // presentCore): the iOS floor, the served layout, the offers.
                guard Encore.isSupported, let services = Encore.shared.services else { return .none }
                let userId = services.user.currentUserId
                let language = services.user.language
                guard !userId.isEmpty else { return .none }
                await services.remoteConfigManager.loadConfig(
                    for: useCase, userId: userId, sdkVersion: Encore.sdkVersion, language: language
                )
                // A user or language change during the load: the layout and attributes read
                // next are the new identity's, so send nothing rather than a mixed search.
                guard services.user.currentUserId == userId, services.user.language == language else { return .none }
                let layout = services.sduiConfigManager.presentationLayout(for: useCase, strings: SDKStrings.current)
                // The server resolved no sheet for this user: the sheet would show nothing.
                guard layout.config != nil else { return .sheetUnavailable }
                let label = PlacementLabel.sanitized(placement)
                // Strict unlock narrows the set the sheet will show, so the gate narrows it too.
                let strict = (Encore.shared.configuration?.unlock ?? .optimistic) == .strict
                let key = TriggerSheetCacheKey(
                    userId: userId,
                    attributes: services.user.requestAttributes,
                    variantId: layout.variantId,
                    cachePlacementId: services.remoteConfigManager.cachePlacement(for: label)
                )
                let shareKey = TriggerSheetSearchKey(
                    userId: key.userId, variantId: key.variantId, useCase: useCase, placement: label,
                    cachePlacementId: key.cachePlacementId, countryCode: key.attributes?.countryCode,
                    language: key.attributes?.languageTag, strict: strict
                )
                let offers = await TriggerSheetSearchCoalescer.shared.run(key: shareKey) {
                    do {
                        let fetched = try await services.offers.fetchOffers(
                            userId: key.userId,
                            attributes: key.attributes,
                            variantId: key.variantId,
                            placementId: label,
                            maxPostbackTimeMs: strict ? StrictUnlock.maxPostbackTimeMs : nil,
                            useCase: useCase,
                            cachePlacementId: key.cachePlacementId,
                            purpose: OfferSearchPurpose.prefetch
                        )
                        let offers = Encore.shared.selfReportedCampaigns.excluding(from: fetched, userId: userId).offerList
                        // The entry's own expiry (it may come from an earlier prefetch), less a margin: the
                        // item is stale from then. No entry (a strict search is never cached, and the
                        // sheet searches again anyway): a full cache lifetime.
                        let expiry = await services.offers.cacheExpiry(
                            userId: key.userId, attributes: key.attributes, variantId: key.variantId,
                            useCase: useCase, cachePlacementId: key.cachePlacementId
                        ) ?? Date().addingTimeInterval(OffersCache.cacheTTL)
                        let heldUntil = TriggerSheet.regateTime(forExpiry: expiry, now: Date())
                        return offers.isEmpty ? nil : TriggerSheetOffers(
                            useCase: useCase, campaignIds: offers.map(\.id), cacheKey: key, heldUntil: heldUntil,
                            logos: TriggerSheetOffers.logos(of: offers), perk: TriggerSheetOffers.perk(of: offers)
                        )
                    } catch {
                        // No offers, the trial limit (409) or offline: nothing to open.
                        Logger.debug(.offers, "[TRIGGER] sheet eligibility: \(error)")
                        return nil
                    }
                }
                return offers.map(TriggerSheetEligibility.offers) ?? .none
            },
            closed: { held in
                // Exactly the set the gate filled and the sheet read.
                await Encore.shared.services?.offers.evict(
                    userId: held.cacheKey.userId,
                    attributes: held.cacheKey.attributes,
                    variantId: held.cacheKey.variantId,
                    useCase: held.useCase,
                    cachePlacementId: held.cacheKey.cachePlacementId
                )
                // Other mounts may hold the same set: they run their gate again.
                TriggerHeldOffers.changed()
            }
        )
    }
}
