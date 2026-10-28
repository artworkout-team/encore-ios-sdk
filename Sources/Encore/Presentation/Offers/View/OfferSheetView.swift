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

    /// The layout this presentation renders, taken once when it mounts: a config
    /// that lands mid-sheet (a language change) must not swap the template
    /// under the context's copy, and the recursive config tree stays out of
    /// repeated config lookups during body evaluation.
    @State private var config: SDUIConfig?
    /// The variant and experiment analytics report, taken with `config`.
    @State private var variantId: String?
    @State private var experimentId: String?

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
    private let presentationHost: OfferSheetPresentationHost
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
        layout: PresentationLayout? = nil,
        presentationHost: OfferSheetPresentationHost,
        onDismiss: @escaping () -> Void,
        onCompletion: @escaping (Result<PresentationResult, EncoreError>) -> Void
    ) {
        self.initialStateOverride = initialStateOverride
        self.presentationHost = presentationHost
        self.onDismiss = onDismiss
        let layout = layout ?? sduiConfigManager?.presentationLayout(for: offerContext.useCase, strings: offerContext.strings)
        _config = State(initialValue: layout?.config)
        _variantId = State(initialValue: layout?.variantId)
        _experimentId = State(initialValue: layout?.experimentId)

        let handler = SheetDismissHandler(onCompletion: onCompletion, initiallyPurchased: initiallyPurchased)
        _viewModel = StateObject(wrappedValue: OfferSheetViewModel(
            offerResponse: offerResponse,
            userId: userId,
            presentationId: presentationId,
            placementId: placementId,
            placementLabel: placementLabel,
            offerContext: offerContext,
            completionHandler: handler,
            layout: layout?.config,
            claimVariantId: layout?.renderedVariantId
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
                fallbackContent
            }
        }
        .overlay {
            if viewModel.verificationState != .idle {
                VerificationPendingView(
                    strings: viewModel.offerContext.strings,
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
        .onAppear {
            setupContext()

            // Set variant metadata for analytics
            viewModel.setVariantMetadata(
                variantId: variantId,
                experimentId: experimentId,
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
                    viewModel.handleSDUIAction(onEnterAction, offer: sduiContext.currentOffer, trigger: .onEnter)
                }
            }

            // Prefill email from developer-provided user attributes if not already set
            if sduiContext.values["email"]?.isEmpty != false,
               let email = entitlementsManager?.userAttributes.email, !email.isEmpty
            {
                sduiContext.values["email"] = email
            }

            // After the config's initial values are in: it replaces the dictionary.
            viewModel.preparePublisherReward(config: config, context: sduiContext)
            // After the initial state and selection are in, so an initial preload state counts.
            viewModel.startStepsPreload(on: sduiContext)

            // Offer impressions come from the offer row's visibility probe.
            // A featured offer drawn outside a row falls back to its primary
            // creative.
            viewModel.startTimeTracking()
        }
        .onDisappear {
            Logger.info(.presentation, "onDisappear fired")
            viewModel.endStepsPreload()

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

    private var fallbackContent: some View {
        FallbackOfferSheetView(
            viewModel: viewModel,
            preferredColorScheme: preferredColorScheme,
            isClaimDisabled: !sduiContext.isClaimEnabled,
            onClose: {
                viewModel.completionHandler.stageDismissal(.userTappedClose)
                Self.requestDismissal(
                    presentationHost: presentationHost,
                    completionHandler: viewModel.completionHandler,
                    onDismiss: onDismiss
                )
            },
            onSafariEvent: viewModel.handleSafariTrackingEvent,
            onSafariDismiss: viewModel.handleSafariDismiss
        )
    }

    // MARK: - SDUI Content

    @available(iOS 17.0, *)
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
            presentationStyle: presentationHost.contentPresentationStyle
        ))
        // Expose the active Appearance to ViewModifiers (e.g. SDUIBackgroundModifier)
        // so `{"appearance": "accent"}` in variant JSON resolves to the per-app brand color.
        .environment(\.sduiAppearance, sduiContext.appearance)
        .presentationDetents(detentsForCurrentState(loadedConfig))
        .applyCornerRadius(loadedConfig.cornerRadius)
        .presentationDragIndicator(loadedConfig.showDragIndicator == true ? .visible : .hidden)
        .presentationBackground(sduiContext.appearance.background)
        .interactiveDismissDisabled(false)
        .preferredColorScheme(preferredColorScheme)
        // Only one wrapper is ever set: the sheet is `.inAppSheet`; the cover is `.inAppBrowser` and the
        // `.external` fallback. Both dismiss through `handleSafariDismiss()`, so the grant is identical.
        .sheet(item: $viewModel.safariSheetWrapper) { wrapper in
            safariSheet(for: wrapper)
        }
        .fullScreenCover(item: $viewModel.safariCoverWrapper) { wrapper in
            safariCover(for: wrapper)
        }
        // `.inAppPreload`: claim screen, hidden web view, then the in-app browser.
        // The two × are the exits; any other disappearance is settled the same way.
        .fullScreenCover(item: $viewModel.claimPreload) { controller in
            ClaimPreloadCover(
                controller: controller,
                strings: viewModel.offerContext.strings,
                onClose: { viewModel.handleClaimPreloadClosed() },
                onEscape: { viewModel.handleClaimPreloadEscaped() }
            )
            .preferredColorScheme(.light)
            // A cover is its own presentation: carry the served direction into it.
            .modifier(ServedLayoutDirectionModifier(locale: viewModel.offerContext.servedLocale))
            .interactiveDismissDisabled()
            .onDisappear { viewModel.handleClaimPreloadDisappeared(controller) }
        }
        // Rows under the claim screen are not seen; they are checked again when it lifts.
        .environment(\.visibilityProbesPaused, viewModel.claimPreload != nil)
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
        viewModel.bind(sduiContext: sduiContext) { [weak viewModel] in
            guard let completionHandler = viewModel?.completionHandler else { return }
            Self.requestDismissal(
                presentationHost: presentationHost,
                completionHandler: completionHandler,
                onDismiss: onDismiss
            )
        }
        sduiContext.onAction = { [weak viewModel] action, offer in
            viewModel?.handleSDUIAction(action, offer: offer)
        }
        sduiContext.onOfferVisible = { [weak viewModel] offer, displayIndex, _ in
            viewModel?.trackSDUIOfferImpression(offer, displayIndex: displayIndex)
        }
    }

    private static func requestDismissal(
        presentationHost: OfferSheetPresentationHost,
        completionHandler: SheetDismissHandler,
        onDismiss: () -> Void
    ) {
        switch presentationHost {
        case .managedWindow(.sheet):
            onDismiss()
        case .managedWindow(.fullScreenCover):
            completionHandler.handleImmediate(dismissal: completionHandler.resolvedDismissal)
        case .viewController:
            completionHandler.handleImmediate(dismissal: completionHandler.resolvedDismissal)
            onDismiss()
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
    @available(iOS 17.0, *)
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
    @available(iOS 17.0, *)
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
            Text(verbatim: "Offer Sheet Preview")
        }
}
