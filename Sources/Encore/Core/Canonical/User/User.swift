// Sources/Encore/Domain/Entities/User.swift
//
// User domain entities.
// Contains user attributes for targeting and personalization.
//

import Foundation

/// Structured user attributes for offer targeting and personalization.
///
/// `UserAttributes` contains optional metadata about a user that can be used
/// to personalize offers and improve targeting. All fields are optional—pass
/// only what you have available.
///
/// ## Basic Usage
///
/// ```swift
/// let attributes = UserAttributes(
///     email: "user@example.com",
///     firstName: "Jane",
///     subscriptionTier: "premium"
/// )
/// Encore.shared.identify(userId: "user_123", attributes: attributes)
/// ```
///
/// ## Updating Attributes
///
/// Use ``Encore/setUserAttributes(_:)`` to update attributes after initial identification.
/// New attributes are **merged** with existing ones:
///
/// ```swift
/// // After subscription upgrade
/// Encore.shared.setUserAttributes(UserAttributes(
///     subscriptionTier: "enterprise",
///     billingCycle: "annual"
/// ))
/// ```
///
/// ## Custom Attributes
///
/// Use the ``custom`` dictionary for any app-specific attributes not covered
/// by the standard fields:
///
/// ```swift
/// let attributes = UserAttributes(
///     email: "user@example.com",
///     custom: [
///         "app_version": "2.1.0",
///         "feature_flag_beta": "true",
///         "preferred_category": "electronics"
///     ]
/// )
/// ```
///
/// ## Expected Formats
///
/// - `countryCode`: ISO 3166-1 alpha-2 (e.g., "US", "GB", "DE")
/// - `age`: whole years, 0 to 120. Anything else is dropped with a warning.
/// - `dateOfBirth`: "YYYY-MM-DD", or an ISO 8601 date-time with a zone. Kept on the device only.
/// - `latitude`/`longitude`: Decimal degrees as strings (e.g., "37.7749", "-122.4194")
///
/// - Note: The `userId` is handled separately via ``Encore/identify(userId:attributes:)``
///         since it represents identity, not metadata.
public struct UserAttributes: Codable, Equatable, Sendable {
    
    /// User's email address.
    ///
    /// Used for personalized communications and offer targeting.
    public let email: String?
    
    /// User's first name.
    public let firstName: String?
    
    /// User's last name.
    public let lastName: String?
    
    /// User's phone number.
    ///
    /// Include country code for international numbers (e.g., "+1-555-123-4567").
    public let phoneNumber: String?
    
    /// User's postal/ZIP code.
    public let postalCode: String?
    
    /// User's city.
    public let city: String?
    
    /// User's state or province.
    public let state: String?
    
    /// User's country code in ISO 3166-1 alpha-2 format.
    ///
    /// Example: "US", "GB", "DE", "JP"
    public let countryCode: String?
    
    /// User's latitude as a decimal degrees string.
    ///
    /// Example: "37.7749"
    public let latitude: String?
    
    /// User's longitude as a decimal degrees string.
    ///
    /// Example: "-122.4194"
    public let longitude: String?
    
    /// The user's age in whole years, 0 to 120. A value outside that range is dropped with a warning.
    /// If you hold only a range, pass its lowest end ("13-17" is 13), so a minor is never counted as an adult.
    /// Sent only in the launch you set it and not saved, so pass ``dateOfBirth``, or set the age on every launch.
    public let age: Int?

    /// The user's date of birth, "YYYY-MM-DD" or an ISO 8601 date-time with a zone. Never sent: each
    /// request carries the whole-year age it gives that day, the lower one when ``age`` is set too.
    public let dateOfBirth: String?
    
    /// User's gender.
    ///
    /// Common values: "male", "female", "non-binary", "prefer_not_to_say"
    public let gender: String?
    
    /// The language passed to the initializer. Passing one forwards to
    /// ``Encore/setLanguage(_:)``; it is not stored or sent as an attribute.
    @available(*, deprecated, message: "Use Encore.shared.setLanguage(_:). Removed in the next major version.")
    public var language: String? { languageTag }

