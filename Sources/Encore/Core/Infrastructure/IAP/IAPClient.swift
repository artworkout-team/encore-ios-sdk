//
//  IAPClient.swift
//  Encore
//
//  Minimal IAP client for handling subscription purchases.
//  Infrastructure layer - wraps StoreKit.
//

import Foundation
import StoreKit

/// Product info returned by fetchProductInfo
struct IAPProductInfo {
    let id: String
    let displayName: String
    let displayPrice: String  // Localized renewal price (e.g., "$4.99")
    let subscriptionPeriod: String?  // e.g., "/month", "/year", "/week"

    // Introductory offer — covers free trials, pay-as-you-go, and pay-up-front.
    // "Duration" reflects total eligible window (period.value × periodCount), so a
    // "3 months at $0.99/mo" offer reports `introOfferDuration = "3 months"`.
    let hasIntroOffer: Bool
    let introIsFreeTrial: Bool
    let introOfferPrice: String?     // localized offer price, e.g. "$0.00" or "$0.99"
    let introOfferValue: String?     // total duration value as string, e.g. "3"
    let introOfferUnit: String?      // pluralized for the total, e.g. "months"
    let introOfferDuration: String?  // formatted, e.g. "3 months"
    /// Offer length normalized to days (week × 7, month × 30, year × 365). Sent
    /// to the backend in the lead payload (as `trialDurationDays`) so it can
    /// schedule offer-end reminders off the authoritative StoreKit value.
    /// Populated for any intro offer, not just free trials.
    let introOfferDays: Int?

    // Free-trial-only views into the intro offer above. Computed so older
    // variants that branch on "${trialValue}" / `hasFreeTrial` keep their
    // existing semantics ("is this specifically a free trial") and aren't
    // silently broadened to paid intros.
    var hasFreeTrial: Bool { hasIntroOffer && introIsFreeTrial }
    var freeTrialValue: String? { hasFreeTrial ? introOfferValue : nil }
    var freeTrialUnit: String? { hasFreeTrial ? introOfferUnit : nil }
    var freeTrialDuration: String? { hasFreeTrial ? introOfferDuration : nil }
    var freeTrialDays: Int? { hasFreeTrial ? introOfferDays : nil }
}

/// Unit of an intro offer's billing period. Local mirror of
/// `Product.SubscriptionPeriod.Unit` so the duration math is testable without
/// constructing a StoreKit `Product`.
enum IntroOfferPeriodUnit {
    case day, week, month, year
}

/// Pure inputs to the intro-offer duration calculation. Separated from
/// StoreKit so unit tests can exercise the math (period × periodCount,
/// pluralization, normalization to days) without a `Product` mock.
struct IntroOfferRaw {
    let isFreeTrial: Bool
    let displayPrice: String
    let periodValue: Int
    let periodUnit: IntroOfferPeriodUnit
    let periodCount: Int
}

@MainActor
@available(iOS 15.0, *)
class IAPClient {

    // MARK: - Product Info
    
