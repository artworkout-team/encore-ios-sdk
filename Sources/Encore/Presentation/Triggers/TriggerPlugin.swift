// The internal interface every embeddable trigger implements. The generic host
// (`TriggerHostModel`) owns fetching, events, dismissals and lifecycle; a plug-in
// supplies only what is specific to it: its content, its variant shape and its view.

import SwiftUI

// MARK: - Plug-in

/// One embeddable trigger, registered in ``TriggerRegistry`` under ``id``.
@MainActor
internal protocol TriggerPlugin {
    /// What the trigger reads before `/config`, e.g. the user's open claims.
    associatedtype Content
    /// `ui.template` as this trigger reads it. Decode leniently: a throw renders nothing.
    associatedtype Template: Decodable & Sendable
    /// The decoded variant.
    associatedtype Config: Equatable & Sendable
    /// What one render shows.
    associatedtype Model: Equatable
    associatedtype Body: View

    /// The trigger id: `/config`'s `trigger` and `template.trigger`.
    static var id: String { get }
    /// Layouts a mount may pin (`layout`). Any other pin renders nothing.
    static var pinnableLayouts: Set<String> { get }
    /// Other triggers whose looks this one's `/config` may answer with (vocab ALLOW `renders`).
    static var renders: Set<String> { get }
    /// The trigger whose dismissals this one reads and writes (GiftsButton: the reminder it draws).
    static var dismissalTrigger: String { get }
    /// Whether a claim-log change (a claim, a completion, a thanks tap) runs the gate again.
    static var regatesOnClaimLogChange: Bool { get }

    /// The `/config` request for this mount, or nil to render nothing. The default honours a
    /// known `layout` pin and never sends `autoOpen`.
    func request(for settings: TriggerMountSettings) -> TriggerRequest?

    /// The pre-config gate. Nil means nothing could show: render nothing and skip `/config`,
    /// which assigns the experiment arm.
    func prepare(_ context: TriggerPrepareContext) async -> TriggerGate<Content>
    /// What happened on the device, sent as `state` once the gate passed. Nil by default.
    func state(_ content: Content, context: TriggerPrepareContext) -> TriggerState?
    /// The device tally `request` sends, read as it is built. Nil (none) by default.
    func tally(for request: TriggerRequest, placement: String, now: Date) -> TriggerTally?
    /// The completion a behavior's hide is reported once for: its transaction, else its completion
    /// time in epoch milliseconds. Nil by default.
    func completionKey(_ content: Content) -> String?
    /// Nil renders nothing.
    func decode(_ template: Template) -> Config?
    /// A config the mount presents with instead of fetching `/config` (the app's own view): no
    /// look arm and no trigger holdout. Nil by default: fetch.
    func localConfig(for settings: TriggerMountSettings) -> Config?
    /// The ids a ``localConfig(for:)`` reports under (the rules the app's own view follows). None by default.
    var localVariant: TriggerVariant { get }
    /// Fields on a gate-time `eligible_not_shown`. Empty by default.
    var notShownFields: TriggerEventFields { get }
    /// Why this served config cannot be drawn on this mount at all (its look fails the strict
    /// check), or nil. The host reports it
    /// as soon as the config is read, whatever the content. Nil by default.
    func unrenderable(_ config: Config, settings: TriggerMountSettings) -> TriggerUnrenderable?
    /// What to show for this content under this variant, or nil for nothing.
    func present(_ content: Content, config: Config, context: TriggerPresentContext) -> TriggerPresentation<Model>?
    /// Whether this tap opens the sheet. If so the host mints its presentation id, puts it on
    /// `sdk_trigger_clicked` and presents under it. False by default.
    func opensSheet(_ model: Model, target: String) -> Bool
    /// Called synchronously when the host is about to fire an `autoTap` for this mount. A
    /// trigger limiting auto taps across mounts checks and records it here. After a hold
    /// the host presents again.
    func claimAutoTap(_ model: Model, target: String) -> TriggerAutoTapClaim
    /// A claimed auto tap never ran (its view went, or a tap was in flight): undo the claim.
    func autoTapAborted(_ model: Model)
    /// The SDK user or language changed on this mount: drop per-user mount state.
    func identityChanged()
    /// The shown item's impression counted (after the dwell). Nothing by default.
    func impressed(_ model: Model, variant: TriggerVariant, placement: String, now: Date)
    /// The trigger's own tap action (e.g. open the sheet). The host has already reported the tap.
    func onTap(_ model: Model, target: String, context: TriggerTapContext) async -> TriggerTapOutcome
    func render(_ model: Model, scope: TriggerRenderScope) -> Body
}