    /// The language this attribute set asks for: a host's deprecated
    /// `language`, or the override on the attributes a request carries.
    internal let languageTag: String?
    
    /// User's current subscription tier in your app.
    ///
    /// Example: "free", "basic", "premium", "enterprise"
    public let subscriptionTier: String?
    
    /// Number of months the user has been subscribed.
    public let monthsSubscribed: String?
    
    /// User's billing cycle.
    ///
    /// Example: "monthly", "annual", "quarterly"
    public let billingCycle: String?
    
    /// User's last payment amount as a string.
    ///
    /// Example: "9.99", "99.99"
    public let lastPaymentAmount: String?
    
    /// User's last active date in ISO 8601 format.
    ///
    /// Example: "2024-01-15T10:30:00Z"
    public let lastActiveDate: String?
    
    /// Total number of app sessions.
    public let totalSessions: String?
    
    /// IAP product ID to present when an offer is granted.
    ///
    /// If set, the SDK can automatically initiate an in-app purchase
    /// for this product when the user accepts an offer.
    @available(*, deprecated, message: "Use config.entitlements.iap.productId from remote config instead")
    public let iapProductId: String?

    /// Custom attributes for advanced targeting.
    ///
    /// Use this dictionary for any app-specific attributes not covered
    /// by the standard fields above.
    ///
    /// ```swift
    /// UserAttributes(
    ///     email: "user@example.com",
    ///     custom: [
    ///         "loyalty_tier": "gold",
    ///         "referral_source": "friend"
    ///     ]
    /// )
    /// ```
    public let custom: [String: String]
    
    /// Creates a new set of user attributes.
    ///
    /// All parameters are optional. Pass only the attributes you have available.
    ///
    /// - Parameters:
    ///   - email: User's email address.
    ///   - firstName: User's first name.
    ///   - lastName: User's last name.
    ///   - phoneNumber: User's phone number (include country code).
    ///   - postalCode: User's postal/ZIP code.
    ///   - city: User's city.
    ///   - state: User's state or province.
    ///   - countryCode: ISO 3166-1 alpha-2 country code (e.g., "US").
    ///   - latitude: Latitude as decimal degrees string.
    ///   - longitude: Longitude as decimal degrees string.
    ///   - age: Age in whole years, 0 to 120; anything else is dropped with a warning.
    ///   - dateOfBirth: "YYYY-MM-DD"; sent only as the age it gives. Unreadable: dropped with a warning.
    ///   - gender: User's gender.
    ///   - language: Deprecated: forwards to ``Encore/setLanguage(_:)``.
    ///   - subscriptionTier: Current subscription tier in your app.
    ///   - monthsSubscribed: Months the user has been subscribed.
    ///   - billingCycle: Billing frequency (e.g., "monthly", "annual").
    ///   - lastPaymentAmount: Last payment amount as a string.
    ///   - lastActiveDate: Last active timestamp in ISO 8601 format.
    ///   - totalSessions: Total number of app sessions.
    ///   - iapProductId: IAP product ID to trigger on offer acceptance.
    ///   - custom: Dictionary of custom key-value attributes.
    public init(
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        phoneNumber: String? = nil,
        postalCode: String? = nil,
        city: String? = nil,
        state: String? = nil,
        countryCode: String? = nil,
        latitude: String? = nil,
        longitude: String? = nil,
        age: Int? = nil,
        dateOfBirth: String? = nil,
        gender: String? = nil,
        language: String? = nil,
        subscriptionTier: String? = nil,
        monthsSubscribed: String? = nil,
        billingCycle: String? = nil,
        lastPaymentAmount: String? = nil,
        lastActiveDate: String? = nil,
        totalSessions: String? = nil,
        iapProductId: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.phoneNumber = phoneNumber
        self.postalCode = postalCode
        self.city = city
        self.state = state
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.age = Self.validAge(age)
        self.dateOfBirth = Self.readableDateOfBirth(dateOfBirth)
        self.gender = gender
        self.languageTag = language
        self.subscriptionTier = subscriptionTier
        self.monthsSubscribed = monthsSubscribed
        self.billingCycle = billingCycle
        self.lastPaymentAmount = lastPaymentAmount
        self.lastActiveDate = lastActiveDate
        self.totalSessions = totalSessions
        self.iapProductId = iapProductId
        self.custom = custom
    }
    
