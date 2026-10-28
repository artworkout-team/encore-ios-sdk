// Sources/Encore/Domain/Entities/Campaign.swift
//
// Campaign domain entity.
//

import Foundation

// =============================================================================
// MARK: - Campaign
// =============================================================================


/// Offer is now a Campaign directly - represents an eligible campaign for this user.
internal typealias Offer = Campaign

/// Campaign information
internal struct Campaign {
    let id: String
    let name: String
    let payoutAmount: Double?
    let targetCountries: [String]?
    let destinationUrl: String
    let startDate: Date
    let endDate: Date?
    let priority: Int?
    let newPrice: String?
    let oldPrice: String?
    /// User-facing value proposition, e.g. "3 months of Hulu free". Surfaced as the `offerPerk` SDUI text binding.
    let perk: String?
    /// Display-only strings the backend keys for a variant, e.g. `eligibilityNote`. Read
    /// with `propertyKey` and gate the line on `hasOfferProperty`: a key with nothing
    /// behind it must draw no line at all.
    let displayProperties: [String: String]
    /// Promo badge class from the offers payload. `nil` means the backend
    /// attached no badge — the offer is not labelled a free trial.
    let badgeLabel: BadgeLabel?
    /// The gift-sheet GROUP this campaign files under, nil when blank. A free
    /// string, because the grouping is the server's to edit without a release.
    /// The taxonomy name rides beside it on the wire, for web-sdk to map itself.
    let category: String?
    /// Link the user can send to someone else for this offer. Absent means the
    /// backend minted none, and the share must not fall back to another URL:
    /// an unattributed link loses the claim. Normalized by `webLink`.
    let shareUrl: String?
    /// Advertiser terms for this offer, nil when the campaign carries none or
    /// carries something this SDK cannot open. A variant gates its terms line
    /// on this, so the gate and the tap have to read the same rule.
    let termsUrl: String?
    /// Campaign-level presentation image for the gift surfaces, chosen for the
    /// deal rather than rotated like a creative. Read via `displayHeroImageUrl`.
    let heroImageUrl: String?
    /// Hostname the claim link lands on, as stored (e.g. `www.amazon.com`). Display
    /// only: the claim screen names it, and nothing requests it.
    let expectedDomain: String?
    let organization: Organization
    let creatives: [Creative]
    /// Read only when there is no `primaryCreative` (D13): the served creative
    /// otherwise wins for every field, as it does today.
    let offerFields: CampaignOfferFields
    /// What the app's prize is worth on this offer, e.g. "1,500 tokens", from the
    /// search response. Nil (absent, null, malformed or blank) means the flat prize in
    /// on_yes and no prize at all in on_verified, where such an offer is never paid.
    var publisherRewardLabel: String? = nil

    /// Constrained promo badge for in-app offer cards. Mirrors the contract
    /// enum; kept as a local type so the SDUI layer never imports a generated
    /// `Operations.…` nested type.
    enum BadgeLabel: String {
        case freeTrial = "free_trial"
        case discount
    }

    init(dto: DTO.Offers.Campaign) {
        self.id = dto.id
        self.name = dto.name
        self.payoutAmount = dto.payoutAmount
        self.targetCountries = dto.targetCountries
        self.destinationUrl = dto.destinationUrl
        self.startDate = dto.startDate
        self.endDate = dto.endDate
        self.priority = dto.priority
        self.newPrice = dto.newPrice
        self.oldPrice = dto.oldPrice
        self.perk = dto.perk
        // Two rules, both dropping the key rather than keeping a bad one.
        //
        // The wire type is free-form, so a value is `OpenAPIValueContainer` and anything
        // that is not a string is DROPPED here. The bag is typed as a string map in the
        // contract and the backend refuses anything else on write, so this filter should
        // never fire. It exists because the alternative is worse: a typed value map
        // generates a strict decoder, and one unexpected value would fail the whole offers
        // response and present zero offers, rather than losing one card line.
        //
        // Blank is then ABSENT, so `hasOfferProperty` and the line it guards cannot
        // disagree about one key. NOT `.whitespacesAndNewlines`, which the other fields
        // use: it keeps the C0 separators that Kotlin's `isBlank()` drops, and this one
        // key has to be blank on BOTH platforms or an A/B arm renders two treatments.
        self.displayProperties = (dto.displayProperties?.additionalProperties ?? [:])
            .compactMapValues { container in
                guard let text = container.value as? String,
                      !Self.isDisplayPropertyBlank(text) else { return nil }
                return text
            }
        self.badgeLabel = dto.badgeLabel.flatMap { BadgeLabel(rawValue: $0.rawValue) }
        // Blank is ABSENT, matching `distinctCategories`. Kept here rather than
        // at each reader, so one rule covers the chip strip and the operand.
        self.category = dto.categoryGroup.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Blank is ABSENT, the same rule `category` takes above, so the share
        // gate and the share action cannot disagree about one offer.
        self.termsUrl = Self.webLink(dto.termsUrl)
        self.shareUrl = Self.webLink(dto.shareUrl)
        self.heroImageUrl = dto.heroImageUrl
        self.expectedDomain = dto.expectedDomain
        self.organization = dto.organization.map { Organization(dto: $0) } ?? Organization(id: dto.organizationId, name: dto.name)
        self.creatives = dto.creatives?.map { Creative(dto: $0) } ?? []
        self.offerFields = CampaignOfferFields(dto: dto)
    }
    
