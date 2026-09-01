//
//  PurchaseRequest.swift
//  Encore
//
//  Context passed to the app's EncorePurchaseController when Encore triggers a purchase.
//

import Foundation

/// Context passed to your ``EncorePurchaseController`` when Encore's offer flow triggers a purchase.
///
/// Use this to route purchases through your subscription manager (RevenueCat, Adapty, etc.)
/// with full context including optional promotional offers (`promoOfferId`).
public struct PurchaseRequest: Sendable {
    /// The IAP product identifier to purchase (e.g., "com.app.monthly_premium").
    public let productId: String

    /// The placement that triggered this purchase, if any.
    public let placementId: String?

    /// App Store Connect promotional offer identifier, when a promotional offer
    /// should be applied to this purchase. `nil` for standard purchases.
    public let promoOfferId: String?

    public init(productId: String, placementId: String? = nil, promoOfferId: String? = nil) {
        self.productId = productId
        self.placementId = placementId
        self.promoOfferId = promoOfferId
    }
}