    /// The accepted range, matching the backend and the web SDK.
    static let ageRange = 0...120

    private static func validAge(_ age: Int?) -> Int? {
        guard let age else { return nil }
        guard ageRange.contains(age) else {
            Logger.warn("[USER] age \(age) is outside 0...120 whole years; dropped")
            return nil
        }
        return age
    }

    /// Nil and blank pass as nil; a value with no age in it is dropped, so a merge keeps the last good one.
    private static func readableDateOfBirth(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard DateOfBirth.bornAt(value) != nil else {
            Logger.warn("[USER] dateOfBirth is not a YYYY-MM-DD date; dropped")
            return nil
        }
        return value
    }

    // MARK: - Age

    /// The age a request carries: the lower of ``age`` and the age ``dateOfBirth`` gives at `now`.
    /// A date in the future or over 120 years back gives none.
    internal func resolvedAge(now: Date = Date()) -> Int? {
        let fromDate = dateOfBirth.flatMap { DateOfBirth.age(of: $0, at: now) }
        switch (age, fromDate) {
        case let (stated?, computed?): return min(stated, computed)
        case let (stated, computed): return stated ?? computed
        }
    }

    /// What leaves the device: the resolved age, and no date of birth.
    internal func forWire(now: Date = Date()) -> UserAttributes {
        UserAttributes(
            email: email, firstName: firstName, lastName: lastName, phoneNumber: phoneNumber,
            postalCode: postalCode, city: city, state: state, countryCode: countryCode,
            latitude: latitude, longitude: longitude, age: resolvedAge(now: now), dateOfBirth: nil, gender: gender,
            language: languageTag,
            subscriptionTier: subscriptionTier, monthsSubscribed: monthsSubscribed, billingCycle: billingCycle,
            lastPaymentAmount: lastPaymentAmount, lastActiveDate: lastActiveDate, totalSessions: totalSessions,
            iapProductId: iapProductId, custom: custom
        )
    }

    // MARK: - DTO Mapping
    
    /// The /offers request DTO. `language` is the host's override, which the
    /// server reads as the explicit locale over Accept-Language.
    internal var asDTO: DTO.Offers.UserAttributes {
        DTO.Offers.UserAttributes(
            email: email,
            firstName: firstName,
            lastName: lastName,
            mobile: phoneNumber,
            phoneNumber: phoneNumber,
            postcode: postalCode,
            postalCode: postalCode,
            city: city,
            state: state,
            region: state,
            countryCode: countryCode,
            latitude: latitude,
            longitude: longitude,
            age: resolvedAge(),
            dateOfBirth: nil,
            gender: gender,
            language: languageTag,
            subscriptionTier: subscriptionTier,
            monthsSubscribed: monthsSubscribed,
            billingCycle: billingCycle,
            lastPaymentAmount: lastPaymentAmount,
            lastActiveDate: lastActiveDate,
            totalSessions: totalSessions,
            custom: custom.isEmpty ? nil : .init(additionalProperties: custom.mapValues { $0 })
        )
    }
    
    // MARK: - Merging
    