    /// Every character that makes a display-property value blank.
    ///
    /// Listed rather than inferred, and identical to the backend's
    /// `DISPLAY_PROPERTY_BLANK_CHARS`, V181's `btrim()` set and Android's copy. Four
    /// runtimes disagree about what is blank, so none of their built-ins can be the rule:
    /// this is the union of all four.
    static let displayPropertyBlankScalars: Set<Unicode.Scalar> = Set(
        [0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x001c, 0x001d, 0x001e, 0x001f,
         0x0020, 0x0085, 0x00a0, 0x1680,
         0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
         0x2008, 0x2009, 0x200a, 0x200b, 0x200c, 0x200d, 0x2028, 0x2029,
         0x202f, 0x205f, 0x2060, 0x3000, 0xfeff,
         // Not whitespace to any runtime, but each draws nothing, which is the subject.
         0x00ad, 0x034f, 0x061c, 0x180e, 0x2800, 0x3164, 0xffa0].compactMap(Unicode.Scalar.init)
    )

    /// True when nothing would be drawn, so the key must be absent instead.
    static func isDisplayPropertyBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { displayPropertyBlankScalars.contains($0) }
    }

    /// A link this SDK can open, or nil.
    ///
    /// Blank is ABSENT, the rule `category` takes above. So is a scheme this
    /// SDK cannot open: the schema enforces none, and a variant gates a control
    /// on the field's presence, so a gate that opened on `example.com/terms`
    /// would draw a link whose tap then did nothing.
    private static func webLink(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return trimmed
    }

    // MARK: - Business Logic
    
    /// Primary active creative (first active in list)
    var primaryCreative: Creative? {
        creatives.first { $0.isActive }
    }
    
    /// Advertiser name (shorthand for organization.name)
    var advertiserName: String {
        organization.name
    }

    /// Whether this offer is advertised as a free trial, as opposed to a
    /// discount or no promo at all. Published to the SDUI state machine as
    /// `selectedOfferIsFreeTrial` so variants can branch their copy. Anything
    /// other than an explicit `free_trial` badge is false — an unlabelled offer
    /// must not render "free month" / "$0 today" copy.
    var isFreeTrialOffer: Bool {
        badgeLabel == .freeTrial
    }
    
    /// Display title from primary creative, fallback to campaign name
    var displayTitle: String {
        primaryCreative?.title ?? name
    }

    var displayDescription: String? {
        guard let creative = primaryCreative else { return offerFields.description }
        return creative.description
    }
    
    /// Advertiser description (alias for displayDescription, legacy compatibility)
    var creativeAdvertiserDescription: String? {
        displayDescription
    }
    
    /// With no creative, the campaign logo, else the organization's.
    var displayLogoUrl: String? {
        guard let creative = primaryCreative else { return offerFields.logoUrl ?? organization.logoUrl }
        return creative.logoUrl
    }

    /// The logo drawn on the tile that stands in for a missing picture: the
    /// creative's, else the campaign's, else the organization's. Blanks skipped.
    var tileLogoUrl: String? {
        [primaryCreative?.logoUrl, offerFields.logoUrl, organization.logoUrl]
            .lazy
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Primary image URL from primary creative
    /// The hero if the campaign carries one, else the creative image. Two rungs,
    /// not web's three: its logo rung is reached only when a present URL fails to
    /// LOAD, which a binding cannot observe.
    var displayHeroImageUrl: String? {
        heroImageUrl.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? displayPrimaryImageUrl
    }

    var displayPrimaryImageUrl: String? {
        primaryCreative?.primaryImageUrl
    }
    
    /// The offer's own CTA wording: the active creative's, else (with no creative)
    /// the campaign's. Blank counts as none.
    var servedCtaText: String? {
        (primaryCreative.map { $0.ctaText } ?? offerFields.ctaText)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// CTA text for the native card, falling back to the presentation's `campaign.ctaFallback`.
    func displayCtaText(_ strings: SDKStrings) -> String {
        servedCtaText ?? strings[.campaignCtaFallback]
    }
    
    /// Claim destination. Read as a PAIR with `displayTrackingParameters`: the
    /// creative's override (else the campaign's) with its tracking, or with no
    /// creative the campaign's destination with the campaign's tracking.
    var displayDestinationUrl: String? {
        primaryCreative?.destinationUrl ?? destinationUrl
    }

    /// One whole bag from one level, never merged. Never an empty bag.
    var displayTrackingParameters: [String: Any]? {
        guard let creative = primaryCreative else { return offerFields.trackingParameters }
        return creative.trackingParameters
    }
    /// Steps from the served creative (else, with no creative, the campaign),
    /// minus any whose title and subtitle are both blank, numbered after that
    /// drop so `instructionNumber` has no gaps.
    var displayInstructions: [Instruction] {
        (primaryCreative?.instructions ?? offerFields.instructions).filter { step in
            !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .enumerated().map { index, step in
            var numbered = step
            numbered.position = index + 1
            return numbered
        }
    }
    
    /// Quick instructions from the primary creative, nil when it carries none.
    ///
    /// Blank is ABSENT here rather than at each reader, so the
    /// `quickInstructions` gate and the line it draws agree. Android takes the
    /// same rule at its own seam.
    var displayQuickInstructions: String? {
        (primaryCreative.map { $0.quickInstructions } ?? offerFields.quickInstructions)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// `expectedDomain` for "Finish on {domain}". Nil unless it is a bare hostname.
    var displayExpectedDomain: String? {
        expectedDomain.flatMap(Self.displayHost)
    }

    /// Trimmed, lowercased, a leading `www.` and a trailing root dot dropped. Nil for
    /// anything but a bare hostname (a scheme, path, port or space), so a bad row never
    /// puts a URL on screen. Same rule as web-sdk's `readExpectedDomain`.
    static func displayHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasSuffix(".") { host.removeLast() }
        let range = NSRange(host.startIndex..., in: host)
        guard bareHostname?.firstMatch(in: host, range: range) != nil else { return nil }
        return host
    }

    /// Labels of letters (any script), digits and hyphens, at least two of them.
    private static let bareHostname = try? NSRegularExpression(pattern: #"^[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)+$"#)

    /// Overlay config from the primary creative, if present.
    /// Drives `CreativeOverlayModifier` in the SDUI renderer.
    var displayOverlayConfig: SDUIOverlayConfig? {
        primaryCreative?.overlayConfig
    }

    /// A creative-less offer needs its own tracking, or its claim link is unattributable.
    var isClaimable: Bool {
        primaryCreative != nil || displayTrackingParameters != nil
    }

    /// The attributable claim link: destination, tracking appended as query
    /// items, then every `TRANSACTION_ID` replaced. Nil only with no destination.
    func claimURLString(transactionId: String) -> String? {
        guard let urlString = displayDestinationUrl else { return nil }
        var urlComponents = URLComponents(string: urlString)
        if let trackingParameters = displayTrackingParameters {
            if urlComponents?.queryItems == nil {
                urlComponents?.queryItems = []
            }
            for parameter in trackingParameters {
                urlComponents?.queryItems?.append(URLQueryItem(name: parameter.key, value: "\(parameter.value)"))
            }
        }
        let finalUrl = urlComponents?.url?.absoluteString ?? urlString
        return finalUrl.replacingOccurrences(of: "TRANSACTION_ID", with: transactionId)
    }
}