extension TriggerPlugin {
    func request(for settings: TriggerMountSettings) -> TriggerRequest? {
        guard let layout = settings.layout else { return TriggerRequest(useCase: settings.useCase) }
        guard Self.pinnableLayouts.contains(layout) else {
            TriggerLog.once("\(Self.id).layout.\(layout)", "\(Self.id): unknown layout '\(layout)'; rendering nothing")
            return nil
        }
        return TriggerRequest(useCase: settings.useCase, layout: layout)
    }

    func opensSheet(_ model: Model, target: String) -> Bool { false }
    func state(_ content: Content, context: TriggerPrepareContext) -> TriggerState? { nil }
    func tally(for request: TriggerRequest, placement: String, now: Date) -> TriggerTally? { nil }
    func impressed(_ model: Model, variant: TriggerVariant, placement: String, now: Date) {}
    func completionKey(_ content: Content) -> String? { nil }
    static var renders: Set<String> { TriggerBehavior.renders[id] ?? [] }
    static var dismissalTrigger: String { id }
    static var regatesOnClaimLogChange: Bool { false }
    func localConfig(for settings: TriggerMountSettings) -> Config? { nil }
    var localVariant: TriggerVariant { TriggerVariant(variantId: nil, experimentId: nil, locale: nil) }
    var notShownFields: TriggerEventFields { TriggerEventFields() }
    func unrenderable(_ config: Config, settings: TriggerMountSettings) -> TriggerUnrenderable? { nil }
    func claimAutoTap(_ model: Model, target: String) -> TriggerAutoTapClaim { .fire }
    func autoTapAborted(_ model: Model) {}
    func identityChanged() {}
}

// MARK: - Outcomes

/// What the pre-config gate found.
internal enum TriggerGate<Content> {
    /// Something could show: fetch the variant and present.
    case show(Content)
    /// Nothing to show (no claim, no offers). Silent, and no `/config`.
    case nothing
    /// It would have shown, but something else holds the user out (a `TriggerWire.NotShownReason`).
    /// No `/config`; the host reports it once per (placement, reason) per local day.
    case notShown(reason: String)
}

/// Whether an auto tap the host is about to fire goes ahead.
internal enum TriggerAutoTapClaim: Equatable {
    case fire
    /// Held back for `reason` (a `TriggerWire.NotShownReason`); the host reports it.
    case held(reason: String)
}

// MARK: - Mount settings

/// What the integrator set on one mount, besides the placement and appearance.
internal struct TriggerMountSettings: Sendable, Hashable {
    /// The use case the trigger serves: its sheet, its experiments and its events.
    var useCase: UseCase = .rewardUsers
    /// A pinned layout wire value; nil means managed.
    var layout: String? = nil
    /// `.off` forbids a look that opens the sheet by itself; nil lets Encore decide.
    var autoOpen: AutoOpen? = nil
    /// The look's icon: the gift, the app's own icon, or none.
    var icon: TriggerIcon = .gift
    /// GiftsButton reads `afterClaim`, `reminderLayout` and `afterComplete`; the SDK adds its own
    /// `slot` key inside GiftsButton (never an app's).
    var options: [String: String] = [:]
}

/// Logs a warning once per process per key.
@MainActor
internal enum TriggerLog {
    private static var logged = Set<String>()

    static func once(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        Logger.warn(.configuration, "[TRIGGER] \(message)")
    }
}

// MARK: - Contexts

internal struct TriggerPrepareContext {
    /// The integrator's placement label, as passed.
    let placement: String
    let now: Date
    /// This trigger's dismissed content keys on this device.
    let dismissed: Set<String>
    let settings: TriggerMountSettings
}

internal struct TriggerPresentContext {
    let placement: String
    let now: Date
    let dismissed: Set<String>
    let appearance: AppearanceConfig?
    let settings: TriggerMountSettings
    /// The app's portal theme and icon from the served variant.
    var portal: TriggerPortalTheme? = nil
    /// The mount's publisher values, checked (``TriggerValues/mountValues(_:)``).
    var values: [String: String] = [:]
    /// DEBUG builds only: the demo's text edits for this placement, applied before the fill. Empty otherwise.
    var stringOverrides: [String: String] = [:]
    /// The app's text for each slot, as passed (sanitised where a look takes it). Never leaves the phone.
    var texts: [TriggerTextSlot: String] = [:]
}