    /// Merge with new attributes, preferring non-nil values from the new attributes
    internal func merged(with new: UserAttributes) -> UserAttributes {
        UserAttributes(
            email: new.email ?? email,
            firstName: new.firstName ?? firstName,
            lastName: new.lastName ?? lastName,
            phoneNumber: new.phoneNumber ?? phoneNumber,
            postalCode: new.postalCode ?? postalCode,
            city: new.city ?? city,
            state: new.state ?? state,
            countryCode: new.countryCode ?? countryCode,
            latitude: new.latitude ?? latitude,
            longitude: new.longitude ?? longitude,
            age: new.age ?? age,
            dateOfBirth: new.dateOfBirth ?? dateOfBirth,
            gender: new.gender ?? gender,
            language: new.languageTag ?? languageTag,
            subscriptionTier: new.subscriptionTier ?? subscriptionTier,
            monthsSubscribed: new.monthsSubscribed ?? monthsSubscribed,
            billingCycle: new.billingCycle ?? billingCycle,
            lastPaymentAmount: new.lastPaymentAmount ?? lastPaymentAmount,
            lastActiveDate: new.lastActiveDate ?? lastActiveDate,
            totalSessions: new.totalSessions ?? totalSessions,
            iapProductId: new.iapProductId ?? iapProductId,
            custom: custom.merging(new.custom) { _, new in new }
        )
    }
    
    /// These attributes with `language` set to `tag`. The merge cannot remove
    /// a value (nil means "keep"), so this is how it is dropped or replaced.
    internal func withLanguage(_ tag: String?) -> UserAttributes {
        UserAttributes(
            email: email, firstName: firstName, lastName: lastName, phoneNumber: phoneNumber,
            postalCode: postalCode, city: city, state: state, countryCode: countryCode,
            latitude: latitude, longitude: longitude, age: age, dateOfBirth: dateOfBirth, gender: gender,
            language: tag,
            subscriptionTier: subscriptionTier, monthsSubscribed: monthsSubscribed, billingCycle: billingCycle,
            lastPaymentAmount: lastPaymentAmount, lastActiveDate: lastActiveDate, totalSessions: totalSessions,
            iapProductId: iapProductId, custom: custom
        )
    }

    /// These attributes with ``age`` set to `age`; nil removes it.
    internal func withAge(_ age: Int?) -> UserAttributes {
        UserAttributes(
            email: email, firstName: firstName, lastName: lastName, phoneNumber: phoneNumber,
            postalCode: postalCode, city: city, state: state, countryCode: countryCode,
            latitude: latitude, longitude: longitude, age: age, dateOfBirth: dateOfBirth, gender: gender,
            language: languageTag,
            subscriptionTier: subscriptionTier, monthsSubscribed: monthsSubscribed, billingCycle: billingCycle,
            lastPaymentAmount: lastPaymentAmount, lastActiveDate: lastActiveDate, totalSessions: totalSessions,
            iapProductId: iapProductId, custom: custom
        )
    }

    // MARK: - Coding

    /// Every SDK saved and sent the language under `language`. `dateOfBirth` is saved on the device;
    /// ``forWire(now:)`` strips it before anything is sent.
    private enum CodingKeys: String, CodingKey {
        case email, firstName, lastName, phoneNumber, postalCode, city, state, countryCode
        case latitude, longitude, age, dateOfBirth, gender
        case languageTag = "language"
        case subscriptionTier, monthsSubscribed, billingCycle, lastPaymentAmount, lastActiveDate, totalSessions
        case iapProductId, custom
    }

