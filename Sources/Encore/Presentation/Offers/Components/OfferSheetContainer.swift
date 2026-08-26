//
//  OfferSheetContainer.swift
//  Encore
//
//  SwiftUI container that hosts the offer sheet and manages presentation states.
//  Renamed from OfferSheetPresenter to avoid confusion with OfferPresenter.
//

import SwiftUI

/// Container view that hosts the offer sheet presentation flow.
///
/// Manages transitions between:
/// - Offers view (carousel of available offers)
/// - Credit claimed view (success confirmation)
///
/// This is a pure SwiftUI view with no UIKit dependencies. The UIKit window
/// management is handled by `PresentationWindow`.
@available(iOS 16.0, *)
struct OfferSheetContainer: View {
    
    // MARK: - Presentation State
    
    enum PresentationState: Identifiable {
        case offers
        case creditClaimed(amount: Double, result: Result<PresentationResult, EncoreError>)
        
        var id: String {
            switch self {
            case .offers: return "offers"
            case .creditClaimed: return "creditClaimed"
            }
        }
    }
    
    // MARK: - Properties
    
    let offerResponse: OfferResponse
    let userId: String
    let presentationId: String
    let placementId: String
    /// Publisher-chosen label, or nil when the placement id was auto-generated.
    /// The only placement value stamped on this presentation's analytics.
    let placementLabel: String?
    let offerContext: OfferContext
    let initialStateOverride: String?
    /// True when the IAP-first flow completed a real purchase before this
    /// sheet appeared — staged as the `.purchased` result floor.
    var initiallyPurchased: Bool = false
    let onCompletion: (Result<PresentationResult, EncoreError>) -> Void
    
    @State private var presentationState: PresentationState?
    
    /// Presentation style from cached server config, resolved for this
    /// presentation's use case.
    private var presentationStyle: SDUIPresentationStyle {
        sduiConfigManager?.layout(for: offerContext.useCase)?.presentationStyle ?? .sheet
    }
    
    // MARK: - Body
    
    var body: some View {
        Color.clear
            .modifier(PresentationStyleModifier(
                presentationStyle: presentationStyle,
                presentationState: $presentationState,
                content: { state in
                    presentationContent(for: state)
                }
            ))
            .onAppear {
                // iOS 17 does not present a sheet whose item is already
                // non-nil before the hosting view joins a window. Trigger the
                // first presentation only after the container is attached.
                guard presentationState == nil else { return }
                presentationState = .offers
            }
            .onDisappear {
                // Coordinator's complete() owns cleanup.
                #if DEBUG
                if PresentationWindow.isPresented {
                    Logger.warn(.presentation, "Window still present after onDisappear")
                }
                #endif
            }
    }
    
    // MARK: - Presentation Content
    
    @ViewBuilder
    private func presentationContent(for state: PresentationState) -> some View {
        switch state {
        case .offers:
            OfferSheetView(
                offerResponse: offerResponse,
                userId: userId,
                presentationId: presentationId,
                placementId: placementId,
                placementLabel: placementLabel,
                offerContext: offerContext,
                initialStateOverride: initialStateOverride,
                initiallyPurchased: initiallyPurchased,
                onDismiss: {
                    presentationState = nil
                },
                onCompletion: { result in
                    handleOfferSheetCompletion(result)
                }
            )
            // No global safe-area ignore here. Safe-area policy is owned by the
            // SDUI root in OfferSheetView (SDUIRootSafeAreaModifier): on
            // fullScreenCover the root bleeds so a full-bleed background fills
            // all four safe areas, and the CONTENT re-insets itself via the
            // per-element `style.safeAreaPadding`; on sheet, natural behavior is
            // kept. `respectsSafeArea: false` opts the whole tree out.

        case .creditClaimed(let amount, let result):
            CreditClaimedView(
                credit: CreditData(amount: amount),
                offerContext: offerContext
            ) {
                handleCreditClaimedDismiss(result: result)
            }
            .presentationDetents([.fraction(0.32)])
            .presentationDragIndicator(.hidden)
            .compatiblePresentationCornerRadius(OfferSheetStyles.cornerRadius)
            .compatiblePresentationBackground(OfferSheetStyles.backgroundColor)
        }
    }
    
    // MARK: - Handlers
    
    private func handleOfferSheetCompletion(_ result: Result<PresentationResult, EncoreError>) {
        onCompletion(result)
    }
    
    private func handleCreditClaimedDismiss(result: Result<PresentationResult, EncoreError>) {
        presentationState = nil
    }
}

// MARK: - Supporting Types

struct CreditData: Identifiable {
    let id = UUID()
    let amount: Double
}

// MARK: - Presentation Style Modifier

/// A ViewModifier that conditionally presents content as either a sheet or fullScreenCover
@available(iOS 16.0, *)
struct PresentationStyleModifier<PresentationContent: View>: ViewModifier {
    let presentationStyle: SDUIPresentationStyle
    @Binding var presentationState: OfferSheetContainer.PresentationState?
    let content: (OfferSheetContainer.PresentationState) -> PresentationContent
    
    func body(content baseContent: Content) -> some View {
        switch presentationStyle {
        case .sheet:
            baseContent
                .sheet(item: $presentationState) { state in
                    self.content(state)
                }
        case .fullScreenCover:
            baseContent
                .fullScreenCover(item: $presentationState) { state in
                    self.content(state)
                }
        }
    }
}
