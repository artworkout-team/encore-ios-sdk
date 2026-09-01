
internal struct ErrorResponse: Codable {
    let error: String
    let code: String?
    let success: Bool?
}
