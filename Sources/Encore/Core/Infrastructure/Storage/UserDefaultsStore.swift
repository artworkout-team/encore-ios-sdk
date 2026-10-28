// Sources/Encore/Core/Infrastructure/Storage/UserDefaultsStore.swift
//
// UserDefaults-backed implementation of KeyValueStore.
// Uses standard JSONEncoder/JSONDecoder for backwards compatibility with existing persisted data.

import Foundation

/// UserDefaults-backed key-value storage.
/// Thread-safe (UserDefaults is thread-safe). Uses standard JSON coding.
/// Note: @unchecked Sendable because JSONEncoder/JSONDecoder are thread-safe for read-only use.
internal struct UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    fileprivate let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    init(
        defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }
    
    func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else {
            Logger.debug("Storage: No data for key: \(key)")
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger.warn("Storage: Decode failed for key '\(key)' (\(T.self)): \(error)")
            return nil
        }
    }
    
    func save<T: Encodable>(_ value: T, to key: String) {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key)
        } catch {
            Logger.warn("Storage: Encode failed for key '\(key)' (\(T.self)): \(error)")
        }
    }
    
    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - RawDataStore

extension UserDefaultsStore: RawDataStore {
    struct UnreadableValue: Error {}

    /// Throws when the key holds something other than bytes.
    func rawData(forKey key: String) throws -> Data? {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let data = object as? Data else { throw UnreadableValue() }
        return data
    }

    func setRawData(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }
}
