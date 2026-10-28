// The rules the app's own view follows (`/config?trigger=customClaim`): what it does after a claim,
// after a completion, and whether it opens the sheet by itself. Encore sets them per look so they can
// be tested; a failed or empty read keeps today's behaviour.

import Foundation

/// One placement's rules, and the ids its events report under.
internal struct CustomClaimRules: Equatable, Sendable {
    static let trigger = "customClaim"

    var afterClaim: AfterClaim = .showReminder
    var afterComplete: AfterComplete = .gifts
    /// The look opens the sheet once by itself (only ever an experiment arm).
    var autoOpen = false
    /// The ids events carry: the served look's, or none when nothing was read.
    var variant = TriggerVariant(variantId: nil, experimentId: nil, locale: nil)

    /// Today's behaviour: what the handle does before (or without) an answer.
    static let defaults = CustomClaimRules()

    /// The rules from `behavior`; an unknown step or value keeps that step's default.
    init(behavior: JSONValue? = nil, variant: TriggerVariant = TriggerVariant(variantId: nil, experimentId: nil, locale: nil)) {
        let steps = TriggerBehavior.resolved(behavior, trigger: Self.trigger)
        afterClaim = steps["afterClaim"].flatMap(AfterClaim.init(rawValue:)) ?? .showReminder
        afterComplete = steps["afterComplete"].flatMap(AfterComplete.init(rawValue:)) ?? .gifts
        autoOpen = steps["autoOpen"] == TriggerBehavior.autoOpenOn
        self.variant = variant
    }

    /// What a fetch answered: the arm's rules; anything else (nothing configured, a null template
    /// with or without an experiment) is today's behaviour with no ids.
    init(fetch: TriggerFetch<CustomClaimTemplate>) {
        switch fetch {
        case .template(let variant, let template) where template.trigger == Self.trigger:
            self.init(behavior: template.behavior, variant: variant)
        default:
            self.init()
        }
    }
}

/// The rules one handle follows, shared by its hosts' plug-ins so new ids or a new `autoOpen` apply
/// in place, without new hosts.
@MainActor
internal final class CustomClaimRulesBox {
    var rules: CustomClaimRules
    init(_ rules: CustomClaimRules = .defaults) { self.rules = rules }
}

/// `ui.template` for `customClaim`: rules only. Any drawn key (a root, strings) is ignored.
internal struct CustomClaimTemplate: Decodable, Sendable {
    let trigger: String?
    let behavior: JSONValue?

    private enum CodingKeys: String, CodingKey { case trigger, behavior }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try? container.decodeIfPresent(String.self, forKey: .trigger)
        behavior = try? container.decodeIfPresent(JSONValue.self, forKey: .behavior)
    }
}

/// Reads one placement's rules once per identity (the shared cache), never retrying a failure inside.
/// Nil when nothing could be read (no client or user yet, a failure): keep the rules in force.
@MainActor
internal enum CustomClaimRulesLoader {
    static func load(
        placement: String, useCase: UseCase, autoOpenOff: Bool,
        client: HTTPClientProtocol?, identity: TriggerIdentity?, sdkVersion: String, cache: TriggerConfigCache
    ) async -> CustomClaimRules? {
        guard let client, let identity else { return nil }
        let request = TriggerRequest(useCase: useCase, autoOpenOff: autoOpenOff)
        let key = TriggerConfigCache.Key(trigger: CustomClaimRules.trigger, request: request, placement: PlacementLabel.sanitized(placement), identity: identity)
        let result: TriggerConfigResult<CustomClaimRules> = await cache.result(for: key) {
            let fetch = await TriggerConfigLoader(client: client).load(
                CustomClaimTemplate.self, trigger: CustomClaimRules.trigger, request: request,
                identity: identity, sdkVersion: sdkVersion, placement: placement
            )
            if case .failed = fetch { return .failed }
            let rules = CustomClaimRules(fetch: fetch)
            return .config(rules.variant, rules)
        }
        if case .config(_, let rules) = result { return rules }
        return nil
    }
}
