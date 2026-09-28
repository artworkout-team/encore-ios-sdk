//
//  AppearanceHex.swift
//  Encore
//
//  Parses publisher `AppearanceConfig` colours (CSS hex order) for the renderer.
//

import SwiftUI

/// Strict CSS-order hex parser for publisher-supplied colours.
enum AppearanceHex {
    struct RGBA: Equatable {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8

        var color: Color {
            Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
        }

        /// Black or white text for this background, by WCAG relative luminance (0.179 split).
        var contrastingInk: RGBA {
            func linear(_ c: UInt8) -> Double {
                let v = Double(c) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            return luminance > 0.179 ? RGBA(r: 0, g: 0, b: 0, a: 255) : RGBA(r: 255, g: 255, b: 255, a: 255)
        }
    }

    static func parse(_ value: String) -> RGBA? {
        guard value.hasPrefix("#") else { return nil }
        let digits = value.dropFirst()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit),
              let raw = UInt32(digits, radix: 16) else { return nil }
        switch digits.count {
        case 3:
            return RGBA(r: UInt8((raw >> 8) & 0xF) * 17, g: UInt8((raw >> 4) & 0xF) * 17, b: UInt8(raw & 0xF) * 17, a: 255)
        case 6:
            return RGBA(r: UInt8((raw >> 16) & 0xFF), g: UInt8((raw >> 8) & 0xFF), b: UInt8(raw & 0xFF), a: 255)
        default:
            return RGBA(r: UInt8((raw >> 24) & 0xFF), g: UInt8((raw >> 16) & 0xFF), b: UInt8((raw >> 8) & 0xFF), a: UInt8(raw & 0xFF))
        }
    }

    /// Parses a publisher field, logging (truncated) and returning nil when invalid.
    static func parseField(_ value: String?, name: String) -> RGBA? {
        guard let value else { return nil }
        if let parsed = parse(value) { return parsed }
        Logger.warn(.presentation, "[APPEARANCE] Ignoring invalid \(name): \"\(value.prefix(32))\"")
        return nil
    }
}
