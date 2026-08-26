//
//  OfferSheetView.swift
//  Encore
//
//  Unified offer sheet view that uses server-driven UI by default,
//  with hardcoded fallback layout when SDUI config is unavailable.
//

import SwiftUI

// MARK: - Main Sheet View

@available(iOS 17.0, *)
struct OfferSheetView: View {
    @StateObject private var viewModel: OfferSheetViewModel
    @StateObject private var sduiContext: SDUIContext

    /// SDUI config from SDUIConfigurationManager, resolved for this
    /// presentation's use case (pre-fetched on identify for `.reduceChurn`, lazily
    /// on first presentation for every other use case).
    private var config: SDUIConfig? {
        sduiConfigManager?.layout(for: viewModel.offerContext.useCase)
    }

    /// Computed property to determine the preferred color scheme based on appearance mode
    private var preferredColorScheme: ColorScheme? {
        switch viewModel.offerContext.appearanceMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .auto:
            return nil // Follow system settings
        }
    }

    private let initialStateOverride: String?
    private let onDismiss: () -> Void

    init(
        offerResponse: OfferResponse,
        userId: String,
        presentationId: String,
        placementId: String,
        placementLabel: String?,
        offerContext: OfferContext,
        initialStateOverride: String? = nil,
        initiallyPurchased: Bool = false,
        onDismiss: @escaping () -> Void,
        onCompletion: @escaping (Result<PresentationResult, EncoreError>) -> Void
    ) {
        self.initialStateOverride = initialStateOverride
        self.onDismiss = onDismiss

        let handler = SheetDismissHandler(onCompletion: onCompletion, initiallyPurchased: initiallyPurchased)
        _viewModel = StateObject(wrappedValue: OfferSheetViewModel(
            offerResponse: offerResponse,
            userId: userId,
            presentationId: presentationId,
            placementId: placementId,
            placementLabel: placementLabel,
            offerContext: offerContext,
            completionHandler: handler
        ))

        // Create SDUI context with offer context (includes remote config + IAP data)
        _sduiContext = StateObject(wrappedValue: SDUIContext(
            offers: offerResponse.offerList,
            currentIndex: 0,
            offerContext: offerContext,
            onAction: { _, _ in } // Wired properly in setupContext
        ))
    }

    var body: some View {
        Group {
            if let loadedConfig = config {
                sduiContent(loadedConfig)
            } else {
                FallbackOfferSheetView(
                    viewModel: viewModel,
                    preferredColorScheme: preferredColorScheme,
                    isClaimDisabled: !sduiContext.isClaimEnabled,
                    onClose: {
                        viewModel.completionHandler.stageDismissal(.userTappedClose)
                        onDismiss()
                    },
                    onSafariEvent: viewModel.handleSafariTrackingEvent,
                    onSafariDismiss: viewModel.handleSafariDismiss
                )
            }
        }
        .overlay {
            if viewModel.verificationState != .idle {
                VerificationPendingView(
                    isTimedOut: viewModel.verificationState == .timedOut,
                    onRetry: { viewModel.retryVerification() },
                    onCancel: { viewModel.cancelVerification() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.verificationState != .idle)
        .transaction { transaction in
            // iOS 17 drives every active SDUI animation through root view
            // invalidation. A screen with several repeat-forever effects can
            // otherwise saturate the main thread before scene activation
            // completes. iOS 18+ does not exhibit this behavior, so preserve
            // its normal descendant animations.
            guard #unavailable(iOS 18.0),
                  viewModel.verificationState == .idle
            else { return }
            transaction.animation = nil
        }
        .onAppear {
            setupContext()

            // Set variant metadata for analytics
            viewModel.setVariantMetadata(
                variantId: sduiConfigManager?.variantId(for: viewModel.offerContext.useCase),
                context: sduiContext
            )

            // Initialize state machine if SDUI config available
            if let loadedConfig = config {
                let onEnterAction = sduiContext.initializeFromConfig(loadedConfig)

                // Apply state override if provided (e.g., from triggerIAPFirst success)
                if let stateOverride = initialStateOverride {
                    Logger.info(.presentation, "Applying initial state override: \(stateOverride)")
                    sduiContext.setState(stateOverride)
                } else if let onEnterAction = onEnterAction {
                    // Execute onEnter action for initial state (only if no override)
                    Logger.info(.presentation, "Executing onEnter action for initial state: \(sduiContext.currentState)")
                    viewModel.handleSDUIAction(onEnterAction, offer: sduiContext.currentOffer)
                }
            }

            // Prefill email from developer-provided user attributes if not already set
            if sduiContext.values["email"]?.isEmpty != false,
               let email = entitlementsManager?.userAttributes.email, !email.isEmpty {
                sduiContext.values["email"] = email
            }

            // Offer impressions are fired per-row by the renderer's ForEach
            // `.onAppear` via `context.onOfferVisible` — for carousel layouts
            // all rows mount eagerly (non-lazy hStack); for state-machine
            // layouts, only rows inside a currently-visible state mount. In
            // both cases `trackOfferImpression` dedupes on campaignId.
            viewModel.startTimeTracking()
        }
        .onDisappear {
            Logger.info(.presentation, "onDisappear fired")

            // A claim shadows the gesture on `decline_reason`, as it did in
            // 1.x, so historical row counts keep their meaning. Otherwise the
            // reason is whatever the result record carries, resolved once.
            viewModel.trackOfferClose(
                reason: viewModel.offerWasClaimed
                    ? .offerClaimed
                    : viewModel.completionHandler.resolvedDismissal
            )
            viewModel.completionHandler.handleOnDisappear()
        }
    }

    // MARK: - SDUI Content

    @ViewBuilder
    private func sduiContent(_ loadedConfig: SDUIConfig) -> some View {
        ZStack(alignment: .top) {
            SDUIElementRenderer(element: loadedConfig.root, context: sduiContext)
        }
        // Safe-area policy at the SDUI root. On fullScreenCover the root BLEEDS
        // so a full-bleed background (the gradient) fills all four safe areas
        // (no black top/bottom bands); the CONTENT vStack re-insets itself via
        // its `style.safeAreaPadding`. On sheet, natural safe-area behavior is
        // kept so existing sheet variants don't regress. `respectsSafeArea:
        // false` forces the bleed and lets the variant manage its own insets.
        .modifier(SDUIRootSafeAreaModifier(
            respectsSafeArea: loadedConfig.respectsSafeArea ?? true,
            presentationStyle: loadedConfig.presentationStyle ?? .default
        ))
        // Expose the active Appearance to ViewModifiers (e.g. SDUIBackgroundModifier)
        // so `{"appearance": "accent"}` in variant JSON resolves to the per-app brand color.
        .environment(\.sduiAppearance, Appearance(from: sduiContext.offerContext.uiValues))
        .presentationDetents(detentsForCurrentState(loadedConfig))
        .applyCornerRadius(loadedConfig.cornerRadius)
        .presentationDragIndicator(loadedConfig.showDragIndicator == true ? .visible : .hidden)
        .presentationBackground(Color(UIColor.systemGroupedBackground))
        .interactiveDismissDisabled(false)
        .preferredColorScheme(preferredColorScheme)
        // Two distinct in-app Safari presentations — only one wrapper is ever
        // non-nil. The SHEET (0.95 detent + drag indicator) is the old/default
        // (`.inAppSheet`) claim UX; the fullScreenCover is the opt-in
        // (`.inAppBrowser`). Both dismiss paths route through
        // `handleSafariDismiss()` so grant/transition are identical.
        .sheet(item: $viewModel.safariSheetWrapper) { wrapper in
            safariSheet(for: wrapper)
        }
        .fullScreenCover(item: $viewModel.safariCoverWrapper) { wrapper in
            safariCover(for: wrapper)
        }
        .onChange(of: sduiContext.currentIndex) { oldValue, newValue in
            viewModel.currentOfferIndex = newValue
            if let newIndex = newValue {
                // Swipe-axis analytics only. Impression-firing is owned
                // by `View.onVisible` on the loaded primary creative.
                viewModel.trackOfferSwipe(from: oldValue, to: newIndex)
            }
        }
    }

    // MARK: - Context Setup

    private func setupContext() {
        sduiContext.isClaimEnabled = Encore.shared.isClaimEnabled
        viewModel.bind(sduiContext: sduiContext, onDismiss: onDismiss)
        sduiContext.onAction = { [weak viewModel] action, offer in
            viewModel?.handleSDUIAction(action, offer: offer)
        }
        sduiContext.onOfferVisible = { [weak viewModel] index in
            viewModel?.trackOfferImpression(at: index)
        }
    }

    // MARK: - Detents

    private func detentsFromConfig(_ config: SDUIConfig) -> Set<PresentationDetent> {
        guard let detents = config.presentationDetents else {
            return [.fraction(0.48), .fraction(0.95)]
        }
        return Set(detents.map { PresentationDetent.fraction($0) })
    }

    private func detentsForCurrentState(_ config: SDUIConfig) -> Set<PresentationDetent> {
        let currentState = sduiContext.currentState

        if let stateDetents = config.stateDetents?[currentState] {
            return Set(stateDetents.map { PresentationDetent.fraction($0) })
        }

        return detentsFromConfig(config)
    }

    // MARK: - Safari Sheet

    /// Old/default in-app Safari, presented via `.sheet` at a `0.95` detent with
    /// a visible drag indicator — exact parity with the pre-redesign control
    /// behavior. Dismiss routes through `handleSafariDismiss()` to grant +
    /// transition.
    private func safariSheet(for wrapper: SafariURLWrapper) -> some View {
        SafariView(url: wrapper.url) { event in
            viewModel.handleSafariTrackingEvent(event)
        }
        .presentationDetents([.fraction(0.95)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(OfferSheetStyles.safariCornerRadius)
        .interactiveDismissDisabled(false)
        .onDisappear {
            Logger.info(.presentation, "Safari dismissed")
            viewModel.handleSafariDismiss()
        }
    }

    /// Opt-in (`.inAppBrowser`) in-app Safari, presented via `.fullScreenCover`
    /// so the browser covers the whole screen (no detent / drag indicator).
    /// Dismiss still routes through `handleSafariDismiss()` to grant + transition.
    private func safariCover(for wrapper: SafariURLWrapper) -> some View {
        SafariView(url: wrapper.url) { event in
            viewModel.handleSafariTrackingEvent(event)
        }
        .ignoresSafeArea()
        .interactiveDismissDisabled(false)
        .onDisappear {
            Logger.info("✅ Safari dismissed")
            viewModel.handleSafariDismiss()
        }
    }
}

// MARK: - View Extensions

@available(iOS 17.0, *)
private extension View {
    @ViewBuilder
    func applyCornerRadius(_ radius: CGFloat?) -> some View {
        if let radius = radius {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}

// MARK: - Preview

@available(iOS 17.0, *)
#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            Text("Offer Sheet Preview")
        }
}
