//
//  Bundle.swift
//  Encore
//
//  Host-app bundle accessors. Reads the primary CFBundleIcons entry so SDUI
//  can render the installed app's icon without a network round-trip.
//

import Foundation

#if canImport(UIKit)
import UIKit

extension Bundle {
    /// The host app's primary icon, resolved once per process from
    /// `Info.plist`'s `CFBundleIcons`.
    ///
    /// Modern apps (Xcode 9+ asset-catalog icons) expose a single
    /// `CFBundleIconName` asset — `UIImage(named:)` selects the right
    /// scale and idiom variant at runtime. Legacy file-icon apps list
    /// each rasterized file under `CFBundleIconFiles`; the last entry
    /// is the highest-resolution asset.
    ///
    /// Returns `nil` when the host has no bundled icon (e.g. running
    /// under a test bundle with no app container).
    static let hostAppIcon: UIImage? = resolveHostAppIcon()

    private static func resolveHostAppIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        else { return nil }

        if let name = primary["CFBundleIconName"] as? String,
           let image = UIImage(named: name) {
            return image
        }

        if let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last,
           let image = UIImage(named: last) {
            return image
        }

        return nil
    }
}
#endif
