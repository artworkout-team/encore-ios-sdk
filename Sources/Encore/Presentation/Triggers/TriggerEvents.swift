// The `sdk_trigger_*` events every trigger emits through the host. One family for all
// triggers, keyed by `trigger`; `use_case` is the real use case the mount serves.

import Foundation

// MARK: - Context

/// Fields every trigger event carries.
internal struct TriggerEventContext: Sendable, Equatable {
    let trigger: String
    /// The use case the mount serves, never a trigger-only value.
    let useCase: UseCase
    let placementId: String?
    let variantId: String?
    let experimentId: String?
    let fields: TriggerEventFields
    /// Goes to the envelope's `locale`, not the event properties.
    let servedLocale: String?
    /// The trigger whose spot this one is drawn in (a claim reminder inside GiftsButton); absent otherwise.
    var hostTrigger: String? = nil
    /// `ui.step`: a look's behavior chose what is drawn (or hidden).
    var step: String? = nil
    /// `ui.stepExperimentId`: the experiment that decided the step.
    var stepExperimentId: String? = nil

    /// The host trigger for `trigger` mounted with `settings`: the slot it runs in, unless that slot is its own.
    static func hostTrigger(of trigger: String, settings: TriggerMountSettings) -> String? {
        settings.options[TriggerRegistry.slotOption].flatMap { $0 == trigger ? nil : $0 }
    }
}

/// What a trigger reports. The live sink maps each case to its wire event.
internal enum TriggerEvent: Sendable, Equatable {
    case impression(TriggerEventContext)
    case clicked(TriggerEventContext, target: String, presentationId: String? = nil)
    /// A look opened its sheet by itself; sent once that sheet shows, naming it.
    case autoOpened(TriggerEventContext, presentationId: String?)
    case dismissed(TriggerEventContext)
    /// Would have rendered but did not, for `reason` (a `TriggerWire.NotShownReason`).
    case eligibleNotShown(TriggerEventContext, reason: String)

    func track(on client: AnalyticsClient?) {
        #if DEBUG
        let (name, context) = traced
        EncoreDebugTrace.record("event.sent", [
            "name": name, "trigger": context.trigger, "layout": context.fields.layout ?? "-",
            "variant": context.variantId ?? "-", "hostTrigger": context.hostTrigger ?? "-",
        ])
        #endif
        switch self {
        case .impression(let context):
            client?.track(TriggerImpressionEvent(context), locale: context.servedLocale)
        case .clicked(let context, let target, let presentationId):
            client?.track(TriggerClickedEvent(context, target: target, presentationId: presentationId), locale: context.servedLocale)
        case .autoOpened(let context, let presentationId):
            client?.track(TriggerAutoOpenedEvent(context, presentationId: presentationId), locale: context.servedLocale)
        case .dismissed(let context):
            client?.track(TriggerDismissedEvent(context), locale: context.servedLocale)
        case .eligibleNotShown(let context, let reason):
            client?.track(TriggerEligibleNotShownEvent(context, reason: reason), locale: context.servedLocale)
        }
    }
}

#if DEBUG
extension TriggerEvent {
    /// The wire event name and its context, for the DEBUG trace.
    var traced: (name: String, context: TriggerEventContext) {
        switch self {
        case .impression(let context): return (TriggerImpressionEvent.eventName, context)
        case .clicked(let context, _, _): return (TriggerClickedEvent.eventName, context)
        case .autoOpened(let context, _): return (TriggerAutoOpenedEvent.eventName, context)
        case .dismissed(let context): return (TriggerDismissedEvent.eventName, context)
        case .eligibleNotShown(let context, _): return (TriggerEligibleNotShownEvent.eventName, context)
        }
    }
}
#endif

// MARK: - Wire Events

private let triggerRequiredContext: Set<String> = ["trigger", "use_case"]

