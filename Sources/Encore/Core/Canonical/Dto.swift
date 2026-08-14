// Sources/Encore/Data/DTOs/DTO.swift
//
// Root namespace for all Data Transfer Objects.
// Each domain extends this namespace in its own file.
//
// Usage:
//   let request: DTO.Offers.Request = ...
//   let response: DTO.Transactions.Response = ...
//

import Foundation

/// Namespace for all Data Transfer Objects (mapped from OpenAPI generation).
/// Provides clean, domain-oriented access to verbose auto-generated types.
internal enum DTO {
    // Empty - just a namespace container.
    // Domain-specific DTOs are defined via extensions in separate files.
}

