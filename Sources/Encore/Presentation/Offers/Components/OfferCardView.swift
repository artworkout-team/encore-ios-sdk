//
//  OfferCardView.swift
//  Encore
//

import SwiftUI

@available(iOS 17.0, *)
struct OfferCardView: View {
    let offer: Offer
    let offerContext: OfferContext
    var isClaimDisabled: Bool = false
    let onTap: () -> Void
    
    /// Returns the accent color from configuration or default
    private var accentColor: Color {
        if let colorHex = offerContext.accentColor {
            return Color(hex: colorHex)
        }
        return Color(hex: "#5671FF")
    }
    
    /// Card background color that adapts to system appearance
    private let cardBackgroundColor = Color(UIColor.secondarySystemGroupedBackground)
    
    /// Placeholder color that adapts to system appearance
    private let placeholderColor = Color(UIColor.tertiarySystemFill)
    
    /// Primary text color that adapts to system appearance
    private let primaryTextColor = Color(UIColor.label)
    
    /// Secondary text color that adapts to system appearance
    private let secondaryTextColor = Color(UIColor.secondaryLabel)
    
    /// Shadow color that adapts to system appearance
    private var shadowColor: Color {
        Color(UIColor.label).opacity(0.1)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Offer Image with AsyncImage (353x149 aspect ratio)
            AsyncImage(url: URL(string: offer.displayPrimaryImageUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure, .empty:
                    placeholderColor
                        .aspectRatio(353.0/149.0, contentMode: .fit)
                @unknown default:
                    placeholderColor
                        .aspectRatio(353.0/149.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .cornerRadius(16)
            
            // Content Container
            HStack(alignment: .center, spacing: 12) {
                // Left side: Square Logo with AsyncImage
                AsyncImage(url: URL(string: offer.displayLogoUrl ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure, .empty:
                        placeholderColor
                    @unknown default:
                        placeholderColor
                    }
                }
                .frame(width: 50, height: 50)
                .cornerRadius(8)
                .clipped()
                
                // Middle: Brand name and description
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.advertiserName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(primaryTextColor)
                        .lineLimit(1)
                    
                    if let description = offer.creativeAdvertiserDescription {
                        Text(description)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                }
                
                Spacer(minLength: 8)
                
                // Right side: CTA Button
                Button(action: onTap) {
                    Text(offer.displayCtaText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 27)
                        .padding(.vertical, 13)
                        .frame(minWidth: 80)
                        .background(accentColor)
                        .cornerRadius(.greatestFiniteMagnitude)
                }
                .disabled(isClaimDisabled)
                .opacity(isClaimDisabled ? 0.4 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackgroundColor)
        }
        .background(cardBackgroundColor)
        .cornerRadius(16)
        .shadow(color: shadowColor, radius: 4)
    }
}

