// Sources/Encore/Core/Configuration/Remote/RemoteConfiguration.swift
//
// Domain models for remote configuration.
// Maps from DTOs to domain entities with init(from:) pattern.
//

import Foundation

// MARK: - Root Configuration

/// Remote configuration fetched from /config endpoint.
/// Contains UI, entitlements, and experiments configuration.
/// Codable for disk caching (last-known-good snapshot).
/// Sendable for thread-safe access via Atomic wrapper.
struct RemoteConfiguration: Codable, Sendable {
    let ui: UIConfiguration
    let entitlements: EntitlementConfiguration
    let experiments: ExperimentConfiguration
    /// The locale the backend served this copy in (response `locale`). Nil on
    /// a pre-localization backend. Reported on analytics as `locale`.
    let locale: String?
    /// The request's host language override and Accept-Language value: the
    /// disk stamp. A mismatch means the copy is another language's.
    let language: String?
    let deviceLocale: String?

    init(from dto: DTO.RemoteConfig.ConfigResponseEnvelope, language: String? = nil, deviceLocale: String? = nil) {
        self.ui = UIConfiguration(from: dto.ui, experimentId: dto.uiExperimentId)
        self.entitlements = EntitlementConfiguration(from: dto.entitlements)
        self.experiments = ExperimentConfiguration(from: dto.experiments)
        self.locale = dto.locale
        self.language = language
        self.deviceLocale = deviceLocale
    }

    /// Builds the configuration for a use case carried in the `useCases`
    /// prefetch block.
    ///
    /// The block holds only the UI half. `entitlements` and `experiments`
    /// describe the *app*, not the surface, so they come from the same
    /// response's top-level blocks — which is exactly what a dedicated
    /// `?useCase=` fetch would have returned for them. So do the locales.
    init(
        prefetched: DTO.RemoteConfig.UseCaseDefault,
        servedStrings: UIValues? = nil,
        entitlements: EntitlementConfiguration,
        experiments: ExperimentConfiguration,
        locale: String? = nil,
        language: String? = nil,
        deviceLocale: String? = nil
    ) {
        self.ui = UIConfiguration(from: prefetched, servedStrings: servedStrings)
        self.entitlements = entitlements
        self.experiments = experiments
        self.locale = locale
        self.language = language
        self.deviceLocale = deviceLocale
    }

    /// Composes a configuration from parts. Used by rung 2 of the availability
    /// ladder, which marries a persisted `(variantId, template)` pair with the
    /// persisted config blob's values and entitlements.
    init(
        ui: UIConfiguration,
        entitlements: EntitlementConfiguration,
        experiments: ExperimentConfiguration,
        locale: String? = nil,
        language: String? = nil,
        deviceLocale: String? = nil
    ) {
        self.ui = ui
        self.entitlements = entitlements
        self.experiments = experiments
        self.locale = locale
        self.language = language
        self.deviceLocale = deviceLocale
    }

    /// This configuration with its copy dropped and its app facts kept, for a
    /// session whose locale differs from the one it was resolved in. The
    /// variant is dropped too: its template is that language's.
    func withoutCopy() -> RemoteConfiguration {
        RemoteConfiguration(
            ui: UIConfiguration(variantId: nil, values: ui.values.withoutCopy(), template: nil),
            entitlements: entitlements,
            experiments: experiments
        )
    }
}

// MARK: - Configuration Bundle

/// Everything one `/config` response carries.
///
/// `configuration` is the use case the request resolved — `?useCase=` decides
/// it, and it is fully resolved, experiments included, exactly as it has always
/// been. `prefetched` holds the **default** variant for every *other* use case
/// the app is enabled for, which is what lets a later presentation render
/// straight from cache. It is empty for a single-use-case app, and empty for
/// any backend that predates the block.
struct RemoteConfigurationBundle: Sendable {

    /// The use case `configuration` was resolved for.
    let useCase: UseCase
    let configuration: RemoteConfiguration
    let prefetched: [UseCase: RemoteConfiguration]
    /// App-level, not per use case. Nil when the server predates the field.
    let ruledPlacements: RuledPlacements?

