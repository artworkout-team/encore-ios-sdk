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
    
    /// The hero image's spoken name (`card.image`).
    static func imageAccessibilityLabel(_ offer: Offer, strings: SDKStrings) -> String {
        strings.format(.cardImage, ["offerName": offer.advertiserName])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Offer Image (353x149). Filled into a fixed-ratio frame so the card
            // keeps its height while the image loads. A campaign with no image
            // shows its logo on a 120pt tile instead of an empty box, as the web
            // card does.
            Group {
                if let imageUrl = SDUIImageSlotPlan.nonBlank(offer.displayPrimaryImageUrl) {
                    CachedAsyncImage(
                        url: URL(string: imageUrl),
                        contentMode: .fill,
                        placeholder: { placeholderColor }
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(353.0/149.0, contentMode: .fit)
                    .clipped()
                    .cornerRadius(16)
                } else {
                    SDUILogoTile(
                        logoURL: offer.tileLogoUrl.flatMap(URL.init(string:)),
                        background: Color(UIColor.secondarySystemBackground),
                        aspectRatio: nil,
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .cornerRadius(16)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.imageAccessibilityLabel(offer, strings: offerContext.strings)))
            .accessibilityAddTraits(.isImage)

            // Content Container
            HStack(alignment: .center, spacing: 12) {
                // Left side: square logo
                CachedAsyncImage(url: offer.displayLogoUrl.flatMap(URL.init(string:)), contentMode: .fit,
                                 placeholder: { placeholderColor }, shimmers: SDUILogoTile.logoShimmers,
                                 widthPoints: SDUIImageLoader.logoWidthPoints)
                .frame(width: 50, height: 50)
                .cornerRadius(8)
                .clipped()
                // The advertiser name beside it already says whose logo this is.
                .accessibilityHidden(true)
                
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
                    Text(offer.displayCtaText(offerContext.strings))
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
