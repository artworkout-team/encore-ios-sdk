// Sources/Encore/Core/Canonical/Context/OfferContext.swift
//
// Composition of remote config and IAPContext for offer presentation.
// Provides template variable resolution with explicit property mapping.
//

import Foundation

/// Immutable context combining server configuration and IAP data for offer presentation.
///
/// This struct composes UI values and entitlement config from remote configuration with
/// `IAPContext` (runtime IAP data) to provide a complete context for template
/// variable resolution and UI rendering.
///
/// Thread-safe by design (immutable struct).
///
/// Example:
/// ```swift
/// let iapContext = IAPContext(from: productInfo)
/// let offerContext = OfferContext(uiValues: config.ui.values, entitlements: config.entitlements, iap: iapContext)
/// // Now "${subscriptionPrice}" in templates resolves to the IAP price
/// // And "${appName}" resolves to the server-configured app name
/// ```
struct OfferContext {
    
    // MARK: - Properties
    
    /// UI values from remote configuration (text, appearance)
    let uiValues: UIValues?
    
    /// Entitlement configuration (for value/unit substitution)
    let entitlements: EntitlementConfiguration?
    
    /// Runtime IAP subscription data
    let iap: IAPContext

    /// The use case this presentation belongs to. Selects which template the
    /// render path reads and travels onto every offer event.
    let useCase: UseCase

    /// Publisher-supplied copy overrides, keyed by template variable.
    /// Applied last in `allVariables`, which is what makes the documented
    /// priority — SDK override → backend value → shipped template default —
    /// hold regardless of what the backend sent.
    let copyOverrides: [String: String]

    // MARK: - Initialization

    /// Creates an OfferContext with the given configuration and IAP data
    init(
        uiValues: UIValues?,
        entitlements: EntitlementConfiguration? = nil,
        iap: IAPContext = .empty,
        useCase: UseCase = .reduceChurn,
        copyOverrides: [String: String] = [:]
    ) {
        self.uiValues = uiValues
        self.entitlements = entitlements
        self.iap = iap
        self.useCase = useCase
        self.copyOverrides = copyOverrides
    }

    /// Creates an empty context (for fallback scenarios)
    static let empty = OfferContext(uiValues: nil, entitlements: nil, iap: .empty)
    
    // MARK: - Template Variables
    
