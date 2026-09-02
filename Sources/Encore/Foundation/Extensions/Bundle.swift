//
//  Host-app bundle accessors. Reads the primary CFBundleIcons entry so SDUI
//  can render the installed app's icon without a network round-trip.
//

import Foundation

#if canImport(UIKit)
import UIKit

extension Bundle {
    /// The host app's primary icon, resolved once per process from `Info.plist`.
    /// Prefers the rasterized names in `CFBundleIconFiles`, highest resolution
    /// last. `nil` when the host has no bundled icon, as under a test bundle.
    static let hostAppIcon: UIImage? = resolveHostAppIcon(
        info: Bundle.main.infoDictionary ?? [:],
        loadImage: { UIImage(named: $0) }
    )

    /// Takes its inputs so tests can drive it: the real call reads `Bundle.main`,
    /// which has no app container under a test bundle.
    internal static func resolveHostAppIcon(
        info: [String: Any],
        loadImage: (String) -> UIImage?
    ) -> UIImage? {
        guard let primary = primaryIcon(in: info) else { return nil }

        // An Icon Composer app names an icon stack in CFBundleIconName, and
        // UIImage(named:) raises `Need an imageRef` on it rather than returning
        // nil. Those apps publish rasters here too, so this key existing in any
        // form, even malformed, is the signal to leave the name alone.
        if let declared = primary["CFBundleIconFiles"] {
            for name in ((declared as? [String]) ?? []).reversed() {
                if let image = loadImage(name) { return image }
            }
            return nil
        }

        guard let name = primary["CFBundleIconName"] as? String else { return nil }
        return loadImage(name)
    }

    /// The base key wins outright by existing, malformed included. Falling
    /// through to the iPad override let an iPhone pick the iPad raster.
    private static func primaryIcon(in info: [String: Any]) -> [String: Any]? {
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] else { continue }
            return (icons as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        }
        return nil
    }
}
#endif
