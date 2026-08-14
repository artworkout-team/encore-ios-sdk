import Foundation
import os.lock // Import the low-level C lock

/// High-performance thread-safe wrapper.
/// Uses `os_unfair_lock` directly to support all iOS versions (10+)
/// with maximum speed and no runtime availability checks.
public final class Atomic<T: Sendable>: @unchecked Sendable {
    private var _value: T
    
    // 1. We use the raw C struct.
    // Since Atomic is a class, this memory is stable on the heap.
    private var _lock = os_unfair_lock()

    public init(_ value: T) {
        self._value = value
    }

    public var value: T {
        get {
            // 2. Lock
            os_unfair_lock_lock(&_lock)
            // 3. Defer Unlock (Safe even if crashing)
            defer { os_unfair_lock_unlock(&_lock) }
            return _value
        }
        set {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            _value = newValue
        }
    }

    public func mutate(_ transform: (inout T) -> Void) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        transform(&_value)
    }
    
    /// Mutate and return a result atomically.
    @discardableResult
    public func mutate<R>(_ transform: (inout T) -> R) -> R {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return transform(&_value)
    }
}