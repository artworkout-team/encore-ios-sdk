//
//  SafariView.swift
//  Encore
//

import SwiftUI
import SafariServices

// MARK: - Safari Tracking Events
enum SafariTrackingEvent {
    case attemptingToOpen(url: URL)
    case didOpen(url: URL, openedAt: Date)
    case initialLoadCompleted(url: URL, didLoadSuccessfully: Bool)
    case initialRedirect(from: URL, to: URL)  // Only during initial load, not subsequent navigation
    case dismissed(timeSpentSeconds: TimeInterval)
}

/// Callback type for Safari tracking events
typealias SafariTrackingHandler = (SafariTrackingEvent) -> Void

// MARK: - Safari View

@available(iOS 17.0, *)
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onTrackingEvent: SafariTrackingHandler?
    
    init(url: URL, onTrackingEvent: SafariTrackingHandler? = nil) {
        self.url = url
        self.onTrackingEvent = onTrackingEvent
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        // Track attempt to open
        onTrackingEvent?(.attemptingToOpen(url: url))
        
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        
        let safariVC = SFSafariViewController(url: url, configuration: configuration)
        safariVC.delegate = context.coordinator
        safariVC.dismissButtonStyle = .done
        
        // Record open time and track successful open
        let openedAt = Date()
        context.coordinator.openedAt = openedAt
        self.onTrackingEvent?(.didOpen(url: self.url, openedAt: openedAt))
        
        return safariVC
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // Update coordinator's reference if URL changes
        context.coordinator.currentURL = url
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var parent: SafariView
        var currentURL: URL
        var initialURL: URL
        var openedAt: Date = Date()
        
        init(_ parent: SafariView) {
            self.parent = parent
            self.currentURL = parent.url
            self.initialURL = parent.url
            super.init()
        }
        
        // MARK: - SFSafariViewControllerDelegate
        
        /// Called when the initial URL load completes (success or failure)
        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            parent.onTrackingEvent?(.initialLoadCompleted(
                url: currentURL,
                didLoadSuccessfully: didLoadSuccessfully
            ))
            
            if didLoadSuccessfully {
                Logger.debug(.presentation, "Initial load completed successfully: \(currentURL)")
            } else {
                Logger.debug(.presentation, "Initial load failed: \(currentURL)")
            }
        }
        
        /// Called when the initial load redirects to a different URL
        /// Note: This only fires during the initial page load, NOT for subsequent user navigation
        func safariViewController(_ controller: SFSafariViewController, initialLoadDidRedirectTo URL: URL) {
            let previousURL = currentURL
            currentURL = URL
            
            parent.onTrackingEvent?(.initialRedirect(from: previousURL, to: URL))
            Logger.debug(.presentation, "Initial redirect from \(previousURL) to \(URL)")
        }
        
        /// Called when user taps the Done button
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            let timeSpent = Date().timeIntervalSince(openedAt)
            parent.onTrackingEvent?(.dismissed(timeSpentSeconds: timeSpent))
            Logger.debug(.presentation, "Dismissed after \(String(format: "%.1f", timeSpent))s")
        }
    }
}

struct SafariURLWrapper: Identifiable {
    let id = UUID()
    let url: URL
}

