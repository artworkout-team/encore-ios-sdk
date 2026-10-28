// Sources/Encore/Presentation/Utilities/RightToLeft.swift
//
// Right-to-left rules for SDK UI: which way the sheet lays out, which symbols
// mirror, and which way a drag counts as "forward".

import SwiftUI

/// The layout direction for copy served in a given locale, from the same table
/// as Android's `ServedLayoutDirection` rather than the OS's, so both agree.
enum ServedLayoutDirection {
    /// Nil (inherit the host) only when no locale was served. A host not
    /// localized for Arabic runs LTR, so Arabic copy would sit left-aligned.
    static func direction(for locale: String?) -> LayoutDirection? {
        guard let language = locale?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              !language.isEmpty else { return nil }
        return rightToLeft.contains(language) ? .rightToLeft : .leftToRight
    }

    private static let rightToLeft: Set<String> = [
        "ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "lrc", "mzn", "nqo",
        "ps", "sd", "syr", "ug", "ur", "yi", "ji",
    ]
}

/// Applies the served locale's direction, or nothing when it is unknown.
struct ServedLayoutDirectionModifier: ViewModifier {
    let locale: String?

    func body(content: Content) -> some View {
        if let direction = ServedLayoutDirection.direction(for: locale) {
            content.environment(\.layoutDirection, direction)
        } else {
            content
        }
    }
}

/// SF Symbols named for a physical side (`chevron.left`, `arrow.up.right`) never
/// mirror; `.forward`/`.backward` ones mirror on their own. Variants use the
/// physical names to mean reading direction, so those flip under RTL.
enum SDUISymbolDirection {
    static func mirrorsInRightToLeft(_ systemName: String) -> Bool {
        systemName.split(separator: ".").contains { $0 == "left" || $0 == "right" }
    }
}

/// Drag distance toward the trailing edge, from a PHYSICAL (global-space)
/// translation. Global space is never mirrored, so the sign is explicit here.
enum ForwardDrag {
    static func distance(_ physicalWidth: CGFloat, in direction: LayoutDirection) -> CGFloat {
        direction == .rightToLeft ? -physicalWidth : physicalWidth
    }
}
