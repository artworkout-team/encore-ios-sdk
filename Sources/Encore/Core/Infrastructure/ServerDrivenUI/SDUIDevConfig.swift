//
//  SDUIDevConfig.swift  (source-distribution stub)
//
//  The dev-only SDUI variant subsystem (the real SDUIDevConfig + Variants/) is
//  internal testing tooling and is not shipped. `scripts/release/publish-source.sh`
//  swaps the real implementation for this no-op stub and drops `Variants/`, so the
//  variant JSON stays out of the public distribution while SDUIConfigurationManager's
//  `#if DEBUG` references (useDevConfig / devJSON / logStatus) still resolve.
//
//  Members here must mirror whatever SDUIConfigurationManager references.
//

import Foundation

enum SDUIDevConfig {
    /// Never active in shipped builds — production always uses remote config → fallback.
    static var useDevConfig: Bool { false }
    static let mockVariantId: String? = nil
    static var devJSON: String { "{}" }
    static func logStatus() {}
}
