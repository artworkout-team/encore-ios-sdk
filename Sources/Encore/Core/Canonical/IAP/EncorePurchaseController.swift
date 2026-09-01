//
//  EncorePurchaseController.swift
//  Encore
//
//  Protocol the host app implements to run a purchase through its own subscription manager.
//

import Foundation

/// Outcome of a purchase performed by your ``EncorePurchaseController``.
///
/// Mirrors Apple's StoreKit 2 `Product.PurchaseResult` (`.success` / `.userCancelled`
/// / `.pending`). **Real errors are thrown, not returned** — Encore captures the error
/// type and `localizedDescription` automatically, so you never hand-build a reason string.
public enum EncorePurchaseResult: Sendable {
    /// The purchase completed successfully.
    case purchased
    /// The user dismissed / cancelled the purchase.
    case cancelled
    /// The purchase is deferred (e.g. Ask to Buy / SCA) and may complete later.
    /// Encore treats this as not-yet-converted; the eventual Apple webhook is the source of truth.
    case pending
}

/// Implement this to let Encore control *when* a purchase happens while your app owns
/// *how* it happens. Conform a small class to it and register the instance via
/// `Encore.shared.configure(apiKey:purchaseController:)`. The class can be named anything.
///
/// Encore invokes ``purchase(_:)`` when a user accepts an offer it presented: forward
/// `request.productId` to your subscription manager and return a normalized result (or throw).
/// Encore handles presentation, dismissal, analytics, and attribution around your call —
/// you only run the buy.
///
/// Throw real errors freely — Encore records the type + localizedDescription, resolves the presentation as not-unlocked, and continues. Map a manager's "user cancelled" throw to `.cancelled`.
///
/// ```swift
/// final class AppPurchases: EncorePurchaseController {
///     func purchase(_ request: PurchaseRequest) async throws -> EncorePurchaseResult {
///         switch try await Adapty.makePurchase(/* resolve request.productId */) {
///         case .userCancelled: return .cancelled
///         case .pending:       return .pending
///         default:             return .purchased
///         }
///     }
/// }
/// ```
@MainActor
public protocol EncorePurchaseController: AnyObject {
    /// Perform the purchase for `request.productId`; return `.purchased`/`.cancelled`/`.pending` or throw.
    func purchase(_ request: PurchaseRequest) async throws -> EncorePurchaseResult
}
