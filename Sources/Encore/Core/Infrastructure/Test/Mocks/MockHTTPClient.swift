// Sources/Encore/Core/Infrastructure/Test/Mocks/MockHTTPClient.swift
//
// Mock implementation of HTTPClient for testing.
// Returns mock data based on the configured scenario.
//
// Note: Wrapped in #if DEBUG to exclude from release builds.

import Foundation

// MARK: - Mock Scenarios

/// Mock scenarios for testing the Encore SDK without real API calls.
/// Each scenario represents a complete user journey.
/// Available in all builds (lightweight enum), but MockHTTPClient is DEBUG-only.
///
/// Internal: its only consumer is `EnvironmentConfiguration`, which is itself
/// internal. Test-double vocabulary has no business in a publisher's autocomplete.
internal enum MockScenario: Sendable {
    case successWithOffer      // User has offers available
    case userDeclinedOffers    // User saw offers but declined
    case noOfferAvailable      // No offers available
    case networkError
    case serverError
    case invalidResponse
}

// MARK: - Mock HTTP Client

#if DEBUG

/// Mock HTTP client that returns predefined responses based on the mock scenario.
/// Implements HTTPClientProtocol directly (no real networking).
internal final class MockHTTPClient: HTTPClientProtocol {
    private let mockScenario: MockScenario
    
    init(scenario: MockScenario = .successWithOffer) {
        self.mockScenario = scenario
    }
    
    /// Return mock data instead of making actual network requests
    func request<T: Decodable>(
        path: String,
        method: String,
        body: Encodable? = nil,
        query: [String: String?]? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        Logger.debug(.network, "Mock: \(method) \(path)")
        
        // Route to appropriate mock handler based on path
        if path.contains("offers/search") {
            return try mockOffersSearch()
        } else if path.contains("transactions") {
            return try mockStartTransaction()
        } else if path.contains("entitlements/revoke") {
            return try mockRevokeEntitlements()
        } else if path.contains("entitlements") {
            return try mockFetchEntitlements()
        }
        
        throw EncoreError.protocol(.api(status: 404, code: "unknown_path", message: "Unknown mock path: \(path)"))
    }
    
    // MARK: - Mock Handlers
    
    private func mockOffersSearch<T: Decodable>() throws -> T {
        switch mockScenario {
        case .successWithOffer, .userDeclinedOffers:
            return try JSONCoding.decoder.decode(T.self, from: MockData.Offers.sample())
            
        case .noOfferAvailable:
            return try JSONCoding.decoder.decode(T.self, from: MockData.Offers.empty())
            
        case .networkError:
            throw EncoreError.transport(.network(URLError(.notConnectedToInternet)))
            
        case .serverError:
            throw EncoreError.protocol(.http(status: 500, message: "Mock server error"))
            
        case .invalidResponse:
            throw EncoreError.protocol(.decoding(NSError(domain: "DecodingError", code: 4865, userInfo: nil)))
        }
    }
    
    private func mockStartTransaction<T: Decodable>() throws -> T {
        return try JSONCoding.decoder.decode(T.self, from: MockData.Transactions.start())
    }
    
    private func mockFetchEntitlements<T: Decodable>() throws -> T {
        switch mockScenario {
        case .userDeclinedOffers, .noOfferAvailable:
            return try JSONCoding.decoder.decode(T.self, from: MockData.Entitlements.empty())
            
        case .networkError:
            throw EncoreError.transport(.network(URLError(.notConnectedToInternet)))
            
        case .serverError:
            throw EncoreError.protocol(.http(status: 500, message: "Mock server error"))
            
        case .invalidResponse:
            throw EncoreError.protocol(.decoding(NSError(domain: "DecodingError", code: 4865, userInfo: nil)))
            
        case .successWithOffer:
            return try JSONCoding.decoder.decode(T.self, from: MockData.Entitlements.withCredits())
        }
    }
    
    private func mockRevokeEntitlements<T: Decodable>() throws -> T {
        switch mockScenario {
        case .networkError:
            throw EncoreError.transport(.network(URLError(.notConnectedToInternet)))
        case .serverError:
            throw EncoreError.protocol(.http(status: 500, message: "Mock server error"))
        case .invalidResponse:
            throw EncoreError.protocol(.decoding(NSError(domain: "DecodingError", code: 4865, userInfo: nil)))
        default:
            return try JSONCoding.decoder.decode(T.self, from: MockData.Entitlements.empty())
        }
    }
}

#endif
