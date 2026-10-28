// DEBUG builds only: a live trace of the SDK's trigger decisions for the demo's "Under the hood"
// drawer. Each entry is posted as a notification named by a plain string, so the demo names no SDK
// symbol; a Release build has none of it (scripts/release/verify-no-debug-hooks.sh), while a Debug
// build of the source distribution compiles it like every DEBUG hook. The file is not
// named after the type: an object keeps its source path, which would read as the marker in Release.

#if DEBUG
import Foundation

internal enum EncoreDebugTrace {
    struct Entry: Equatable, Sendable {
        let at: Date
        let name: String
        let fields: [String: String]
    }

    /// No dots, like the demo's other hooks.
    static let notificationName = Notification.Name("EncoreDebugTrace")
    static let capacity = 200

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer: [Entry] = []

    /// The newest `capacity` entries, oldest first.
    static var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Records one step and posts it on the main thread with userInfo `name`, `at` (ISO 8601 with
    /// milliseconds) and the fields.
    static func record(_ name: String, _ fields: [String: String] = [:], at: Date = Date()) {
        let entry = Entry(at: at, name: name, fields: fields)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()
        var info: [String: String] = fields
        info["name"] = name
        info["at"] = timestamp(at)
        let post = { NotificationCenter.default.post(name: notificationName, object: nil, userInfo: info) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer = []
    }

    /// Thread-safe, so one serves every caller.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String { iso.string(from: date) }
}
#endif