    /// All template variables for placeholder substitution.
    ///
    /// Combines properties from UI values, entitlements, and IAP into a single dictionary.
    /// IAP properties override other properties if they exist with the same name.
    ///
    /// Uses explicit property mapping for compile-time safety - if the API schema
    /// changes, this will produce a compiler error rather than silently failing.
    var allVariables: [String: String] {
        var variables: [String: String] = [:]
        
        // Extract UI values (text and appearance)
        if let values = uiValues {
            if let v = values.appName { variables["appName"] = v }
            if let v = values.title { variables["titleText"] = v }
            if let v = values.subtitle { variables["subtitleText"] = v }
            if let v = values.offerDescription { variables["offerDescriptionText"] = v }
            if let v = values.instructionsTitle { variables["instructionsTitleText"] = v }
            if let v = values.lastStepHeader { variables["lastStepHeaderText"] = v }
            if let v = values.lastStepDescription { variables["lastStepDescriptionText"] = v }
            if let v = values.creditClaimedTitle { variables["creditClaimedTitleText"] = v }
            if let v = values.creditClaimedSubtitle { variables["creditClaimedSubtitleText"] = v }
            if let v = values.applyCreditsButton { variables["applyCreditsButtonText"] = v }
            if let v = values.accentTitle { variables["accentTitleText"] = v }
            if let v = values.accentTitleColor { variables["accentTitleColor"] = v }
            if let v = values.accentColor { variables["accentColor"] = v }
            // Custom headline/subheadline with fallback to title/subtitle
            if let v = values.customHeadline ?? values.title { variables["customHeadline"] = v }
            if let v = values.customSubheadline ?? values.subtitle { variables["customSubheadline"] = v }
            // Reward copy. No fallback to title/subtitle: those are the paywall's
            // own strings and would read as a sales pitch on a thank-you screen.
            // The backend guarantees `rewardHeadline` on every reward response
            // precisely because the template references `${rewardHeadline}`
            // unconditionally and an unresolved token renders verbatim.
            if let v = values.rewardHeadline { variables["rewardHeadline"] = v }
            // Omitted when nil, deliberately. The template branches on
            // `hasValue: rewardSubheadline` — absent means the segmented default
            // with its bold run, present means a single plain run. Writing an
            // empty string here would silently drop the bold branch, and with it
            // the design.
            if let v = values.rewardSubheadline { variables["rewardSubheadline"] = v }
        }

        // Extract entitlement values
        if let entitlements = entitlements {
            if let v = entitlements.entitlementValue {
                variables["trialValue"] = v
            }
            if let v = entitlements.entitlementUnit {
                variables["trialUnit"] = v
            }
            if let v = entitlements.premiumTierName {
                variables["premiumTierName"] = v
            }
        }
        // Fallback: premiumTierName defaults to "{appName} Premium" if not set
        if variables["premiumTierName"] == nil, let appName = uiValues?.appName {
            variables["premiumTierName"] = "\(appName) Premium"
        }
        
        // Add IAP properties (these take precedence over remote config)
        if let v = iap.subscriptionPrice { variables["subscriptionPrice"] = v }
        if let v = iap.subscriptionName { variables["subscriptionName"] = v }
        if let v = iap.subscriptionPeriod { variables["subscriptionPeriod"] = v }
        
        // Add IAP free trial properties (overrides native entitlement values if present).
        // Free-trial-specific — kept narrow so older variants using `${trialValue}`
        // don't silently render paid-intro durations.
        if iap.hasFreeTrial {
            if let v = iap.freeTrialValue {
                variables["trialValue"] = v
            }
            if let v = iap.freeTrialUnit {
                variables["trialUnit"] = v
            }
            if let v = iap.freeTrialDuration {
                variables["trialDuration"] = v
            }
        }

        // Intro offer properties — populated for ANY intro (free trial,
        // pay-as-you-go, pay-up-front). Variants that need price + duration
        // regardless of payment mode read these.
        if iap.hasIntroOffer {
            if let v = iap.introOfferPrice {
                variables["introOfferPrice"] = v
            }
            if let v = iap.introOfferValue {
                variables["introOfferValue"] = v
            }
            if let v = iap.introOfferUnit {
                variables["introOfferUnit"] = v
            }
            if let v = iap.introOfferDuration {
                variables["introOfferDuration"] = v
            }
        }

        // SDK overrides win over everything the backend sent. Applied last so
        // the priority holds even after the backend starts returning its own
        // value for a use-case copy key (e.g. `rewardHeadline`) — that value
        // lands in `uiValues` above and is overwritten here when the publisher
        // supplied one. Substitution leaves unresolved `${…}` tokens visible on
        // screen, so a key that any template references must always resolve.
        for (key, value) in copyOverrides {
            variables[key] = value
        }

        return variables
    }
    
    // MARK: - Convenience Accessors
    
    /// Appearance mode from UI values
    var appearanceMode: AppearanceMode {
        guard let mode = uiValues?.appearanceMode else { return .auto }
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .auto: return .auto
        }
    }
    
    // MARK: - UI Values Property Forwarding
    
    /// Title text from UI values
    var titleText: String? { uiValues?.title }
    
    /// Accent title text from UI values
    var accentTitleText: String? { uiValues?.accentTitle }
    
    /// Subtitle text from UI values
    var subtitleText: String? { uiValues?.subtitle }

    /// The headline this presentation's use case actually renders, resolved
    /// through `allVariables` so publisher overrides win. `titleText` is the
    /// churn-specific raw value and does not answer for a reward placement.
    var headlineText: String? { allVariables[useCase.headlineVariable] }

    /// The subheadline for this use case. Absent is a real state for rewards:
    /// the template branches on it, so no default is substituted here.
    var subheadlineText: String? { allVariables[useCase.subheadlineVariable] }
    
    /// Accent color hex from UI values
    var accentColor: String? { uiValues?.accentColor }
    
    /// Accent title color hex from UI values
    var accentTitleColor: String? { uiValues?.accentTitleColor }
    
    /// Credit claimed title text from UI values
    var creditClaimedTitleText: String? { uiValues?.creditClaimedTitle }
    
    /// Credit claimed subtitle text from UI values
    var creditClaimedSubtitleText: String? { uiValues?.creditClaimedSubtitle }
    
    /// Apply credits button text from UI values
    var applyCreditsButtonText: String? { uiValues?.applyCreditsButton }
    
    /// Instructions title text from UI values
    var instructionsTitleText: String? { uiValues?.instructionsTitle }
    
    // MARK: - Appearance Mode
    
    enum AppearanceMode: String {
        case light
        case dark
        case auto
    }
}
