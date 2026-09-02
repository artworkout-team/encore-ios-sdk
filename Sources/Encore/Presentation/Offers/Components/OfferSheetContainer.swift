//
//  OfferSheetContainer.swift
//  Encore
//
//  SwiftUI container that hosts the offer sheet and manages presentation states.
//  Renamed from OfferSheetPresenter to avoid confusion with OfferPresenter.
//

import SwiftUI

enum OfferSheetPresentationHost {
    case managedWindow(SDUIPresentationStyle)
    case viewController

    var contentPresentationStyle: SDUIPresentationStyle {
        switch self {
        case .managedWindow(let presentationStyle): return presentationStyle
        case .viewController: return .fullScreenCover
        }
    }

    var rendersContentDirectly: Bool {
        switch self {
        case .managedWindow(.sheet): return false
        case .managedWindow(.fullScreenCover), .viewController: return true
        }
    }
}

/// Container view that hosts the offer sheet presentation flow.
///
/// Manages transitions between:
/// - Offers view (carousel of available offers)
/// - Credit claimed view (success confirmation)
///
/// This is a pure SwiftUI view with no UIKit dependencies. Its host owns the
/// surrounding window or view-controller navigation.
@available(iOS 17.0, *)
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
    let presentationHost: OfferSheetPresentationHost
    let onDismissRequest: () -> Void
    let onCompletion: (Result<PresentationResult, EncoreError>) -> Void
    
    @State private var presentationState: PresentationState?
    
    // MARK: - Body
    
    var body: some View {
        presentationRoot
            .onAppear {
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

    @ViewBuilder
    private var presentationRoot: some View {
        if presentationHost.rendersContentDirectly {
            if let presentationState {
                presentationContent(for: presentationState)
            } else {
                Color.clear
            }
        } else {
            sheetContainer
        }
    }

    private var sheetContainer: some View {
        Color.clear
            .sheet(item: $presentationState) { state in
                presentationContent(for: state)
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
                presentationHost: presentationHost,
                onDismiss: {
                    switch presentationHost {
                    case .managedWindow(.sheet):
                        presentationState = nil
                    case .managedWindow(.fullScreenCover):
                        break
                    case .viewController:
                        onDismissRequest()
                    }
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
            .presentationCornerRadius(OfferSheetStyles.cornerRadius)
            .presentationBackground(OfferSheetStyles.backgroundColor)
        }
    }
    
    // MARK: - Handlers
    
    private func handleOfferSheetCompletion(_ result: Result<PresentationResult, EncoreError>) {
        onCompletion(result)
    }
    
    private func handleCreditClaimedDismiss(result _: Result<PresentationResult, EncoreError>) {
        presentationState = nil
    }
}

// MARK: - Supporting Types

struct CreditData: Identifiable {
    let id = UUID()
    let amount: Double
}
