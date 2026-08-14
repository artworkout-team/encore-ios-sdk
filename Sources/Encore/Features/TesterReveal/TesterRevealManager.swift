// Sources/Encore/Features/TesterReveal/TesterRevealManager.swift
//
// Wires the ShakeDetector to the TesterRevealClient. On gesture trigger,
// reads the current userId/appAccountId from UserManager and posts.
// Lives at Features/ alongside other domain managers.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

internal final class TesterRevealManager {
    private let client: TesterRevealClient
    #if canImport(CoreMotion)
    private var detector: ShakeDetector?
    #endif

    init(client: TesterRevealClient) {
        self.client = client
        #if canImport(CoreMotion)
        self.detector = ShakeDetector(onTrigger: { [weak self] in
            self?.fireReveal()
        })
        #endif
    }

    func start() {
        #if canImport(CoreMotion)
        detector?.start()
        #endif
    }

    func stop() {
        #if canImport(CoreMotion)
        detector?.stop()
        #endif
    }

    private func fireReveal() {
        guard let userId = userManager?.currentUserId else {
            Logger.debug("TESTER-REVEAL: Skipping reveal — userId unavailable")
            return
        }
        let payload = TesterRevealRequest(
            userId: userId,
            appAccountId: userManager?.appAccountId,
            platform: "ios",
            deviceModel: TesterRevealManager.deviceModelIdentifier(),
            sdkVersion: Encore.sdkVersion
        )
        let client = self.client
        Task.detached { await client.post(payload: payload) }
    }

    /// Hardware identifier (e.g. `iPhone15,3`). Falls back to UIDevice.model
    /// (e.g. `iPhone`) when uname is unavailable.
    static func deviceModelIdentifier() -> String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            #if canImport(UIKit)
            return UIDevice.current.model
            #else
            return nil
            #endif
        }
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.compactMap { _, value -> String? in
            guard let scalar = value as? Int8, scalar != 0 else { return nil }
            return String(UnicodeScalar(UInt8(scalar)))
        }.joined()
        return identifier.isEmpty ? nil : identifier
    }
}