    init(
        from dto: DTO.RemoteConfig.ConfigResponseEnvelope,
        requestedFor useCase: UseCase,
        language: String? = nil,
        deviceLocale: String? = nil
    ) {
        let configuration = RemoteConfiguration(from: dto, language: language, deviceLocale: deviceLocale)
        self.useCase = useCase
        self.configuration = configuration
        self.ruledPlacements = dto.ruledPlacements.map(RuledPlacements.init)

        var prefetched: [UseCase: RemoteConfiguration] = [:]
        for (key, entry) in dto.useCases ?? [:] {
            // A key this SDK version has no case for is skipped rather than
            // rejected: the backend can enable a use case older SDKs never
            // heard of, and that must not cost the app the block's other
            // entries.
            guard let prefetchedUseCase = UseCase(rawValue: key) else {
                Logger.debug("🔍 [RemoteConfig] Ignoring prefetched use case '\(key)' — unknown to this SDK version")
                continue
            }
            // The backend excludes the requested use case from the block. If it
            // ever stops doing so, the *default* variant must not displace the
            // resolution we just asked for — that resolution ran the experiments
            // this one deliberately skips.
            guard prefetchedUseCase != useCase else {
                Logger.debug("🔍 [RemoteConfig] Ignoring prefetched '\(key)' — this request already resolved it")
                continue
            }
            prefetched[prefetchedUseCase] = RemoteConfiguration(
                prefetched: entry,
                servedStrings: configuration.ui.values,
                entitlements: configuration.entitlements,
                experiments: configuration.experiments,
                locale: configuration.locale,
                language: language,
                deviceLocale: deviceLocale
            )
        }
        self.prefetched = prefetched
    }
}

// MARK: - UI Configuration

/// UI configuration including SDUI template and values for substitution.
/// Codable for disk caching. Note: `template` (SDUIConfig) is excluded from coding
/// because SDUIConfig is Decodable-only — it's re-parsed from the network response.
/// @unchecked Sendable: SDUIConfig is a value-type tree; safe for cross-thread access.
struct UIConfiguration: Codable, @unchecked Sendable {
    let variantId: String?
    /// Experiment that decided `variantId`; nil for a default, pinned, or holdout variant.
    let experimentId: String?
    let variantName: String?
    let minSdkVersion: String?
    let values: UIValues

    /// Parsed SDUI template. Not persisted in this blob; the raw wire bytes
    /// are stored by `TemplateStore` (via the repository) as an atomic
    /// (variantId, template) unit.
    let template: SDUIConfig?

    /// True only for a configuration decoded from a live `/config` response.
    /// Distinguishes a fresh null template (the server said no) from a
    /// disk-restored one (degrade to the stored template).
    let fromNetwork: Bool

    // Exclude template and the freshness marker from Codable
    // (SDUIConfig is Decodable-only; the marker is transient by design).
    enum CodingKeys: String, CodingKey {
        case variantId, experimentId, variantName, minSdkVersion, values
    }

    init(from dto: DTO.RemoteConfig.UIConfig, experimentId: String?) {
        self.variantId = dto.variantId
        self.experimentId = experimentId
        self.variantName = dto.variantName
        self.minSdkVersion = dto.minSdkVersion
        self.template = Self.parseTemplate(dto.template)
        self.values = UIValues(from: dto.values)
        self.fromNetwork = true
    }

    /// Maps one entry of the `useCases` prefetch block.
    ///
    /// `minSdkVersion` is nil because the block does not carry one: it is a
    /// property of the resolution the backend performed, and the prefetched
    /// entry is a default variant rather than a resolution. Nothing in the SDK
    /// reads the field today, and inventing a value here would be worse than
    /// admitting its absence.
    init(from dto: DTO.RemoteConfig.UseCaseDefault, servedStrings: UIValues? = nil) {
        self.variantId = dto.variantId
        self.experimentId = dto.experimentId
        self.variantName = dto.variantName
        self.minSdkVersion = nil
        self.template = Self.parseTemplate(dto.template)
        let values = UIValues(from: dto.values)
        self.values = servedStrings.map(values.inheritingServedStrings(from:)) ?? values
        self.fromNetwork = true
    }

