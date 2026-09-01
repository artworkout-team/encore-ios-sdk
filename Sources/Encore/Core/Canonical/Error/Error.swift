import Foundation

// Context where errors can occur in the SDK
internal enum ErrorContext: String, Encodable {
    case configuration = "configuration"
    case presentOfferInitialization = "present_offer_initialization"
    case fetchOfferData = "fetch_offer_data"
    case startTransaction = "start_transaction"
    case logImpression = "log_impression"
    case fetchEntitlements = "fetch_entitlements"
    case verifyTransaction = "verify_transaction"
    case grantSignal = "grant_signal"
    case apiRequest = "api_request"
    case outbox = "outbox"
    case analytics = "analytics"
}

// MARK: - Error Hierarchy
//
// EncoreError
// ├── transport       "The road is broken"
// │   └── network
// ├── protocol        "The language failed"
// │   ├── http        (status code, but body unreadable)
// │   ├── api         (server said "no" intelligibly)
// │   └── decoding    (body unreadable on 2xx)
// ├── integration     "SDK misused"
// │   ├── notConfigured
// │   └── invalidURL
// └── domain          "Client business rule violated" (just a message, no sub-enum)

public enum EncoreError: Error, LocalizedError, Sendable {
    case transport(TransportError)
    case `protocol`(ProtocolError)
    case integration(IntegrationError)
    case domain(String)
    
    // MARK: - Transport Errors
    /// "The road is broken" - network/storage connectivity issues
    public enum TransportError: Error, LocalizedError, Sendable {
        case network(Error)
        case persistence(Error)
        
        public var errorDescription: String? {
            switch self {
            case .network(let error):
                return "Network error: \(error.localizedDescription)"
            case .persistence(let error):
                return "Persistence error: \(error.localizedDescription)"
            }
        }
        
        public var underlying: Error? {
            switch self {
            case .network(let error): return error
            case .persistence(let error): return error
            }
        }
    }
    
    // MARK: - Protocol Errors
    /// "The language failed" - HTTP/API communication issues
    public enum ProtocolError: Error, LocalizedError, Sendable {
        /// Server returned non-2xx status with unreadable/unexpected body
        case http(status: Int, message: String?)
        /// Server returned structured error response (server's domain error)
        case api(status: Int, code: String?, message: String)
        /// Server returned 2xx but body didn't match expected schema
        case decoding(Error)
        
        public var errorDescription: String? {
            switch self {
            case .http(let status, let message):
                if let message = message {
                    return "HTTP \(status): \(message)"
                }
                return "HTTP error \(status)"
            case .api(let status, let code, let message):
                if let code = code {
                    return "HTTP \(status) - API error (\(code)): \(message)"
                }
                return "HTTP \(status) - API error: \(message)"
            case .decoding(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            }
        }
        
        public var underlying: Error? {
            switch self {
            case .decoding(let error): return error
            default: return nil
            }
        }
    }
    
    // MARK: - Integration Errors
    /// "SDK misused" - programmer/configuration errors
    public enum IntegrationError: Error, LocalizedError, Sendable {
        case notConfigured
        case invalidApiKey
        case invalidURL
        
        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Encore SDK not configured. Call Encore.shared.configure(apiKey:) before use."
            case .invalidApiKey:
                return "Invalid API key. Please check your API key and try again."
            case .invalidURL:
                return "Failed to construct a valid URL for the API request."
            }
        }
    }
    
    // MARK: - LocalizedError
    public var errorDescription: String? {
        switch self {
        case .transport(let error): return error.errorDescription
        case .protocol(let error): return error.errorDescription
        case .integration(let error): return error.errorDescription
        case .domain(let message): return "Domain error: \(message)"
        }
    }
    
    /// The underlying system error, if this error wraps one.
    public var underlying: Error? {
        switch self {
        case .transport(let error): return error.underlying
        case .protocol(let error): return error.underlying
        default: return nil
        }
    }
    
    /// Machine-readable error type identifier for backend reporting.
    internal var typeIdentifier: String {
        switch self {
        case .transport(.network): return "network_error"
        case .transport(.persistence): return "persistence_error"
        case .protocol(.http): return "http_error"
        case .protocol(.api): return "api_error"
        case .protocol(.decoding): return "decoding_error"
        case .integration(.notConfigured): return "not_configured"
        case .integration(.invalidApiKey): return "invalid_api_key"
        case .integration(.invalidURL): return "invalid_url"
        case .domain: return "domain_error"
        }
    }
}

// MARK: - Equatable (for testing)
extension EncoreError: Equatable {
    public static func == (lhs: EncoreError, rhs: EncoreError) -> Bool {
        switch (lhs, rhs) {
        case (.transport(let l), .transport(let r)): return l == r
        case (.protocol(let l), .protocol(let r)): return l == r
        case (.integration(let l), .integration(let r)): return l == r
        case (.domain(let lMsg), .domain(let rMsg)): return lMsg == rMsg
        default: return false
        }
    }
}

extension EncoreError.TransportError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.network, .network): return true // Compare by type, not underlying
        case (.persistence, .persistence): return true
        default: return false
        }
    }
}

extension EncoreError.ProtocolError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.http(let lStatus, let lMsg), .http(let rStatus, let rMsg)):
            return lStatus == rStatus && lMsg == rMsg
        case (.api(let lStatus, let lCode, let lMsg), .api(let rStatus, let rCode, let rMsg)):
            return lStatus == rStatus && lCode == rCode && lMsg == rMsg
        case (.decoding, .decoding): return true // Compare by type
        default: return false
        }
    }
}

extension EncoreError.IntegrationError: Equatable {}
