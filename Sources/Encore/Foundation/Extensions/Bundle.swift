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
    /// Icon Composer apps expose `CFBundleIconName`, but that name points to an
    /// icon stack rather than a bitmap image. Asking `UIImage(named:)` to load
    /// the stack raises an Objective-C exception (`Need an imageRef`) instead
    /// of returning `nil`. Both Icon Composer and asset-catalog app icons also
    /// publish rasterized filenames through `CFBundleIconFiles`, so prefer
    /// those bundle resources and use the named asset only as a legacy fallback.
    ///
    /// Returns `nil` when the host has no bundled icon (e.g. running
    /// under a test bundle with no app container).
    static let hostAppIcon: UIImage? = resolveHostAppIcon()

    private static func resolveHostAppIcon() -> UIImage? {
        let bundle = Bundle.main
        let primaryIcons = primaryIconDictionaries(in: bundle)
        let iconFiles = primaryIcons.flatMap { $0["CFBundleIconFiles"] as? [String] ?? [] }

        if let image = largestRasterIcon(namedBy: iconFiles, in: bundle) {
            return image
        }

        // When file metadata exists, do not fall through to `UIImage(named:)`:
        // the unresolved name may be an Icon Composer stack and UIKit traps
        // before Swift can handle the failure.
        guard iconFiles.isEmpty,
              let name = primaryIcons.lazy.compactMap({ $0["CFBundleIconName"] as? String }).first,
              let image = UIImage(named: name, in: bundle, compatibleWith: nil)
        else { return nil }

        return image
    }

    private static func primaryIconDictionaries(in bundle: Bundle) -> [[String: Any]] {
        let info = bundle.infoDictionary ?? [:]
        return ["CFBundleIcons~ipad", "CFBundleIcons"].compactMap { key in
            guard let icons = info[key] as? [String: Any] else { return nil }
            return icons["CFBundlePrimaryIcon"] as? [String: Any]
        }
    }

    private static func largestRasterIcon(namedBy iconFiles: [String], in bundle: Bundle) -> UIImage? {
        guard !iconFiles.isEmpty else { return nil }

        let iconNames = Set(iconFiles.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        })
        let rasterIcons = (bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? [])
            .filter { url in
                let resourceName = url.deletingPathExtension().lastPathComponent
                return iconNames.contains { iconName in
                    resourceName == iconName
                        || resourceName.hasPrefix("\(iconName)@")
                        || resourceName.hasPrefix("\(iconName)~")
                }
            }
            .compactMap { UIImage(contentsOfFile: $0.path) }

        return rasterIcons.max { lhs, rhs in
            let lhsPixels = lhs.size.width * lhs.scale * lhs.size.height * lhs.scale
            let rhsPixels = rhs.size.width * rhs.scale * rhs.size.height * rhs.scale
            return lhsPixels < rhsPixels
        }
    }
}
#endif
