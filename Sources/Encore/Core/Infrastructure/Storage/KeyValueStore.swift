// Sources/Encore/Core/Infrastructure/Storage/KeyValueStore.swift
//
// Generic key-value storage protocol.
// Infrastructure layer: knows HOW to store, not WHAT to store.

import Foundation

/// Generic key-value storage interface.
/// Implementations handle the mechanism (UserDefaults, Keychain, etc.),
/// while Repositories own the semantic keys and data schemas.
internal protocol KeyValueStore: Sendable {
    func load<T: Decodable>(_ key: String) -> T?
    func save<T: Encodable>(_ value: T, to key: String)
    func remove(_ key: String)
}
