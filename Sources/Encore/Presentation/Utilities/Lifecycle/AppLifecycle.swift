// Presentation/Utilities/Lifecycle/AppLifecycle.swift
//
// Observes app lifecycle notifications and emits events via Combine publishers.
// Consumers subscribe to events rather than setting up their own NotificationCenter observers.
//

import UIKit
import Combine

/// Centralized app lifecycle event source. Emits events via publishers.
/// Handlers are @MainActor isolated to safely access UI state (PresentationWindow).
/// UIKit delivers these notifications on main thread, so no actual hop occurs.
internal final class AppLifecycle {
    
    // MARK: - Publishers (Consumers subscribe to these)
    
    let didForeground = PassthroughSubject<Void, Never>()
    let didBackground = PassthroughSubject<Void, Never>()
    let willTerminate = PassthroughSubject<Void, Never>()
    
    // MARK: - Private
    
    private let appBundleId = Bundle.main.bundleIdentifier ?? "unknown"
    
    init() {
        setupObservers()
    }
    
    private func setupObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleTermination), name: UIApplication.willTerminateNotification, object: nil)
    }
    
    // MARK: - Handlers (Emit events + track analytics)
    // @MainActor: Safe access to PresentationWindow. UIKit delivers on main, so no hop.
    
    @MainActor @objc private func handleForeground() {
        didForeground.send()
        analyticsClient?.track(AppForegroundedEvent(appBundleId: appBundleId))
    }
    
    @MainActor @objc private func handleBackground() {
        didBackground.send()
        analyticsClient?.track(
            AppBackgroundedEvent(appBundleId: appBundleId, offerSheetVisible: PresentationWindow.isPresented)
        )
    }
    
    @MainActor @objc private func handleTermination() {
        willTerminate.send()
        analyticsClient?.track(
            AppTerminatedEvent(appBundleId: appBundleId, offerSheetVisible: PresentationWindow.isPresented)
        )
    }
}