/// What a tap action can use beyond the model.
internal struct TriggerTapContext {
    let placement: String
    let settings: TriggerMountSettings
    let appearance: AppearanceConfig?
    /// The variant on show, for entry attribution on whatever the tap opens.
    let variant: TriggerVariant
    /// Minted by the host when ``TriggerPlugin/opensSheet(_:target:)`` said yes; already on the clicked event.
    let presentationId: String?
    /// Presents the regular Encore sheet, exactly as the app's own
    /// `placement(_:).useCase(_:).show()` would, under ``presentationId``, and returns once it closes.
    let presentSheet: @MainActor (TriggerSheetRequest) async -> PresentationResult
    /// False once the user or language changed since the tap, or the mount went away (its task
    /// cancelled): stop waiting, start nothing new.
    let isCurrent: @MainActor () -> Bool
    /// False once the user or language changed since the tap. A sheet that already showed still
    /// cleans up after itself when only the mount went away.
    let isSameIdentity: @MainActor () -> Bool
    /// When the tap happened, on the host's clock.
    var now = Date()
}

/// One Encore sheet a trigger opens.
/// It carries no appearance: a component's `appearance` styles only the component, and the sheet
/// resolves its own exactly as the app's `placement(_:).useCase(_:).show()` would.
internal struct TriggerSheetRequest: Sendable, Equatable {
    let placement: String?
    let useCase: UseCase
    /// The integrator's prize for this sheet; the host fills it from its own ``TriggerHostModel/publisherReward``.
    var publisherReward: PublisherReward? = nil
    /// Set by the host for an auto tap: if the mount goes away (or the user changes) while the
    /// sheet still loads, it never shows.
    var cancelsWithTask = false
}

/// Plug-in supplied event fields; the host adds the common ones.
internal struct TriggerEventFields: Sendable, Equatable {
    var transactionId: String?
    var campaignId: String?
    /// The layout actually rendered.
    var layout: String?
    /// The slots drawn with the app's text, sorted (`text_slots`); nil when none. Never the text.
    var textSlots: [String]? = nil
}

internal struct TriggerPresentation<Model: Equatable>: Equatable {
    let model: Model
    /// The view's fixed height. Bridges size their host to it; 0 draws nothing.
    let height: CGFloat
    /// The look's own cap (its root's `maxWidth`); nil fills the container.
    var maxWidth: CGFloat? = nil
    /// Identifies the shown item: the impression fires once per key, and dismiss stores it.
    let contentKey: String
    let eventFields: TriggerEventFields
    let dismissible: Bool
    /// When the host should present again, e.g. the end of a countdown.
    let refreshAt: Date?
    /// When the host should run the gate (and its request) again at once, e.g. the thanks state
    /// ending at midnight. At most once a day; never for an expiring offer set (``staleAt``).
    var regateAt: Date? = nil
    /// When the held sheet offers stop being served from the cache. The host only marks the item
    /// stale then (no request): its next appear, foreground or tap runs the gate. So a mount off
    /// screen, or under a sheet, sends no search while nobody can see or tap it.
    var staleAt: Date? = nil
    /// A tap target the host fires by itself, once per content key per host and user, and only after
    /// that item's impression counted, e.g. a trigger that opens the sheet without waiting for the user.
    var autoTap: String? = nil
    /// The variant's look failed the strict pre-check: the host draws nothing and reports it.
    var unrenderable: TriggerUnrenderable? = nil
    /// Other content keys a dismiss stores with ``contentKey`` (a slot's × hides every claim on show).
    var dismissAlso: [String] = []
}

internal enum TriggerTapOutcome: Sendable, Equatable {
    case keep
    /// Re-run `prepare`, e.g. the item is gone server side.
    case refresh
}

/// What a rendered trigger can do and know.
internal struct TriggerRenderScope {
    /// Any part on screen.
    let onScreen: Bool
    /// A tap action is in flight; further taps are ignored until it ends.
    var busy: Bool = false
    let tapped: (_ target: String) -> Void
    let dismissed: () -> Void
}
