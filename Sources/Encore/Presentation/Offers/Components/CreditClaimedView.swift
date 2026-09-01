//
//  CreditClaimedView.swift
//  Encore
//

import SwiftUI

@available(iOS 17.0, *)
struct CreditClaimedView: View {
    let credit: CreditData
    let offerContext: OfferContext
    let onDismiss: () -> Void
    
    @Environment(\.dismiss) var dismiss
    
    /// Primary text color that adapts to system appearance
    private let primaryTextColor = Color(UIColor.label)
    
    /// Secondary text color that adapts to system appearance
    private let secondaryTextColor = Color(UIColor.secondaryLabel)
    
    /// Close button color that adapts to system appearance
    private let closeButtonColor = Color(UIColor.tertiaryLabel)
    
    /// Accent blue for buttons
    private let accentBlue = Color(hex: "#5671FF")
    
    /// Computed property to determine the preferred color scheme based on appearance mode
    private var preferredColorScheme: ColorScheme? {
        switch offerContext.appearanceMode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .auto:
            return nil // Follow system settings
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(offerContext.creditClaimedTitleText ?? "Credit claimed!")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(primaryTextColor)
                    
                    Text(formatSubtitle())
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(closeButtonColor)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()           

            // Apply Credits Button
            Button {
                onDismiss()
            } label: {
                HStack(spacing: 8) {
                    Text(offerContext.applyCreditsButtonText ?? "Apply credits")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    
                    // Custom arrow icon
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(accentBlue)
                .cornerRadius(28)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(preferredColorScheme)
    }
    
    private func formatSubtitle() -> String {
        let productName = offerContext.instructionsTitleText ?? "your subscription"
        
        if let customSubtitle = offerContext.creditClaimedSubtitleText {
            // Use custom template and replace placeholders
            return customSubtitle
                .replacingOccurrences(of: "{amount}", with: "\(Int(credit.amount))")
                .replacingOccurrences(of: "{product}", with: productName)
        } else {
            // Use default text
            return "You've earned $\(Int(credit.amount)) credit for \(productName). Apply it to save on your order instantly."
        }
    }
}

