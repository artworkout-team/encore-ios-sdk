// Sources/Encore/Core/Infrastructure/Networking/HTTPClient.swift
//
// Generic HTTP client that handles request building, execution, and error handling.
// This is the single source of truth for all network operations.
//

import Foundation

// MARK: - HTTP Client Protocol

internal protocol HTTPClientProtocol: Sendable {
    func request<T: Decodable>(
        path: String,
        method: String,
        body: Encodable?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> T
    
    /// Overload for pre-serialized JSON body (e.g., from outbox storage).
    /// Skips encoding - sends bodyData directly.
    func request<T: Decodable>(
        path: String,
        method: String,
        bodyData: Data?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> T

    /// `request` that also returns the HTTP status, for a caller that trusts only an exact code.
    func requestWithStatus<T: Decodable>(
        path: String,
        method: String,
        body: Encodable?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> (T, Int)
}

// Protocol extension for default parameters
extension HTTPClientProtocol {
    func request<T: Decodable>(
        path: String,
        method: String,
        body: Encodable? = nil,
        query: [String: String?]? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await request(path: path, method: method, body: body, query: query, headers: headers)
    }
    /// A stand-in client that knows no status reports 200 for any answer it decodes.
    func requestWithStatus<T: Decodable>(
        path: String,
        method: String,
        body: Encodable?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> (T, Int) {
        let value: T = try await request(path: path, method: method, body: body, query: query, headers: headers)
        return (value, 200)
    }
    // No default for the `bodyData:` overload: one with this signature would
    // satisfy the requirement and call itself, so a conformer that forgot the
    // overload recursed without end. Without it, forgetting is a compile error.
}

// MARK: - HTTP Client Implementation

internal final class HTTPClient: HTTPClientProtocol, Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let defaultHeaders: [String: String]

    init(baseURL: URL, headers: [String: String] = [:]) {
        self.baseURL = baseURL
        self.defaultHeaders = headers
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Public API
    
    /// Performs a request with an Encodable body and decodes the response.
    func request<T: Decodable>(
        path: String,
        method: String,
        body: Encodable? = nil,
        query: [String: String?]? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let bodyData = try body.map { try JSONCoding.encoder.encode($0) }
        return try await request(path: path, method: method, bodyData: bodyData, query: query, headers: headers)
    }
    
    /// Performs a request with pre-serialized body data (skips encoding).
    func request<T: Decodable>(
        path: String,
        method: String,
        bodyData: Data? = nil,
        query: [String: String?]? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        try await perform(path: path, method: method, bodyData: bodyData, query: query, headers: headers).0
    }

    func requestWithStatus<T: Decodable>(
        path: String,
        method: String,
        body: Encodable?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> (T, Int) {
        let bodyData = try body.map { try JSONCoding.encoder.encode($0) }
        return try await perform(path: path, method: method, bodyData: bodyData, query: query, headers: headers)
    }

    private func perform<T: Decodable>(
        path: String,
        method: String,
        bodyData: Data?,
        query: [String: String?]?,
        headers: [String: String]
    ) async throws -> (T, Int) {
        let urlRequest = buildRequest(path: path, method: method, bodyData: bodyData, query: query, headers: headers)
        
        Logger.debug(.network, "\(method) \(urlRequest.url?.absoluteString ?? path)")

        // Wrap network errors as EncoreError at the boundary
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw EncoreError.transport(.network(error))
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EncoreError.transport(.network(URLError(.badServerResponse)))
        }
        
        // Validate status code
        guard (200...299).contains(httpResponse.statusCode) else {
            let status = httpResponse.statusCode
            // Server error: try to decode Encore's standard error payload; otherwise fall back to raw HTTP error.
            if let errorResponse = try? JSONCoding.decoder.decode(ErrorResponse.self, from: data) {
                throw EncoreError.protocol(.api(status: status, code: errorResponse.code, message: errorResponse.error))
            }
            // Unexpected format - log locally for SDK debugging (don't report to server, it came from there)
            Logger.debug(.network, "Unexpected error response format for status \(status)")
            throw EncoreError.protocol(.http(status: status, message: String(data: data, encoding: .utf8)))
        }
        
        // Handle empty responses - shortcut for endpoints that return no body
        if data.isEmpty, let empty = EmptyResponse() as? T {
            return (empty, httpResponse.statusCode)
        }
        
        // Decode response (empty data for non-EmptyResponse types will fail here as contract drift)
        do {
            return (try JSONCoding.decoder.decode(T.self, from: data), httpResponse.statusCode)
        } catch {
            Logger.debug(.network, "Decoding error for \(T.self): \(error)")
            throw EncoreError.protocol(.decoding(error))
        }
    }
    
    // MARK: - Private Helpers

    /// `/config` (the sheet's and every trigger's) gives up after 10 s instead of URLSession's
    /// 60 s: a trigger or sheet waiting on it draws nothing until then. A timed-out request is not
    /// retried by itself; it fails like any other (see the callers).
    static let configTimeout: TimeInterval = 10

    /// The request timeout for `path`; nil keeps URLSession's default.
    static func timeout(forPath path: String) -> TimeInterval? {
        path == "config" ? configTimeout : nil
    }

    func buildRequest(
        path: String,
        method: String,
        bodyData: Data?,
        query: [String: String?]?,
        headers: [String: String]
    ) -> URLRequest {
        // Build URL with query parameters
        var url = baseURL.appendingPathComponent(path)
        
        if let query = query {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.compactMap { key, value in
                value.map { URLQueryItem(name: key, value: $0) }
            }
            if let newUrl = components?.url {
                url = newUrl
            }
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Apply default headers, then caller headers (caller overrides defaults)
        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        request.httpBody = bodyData
        if let timeout = Self.timeout(forPath: path) { request.timeoutInterval = timeout }

        return request
    }
}

// MARK: - Empty Response Helper

/// Placeholder for endpoints that return no body on success.
internal struct EmptyResponse: Decodable {}
