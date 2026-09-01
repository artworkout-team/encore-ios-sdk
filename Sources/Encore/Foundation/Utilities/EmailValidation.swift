//
//  EmailValidation.swift
//  Encore
//
//  Email format validation and private relay detection.
//

import Foundation

enum EmailValidation {

    /// Validates basic email format (local@domain.tld).
    static func isValid(_ email: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    /// Detects Apple's Hide My Email private relay addresses.
    /// These addresses cannot receive third-party mail and are unsuitable for lead capture.
    static func isPrivateRelay(_ email: String) -> Bool {
        email.lowercased().hasSuffix("@privaterelay.icloud.com")
    }
}
