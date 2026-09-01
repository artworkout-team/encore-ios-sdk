// Sources/Encore/Core/Extensions/Collection+Extensions.swift
//
// General-purpose collection extensions.
//

import Foundation

extension Dictionary {
    /// Returns `nil` if empty, otherwise `self`. Useful for optional chaining on non-optional collections.
    var nonEmpty: Self? { isEmpty ? nil : self }
}

extension Array {
    /// Returns `nil` if empty, otherwise `self`. Useful for optional chaining on non-optional collections.
    var nonEmpty: Self? { isEmpty ? nil : self }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
