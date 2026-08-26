// Presentation/Utils/Window/PresentationWindow.swift
//
// UIWindow utilities for presentation management.
// Encapsulates UIKit bridging for SwiftUI overlay presentation.
//

import SwiftUI
import UIKit

/// Manages presentation windows and view controller discovery.
///
/// This is the SDK's UIKit escape hatch for "present above everything" semantics.
/// SwiftUI views are hosted in a custom `UIWindow` at the highest window level.
///
/// Thread Safety: All operations are `@MainActor` isolated.
extension OfferContext.AppearanceMode {
    /// `.unspecified` for `auto` so the sheet inherits the HOST app rather than
    /// the device — a light-only publisher should not get a dark sheet.
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return .unspecified
        }
    }
}

@MainActor
private final class PresentationHostingController<Content: View>: UIHostingController<Content> {
    private weak var orientationSource: UIViewController?

    init(rootView: Content, orientationSource: UIViewController?) {
        self.orientationSource = orientationSource
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        orientationSource?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationSource?.preferredInterfaceOrientationForPresentation
            ?? super.preferredInterfaceOrientationForPresentation
    }

    override var shouldAutorotate: Bool {
        orientationSource?.shouldAutorotate ?? super.shouldAutorotate
    }
}

@MainActor
enum PresentationWindow {
    // MARK: - Window State

    /// The custom window used for presenting offer sheets.
    private(set) static var window: UIWindow?

    /// The hosting controller for the presented SwiftUI view.
    private static var hostingController: UIViewController?

    /// iOS 17 requires the overlay to become key before presenting SwiftUI
    /// content from its root controller. Weak so the SDK never extends the
    /// host window's lifetime.
    private weak static var previousKeyWindow: UIWindow?

    /// Called when the window is dismissed (cleanup, swipe-away, etc.)
    private static var onDismissHandler: (() -> Void)?

    /// Whether an offer sheet is currently presented.
    static var isPresented: Bool {
        window != nil
    }

    // MARK: - Present SwiftUI View

    /// Presents a SwiftUI view in a transparent overlay `UIWindow` above all other content.
    /// Returns the created window on success, nil when no window scene is available.
    /// `overrideUserInterfaceStyle` forces the sheet's appearance; `.unspecified` (the
    /// default) inherits the host app, which is what `auto` means.
    /// `onDismiss` fires when the window is cleaned up (dismissal, system removal, etc).
    @discardableResult
    static func present<Content: View>(
        _ rootView: Content,
        overrideUserInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        _ onDismiss: (() -> Void)? = nil
    ) -> UIWindow? {
        // Auto-clean stale window instead of bailing — prevents stuck states
        if window != nil {
            Logger.warn(.presentation, "Stale window detected — cleaning up")
            analyticsClient?.track(SDKErrorEvent(
                error: .domain("Stale presentation window detected"),
                context: .presentOfferInitialization
            ))
            cleanup()
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            Logger.error(.integration(.notConfigured), context: .presentOfferInitialization)
            return nil
        }

        // Store dismiss handler
        onDismissHandler = onDismiss

        // Create overlay window
        let newWindow = UIWindow(windowScene: windowScene)
        // Set on the WINDOW, not via `.preferredColorScheme`: the SDUI palette
        // is dynamic UIColors, which resolve against the UIKit trait collection
        // and ignore the SwiftUI environment — so an explicit `appearance_mode`
        // had no effect inside a host that pins its own style.
        newWindow.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        newWindow.frame = windowScene.coordinateSpace.bounds
        newWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1000)
        newWindow.backgroundColor = .clear

        let sourceWindow = windowScene.windows.first(where: \.isKeyWindow)
        let orientationSource = sourceWindow?.rootViewController.map { topViewController(from: $0) }

        // Create hosting controller
        let hosting = PresentationHostingController(
            rootView: rootView,
            orientationSource: orientationSource
        )
        hosting.modalPresentationStyle = .overFullScreen
        hosting.view.backgroundColor = .clear

        if #available(iOS 18.0, *) {
            newWindow.rootViewController = UIViewController()
            newWindow.isHidden = false
        } else {
            // A UIKit modal containing another SwiftUI sheet stays transparent
            // on iOS 17. Host the container directly at the window root so its
            // own sheet/full-screen-cover presentation has a visible presenter.
            previousKeyWindow = sourceWindow
            newWindow.rootViewController = hosting
            newWindow.makeKeyAndVisible()
        }

        // Store references
        window = newWindow
        hostingController = hosting

        // iOS 17 already hosts the container at the window root.
        if #available(iOS 18.0, *) {
            newWindow.rootViewController?.present(hosting, animated: true)
        }
        return newWindow
    }

    // MARK: - Cleanup

    /// Cleans up the presentation window after dismissal.
    static func cleanup() {
        let handler = onDismissHandler
        let keyWindowToRestore = previousKeyWindow

        hostingController?.dismiss(animated: false)
        hostingController = nil
        window?.resignKey()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKeyWindow = nil
        onDismissHandler = nil
        keyWindowToRestore?.makeKey()

        // Fire handler after clearing state to prevent re-entrancy issues
        handler?()
    }

    #if DEBUG
        /// Test-only: set the dismiss handler without presenting a window.
        static func _setDismissHandler(_ handler: (() -> Void)?) {
            onDismissHandler = handler
        }
    #endif

    // MARK: - View Controller Discovery

    /// Finds the top-most presented view controller in the app's window hierarchy.
    static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController
        else {
            return nil
        }
        return topViewController(from: rootViewController)
    }

    /// Recursively traverses view controller hierarchy to find the top-most controller.
    static func topViewController(from viewController: UIViewController) -> UIViewController {
        if let presentedViewController = viewController.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        if let navigationController = viewController as? UINavigationController,
           let top = navigationController.topViewController
        {
            return topViewController(from: top)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selected = tabBarController.selectedViewController
        {
            return topViewController(from: selected)
        }
        return viewController
    }
}
