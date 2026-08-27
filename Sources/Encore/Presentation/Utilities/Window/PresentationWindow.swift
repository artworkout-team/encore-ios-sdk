// Presentation/Utils/Window/PresentationWindow.swift
//
// UIWindow utilities for presentation management.
// Encapsulates UIKit bridging for SwiftUI overlay presentation.
//

import UIKit
import SwiftUI

/// Manages presentation windows and view controller discovery.
///
/// This is the SDK's UIKit escape hatch for "present above everything" semantics.
/// SwiftUI views are hosted in a custom `UIWindow` at the highest window level.
///
/// Thread Safety: All operations are `@MainActor` isolated.
internal extension OfferContext.AppearanceMode {
    /// `.unspecified` for `auto` so the sheet inherits the HOST app rather than
    /// the device — a light-only publisher should not get a dark sheet.
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .auto:  return .unspecified
        }
    }
}

@MainActor
private final class PresentationHostingController<Content: View>: UIHostingController<Content> {
    private let orientationMask: UIInterfaceOrientationMask
    private let preferredOrientation: UIInterfaceOrientation
    private let allowsAutorotation: Bool
    
    init(
        rootView: Content,
        orientationMask: UIInterfaceOrientationMask,
        preferredOrientation: UIInterfaceOrientation,
        allowsAutorotation: Bool
    ) {
        self.orientationMask = orientationMask
        self.preferredOrientation = preferredOrientation
        self.allowsAutorotation = allowsAutorotation
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        orientationMask
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        preferredOrientation
    }

    override var shouldAutorotate: Bool {
        allowsAutorotation
    }
}

@MainActor
internal enum PresentationWindow {
    // MARK: - Window State
    
    /// The custom window used for presenting offer sheets.
    private(set) static var window: UIWindow?
    
    /// The hosting controller for the presented SwiftUI view.
    private static var hostingController: UIViewController?
    
    /// The host window restored after the Encore overlay closes. Weak so the
    /// SDK never extends the host window's lifetime.
    private weak static var previousKeyWindow: UIWindow?

    /// Called when the window is dismissed (cleanup, swipe-away, etc.)
    private static var onDismissHandler: (() -> Void)?
    
    /// Whether an offer sheet is currently presented.
    static var isPresented: Bool { window != nil }
    
    // MARK: - Present SwiftUI View
    
    /// Presents a SwiftUI view in a transparent overlay `UIWindow` above all other content.
    /// Returns the created window on success, nil when no window scene is available.
    /// `overrideUserInterfaceStyle` forces the sheet's appearance; `.unspecified` (the
    /// default) inherits the host app, which is what `auto` means.
    /// `onDismiss` fires when the window is cleaned up (dismissal, system removal, etc).
    @discardableResult
    static func present<Content: View>(
        _ rootView: Content,
        presentationStyle: SDUIPresentationStyle,
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
        let sourceRootViewController = sourceWindow?.rootViewController
        let orientationMask = supportedInterfaceOrientationsFromInfoPlist()
            ?? UIApplication.shared.delegate?.application?(
                UIApplication.shared,
                supportedInterfaceOrientationsFor: sourceWindow
            )
            ?? sourceRootViewController?.supportedInterfaceOrientations
            ?? .all
        let preferredOrientation = windowScene.interfaceOrientation
        
        // Create hosting controller
        let hosting = PresentationHostingController(
            rootView: rootView,
            orientationMask: orientationMask,
            preferredOrientation: preferredOrientation,
            allowsAutorotation: sourceRootViewController?.shouldAutorotate ?? true
        )
        hosting.modalPresentationStyle = .overFullScreen
        hosting.modalTransitionStyle = .coverVertical
        hosting.view.backgroundColor = .clear

        // Sheets use SwiftUI's own presentation from a root-hosted container.
        // Full-screen content is rendered directly by OfferSheetContainer and
        // presented once through UIKit's cover-vertical modal transition.
        let hostsDirectlyAtRoot = presentationStyle == .sheet

        if hostsDirectlyAtRoot {
            newWindow.rootViewController = hosting
        } else {
            let presentingController = UIViewController()
            presentingController.view.backgroundColor = .clear
            newWindow.rootViewController = presentingController
        }

        previousKeyWindow = sourceWindow
        
        // Store references
        window = newWindow
        hostingController = hosting
        
        newWindow.makeKeyAndVisible()

        if !hostsDirectlyAtRoot {
            newWindow.rootViewController?.present(hosting, animated: true)
        }
        return newWindow
    }

    private static func supportedInterfaceOrientationsFromInfoPlist() -> UIInterfaceOrientationMask? {
        let idiomSuffix = UIDevice.current.userInterfaceIdiom == .pad ? "~ipad" : "~iphone"
        let info = Bundle.main.infoDictionary
        let orientationNames = info?["UISupportedInterfaceOrientations\(idiomSuffix)"] as? [String]
            ?? info?["UISupportedInterfaceOrientations"] as? [String]
        guard let orientationNames, !orientationNames.isEmpty else { return nil }

        return orientationNames.reduce(into: UIInterfaceOrientationMask(rawValue: 0)) { mask, orientationName in
            switch orientationName {
            case "UIInterfaceOrientationPortrait": mask.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown": mask.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft": mask.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight": mask.insert(.landscapeRight)
            default: break
            }
        }
    }
    
    // MARK: - Cleanup

    /// Dismisses the presented hosting controller before removing its window.
    /// Root-hosted sheets have already animated out through SwiftUI, so they
    /// fall through to immediate teardown even when `animated` is true.
    static func cleanup(animated: Bool = false, completion: (() -> Void)? = nil) {
        let handler = onDismissHandler
        let keyWindowToRestore = previousKeyWindow
        let hostingControllerToDismiss = hostingController
        let windowToRemove = window
        onDismissHandler = nil
        
        let finish = {
            if hostingController === hostingControllerToDismiss {
                hostingController = nil
            }
            if window === windowToRemove {
                windowToRemove?.resignKey()
                windowToRemove?.isHidden = true
                windowToRemove?.rootViewController = nil
                window = nil
                previousKeyWindow = nil
                keyWindowToRestore?.makeKey()
            }

            // Fire callbacks after clearing state to prevent re-entrancy.
            handler?()
            completion?()
        }

        guard animated,
              let hostingControllerToDismiss,
              hostingControllerToDismiss.presentingViewController != nil
        else {
            hostingControllerToDismiss?.dismiss(animated: false)
            finish()
            return
        }

        hostingControllerToDismiss.dismiss(animated: true, completion: finish)
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
              let rootViewController = window.rootViewController else {
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
           let top = navigationController.topViewController {
            return topViewController(from: top)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selected = tabBarController.selectedViewController {
            return topViewController(from: selected)
        }
        return viewController
    }
}
