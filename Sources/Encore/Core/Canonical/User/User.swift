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
/// - `language`: ISO 639-1 (e.g., "en", "es", "zh")
/// - `dateOfBirth`: ISO 8601 date (e.g., "1990-05-15")
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
    
    /// User's date of birth in ISO 8601 format.
    ///
    /// Example: "1990-05-15"
    public let dateOfBirth: String?
    
    /// User's gender.
    ///
    /// Common values: "male", "female", "non-binary", "prefer_not_to_say"
    public let gender: String?
    
    /// User's preferred language in ISO 639-1 format.
    ///
    /// Example: "en", "es", "zh", "ja"
    public let language: String?
    
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
    ///   - dateOfBirth: Date of birth in ISO 8601 format.
    ///   - gender: User's gender.
    ///   - language: ISO 639-1 language code (e.g., "en").
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
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.language = language
        self.subscriptionTier = subscriptionTier
        self.monthsSubscribed = monthsSubscribed
        self.billingCycle = billingCycle
        self.lastPaymentAmount = lastPaymentAmount
        self.lastActiveDate = lastActiveDate
        self.totalSessions = totalSessions
        self.iapProductId = iapProductId
        self.custom = custom
    }
    
    // MARK: - DTO Mapping
    
    /// Convert to API DTO for network requests
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
            dateOfBirth: dateOfBirth,
            gender: gender,
            language: language,
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
            dateOfBirth: new.dateOfBirth ?? dateOfBirth,
            gender: new.gender ?? gender,
            language: new.language ?? language,
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
    
    /// Full name constructed from firstName and lastName.
    /// Returns nil if both are nil/empty.
    var fullName: String? {
        let parts = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}


// Zero-cost rename kept as fix-it signage, like NotGrantedReason and
// EncorePresentationResult. Costs nothing to carry.
@available(*, deprecated, renamed: "UserAttributes")
public typealias EncoreAttributes = UserAttributes
