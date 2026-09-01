// Presentation/Extensions/Color.swift
//
// Helper extension for hex colors
//

import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Linearly mixes this color toward `other` by `amount` (0 = self, 1 =
    /// other) in sRGB. Backs the `lighten` (mix toward white) and `darken`
    /// (mix toward black) SDUI color transforms. Resolves both endpoints
    /// through `UIColor` so semantic/dynamic colors flatten to their current
    /// trait value before mixing.
    func sduiMixed(with other: Color, amount: Double) -> Color {
        let t = max(0, min(1, amount))
        #if canImport(UIKit)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let ct = CGFloat(t)
        return Color(
            .sRGB,
            red: Double(r1 + (r2 - r1) * ct),
            green: Double(g1 + (g2 - g1) * ct),
            blue: Double(b1 + (b2 - b1) * ct),
            opacity: Double(a1 + (a2 - a1) * ct)
        )
        #else
        return self
        #endif
    }
}

