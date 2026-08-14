// Sources/Encore/Core/Accessors.swift
//
// Convenience accessors for SDK services.
// These are syntax sugar - they forward to ServiceContainer.
//
// Usage: `analyticsClient?.track(...)` instead of `Encore.shared.services?.analytics.track(...)`
//
// NOTE: All accessors return optionals to guarantee we never crash the host app.
// If the SDK is not configured, calls silently become no-ops (via optional chaining).
//

import Foundation


// MARK: - Configuration-Scoped Services
internal var configuration: Configuration? { Encore.shared.configuration }

internal var analyticsClient: AnalyticsClient? { Encore.shared.services?.analytics }
internal var errorsClient: ErrorsClient? { Encore.shared.services?.errors }
internal var userManager: UserManager? { Encore.shared.services?.user }
internal var entitlementsManager: EntitlementManager? { Encore.shared.services?.entitlements }
internal var offersManager: OffersManager? { Encore.shared.services?.offers }
internal var transactionsManager: TransactionsManager? { Encore.shared.services?.transactions }
internal var sduiConfigManager: SDUIConfigurationManager? { Encore.shared.services?.sduiConfigManager }
internal var remoteConfigManager: RemoteConfigurationManager? { Encore.shared.services?.remoteConfigManager }
internal var experimentManager: ExperimentManager? { Encore.shared.services?.experimentManager }
internal var strictUnlockReconciler: StrictUnlockReconciler? { Encore.shared.services?.strictUnlockReconciler }

// MARK: - Instance-Scoped Services (Not Configuration-Dependent)
// Lives on Encore.shared directly, not in ServiceContainer.
internal var lifecycle: AppLifecycle? { Encore.shared.lifecycle }

