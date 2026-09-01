// Sources/Encore/Foundation/Extensions/Encodable+PrettyJSON.swift
//
// Generic pretty-printed JSON for debug logging.

import Foundation

extension Encodable {
    /// Pretty-printed JSON for debug logging, using the SDK's shared coding config.
    /// Falls back to `String(describing:)` if encoding fails.
    var prettyJSON: String {
        guard let data = try? JSONCoding.prettyEncoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return String(describing: self)
        }
        return json
    }
}