    /// Bounded product lookup. `Product.products(for:)` is network-backed with
    /// no deadline of its own; unbounded, it held the tap-to-sheet path hostage
    /// (validation finding 2026-08-11 — same hazard class as the telemetry
    /// lookup bound near `delegatePurchase`). Timeout returns nil, logged
    /// distinctly from not-found.
    static func fetchProductInfo(productId: String, timeoutSeconds: TimeInterval = 5) async -> IAPProductInfo? {
        // Abandon-the-loser shape (same reason as `purchaseWithTimeout`): a
        // task group would await a StoreKit fetch that may not observe
        // cancellation, reinstating the stall this bound exists to prevent.
        final class ResumeOnce {
            var resumed = false
        }
        let flag = ResumeOnce()
        // Cancelled by the winner: an uncancelled timer keeps a main-actor
        // task sleeping for the full deadline after the work is already done.
        let timer = Atomic<Task<Void, Never>?>(nil)

        return await withCheckedContinuation { continuation in
            let fetch = Task { @MainActor in
                let info = await fetchProductInfoUnbounded(productId: productId)
                guard !flag.resumed else { return }
                flag.resumed = true
                timer.value?.cancel()
                continuation.resume(returning: info)
            }
            timer.value = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled, !flag.resumed else { return }
                flag.resumed = true
                fetch.cancel()
                Logger.warn(.iap, "Product info lookup timed out after \(Int(timeoutSeconds))s for '\(productId)' — presenting without product context")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Fetch product information without purchasing
    /// Returns product info if found, nil if product not found
    private static func fetchProductInfoUnbounded(productId: String) async -> IAPProductInfo? {
        do {
            Logger.debug(.iap, "Fetching product info: \(productId)")
            
            guard let product = try await Product.products(for: [productId]).first else {
                Logger.debug(.iap, "Product not found: \(productId)")
                return nil
            }
            
            // Format subscription period if this is a subscription product
            let period = formatSubscriptionPeriod(product.subscription?.subscriptionPeriod)

            // Extract intro offer (free trial OR pay-as-you-go OR pay-up-front)
            let intro = extractIntroOfferInfo(from: product)

            if intro.hasIntroOffer {
                let kind = intro.introIsFreeTrial ? "free trial" : "intro offer"
                Logger.debug(.iap, "Product info fetched: \(product.displayName) - \(product.displayPrice)\(period ?? "") with \(intro.introOfferDuration ?? "unknown") \(kind) at \(intro.introOfferPrice ?? "n/a")")
            } else {
                Logger.debug(.iap, "Product info fetched: \(product.displayName) - \(product.displayPrice)\(period ?? "")")
            }

            return IAPProductInfo(
                id: product.id,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                subscriptionPeriod: period,
                hasIntroOffer: intro.hasIntroOffer,
                introIsFreeTrial: intro.introIsFreeTrial,
                introOfferPrice: intro.introOfferPrice,
                introOfferValue: intro.introOfferValue,
                introOfferUnit: intro.introOfferUnit,
                introOfferDuration: intro.introOfferDuration,
                introOfferDays: intro.introOfferDays
            )
        } catch {
            Logger.debug(.iap, "Failed to fetch product info: \(error)")
            return nil
        }
    }
    
    /// Format subscription period as a readable string (e.g., "/month", "/year")
    private static func formatSubscriptionPeriod(_ period: Product.SubscriptionPeriod?) -> String? {
        guard let period = period else { return nil }
        
        switch period.unit {
        case .day:
            return period.value == 1 ? "/day" : "/\(period.value) days"
        case .week:
            return period.value == 1 ? "/week" : "/\(period.value) weeks"
        case .month:
            return period.value == 1 ? "/month" : "/\(period.value) months"
        case .year:
            return period.value == 1 ? "/year" : "/\(period.value) years"
        @unknown default:
            return nil
        }
    }
    
    /// Intro-offer context extracted from a StoreKit product. Covers free
    /// trials and paid intros uniformly — variants branch on
    /// `introIsFreeTrial` if they need different price framing.
    struct IntroOfferDescriptor {
        let hasIntroOffer: Bool
        let introIsFreeTrial: Bool
        let introOfferPrice: String?
        let introOfferValue: String?
        let introOfferUnit: String?
        let introOfferDuration: String?
        let introOfferDays: Int?

        static let none = IntroOfferDescriptor(
            hasIntroOffer: false,
            introIsFreeTrial: false,
            introOfferPrice: nil,
            introOfferValue: nil,
            introOfferUnit: nil,
            introOfferDuration: nil,
            introOfferDays: nil
        )
    }

    /// Compute intro-offer fields from pre-extracted, StoreKit-free inputs.
    /// Total duration = `periodValue * periodCount` — the "eligible window"
    /// across all payment modes:
    /// - `.freeTrial`        → periodCount typically 1, total = the trial period
    /// - `.payAsYouGo`       → periodCount > 1, total = reduced-price window
    /// - `.payUpFront`       → periodCount 1, total = paid window
    /// Day multipliers (week × 7, month × 30, year × 365) are approximations —
    /// fine for reminder scheduling. Apple's authoritative end date is shown
    /// in Settings → Subscriptions.
    static func computeIntroOfferInfo(_ raw: IntroOfferRaw) -> IntroOfferDescriptor {
        let totalValue = raw.periodValue * raw.periodCount

        let unitStrings: (singular: String, plural: String, daysPerUnit: Int)
        switch raw.periodUnit {
        case .day:   unitStrings = ("day", "days", 1)
        case .week:  unitStrings = ("week", "weeks", 7)
        case .month: unitStrings = ("month", "months", 30)
        case .year:  unitStrings = ("year", "years", 365)
        }
        let unit = totalValue == 1 ? unitStrings.singular : unitStrings.plural

        return IntroOfferDescriptor(
            hasIntroOffer: true,
            introIsFreeTrial: raw.isFreeTrial,
            introOfferPrice: raw.displayPrice,
            introOfferValue: "\(totalValue)",
            introOfferUnit: unit,
            introOfferDuration: "\(totalValue) \(unit)",
            introOfferDays: totalValue * unitStrings.daysPerUnit
        )
    }

    /// Bridge from StoreKit `Product` to the pure intro-offer math.
    private static func extractIntroOfferInfo(from product: Product) -> IntroOfferDescriptor {
        guard let subscription = product.subscription,
              let intro = subscription.introductoryOffer else {
            return .none
        }

        let unit: IntroOfferPeriodUnit
        switch intro.period.unit {
        case .day:   unit = .day
        case .week:  unit = .week
        case .month: unit = .month
        case .year:  unit = .year
        @unknown default: return .none
        }

        return computeIntroOfferInfo(IntroOfferRaw(
            isFreeTrial: intro.paymentMode == .freeTrial,
            displayPrice: intro.displayPrice,
            periodValue: intro.period.value,
            periodUnit: unit,
            periodCount: intro.periodCount
        ))
    }
    
    // MARK: - Delegated Purchase

    /// SDK-side allowance for an ``EncorePurchaseController`` to resolve.
    /// A controller that never returns would otherwise wedge the sheet-lifetime
    /// await; expiry folds into a failed purchase (`controller_threw:
    /// PurchaseControllerTimeoutError` in telemetry) and the flow continues.
    internal static var controllerTimeoutSeconds: TimeInterval = 300

    /// Deadline for the telemetry-only StoreKit product lookup that precedes
    /// the controller. Short by design: its result only decorates an analytics
    /// event, so it is never worth making the user wait.
    internal static var productInfoTimeoutSeconds: TimeInterval = 2

    /// Test seam for that lookup. When set, StoreKit is never consulted.
    /// `swift test` has no StoreKit configuration and no App Store account, so
    /// the real fetch can only fail — and it fails slowly, over the network,
    /// which is enough to dominate timing assertions in unrelated tests.
    internal static var productInfoProviderForTesting:
        (@Sendable (String) async -> (name: String, price: String, type: String))?

    /// Marker error so a hung controller is distinguishable in telemetry.
    struct PurchaseControllerTimeoutError: Error {}

    /// Races the controller's purchase against `controllerTimeoutSeconds`.
    ///
    /// Deliberately unstructured: a task group would await the controller
    /// child even after the timeout throws (cancellation is only cooperative),
    /// so a controller wedged on something cancellation can't reach — e.g. a
    /// never-resumed delegate continuation — would keep the sheet-lifetime
    /// await suspended forever. Here the loser is cancelled and abandoned;
    /// a late result from an abandoned controller is discarded.
    private static func purchaseWithTimeout(
        _ controller: EncorePurchaseController,
        _ request: PurchaseRequest
    ) async throws -> EncorePurchaseResult {
        let timeout = controllerTimeoutSeconds

        // Both racers hop to the main actor before touching this, so the
        // resume-once check is serial.
        final class ResumeOnce {
            var resumed = false
        }
        let flag = ResumeOnce()
        // Cancelled by the winner: without this every completed purchase left
        // a main-actor task sleeping out the full 300s allowance.
        let timer = Atomic<Task<Void, Never>?>(nil)

        return try await withCheckedThrowingContinuation { continuation in
            let purchaseTask = Task { @MainActor in
                let result: Result<EncorePurchaseResult, Error>
                do {
                    result = .success(try await controller.purchase(request))
                } catch {
                    result = .failure(error)
                }
                guard !flag.resumed else {
                    Logger.warn(.iap, "Discarding late purchase-controller result after timeout")
                    return
                }
                flag.resumed = true
                timer.value?.cancel()
                continuation.resume(with: result)
            }
            timer.value = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, !flag.resumed else { return }
                flag.resumed = true
                purchaseTask.cancel()
                continuation.resume(throwing: PurchaseControllerTimeoutError())
            }
        }
    }

    /// Runs the purchase through the registered ``EncorePurchaseController``.
    /// With none registered the funnel terminates at `.notAttempted` — the SDK
    /// never charges on the publisher's behalf. Returns the publisher-funnel
    /// outcome for the result record.
    /// `placementId` is the local placement identity handed to the host's
    /// ``PurchaseRequest`` (unchanged public behaviour). `placementLabel` is the
    /// publisher-chosen label and the ONLY placement value the analytics events
    /// here carry — omitted when the placement id was auto-generated
    /// (2026-08-14 reversal: minted ids never go on the wire).
    static func delegatePurchase(productId: String, placementId: String?, placementLabel: String? = nil, promoOfferId: String? = nil, presentationId: String? = nil, useCase: UseCase = .reduceChurn) async -> PublisherOutcome {
        let request = PurchaseRequest(productId: productId, placementId: placementId, promoOfferId: promoOfferId)
        // Every delegated purchase runs inside a presented sheet, so the sheet's
        // variant is the variant of the attempt — resolved for the PRESENTING
        // use case. The bare `variantId` accessor is hardcoded to churn
        // intervention, so it would file a non-churn purchase against a variant
        // that never rendered, beside a correct `use_case` and `placement_id`.
        let variantId = sduiConfigManager?.variantId(for: useCase)

        // EncorePurchaseController. Fires the presenting START event, plus a success event on .purchased.
        if let controller = Encore.shared.purchaseController {
            let info = await resolveProductInfoForTelemetry(productId: productId)
            analyticsClient?.track(
                IAPPurchasePresentingEvent(
                    productId: productId,
                    productName: info.name,
                    price: info.price,
                    type: info.type,
                    trigger: "delegated_to_controller",
                    placementId: placementLabel,
                    promoOfferId: promoOfferId,
                    handlerKind: "controller",
                    variantId: variantId,
                    presentationId: presentationId,
                    useCase: useCase.rawValue
                )
            )
            do {
                switch try await purchaseWithTimeout(controller, request) {
                case .purchased:
                    Encore.shared.services?.iapObserver?.reconcileTransactions()
                    Logger.info(.iap, "Controller purchase succeeded: \(productId)")
                    analyticsClient?.track(
                        IAPPurchaseSuccessEvent(
                            productId: productId,
                            productName: info.name,
                            price: info.price,
                            type: info.type,
                            source: "controller",
                            placementId: placementLabel,
                            transactionId: nil,
                            purchaseDate: nil,
                            originalPurchaseDate: nil,
                            environment: nil,
                            variantId: variantId,
                            presentationId: presentationId,
                            useCase: useCase.rawValue
                        )
                    )
                    return .purchased
                case .cancelled:
                    Logger.info(.iap, "Controller purchase cancelled: \(productId)")
                    analyticsClient?.track(
                        IAPPurchaseFailedEvent(
                            productId: productId,
                            productName: info.name,
                            price: info.price,
                            type: info.type,
                            reason: "cancelled",
                            variantId: variantId,
                            placementId: placementLabel,
                            presentationId: presentationId,
                            useCase: useCase.rawValue
                        )
                    )
                    return .cancelled
                case .pending:
                    Logger.info(.iap, "Controller purchase pending: \(productId)")
                    analyticsClient?.track(
                        IAPPurchasePendingEvent(
                            productId: productId,
                            productName: info.name,
                            price: info.price,
                            type: info.type,
                            variantId: variantId,
                            placementId: placementLabel,
                            presentationId: presentationId,
                            useCase: useCase.rawValue
                        )
                    )
                    return .pending
                }
            } catch {
                Logger.warn(.iap, "Controller purchase threw: \(type(of: error))")
                analyticsClient?.track(
                    IAPPurchaseFailedEvent(
                        productId: productId,
                        productName: info.name,
                        price: info.price,
                        type: info.type,
                        reason: "controller_threw: \(type(of: error))",
                        variantId: variantId,
                        placementId: placementLabel,
                        presentationId: presentationId,
                        useCase: useCase.rawValue
                    )
                )
                return .failed
            }
        }

        // No controller: the app has a product to sell but no mechanism to sell
        // it. Charging the user from inside the SDK would run purchase code the
        // publisher never wrote, bypassing their receipt validation and
        // entitlement bookkeeping — so the funnel terminates here instead.
        Logger.warn(.iap, "Product \(productId) is configured but no EncorePurchaseController is registered — skipping purchase. Register one via configure(apiKey:purchaseController:options:).")
        analyticsClient?.track(IAPNoPurchaseControllerEvent(productId: productId, placementId: placementLabel, variantId: variantId, presentationId: presentationId, useCase: useCase.rawValue))
        return .notAttempted
    }

    /// Resolve product info from StoreKit for telemetry. Best-effort: returns
    /// empty strings when the App Store fetch fails or outruns
    /// ``productInfoTimeoutSeconds``, so enriching an analytics event can never
    /// delay the purchase itself.
    ///
    /// The bound is the point. This lookup runs *ahead* of the publisher's
    /// controller, and `Product.products(for:)` is network-backed with no
    /// deadline of its own — unbounded, it makes the user wait on the App Store
    /// before their own purchase code is even invoked.
    private static func resolveProductInfoForTelemetry(
        productId: String
    ) async -> (name: String, price: String, type: String) {
        if let provider = productInfoProviderForTesting {
            return await provider(productId)
        }

        let empty = (name: "", price: "", type: "")
        let timeout = productInfoTimeoutSeconds

        // Same abandon-the-loser shape as `purchaseWithTimeout`, for the same
        // reason: a task group would await a StoreKit fetch that may not
        // observe cancellation, reinstating the stall this exists to bound.
        final class ResumeOnce {
            var resumed = false
        }
        let flag = ResumeOnce()
        // Cancelled by the winner, as in the other two races here.
        let timer = Atomic<Task<Void, Never>?>(nil)

        return await withCheckedContinuation { continuation in
            let fetch = Task { @MainActor in
                var info = empty
                do {
                    if let product = try await Product.products(for: [productId]).first {
                        info = (
                            name: product.displayName,
                            price: product.price.description,
                            type: product.type.rawValue
                        )
                    }
                } catch {
                    Logger.debug(.iap, "Couldn't resolve product info for presented event: \(error)")
                }
                guard !flag.resumed else { return }
                flag.resumed = true
                timer.value?.cancel()
                continuation.resume(returning: info)
            }
            timer.value = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, !flag.resumed else { return }
                flag.resumed = true
                fetch.cancel()
                Logger.debug(.iap, "Product info lookup exceeded \(timeout)s — emitting purchase telemetry without it")
                continuation.resume(returning: empty)
            }
        }
    }


}

// MARK: - Errors

enum IAPError: Error {
    case productNotFound
    case failedVerification
}

extension IAPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "IAP product not found"
        case .failedVerification:
            return "Transaction verification failed"
        }
    }
}
