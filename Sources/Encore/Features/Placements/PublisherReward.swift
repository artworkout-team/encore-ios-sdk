// The app's own prize for trying an offer ("reward for trying") and its daily limit.
// Encore's server decides every promise and every grant; the device keeps no count.
// A Yes never reaches Encore's money path.

import Foundation

// MARK: - Public API

/// A prize your app pays when the user says they finished an offer.
///
/// Passing one is a commitment: grant it when `result.claim?.userConfirmedCompletion`
/// is true, which happens only when Encore's server granted it. An app whose reward
/// settings pay on verification never gets the flag: credit `reward.amount` from the
/// `offer_completed` webhook instead, once per `transactionId`. Only `id` leaves the device.
public struct PublisherReward: Sendable, Equatable {
    /// Stable identifier, sent as `publisher_reward_id` on analytics.
    public let id: String
    /// What the user gets, e.g. "100 coins". Blank means no prize.
    public let title: String
    /// Optional line under the promise.
    public let detail: String?
    /// Optional remote icon for the promise.
    public let iconUrl: URL?

    public init(id: String, title: String, detail: String? = nil, iconUrl: URL? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.iconUrl = iconUrl
    }

    /// A blank id or title is treated as no prize, so no promise is shown.
    var isUsable: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The icon to show, or nil: it needs an `http://` or `https://` prefix (any case)
    /// and a host, the rule the React Native and Flutter bridges apply.
    var promisableIconUrl: String? {
        guard let raw = iconUrl?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let lowered = raw.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
              let host = URL(string: raw)?.host, !host.isEmpty else { return nil }
        return raw
    }
}

/// Limits on how often the prize can be earned. Set ``Encore/publisherRewardPolicy``.
///
/// Encore's server enforces them per identified user across devices: one prize per
/// offer, ever, and `dailyLimit` (clamped to `1...10`) per rolling 24 hours.
public struct PublisherRewardPolicy: Sendable, Equatable {
    /// Hard ceiling on ``dailyLimit``.
    public static let maxDailyLimit = 10

    public let dailyLimit: Int

    public init(dailyLimit: Int = 3) {
        self.dailyLimit = min(max(dailyLimit, 1), Self.maxDailyLimit)
    }
}

// MARK: - Variant values

/// The `context.values` keys the reward-for-trying variant reads. The variant
/// tests them with `hasValue`, so "not eligible" is an absent key, never "false".
/// Inside a card, `publisherRewardTitle` reads that offer's own prize when it has one.
enum PublisherRewardValueKey {
    static let title = "publisherRewardTitle"
    static let detail = "publisherRewardDetail"
    static let iconUrl = "publisherRewardIconUrl"
    static let eligible = "publisherRewardEligible"
}

/// How the app pays its prize, from the offers search. A string on the wire, so
/// a mode this SDK doesn't know is read as on-yes rather than failing the search.
enum PublisherRewardMode: Sendable, Equatable {
    /// A granted Yes pays (`userConfirmedCompletion`).
    case onYes
    /// A Yes never pays; the app pays from the brand's verified completion.
    case onVerified

    init(wire: String?) {
        self = wire == "on_verified" ? .onVerified : .onYes
    }
}

/// Why a question or a Yes earned no prize. Analytics wire values; `no_prize`,
/// `per_offer`, `daily_cap` and `pays_on_verification` are also the server's
/// `reason` on a self-report.
enum PublisherRewardIneligibility: String, Sendable {
    case noPrize = "no_prize"
    case perOffer = "per_offer"
    case dailyCap = "daily_cap"
    /// The app pays when the brand confirms the completion, never on a Yes.
    case paysOnVerification = "pays_on_verification"
    /// No identified user: prizes are promised only after identify().
    case anonymous = "anonymous"
    /// The server gave no answer: an older backend, offline, or too slow.
    case unverified = "unverified"
}

// MARK: - The pre-release prize count

/// Pre-release builds of this feature counted prizes per user id on the device. The
/// server keeps that count now, so `configure` removes any such record.
enum LegacyPrizeCount {
    static let storeKey = "com.encore.publisherRewardCaps"

    static func remove(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storeKey)
    }
}
