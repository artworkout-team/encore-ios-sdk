//
//  FallbackSwiftView.swift
//  Encore
//
//  SwiftUI view and components for the fallback (non-SDUI) offer sheet layout.
//

import Combine
import SwiftUI

// MARK: - Fallback Offer Sheet View

@available(iOS 17.0, *)
struct FallbackOfferSheetView: View {
    @ObservedObject var viewModel: OfferSheetViewModel
    let preferredColorScheme: ColorScheme?
    var isClaimDisabled: Bool = false
    let onClose: () -> Void
    let onSafariEvent: (SafariTrackingEvent) -> Void
    let onSafariDismiss: () -> Void

    @State private var trackedOfferIndex: Int?
    
    private var accentColor: Color { Self.accent(for: viewModel.offerContext) }

    /// Placement accent > server accent > fallback blue. Only the accent applies here:
    /// this view's subviews hard-code their own text colours.
    static func accent(for context: OfferContext) -> Color {
        if let override = context.appearance?.accentColor.flatMap(AppearanceHex.parse) {
            return override.color
        }
        if let hex = context.accentColor {
            return Color(hex: hex)
        }
        return OfferSheetStyles.accentBlue
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            OfferSheetStyles.backgroundColor
                .ignoresSafeArea()
            
            mainContent
        }
        .presentationDetents([.fraction(0.48), .fraction(0.95)])
        .presentationCornerRadius(OfferSheetStyles.cornerRadius)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
        .preferredColorScheme(preferredColorScheme)
        .sheet(item: $viewModel.safariSheetWrapper) { wrapper in
            SafariView(url: wrapper.url) { event in
                onSafariEvent(event)
            }
            .presentationDetents([.fraction(0.95)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(OfferSheetStyles.safariCornerRadius)
            .interactiveDismissDisabled(false)
            .onDisappear {
                Logger.info(.presentation, "Safari dismissed")
                onSafariDismiss()
            }
        }
        .onReceive(viewModel.$currentOfferIndex.removeDuplicates()) { newIndex in
            guard let newIndex else { return }
            defer { trackedOfferIndex = newIndex }

            if let trackedOfferIndex, trackedOfferIndex != newIndex {
                viewModel.trackOfferSwipe(from: trackedOfferIndex, to: newIndex)
            }
            viewModel.trackOfferImpression(at: newIndex)
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            SheetHeaderView(
                offerContext: viewModel.offerContext,
                onClose: onClose
            )
            
            CarouselView(
                offers: viewModel.visibleOffers,
                currentIndex: $viewModel.currentOfferIndex,
                offerContext: viewModel.offerContext,
                isClaimDisabled: isClaimDisabled,
                onOfferTap: viewModel.handleOfferTap
            )
            .layoutPriority(1)
            .padding(.top, 20)
            
            // Page indicators centered between carousel and bottom
            if viewModel.visibleOffers.count > 1 {
                Spacer()
                CompactPageIndicator(
                    totalPages: viewModel.visibleOffers.count,
                    currentPage: viewModel.currentOfferIndex ?? 0,
                    activeColor: accentColor,
                    inactiveColor: OfferSheetStyles.indicatorGray
                )
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .ignoresSafeArea(edges: .bottom)
    }    
}

// MARK: - Sheet Header

@available(iOS 17.0, *)
struct SheetHeaderView: View {
    let offerContext: OfferContext
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Grabber Handle
            RoundedRectangle(cornerRadius: 2.5)
                .fill(OfferSheetStyles.grabberGray)
                .frame(width: OfferSheetStyles.grabberWidth, height: OfferSheetStyles.grabberHeight)
                .padding(.top, 8)
            
            // Close Button
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(OfferSheetStyles.closeButtonFont)
                        .foregroundColor(OfferSheetStyles.closeButtonGray)
                }
                .accessibilityLabel(Text(verbatim: offerContext.strings[.modalClose]))
                .padding(.trailing, 16)
                .padding(.top, 2)
            }
            
            // Title and Subtitle
            VStack(alignment: .leading, spacing: 8) {
                copy.headline.reduce(Text(verbatim: "")) { text, run in
                    text + Text(run.text)
                        .foregroundColor(run.isHighlighted ? accentTitleColor : OfferSheetStyles.primaryText)
                }
                .font(OfferSheetStyles.titleFont)
                .fixedSize(horizontal: false, vertical: true)

                if let subheadline = copy.subheadline {
                    Text(subheadline)
                        .font(OfferSheetStyles.subtitleFont)
                        .foregroundColor(OfferSheetStyles.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OfferSheetStyles.horizontalPadding)
            .padding(.top, 8)
        }
    }

    private var copy: SheetHeaderCopy { SheetHeaderCopy(offerContext: offerContext) }

    private var accentTitleColor: Color {
        if let colorHex = offerContext.accentTitleColor {
            return Color(hex: colorHex)
        }
        return Color(hex: "#16BD25")
    }
}

// MARK: - Sheet Header Copy

/// The fallback header's copy decision, resolved without a renderer so the
/// use-case branch is testable the way `SDUIInlineMarkup` is.
struct SheetHeaderCopy: Equatable {
    /// Highlighted runs carry the accent color. Churn splits its accent into a
    /// separate field; reward carries it inline as `*marked*`, because reward
    /// copy reaches the SDK as one substituted string.
    let headline: [SDUIInlineMarkup.Run]
    /// `nil` renders nothing. Absent reward subcopy is a real state: the
    /// template branches on it, so no default is invented here.
    let subheadline: String?

