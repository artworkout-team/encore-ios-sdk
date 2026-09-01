//
//  OfferSheetStyles.swift
//  Encore
//

import SwiftUI

@available(iOS 17.0, *)
struct OfferSheetStyles {
    // MARK: - Colors (Dark Mode Adaptive)
    
    /// Sheet background - adapts to system appearance
    static let backgroundColor = Color(UIColor.systemGroupedBackground)
    
    /// Primary text color - adapts to system appearance
    static let primaryText = Color(UIColor.label)
    
    /// Secondary text color - adapts to system appearance
    static let secondaryText = Color(UIColor.secondaryLabel)
    
    /// Accent green for highlights
    static let accentGreen = Color(hex: "#16BD25")
    
    /// Accent blue for buttons and highlights
    static let accentBlue = Color(hex: "#5671FF")
    
    /// Close button color - adapts to system appearance
    static let closeButtonGray = Color(UIColor.tertiaryLabel)
    
    /// Grabber handle color - adapts to system appearance
    static let grabberGray = Color(UIColor.separator)
    
    /// Page indicator color - adapts to system appearance
    static let indicatorGray = Color(UIColor.tertiaryLabel)
    
    /// Card background - adapts to system appearance
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
    
    /// Placeholder/fallback background - adapts to system appearance
    static let placeholderBackground = Color(UIColor.tertiarySystemFill)
    
    // MARK: - Spacing
    
    static let horizontalPadding: CGFloat = 20
    static let carouselSpacing: CGFloat = 12
    static let carouselMargin: CGFloat = 20
    
    // MARK: - Sizing
    
    static let grabberWidth: CGFloat = 46
    static let grabberHeight: CGFloat = 5
    static let cornerRadius: CGFloat = 20
    static let safariCornerRadius: CGFloat = 16
    static let gradientHeight: CGFloat = 100
    
    // MARK: - Typography
    
    static let titleFont = Font.system(size: 24, weight: .semibold)
    static let subtitleFont = Font.system(size: 17, weight: .regular)
    static let instructionTitleFont = Font.system(size: 18, weight: .regular)
    static let instructionBulletFont = Font.system(size: 16, weight: .regular)
    static let closeButtonFont = Font.system(size: 15, weight: .semibold)
}