    /// Decodes through the initializer so a saved or bridged `age` and `dateOfBirth` are checked too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            email: try c.decodeIfPresent(String.self, forKey: .email),
            firstName: try c.decodeIfPresent(String.self, forKey: .firstName),
            lastName: try c.decodeIfPresent(String.self, forKey: .lastName),
            phoneNumber: try c.decodeIfPresent(String.self, forKey: .phoneNumber),
            postalCode: try c.decodeIfPresent(String.self, forKey: .postalCode),
            city: try c.decodeIfPresent(String.self, forKey: .city),
            state: try c.decodeIfPresent(String.self, forKey: .state),
            countryCode: try c.decodeIfPresent(String.self, forKey: .countryCode),
            latitude: try c.decodeIfPresent(String.self, forKey: .latitude),
            longitude: try c.decodeIfPresent(String.self, forKey: .longitude),
            age: Self.decodeAge(c),
            dateOfBirth: try? c.decodeIfPresent(String.self, forKey: .dateOfBirth),
            gender: try c.decodeIfPresent(String.self, forKey: .gender),
            language: try c.decodeIfPresent(String.self, forKey: .languageTag),
            subscriptionTier: try c.decodeIfPresent(String.self, forKey: .subscriptionTier),
            monthsSubscribed: try c.decodeIfPresent(String.self, forKey: .monthsSubscribed),
            billingCycle: try c.decodeIfPresent(String.self, forKey: .billingCycle),
            lastPaymentAmount: try c.decodeIfPresent(String.self, forKey: .lastPaymentAmount),
            lastActiveDate: try c.decodeIfPresent(String.self, forKey: .lastActiveDate),
            totalSessions: try c.decodeIfPresent(String.self, forKey: .totalSessions),
            iapProductId: try c.decodeIfPresent(String.self, forKey: .iapProductId),
            custom: try c.decodeIfPresent([String: String].self, forKey: .custom) ?? [:]
        )
    }

    /// A whole number as is; a fraction (a bridge map, hand-written JSON) floored, so 17.9 stays a minor,
    /// as the backend and web read it. Not a number: absent, never a failed decode.
    private static func decodeAge(_ c: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let whole = try? c.decodeIfPresent(Int.self, forKey: .age) { return whole }
        guard let number = try? c.decodeIfPresent(Double.self, forKey: .age) else { return nil }
        let floored = number.rounded(.down)
        // Past Int32 the conversion could trap; anything that far out is dropped by the range check anyway.
        guard floored.isFinite, abs(floored) <= Double(Int32.max) else { return Int.max }
        return Int(floored)
    }

    /// Full name constructed from firstName and lastName.
    /// Returns nil if both are nil/empty.
    var fullName: String? {
        let parts = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}


// MARK: - Date of birth

/// The backend's reading of a date of birth (`requestAge.ts`), so the SDK and a direct API call agree.
internal enum DateOfBirth {
    private static let pattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2}))?$"#
    )

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The instant of birth, or nil when the text is not a real calendar date in a form the backend reads.
    static func bornAt(_ value: String) -> Date? {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = pattern?.firstMatch(in: value, range: range) else { return nil }
        func int(_ i: Int) -> Int? { Range(match.range(at: i), in: value).flatMap { Int(value[$0]) } }
        guard let y = int(1), let m = int(2), let d = int(3) else { return nil }
        let day = DateComponents(year: y, month: m, day: d)
        // A day that does not round-trip (2010-02-30) is not a date.
        guard let midnight = utc.date(from: day),
              utc.dateComponents([.year, .month, .day], from: midnight) == day else { return nil }
        guard let hour = int(4), let minute = int(5),
              let zoneRange = Range(match.range(at: 7), in: value) else { return midnight }
        let seconds = hour * 3600 + minute * 60 + (int(6) ?? 0)
        return midnight.addingTimeInterval(TimeInterval(seconds - offsetSeconds(String(value[zoneRange]))))
    }

    /// Whole years at `now`, in UTC; nil for an unreadable date, one in the future, or one over 120 years.
    static func age(of value: String, at now: Date) -> Int? {
        guard let born = bornAt(value), born <= now else { return nil }
        let b = utc.dateComponents([.year, .month, .day], from: born)
        let n = utc.dateComponents([.year, .month, .day], from: now)
        guard let by = b.year, let bm = b.month, let bd = b.day,
              let ny = n.year, let nm = n.month, let nd = n.day else { return nil }
        let beforeBirthday = nm < bm || (nm == bm && nd < bd)
        let age = ny - by - (beforeBirthday ? 1 : 0)
        return UserAttributes.ageRange.contains(age) ? age : nil
    }

    private static func offsetSeconds(_ zone: String) -> Int {
        guard zone != "Z" else { return 0 }
        let digits = zone.dropFirst().filter(\.isNumber)
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.suffix(2)) ?? 0
        return (zone.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}

// Zero-cost rename kept as fix-it signage, like NotGrantedReason and
// EncorePresentationResult. Costs nothing to carry.
@available(*, deprecated, renamed: "UserAttributes")
public typealias EncoreAttributes = UserAttributes
