//
//  IAPEvents.swift
//  Encore
//
//  Analytics events for In-App Purchase interactions.
//

import Foundation

// MARK: - IAP Events

/// Terminal misconfiguration: a product is configured for the app but no
/// `EncorePurchaseController` is registered, so the publisher funnel ends
/// without a purchase attempt. Every occurrence is lost revenue.
struct IAPNoPurchaseControllerEvent: AnalyticsEvent {
    static let eventName = "sdk_iap_no_purchase_controller"

    let productId: String
    let placementId: String?
    let variantId: String?
    /// Presentation this attempt ran inside, when it came from a sheet —
    /// the join key back to the impression that drove the purchase.
    var presentationId: String? = nil
    /// Use case of the presenting sheet.
    var useCase: String? = nil
}

/// "Purchase attempt started" funnel event — emitted once per attempt (native and delegated) before the buy runs. `trigger` ∈ {native, delegated_to_controller}; placement/promo/handlerKind are nil on the native path.
struct IAPPurchasePresentingEvent: AnalyticsEvent {
    static let eventName = "sdk_iap_purchase_presenting"

    let productId: String
    let productName: String
    let price: String
    let type: String
    let trigger: String

    // Delegated-path context; nil on the native path.
    /// Placement that triggered the attempt, when known.
    var placementId: String? = nil
    /// Win-back / promotional offer id, when the attempt carries one.
    var promoOfferId: String? = nil
    /// Which delegated entry point ran: "controller". Nil on the native path.
    var handlerKind: String? = nil
    /// SDUI variant driving the sheet the attempt came from, when resolved.
    var variantId: String? = nil
    /// Presentation this attempt ran inside, when it came from a sheet —
    /// the join key back to the impression that drove the purchase.
    var presentationId: String? = nil
    /// Use case of the presenting sheet.
    var useCase: String? = nil
}

/// IAP purchase succeeded. `source` ∈ {native, controller}; transaction fields are nil on the controller path (the StoreKit txn is owned by the publisher's manager).
struct IAPPurchaseSuccessEvent: AnalyticsEvent {
    static let eventName = "sdk_iap_purchase_success"

    // Base properties
    let productId: String
    let productName: String
    let price: String
    let type: String
    /// `"native"` (Encore-driven StoreKit) or `"controller"` (publisher's
    /// `EncorePurchaseController` reported `.purchased`).
    let source: String
    /// Placement that triggered the purchase, when known (delegated path).
    let placementId: String?
    // Success-specific — nil on the delegated/controller path.
    let transactionId: String?
    let purchaseDate: String?
    let originalPurchaseDate: String?
    let environment: String?
    let variantId: String?
    /// Presentation this attempt ran inside, when it came from a sheet —
    /// the join key back to the impression that drove the purchase.
    var presentationId: String? = nil
    /// Use case of the presenting sheet.
    var useCase: String? = nil
}

/// Tracked when IAP purchase fails
struct IAPPurchaseFailedEvent: AnalyticsEvent {
    static let eventName = "sdk_iap_purchase_failed"
    
    // Base properties
    let productId: String
    let productName: String
    let price: String
    let type: String
    // Failure-specific
    let reason: String
    let variantId: String?
    /// Placement that triggered the attempt, when known — kept in step with
    /// the presenting/success twins so the delegated funnel splits by placement
    /// at every terminal outcome, not only the winning one.
    var placementId: String? = nil
    /// Presentation this attempt ran inside, when it came from a sheet —
    /// the join key back to the impression that drove the purchase.
    var presentationId: String? = nil
    /// Use case of the presenting sheet.
    var useCase: String? = nil
}

/// Tracked when IAP purchase is pending
struct IAPPurchasePendingEvent: AnalyticsEvent {
    static let eventName = "sdk_iap_purchase_pending"

    let productId: String
    let productName: String
    let price: String
    let type: String
    let variantId: String?
    /// Placement that triggered the attempt, when known.
    var placementId: String? = nil
    /// Presentation this attempt ran inside, when it came from a sheet —
    /// the join key back to the impression that drove the purchase.
    var presentationId: String? = nil
    /// Use case of the presenting sheet.
    var useCase: String? = nil
}
