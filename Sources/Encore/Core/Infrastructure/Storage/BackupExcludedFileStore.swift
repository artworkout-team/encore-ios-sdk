// Key-value storage the system never backs up: one JSON file per key in Application Support,
// with the folder and every file marked excluded from backup. A restored or migrated device
// starts without it (the claim log and its status checks would otherwise bring back reminders
// for claims long over).

import Foundation

internal struct BackupExcludedFileStore: KeyValueStore, @unchecked Sendable {
    /// `Application Support/Encore/NotBackedUp`.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Encore", isDirectory: true).appendingPathComponent("NotBackedUp", isDirectory: true)
    }

    let directory: URL
    /// Where an earlier build kept these keys; a value found there moves to its file on first read.
    private let legacy: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL = Self.defaultDirectory, legacy: UserDefaults? = .standard) {
        self.directory = directory
        self.legacy = legacy
    }

    /// The file for `key`. Anything but letters, digits, `.`, `_` and `-` is escaped, so a user id
    /// with a slash stays one file inside the folder.
    func fileURL(for key: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._-")
        let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }

    func load<T: Decodable>(_ key: String) -> T? {
        let url = fileURL(for: key)
        if let data = try? Data(contentsOf: url) {
            return try? decoder.decode(T.self, from: data)
        }
        // A value an earlier build stored in UserDefaults (which is backed up): move it here.
        guard let legacy, let data = legacy.data(forKey: key) else { return nil }
        guard let value = try? decoder.decode(T.self, from: data) else { return nil }
        if write(data, to: url) { legacy.removeObject(forKey: key) }
        return value
    }

    func save<T: Encodable>(_ value: T, to key: String) {
        guard let data = try? encoder.encode(value) else {
            Logger.warn("Storage: Encode failed for key '\(key)'")
            return
        }
        _ = write(data, to: fileURL(for: key))
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
        legacy?.removeObject(forKey: key)
    }

    /// Writes atomically, then marks the file excluded (an atomic write replaces the file, and its
    /// flag with it). Never throws: a failed write leaves the previous value.
    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try prepareDirectory()
            try data.write(to: url, options: .atomic)
            Self.excludeFromBackup(url)
            return true
        } catch {
            Logger.warn("Storage: Write failed for '\(url.lastPathComponent)': \(error)")
            return false
        }
    }

    private func prepareDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        Self.excludeFromBackup(directory)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