    /// Direct construction from an already-parsed template. For callers that
    /// hold an `SDUIConfig` rather than a DTO: a rung-2 stored template
    /// marrying with the persisted blob, and tests exercising the
    /// null-template branch without a network round trip.
    init(
        variantId: String?,
        experimentId: String? = nil,
        variantName: String? = nil,
        minSdkVersion: String? = nil,
        values: UIValues = .empty,
        template: SDUIConfig?,
        fromNetwork: Bool = false
    ) {
        self.variantId = variantId
        self.experimentId = experimentId
        self.variantName = variantName
        self.minSdkVersion = minSdkVersion
        self.values = values
        self.template = template
        self.fromNetwork = fromNetwork
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.variantId = try container.decodeIfPresent(String.self, forKey: .variantId)
        self.experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        self.variantName = try container.decodeIfPresent(String.self, forKey: .variantName)
        self.minSdkVersion = try container.decodeIfPresent(String.self, forKey: .minSdkVersion)
        self.values = try container.decode(UIValues.self, forKey: .values)
        self.template = nil  // Not persisted here; the template store holds it
        self.fromNetwork = false
    }

    /// Parses the wire template payload. Never throws outward: an unparseable
    /// template resolves to no layout.
    private static func parseTemplate(_ template: DTO.RemoteConfig.UITemplate?) -> SDUIConfig? {
        guard let template else { return nil }
        do {
            return try JSONDecoder().decode(SDUIConfig.self, from: JSONEncoder().encode(template))
        } catch {
            Logger.warn(.configuration, "Failed to parse SDUI template: \(error)")
            return nil
        }
    }

    /// Parses raw stored template JSON. Never throws outward.
    static func parseTemplate(_ data: Data?) -> SDUIConfig? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(SDUIConfig.self, from: data)
        } catch {
            Logger.warn(.configuration, "Failed to parse SDUI template: \(error)")
            return nil
        }
    }
}

// MARK: - UI Values

/// Text and appearance values for template substitution.
/// Equatable so the persisted template pair (which snapshots these) can be
/// compared whole in tests.
struct UIValues: Codable, Sendable, Equatable {
    // Text values
    let appName: String?
    let title: String?
    let subtitle: String?
    let offerDescription: String?
    let instructionsTitle: String?
    let lastStepHeader: String?
    let lastStepDescription: String?
    let creditClaimedTitle: String?
    let creditClaimedSubtitle: String?
    let applyCreditsButton: String?
    let accentTitle: String?
    let customHeadline: String?
    let customSubheadline: String?
    /// Non-null on every reward response — the template references
    /// `${rewardHeadline}` unconditionally, and substitution leaves an
    /// unresolved token visible on screen.
    let rewardHeadline: String?
    /// Null unless the publisher configured an override, and that is
    /// load-bearing: the template branches on whether the key is present.
    let rewardSubheadline: String?
    /// Reward button and badge wording. Null when the variant words them in its
    /// own template, in which case no token is served to substitute into.
    let rewardCta: String?
    let rewardDecline: String?
    let rewardBadge: String?
    let rewardMoreGifts: String?
    let rewardOtherGifts: String?

    // Appearance values
    let appearanceMode: AppearanceMode?
    let accentColor: String?
    let accentTitleColor: String?

    /// SDK-owned copy in the response `locale`, by wire id (see `SDKStrings`).
    /// Only ids the locale has are present; nil means English throughout.
    let strings: [String: String]?
    let plurals: [String: SDKStrings.PluralForms]?

    enum AppearanceMode: String, Codable {
        case light
        case dark
        case auto
    }
    
