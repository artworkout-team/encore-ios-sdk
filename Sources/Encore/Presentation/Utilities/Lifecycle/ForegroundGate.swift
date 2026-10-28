// Holds the launch network work until the app first becomes active, so a background
// launch (a silent push, a background refresh) fetches nothing nobody will see.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Opens once. Held actions run in order when it opens; after that, actions run at once.
internal final class ForegroundGate: @unchecked Sendable {

    private let lock = NSLock()
    private var opened = false
    private var pending: [() -> Void] = []
    private var subscription: AnyCancellable?

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func runWhenOpen(_ action: @escaping () -> Void) {
        lock.lock()
        let runNow = opened
        if !runNow { pending.append(action) }
        lock.unlock()
        if runNow { action() }
    }

    func open() {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        opened = true
        let actions = pending
        pending = []
        subscription = nil
        lock.unlock()
        actions.forEach { $0() }
    }

    /// Opens now unless the app launched in the background, else on the first `didForeground` or
    /// scene `willEnterForeground`. A scene-based app reads `.background` until its scene connects.
    @MainActor
    func start(
        launchedInBackground: Bool,
        didForeground: PassthroughSubject<Void, Never>,
        sceneWillEnterForeground: AnyPublisher<Void, Never> = ForegroundGate.sceneWillEnterForeground
    ) {
        guard launchedInBackground else {
            open()
            return
        }
        let subscription = didForeground.merge(with: sceneWillEnterForeground).first().sink { [weak self] in self?.open() }
        lock.lock()
        if !opened { self.subscription = subscription }
        lock.unlock()
    }

    /// Fires on a user launch of a scene-based app before activation, and not on a silent push.
    static var sceneWillEnterForeground: AnyPublisher<Void, Never> {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification).map { _ in () }.eraseToAnyPublisher()
        #else
        Empty().eraseToAnyPublisher()
        #endif
    }

    #if DEBUG
    /// Test seam: stands in for `applicationState`, which a test host cannot set.
    nonisolated(unsafe) static var launchedInBackgroundOverrideForTesting: Bool?
    #endif

    #if canImport(UIKit)
    /// True only for a background launch. An app extension has no `UIApplication`, so it counts as foreground.
    @MainActor
    static var launchedInBackground: Bool {
        #if DEBUG
        if let override = launchedInBackgroundOverrideForTesting { return override }
        #endif
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector),
              let app = UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication else { return false }
        return app.applicationState == .background
    }
    #else
    static var launchedInBackground: Bool { false }
    #endif
}