    /// Churn priority: host copy > dashboard copy > shipped default.
    init(offerContext: OfferContext, strings: SDKStrings? = nil) {
        let strings = strings ?? offerContext.strings
        switch offerContext.useCase {
        case .reduceChurn:
            if let headline = offerContext.churnHeadlineOverride {
                self.headline = SDUIInlineMarkup.parse(headline)
            } else {
                var accent = offerContext.accentTitleText ?? strings[.fallbackHeadlineAccent]
                if !accent.isEmpty, !accent.hasPrefix(" ") { accent = " " + accent }
                self.headline = [
                    SDUIInlineMarkup.Run(text: offerContext.titleText ?? strings[.fallbackHeadline], isHighlighted: false),
                    SDUIInlineMarkup.Run(text: accent, isHighlighted: true),
                ]
            }
            subheadline = offerContext.churnSubheadlineOverride
                ?? offerContext.subtitleText
                ?? strings[.fallbackSubheadline]
        case .rewardUsers:
            headline = SDUIInlineMarkup.parse(offerContext.headlineText ?? "")
            let sub = offerContext.subheadlineText
            subheadline = (sub?.isEmpty ?? true) ? nil : sub
        }
    }
}

// MARK: - Instructions

@available(iOS 17.0, *)
struct InstructionsView: View {
    let offer: Offer
    
    var body: some View {
        let instructions = offer.displayInstructions
        if let quickInstructions = offer.displayQuickInstructions {
            VStack(alignment: .leading, spacing: 8) {
                Text(quickInstructions)
                    .font(OfferSheetStyles.instructionTitleFont)
                    .foregroundColor(OfferSheetStyles.primaryText)
                    .multilineTextAlignment(.leading)
                
                if !instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(instructions, id: \.title) { instruction in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: "•")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(OfferSheetStyles.primaryText)
                                Text(instruction.title)
                                    .font(OfferSheetStyles.instructionBulletFont)
                                    .foregroundColor(OfferSheetStyles.primaryText)
                                    .lineSpacing(2)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OfferSheetStyles.horizontalPadding)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


// MARK: - Carousel

@available(iOS 17.0, *)
struct CarouselView: View {
    let offers: [Offer]
    @Binding var currentIndex: Int?
    let offerContext: OfferContext
    var isClaimDisabled: Bool = false
    let onOfferTap: @MainActor (Offer) -> Void

    var body: some View {
        ScrollOfferPager(
            offers: offers,
            currentIndex: $currentIndex,
            offerContext: offerContext,
            isClaimDisabled: isClaimDisabled,
            onOfferTap: onOfferTap
        )
    }
}

@available(iOS 17.0, *)
private struct ScrollOfferPager: View {
    let offers: [Offer]
    @Binding var currentIndex: Int?
    let offerContext: OfferContext
    let isClaimDisabled: Bool
    let onOfferTap: @MainActor (Offer) -> Void
    @State private var scrollPosition: Int?

    init(
        offers: [Offer],
        currentIndex: Binding<Int?>,
        offerContext: OfferContext,
        isClaimDisabled: Bool,
        onOfferTap: @escaping @MainActor (Offer) -> Void
    ) {
        self.offers = offers
        self._currentIndex = currentIndex
        self.offerContext = offerContext
        self.isClaimDisabled = isClaimDisabled
        self.onOfferTap = onOfferTap
        self._scrollPosition = State(initialValue: currentIndex.wrappedValue)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                        OfferCardView(offer: offer, offerContext: offerContext, isClaimDisabled: isClaimDisabled) {
                            onOfferTap(offer)
                        }
                        .padding(.horizontal, OfferSheetStyles.carouselMargin)
                        .frame(width: geometry.size.width)
                        .background {
                            GeometryReader { pageGeometry in
                                Color.clear.preference(
                                    key: OfferPageCenterPreferenceKey.self,
                                    value: [index: pageGeometry.frame(in: .global).midX]
                                )
                            }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollPosition.animation(.default))
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .onPreferenceChange(OfferPageCenterPreferenceKey.self) { pageCenters in
                updateVisiblePage(from: pageCenters, viewportCenter: geometry.frame(in: .global).midX)
            }
        }
    }

    private func updateVisiblePage(from pageCenters: [Int: CGFloat], viewportCenter: CGFloat) {
        guard let visiblePage = pageCenters.min(by: {
            abs($0.value - viewportCenter) < abs($1.value - viewportCenter)
        }),
              visiblePage.key != currentIndex
        else { return }
        currentIndex = visiblePage.key
    }
}

private struct OfferPageCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}