    init(from dto: DTO.RemoteConfig.UIValues) {
        // Text
        self.appName = dto.text.appName
        self.title = dto.text.title
        self.subtitle = dto.text.subtitle
        self.offerDescription = dto.text.offerDescription
        self.instructionsTitle = dto.text.instructionsTitle
        self.lastStepHeader = dto.text.lastStepHeader
        self.lastStepDescription = dto.text.lastStepDescription
        self.creditClaimedTitle = dto.text.creditClaimedTitle
        self.creditClaimedSubtitle = dto.text.creditClaimedSubtitle
        self.applyCreditsButton = dto.text.applyCreditsButton
        self.accentTitle = dto.text.accentTitle
        self.customHeadline = dto.text.customHeadline
        self.customSubheadline = dto.text.customSubheadline
        self.rewardHeadline = dto.text.rewardHeadline
        self.rewardSubheadline = dto.text.rewardSubheadline
        self.rewardCta = dto.text.rewardCta
        self.rewardDecline = dto.text.rewardDecline
        self.rewardBadge = dto.text.rewardBadge
        self.rewardMoreGifts = dto.text.rewardMoreGifts
        self.rewardOtherGifts = dto.text.rewardOtherGifts

        // Appearance
        self.appearanceMode = dto.appearance.mode.flatMap { AppearanceMode(rawValue: $0.rawValue) }
        self.accentColor = dto.appearance.accentColor
        self.accentTitleColor = dto.appearance.accentTitleColor

        // Served SDK strings
        self.strings = dto.strings?.additionalProperties
        self.plurals = dto.plurals?.additionalProperties.mapValues {
            SDKStrings.PluralForms(zero: $0.zero, one: $0.one, two: $0.two, few: $0.few, many: $0.many, other: $0.other)
        }
    }

    /// These values with `source`'s SDK strings where this carries none. A
    /// prefetched entry is served without them, but shares its response's locale.
    func inheritingServedStrings(from source: UIValues) -> UIValues {
        UIValues(
            appName: appName, title: title, subtitle: subtitle, offerDescription: offerDescription,
            instructionsTitle: instructionsTitle, lastStepHeader: lastStepHeader, lastStepDescription: lastStepDescription,
            creditClaimedTitle: creditClaimedTitle, creditClaimedSubtitle: creditClaimedSubtitle, applyCreditsButton: applyCreditsButton,
            accentTitle: accentTitle, customHeadline: customHeadline, customSubheadline: customSubheadline,
            rewardHeadline: rewardHeadline, rewardSubheadline: rewardSubheadline,
            rewardCta: rewardCta, rewardDecline: rewardDecline, rewardBadge: rewardBadge,
            rewardMoreGifts: rewardMoreGifts, rewardOtherGifts: rewardOtherGifts,
            appearanceMode: appearanceMode, accentColor: accentColor, accentTitleColor: accentTitleColor,
            strings: strings ?? source.strings, plurals: plurals ?? source.plurals
        )
    }
    
    /// The app facts (name, appearance) with every piece of copy dropped.
    func withoutCopy() -> UIValues {
        UIValues(
            appName: appName, title: nil, subtitle: nil, offerDescription: nil,
            instructionsTitle: nil, lastStepHeader: nil, lastStepDescription: nil,
            creditClaimedTitle: nil, creditClaimedSubtitle: nil, applyCreditsButton: nil,
            accentTitle: nil, customHeadline: nil, customSubheadline: nil,
            rewardHeadline: nil, rewardSubheadline: nil,
            rewardCta: nil, rewardDecline: nil, rewardBadge: nil, rewardMoreGifts: nil, rewardOtherGifts: nil,
            appearanceMode: appearanceMode, accentColor: accentColor, accentTitleColor: accentTitleColor,
            strings: nil, plurals: nil
        )
    }

    /// Empty values for fallback scenarios
    static let empty = UIValues(
        appName: nil, title: nil, subtitle: nil, offerDescription: nil,
        instructionsTitle: nil, lastStepHeader: nil, lastStepDescription: nil,
        creditClaimedTitle: nil, creditClaimedSubtitle: nil, applyCreditsButton: nil,
        accentTitle: nil, customHeadline: nil, customSubheadline: nil,
        rewardHeadline: nil, rewardSubheadline: nil,
        rewardCta: nil, rewardDecline: nil, rewardBadge: nil, rewardMoreGifts: nil, rewardOtherGifts: nil,
        appearanceMode: nil, accentColor: nil, accentTitleColor: nil,
        strings: nil, plurals: nil
    )

