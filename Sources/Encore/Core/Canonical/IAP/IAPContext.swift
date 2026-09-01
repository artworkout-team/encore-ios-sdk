// Sources/Encore/Core/Canonical/IAP/IAPContext.swift
//
// Immutable context for IAP subscription data.
// Separated from RemoteConfig to maintain clear boundaries between
// server configuration and runtime IAP state.
//

import Foundation

/// Immutable context containing IAP subscription information.
///
/// This struct holds subscription data fetched at runtime from StoreKit.
/// It's designed to be composed with `RemoteConfig` in an `OfferContext`
/// for template variable resolution.
///
/// Thread-safe by design (immutable struct conforming to Sendable).
struct IAPContext: Sendable {

    /// Localized renewal price (e.g., "$4.99"). Always the regular price —
    /// the intro offer's discounted price lives on `introOfferPrice`.
    let subscriptionPrice: String?

    /// The subscription product display name
    let subscriptionName: String?

    /// The subscription period suffix (e.g., "/month", "/year")
    let subscriptionPeriod: String?

    // MARK: - Introductory offer

    /// Whether the product has any introductory offer (free trial, pay-as-you-go,
    /// or pay-up-front). Variants gate intro-only copy on this rather than the
    /// narrower `hasFreeTrial` so paid intros surface their price and duration.
    let hasIntroOffer: Bool

    /// True when the intro offer is specifically a free trial. Drives the
    /// "$0 vs ${introOfferPrice}" branch in the big-price slot.
    let introIsFreeTrial: Bool

    /// Localized intro offer price (e.g., "$0.00" for free trial, "$0.99"
    /// for pay-as-you-go, "$2.99" for pay-up-front).
    let introOfferPrice: String?

    /// Intro offer total duration value (e.g., "3" for "3 months at $0.99/mo").
    let introOfferValue: String?

    /// Intro offer unit, pluralized for the total value (e.g., "months").
    let introOfferUnit: String?

    /// Formatted intro offer duration (e.g., "3 months", "7 days").
    let introOfferDuration: String?

    /// Intro offer length normalized to days. Sent to the backend in the lead
    /// payload (as `trialDurationDays` — the wire field name predates the paid-intro
    /// generalization) so it can schedule offer-end reminders against the
    /// StoreKit-authoritative value rather than the portal-typed mirror.
    let introOfferDays: Int?

    // MARK: - Free-trial-only views

    /// Free-trial-only views into the intro offer fields above. Computed so
    /// older variants that branch on "${trialValue}" / `hasFreeTrial` keep
    /// their semantics ("is this specifically a free trial") and aren't
    /// silently broadened when the offer is a paid intro.
    var hasFreeTrial: Bool { hasIntroOffer && introIsFreeTrial }
    var freeTrialValue: String? { hasFreeTrial ? introOfferValue : nil }
    var freeTrialUnit: String? { hasFreeTrial ? introOfferUnit : nil }
    var freeTrialDuration: String? { hasFreeTrial ? introOfferDuration : nil }
    var freeTrialDays: Int? { hasFreeTrial ? introOfferDays : nil }

    /// Empty context with no IAP data
    static let empty = IAPContext(
        subscriptionPrice: nil,
        subscriptionName: nil,
        subscriptionPeriod: nil,
        hasIntroOffer: false,
        introIsFreeTrial: false,
        introOfferPrice: nil,
        introOfferValue: nil,
        introOfferUnit: nil,
        introOfferDuration: nil,
        introOfferDays: nil
    )

    /// Creates an IAPContext from IAPProductInfo
    init(from productInfo: IAPProductInfo?) {
        self.subscriptionPrice = productInfo?.displayPrice
        self.subscriptionName = productInfo?.displayName
        self.subscriptionPeriod = productInfo?.subscriptionPeriod
        self.hasIntroOffer = productInfo?.hasIntroOffer ?? false
        self.introIsFreeTrial = productInfo?.introIsFreeTrial ?? false
        self.introOfferPrice = productInfo?.introOfferPrice
        self.introOfferValue = productInfo?.introOfferValue
        self.introOfferUnit = productInfo?.introOfferUnit
        self.introOfferDuration = productInfo?.introOfferDuration
        self.introOfferDays = productInfo?.introOfferDays
    }

    /// Creates an IAPContext with explicit values
    init(
        subscriptionPrice: String?,
        subscriptionName: String?,
        subscriptionPeriod: String?,
        hasIntroOffer: Bool = false,
        introIsFreeTrial: Bool = false,
        introOfferPrice: String? = nil,
        introOfferValue: String? = nil,
        introOfferUnit: String? = nil,
        introOfferDuration: String? = nil,
        introOfferDays: Int? = nil
    ) {
        self.subscriptionPrice = subscriptionPrice
        self.subscriptionName = subscriptionName
        self.subscriptionPeriod = subscriptionPeriod
        self.hasIntroOffer = hasIntroOffer
        self.introIsFreeTrial = introIsFreeTrial
        self.introOfferPrice = introOfferPrice
        self.introOfferValue = introOfferValue
        self.introOfferUnit = introOfferUnit
        self.introOfferDuration = introOfferDuration
        self.introOfferDays = introOfferDays
    }
}
