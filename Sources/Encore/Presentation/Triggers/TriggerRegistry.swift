// The triggers this SDK build ships, by id. Registration is internal in v1:
// a host app cannot add its own.

import Foundation

@MainActor
internal struct TriggerRegistry {
    /// Builds a mounted host for a placement, its settings and appearance.
    typealias Factory = @MainActor (_ placement: String, _ settings: TriggerMountSettings, _ appearance: AppearanceConfig?) -> TriggerHosting

    private var factories: [String: Factory] = [:]

    /// Every shipped trigger, on live dependencies.
    static let shared: TriggerRegistry = {
        var registry = TriggerRegistry()
        registry.register(ClaimReminderTrigger.live)
        registry.register(GiftsSpotTrigger.live)
        return registry
    }()

    /// Ids already logged as unknown, so each is logged once per process.
    private static var loggedUnknown = Set<String>()

    /// `dependencies` nil means live. (Optional rather than a `.live` default: Swift 6.0
    /// rejects a main-actor default argument.)
    mutating func register<Plugin: TriggerPlugin>(
        _ plugin: @escaping @autoclosure @MainActor () -> Plugin,
        dependencies: TriggerHostModel<Plugin>.Dependencies? = nil
    ) {
        factories[Plugin.id] = { placement, settings, appearance in
            TriggerHostModel(
                plugin: plugin(),
                placement: placement,
                settings: settings,
                appearance: appearance,
                dependencies: dependencies ?? .live
            )
        }
    }

    var ids: Set<String> { Set(factories.keys) }

    /// The option that tells a plug-in it runs inside GiftsButton's after-claim slot. Internal:
    /// ``host(id:placement:settings:appearance:)`` drops it from an app's options.
    nonisolated static let slotOption = "slot"

    /// The two hosts' settings in GiftsButton's slot: the gifts host keeps the mount's; the reminder
    /// takes its use case, the pinned reminder look, no auto open and the same icon.
    static func slotSettings(_ settings: TriggerMountSettings) -> (gifts: TriggerMountSettings, reminder: TriggerMountSettings) {
        var gifts = settings
        gifts.options[slotOption] = GiftsButtonTrigger.id
        let reminder = TriggerMountSettings(
            useCase: settings.useCase, layout: settings.options[AfterClaim.reminderLayoutKey], autoOpen: nil,
            icon: settings.icon, options: [slotOption: GiftsButtonTrigger.id]
        )
        return (gifts, reminder)
    }

    /// A host for `id`, or nil when this build has no such trigger. Nil does no work at all.
    func host(id: String, placement: String, settings: TriggerMountSettings = TriggerMountSettings(), appearance: AppearanceConfig?) -> TriggerHosting? {
        // The slot option is the SDK's own: an app passing it would relabel events and change ×.
        var settings = settings
        settings.options[Self.slotOption] = nil
        guard let factory = factories[id] else {
            if Self.loggedUnknown.insert(id).inserted {
                Logger.warn(.configuration, "[TRIGGER] Unknown trigger id '\(id)'; rendering nothing")
            }
            return nil
        }
        return factory(placement, settings, appearance)
    }
}