/// Wire body shared by the four events. `experiment_id` is an explicit null when absent,
/// as on every platform; the other optional fields are omitted.
private struct TriggerEventBody: Encodable {
    let context: TriggerEventContext
    let target: String?
    var presentationId: String?
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case trigger, placementId, variantId, experimentId, useCase, transactionId, campaignId, layout, target, presentationId, reason
        case hostTrigger, step, stepExperimentId, textSlots
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context.trigger, forKey: .trigger)
        try container.encode(context.useCase.rawValue, forKey: .useCase)
        try container.encodeIfPresent(context.placementId, forKey: .placementId)
        try container.encodeIfPresent(context.variantId, forKey: .variantId)
        try container.encode(context.experimentId, forKey: .experimentId)
        try container.encodeIfPresent(context.fields.transactionId, forKey: .transactionId)
        try container.encodeIfPresent(context.fields.campaignId, forKey: .campaignId)
        try container.encodeIfPresent(context.fields.layout, forKey: .layout)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(presentationId, forKey: .presentationId)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(context.hostTrigger, forKey: .hostTrigger)
        try container.encodeIfPresent(context.step, forKey: .step)
        try container.encodeIfPresent(context.stepExperimentId, forKey: .stepExperimentId)
        // What was drawn: never on eligible_not_shown (a reason), never empty.
        if reason == nil, let slots = context.fields.textSlots, !slots.isEmpty { try container.encode(slots, forKey: .textSlots) }
    }
}

/// At least half on screen for a second. Once per content key per host instance.
internal struct TriggerImpressionEvent: AnalyticsEvent {
    static let eventName = TriggerWire.Event.impression
    static var requiredContext: Set<String> { triggerRequiredContext }

    let context: TriggerEventContext

    init(_ context: TriggerEventContext) { self.context = context }

    func encode(to encoder: Encoder) throws {
        try TriggerEventBody(context: context, target: nil).encode(to: encoder)
    }
}

/// A click (`button`, `card`, `arrow`). `presentation_id` names the sheet it opened, when it opened one.
internal struct TriggerClickedEvent: AnalyticsEvent {
    static let eventName = TriggerWire.Event.clicked
    static var requiredContext: Set<String> { triggerRequiredContext.union(["target"]) }

    let context: TriggerEventContext
    let target: String
    let presentationId: String?

    init(_ context: TriggerEventContext, target: String, presentationId: String? = nil) {
        self.context = context
        self.target = target
        self.presentationId = presentationId
    }

    func encode(to encoder: Encoder) throws {
        try TriggerEventBody(context: context, target: target, presentationId: presentationId).encode(to: encoder)
    }
}

/// A look opened its sheet by itself, sent once that sheet shows: the click's fields, no target,
/// and `presentation_id` naming the sheet.
internal struct TriggerAutoOpenedEvent: AnalyticsEvent {
    static let eventName = TriggerWire.Event.autoOpened
    static var requiredContext: Set<String> { triggerRequiredContext }

    let context: TriggerEventContext
    let presentationId: String?

    init(_ context: TriggerEventContext, presentationId: String?) {
        self.context = context
        self.presentationId = presentationId
    }

    func encode(to encoder: Encoder) throws {
        try TriggerEventBody(context: context, target: nil, presentationId: presentationId).encode(to: encoder)
    }
}

/// The user dismissed the shown item on this device.
internal struct TriggerDismissedEvent: AnalyticsEvent {
    static let eventName = TriggerWire.Event.dismissed
    static var requiredContext: Set<String> { triggerRequiredContext }

    let context: TriggerEventContext

    init(_ context: TriggerEventContext) { self.context = context }

    func encode(to encoder: Encoder) throws {
        try TriggerEventBody(context: context, target: nil).encode(to: encoder)
    }
}

/// The user reached a mounted trigger that would have rendered but did not (reasons in
/// ``TriggerWire/NotShownReason``). Once per (trigger, placement, reason) per local day on this device.
internal struct TriggerEligibleNotShownEvent: AnalyticsEvent {
    static let eventName = TriggerWire.Event.eligibleNotShown
    static var requiredContext: Set<String> { triggerRequiredContext.union(["reason"]) }

    let context: TriggerEventContext
    let reason: String

    init(_ context: TriggerEventContext, reason: String) {
        self.context = context
        self.reason = reason
    }

    func encode(to encoder: Encoder) throws {
        try TriggerEventBody(context: context, target: nil, reason: reason).encode(to: encoder)
    }
}
