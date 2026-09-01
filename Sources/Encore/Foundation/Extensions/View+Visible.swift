//
//  View+Visible.swift
//  Encore
//
//  Generic SwiftUI primitive that fires a closure whenever a view occupies
//  at least a configurable fraction of its own area within the active
//  window's bounds. Used today for offer impression tracking on the
//  loaded primary creative; intentionally domain-free so other features
//  (exposure events, viewport-driven prefetch, A/B variant exposure
//  signals) can reach for it without coupling to ads.
//

import SwiftUI
import UIKit

extension View {
    /// Invokes `action` whenever this view occupies at least `threshold`
    /// of its own area within the active window's bounds.
    ///
    /// Stateless — `action` may fire multiple times as scroll, rotation,
    /// or layout transitions cause the frame to change while the
    /// threshold remains satisfied. Callers that need "fire exactly
    /// once" semantics must dedupe at a level whose lifetime outlasts
    /// the view itself: SwiftUI may recycle (LazyVStack), recreate
    /// (conditional branches), or rebuild the underlying view, resetting
    /// any modifier `@State`. The dedup ledger belongs higher up the tree.
    ///
    /// `threshold` is a fraction of the view's own area, not the screen.
    /// `0.5` ≈ IAB Viewable Impression definition (≥ 50% on screen).
    /// `0` means "any pixel intersects." Defaults to `0.5`.
    ///
    /// Uses the active window's bounds (not `UIScreen.main.bounds`), so
    /// iPad multi-scene / Stage Manager / Slide Over presentations
    /// report visibility against the host app's actual window, not the
    /// physical screen.
    func onVisible(
        threshold: Double = 0.5,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(VisibilityProbe(threshold: threshold, action: action))
    }
}

private struct VisibilityProbe: ViewModifier {
    let threshold: Double
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { evaluate(frame: proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { frame in
                        // Single-argument `onChange` (iOS 14+) — keeps the
                        // primitive available below iOS 17. The two-argument
                        // (`old, new`) form would gate the whole API.
                        evaluate(frame: frame)
                    }
            }
        )
    }

    private func evaluate(frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let bounds = Self.activeWindowBounds
        let intersection = frame.intersection(bounds)
        let visibleArea = intersection.width * intersection.height
        let totalArea = frame.width * frame.height
        guard totalArea > 0, visibleArea / totalArea >= threshold else { return }
        action()
    }

    /// Active window's bounds — correct for iPad multi-scene presentations
    /// where `UIScreen.main.bounds` would over-report visibility against
    /// pixels the user can't actually see.
    private static var activeWindowBounds: CGRect {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.bounds ?? UIScreen.main.bounds
    }
}
