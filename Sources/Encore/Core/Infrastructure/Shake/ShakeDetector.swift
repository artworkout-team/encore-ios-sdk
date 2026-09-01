// Sources/Encore/Core/Infrastructure/Shake/ShakeDetector.swift
//
// Counts shake gestures via CoreMotion accelerometer (avoids the UIWindow
// motionEnded extension trick which can clobber host-app overrides). Fires
// once when the device crosses 5 shakes in 10s. Used to identify a tester
// device for the reveal flow without any UI integration in the host app.

import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

internal protocol ShakeCounter {
    /// Record a shake at `timestamp`. Returns true exactly once when the
    /// threshold is crossed inside the window; the counter is reset after
    /// firing so the next N shakes are needed to fire again.
    @discardableResult
    func register(at timestamp: Date) -> Bool
}

internal final class SlidingWindowShakeCounter: ShakeCounter {
    private let threshold: Int
    private let window: TimeInterval
    private var timestamps: [Date] = []

    init(threshold: Int = 5, window: TimeInterval = 10) {
        self.threshold = threshold
        self.window = window
    }

    @discardableResult
    func register(at timestamp: Date) -> Bool {
        let cutoff = timestamp.addingTimeInterval(-window)
        timestamps = timestamps.filter { $0 >= cutoff }
        timestamps.append(timestamp)
        if timestamps.count >= threshold {
            timestamps.removeAll()
            return true
        }
        return false
    }
}

#if canImport(CoreMotion)
/// Polls the accelerometer at 50Hz and detects "shake" events via a magnitude
/// threshold (g-force >= 2.5) with a 250ms refractory period to suppress
/// double-counting from the same physical motion. Throttles outbound triggers
/// to once per 30s so a tester can't accidentally flood the backend.
internal final class ShakeDetector {
    private let motionManager: CMMotionManager
    private let counter: ShakeCounter
    private let magnitudeThreshold: Double
    private let refractoryInterval: TimeInterval
    private let throttle: TimeInterval
    private let onTrigger: () -> Void

    private var lastShakeAt: Date?
    private var lastFireAt: Date?
    private var isRunning = false

    init(
        motionManager: CMMotionManager = CMMotionManager(),
        counter: ShakeCounter = SlidingWindowShakeCounter(),
        magnitudeThreshold: Double = 2.5,
        refractoryInterval: TimeInterval = 0.25,
        throttle: TimeInterval = 30,
        onTrigger: @escaping () -> Void
    ) {
        self.motionManager = motionManager
        self.counter = counter
        self.magnitudeThreshold = magnitudeThreshold
        self.refractoryInterval = refractoryInterval
        self.throttle = throttle
        self.onTrigger = onTrigger
    }

    func start() {
        guard !isRunning else { return }
        guard motionManager.isAccelerometerAvailable else {
            Logger.debug("SHAKE: Accelerometer unavailable; ShakeDetector idle")
            return
        }
        motionManager.accelerometerUpdateInterval = 1.0 / 50.0
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handleSample(x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z, at: Date())
        }
        isRunning = true
        Logger.debug("SHAKE: ShakeDetector started")
    }

    func stop() {
        guard isRunning else { return }
        motionManager.stopAccelerometerUpdates()
        isRunning = false
        Logger.debug("SHAKE: ShakeDetector stopped")
    }

    deinit { stop() }

    func handleSample(x: Double, y: Double, z: Double, at now: Date) {
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard magnitude >= magnitudeThreshold else { return }
        if let lastShakeAt, now.timeIntervalSince(lastShakeAt) < refractoryInterval { return }
        lastShakeAt = now

        guard counter.register(at: now) else { return }

        if let lastFireAt, now.timeIntervalSince(lastFireAt) < throttle {
            Logger.debug("SHAKE: Threshold hit but throttled")
            return
        }
        lastFireAt = now
        Logger.info("SHAKE: Tester gesture detected — triggering reveal")
        onTrigger()
    }
}
#endif