    private init(
        appName: String?, title: String?, subtitle: String?, offerDescription: String?,
        instructionsTitle: String?, lastStepHeader: String?, lastStepDescription: String?,
        creditClaimedTitle: String?, creditClaimedSubtitle: String?, applyCreditsButton: String?,
        accentTitle: String?, customHeadline: String?, customSubheadline: String?,
        rewardHeadline: String?, rewardSubheadline: String?,
        rewardCta: String?, rewardDecline: String?, rewardBadge: String?, rewardMoreGifts: String?, rewardOtherGifts: String?,
        appearanceMode: AppearanceMode?, accentColor: String?, accentTitleColor: String?,
        strings: [String: String]?, plurals: [String: SDKStrings.PluralForms]?
    ) {
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.offerDescription = offerDescription
        self.instructionsTitle = instructionsTitle
        self.lastStepHeader = lastStepHeader
        self.lastStepDescription = lastStepDescription
        self.creditClaimedTitle = creditClaimedTitle
        self.creditClaimedSubtitle = creditClaimedSubtitle
        self.applyCreditsButton = applyCreditsButton
        self.accentTitle = accentTitle
        self.customHeadline = customHeadline
        self.customSubheadline = customSubheadline
        self.rewardHeadline = rewardHeadline
        self.rewardSubheadline = rewardSubheadline
        self.rewardCta = rewardCta
        self.rewardDecline = rewardDecline
        self.rewardBadge = rewardBadge
        self.rewardMoreGifts = rewardMoreGifts
        self.rewardOtherGifts = rewardOtherGifts
        self.appearanceMode = appearanceMode
        self.accentColor = accentColor
        self.accentTitleColor = accentTitleColor
        self.strings = strings
        self.plurals = plurals
    }
}

// MARK: - Entitlement Configuration

/// Entitlement configuration - IAP or Native mode.
/// Mode is implicit: if `iap` has a productId, use IAP mode; otherwise use Native.
struct EntitlementConfiguration: Codable, Sendable {
    let iap: IAPEntitlement?
    let native: NativeEntitlement?
    
    /// True if app uses IAP mode (has productId configured)
    var usesIAPMode: Bool { iap != nil }
    
    /// IAP product ID if configured
    var iapProductId: String? { iap?.productId }
    
    /// Entitlement value for template substitution (from native config)
    var entitlementValue: String? { native?.value }
    
    /// Entitlement unit for template substitution (from native config)
    var entitlementUnit: String? { native?.unit }
    
    /// Premium tier name for template substitution (e.g., "Tinder Premium")
    var premiumTierName: String? { iap?.premiumTierName }

    struct IAPEntitlement: Codable, Sendable {
        let productId: String
        let premiumTierName: String?
    }
    
    struct NativeEntitlement: Codable, Sendable {
        let type: String
        let value: String
        let unit: String
        let durationDays: Int
    }
    
    init(from dto: DTO.RemoteConfig.EntitlementsConfig) {
        self.iap = dto.iap.map { IAPEntitlement(productId: $0.productId, premiumTierName: $0.premiumTierName) }
        self.native = dto.native.map {
            NativeEntitlement(type: $0._type, value: $0.value, unit: $0.unit, durationDays: $0.durationDays)
        }
    }
    
    /// Empty entitlements for fallback scenarios
    static let empty = EntitlementConfiguration(iap: nil, native: nil)
    
    private init(iap: IAPEntitlement?, native: NativeEntitlement?) {
        self.iap = iap
        self.native = native
    }
}

// MARK: - Experiment Configuration

/// Experiment configuration for A/B testing features.
struct ExperimentConfiguration: Codable, Sendable {
    let ncl: NCLExperiment?
    
    struct NCLExperiment: Codable, Sendable {
        let rolloutPct: Int
        let assignmentVersion: Int
        let enabled: Bool
    }
    
    init(from dto: DTO.RemoteConfig.ExperimentsConfig) {
        self.ncl = dto.ncl.map {
            NCLExperiment(rolloutPct: $0.rolloutPct, assignmentVersion: $0.assignmentVersion, enabled: $0.enabled)
        }
    }
    
    /// Empty experiments for fallback scenarios
    static let empty = ExperimentConfiguration(ncl: nil)
    
    private init(ncl: NCLExperiment?) {
        self.ncl = ncl
    }
}
