// The trigger `/config` fetch and its lenient envelope. Every wire string lives in
// `TriggerWire`, so a backend rename is a one-line change.

import Foundation

// MARK: - Wire

internal enum TriggerWire {
    /// The use case the trigger serves (the real one, e.g. `post-action-reward`). Always sent.
    static let useCaseQuery = "useCase"
    static let triggerQuery = "trigger"
    /// A pinned look: the server serves that layout's `pin` variant and never enrols.
    static let layoutQuery = "layout"
    /// The mount's opt-out from a look that opens the sheet by itself: sent as `autoOpen=off`, and only then.
    static let autoOpenQuery = "autoOpen"
    /// What happened on the device (``TriggerState``); the served look's behavior picks the step's look.
    static let stateQuery = "state"
    /// The Gifts Button's device tally (``TriggerTally``), one integer each.
    enum Tally {
        static let seenDays = "seenDays"
        static let seenCount = "seenCount"
        static let taps = "taps"
        static let firstSeenDaysAgo = "firstSeenDaysAgo"
        static let lastTapDaysAgo = "lastTapDaysAgo"
        static let nudges = "nudges"
    }
    /// The root `ui.template` key naming the trigger.
    static let templateTriggerKey = "trigger"
    static let path = "config"

    /// Event names, one family for every trigger.
    enum Event {
        static let impression = "sdk_trigger_impression"
        static let clicked = "sdk_trigger_clicked"
        /// A look opened its sheet by itself (once that sheet showed); the click's fields without a target.
        static let autoOpened = "sdk_trigger_auto_opened"
        static let dismissed = "sdk_trigger_dismissed"
        /// The user reached a mounted trigger that would have rendered but did not.
        static let eligibleNotShown = "sdk_trigger_eligible_not_shown"
    }

    /// `reason` values for ``Event/eligibleNotShown``.
    enum NotShownReason {
        /// The trigger's own experiment held the user out: a null template WITH an experiment id.
        static let holdout = "holdout"
        /// The sheet the trigger opens would show nothing for this user (no sheet served).
        static let sheetUnavailable = "sheet_unavailable"
        /// An auto trigger that already fired today for this placement.
        static let autoHeld = "auto_held"
        /// The variant's look uses something this SDK does not draw as authored.
        static let unrenderable = "unrenderable"
        /// The look's `behavior.afterComplete` is `hide`: nothing after a completion. Once per completion per mount.
        static let afterCompleteHide = "after_complete_hide"
        /// A null template with a `ui.step` this SDK does not know: nothing drawn, never a holdout.
        static let unknownStep = "unknown_step"
    }

    /// `ui.step` values.
    enum Step {
        static let afterClaim = "afterClaim"
        static let afterComplete = "afterComplete"
        /// The server nudged a user who keeps not tapping the button (its look's `ifIgnored`).
        static let ifIgnored = "ifIgnored"
        /// The steps this SDK knows; any other is read as no step (a newer server may add more).
        static let known: Set<String> = [afterClaim, afterComplete, ifIgnored]
    }
}

/// What happened on the device, sent as `state` on a trigger's `/config` (vocab §2.8).
internal enum TriggerState: String, Sendable, Hashable {
    /// An eligible open claim: in its window, in the held offers, not dismissed.
    case claimOpen
    /// An offer finished on this local day, none claimed since, its thanks not tapped.
    case completed
}

// MARK: - Request

/// What one mount asks `/config` for, beyond the trigger, user and placement.
internal struct TriggerRequest: Sendable, Hashable {
    let useCase: UseCase
    /// A pinned layout; nil means managed (experiment arm, else the trigger's default).
    var layout: String? = nil
    /// `autoOpen=off`: the mount forbids a look that opens the sheet by itself.
    var autoOpenOff = false
    /// Joins the cache key: each state has its own answer.
    var state: TriggerState? = nil
    /// The Gifts Button's device tally; joins the cache key, so a changed tally asks again.
    var tally: TriggerTally? = nil
}

/// What one placement's Gifts Button saw on this device and how the user answered, already capped.
/// The server alone decides what it means (the look's `ifIgnored` step).
internal struct TriggerTally: Sendable, Hashable {
    /// Distinct local days with a counted impression, before this request.
    var seenDays = 0
    /// Mounts whose impression counted.
    var seenCount = 0
    /// The user's own taps; a look's pop is not one.
    var taps = 0
    /// Local days since the first counted impression; 0 when never seen.
    var firstSeenDaysAgo = 0
    /// Local days since the last tap; nil (not sent) when never tapped.
    var lastTapDaysAgo: Int? = nil
    /// Impressions of an `ifIgnored` answer.
    var nudges = 0

    var query: [String: String] {
        var query = [
            TriggerWire.Tally.seenDays: String(seenDays),
            TriggerWire.Tally.seenCount: String(seenCount),
            TriggerWire.Tally.taps: String(taps),
            TriggerWire.Tally.firstSeenDaysAgo: String(firstSeenDaysAgo),
            TriggerWire.Tally.nudges: String(nudges),
        ]
        if let lastTapDaysAgo { query[TriggerWire.Tally.lastTapDaysAgo] = String(lastTapDaysAgo) }
        return query
    }
}

// MARK: - Results

/// Who a trigger is fetched for: the arm is assigned per user, the copy is served per language.
internal struct TriggerIdentity: Sendable, Hashable {
    let userId: String
    let language: String?
}

/// The served variant's ids and locale.
internal struct TriggerVariant: Sendable, Equatable {
    let variantId: String?
    let experimentId: String?
    /// Sets the view's direction and the events' locale.
    let locale: String?
    /// The app's portal theme and icon, from the served `ui.values`.
    var portal: TriggerPortalTheme? = nil
    /// `template.layout` as served, for an `unrenderable` report.
    var servedLayout: String? = nil
    /// `ui.step`: a look's behavior chose what is served (with template null, a hide).
    var step: String? = nil
    /// `ui.stepExperimentId`: the requested trigger's arm experiment, which decided the step.
    var stepExperimentId: String? = nil
    /// `template.trigger` when it is not the requested trigger (a reminder in a gifts button's spot).
    var drawnTrigger: String? = nil
}

/// What the app's portal settings add to a trigger's look: its accent, its light/dark mode and
/// its App Store icon (`ui.values.appearance` and `ui.values.media`).
internal struct TriggerPortalTheme: Sendable, Equatable, Decodable {
    let accentColor: String?
    /// `light`, `dark` or `auto` (follow the device).
    let mode: String?
    let appIconUrl: String?

    init(accentColor: String?, mode: String?, appIconUrl: String?) {
        self.accentColor = accentColor
        self.mode = mode
        self.appIconUrl = appIconUrl
    }

    private enum CodingKeys: String, CodingKey { case appearance, media }
    private enum AppearanceKeys: String, CodingKey { case accentColor, mode }
    private enum MediaKeys: String, CodingKey { case appstoreIcon }

    /// `ui.values`, leniently: a malformed field reads as absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appearance = try? container.nestedContainer(keyedBy: AppearanceKeys.self, forKey: .appearance)
        let media = try? container.nestedContainer(keyedBy: MediaKeys.self, forKey: .media)
        accentColor = (try? appearance?.decodeIfPresent(String.self, forKey: .accentColor)) ?? nil
        mode = (try? appearance?.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        appIconUrl = ((try? media?.decodeIfPresent(String.self, forKey: .appstoreIcon)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isEmpty: Bool { accentColor == nil && mode == nil && appIconUrl == nil }
}

/// A fetch, before the plug-in decodes the template.
internal enum TriggerFetch<Template: Sendable>: Sendable {
    case template(TriggerVariant, Template)
    /// The server answered for this trigger with a null template: holdout, no experiment,
    /// kill switch or a version gate. The ids are whatever the response carried.
    case heldOut(TriggerVariant)
    /// A null template with `step: afterComplete`: the look's behavior hides it after a completion.
    case hidden(TriggerVariant)
    /// A null template with a step this SDK does not know.
    case unknownStep(TriggerVariant)
    /// A look for a trigger the requested one may not render.
    case foreign(TriggerVariant, trigger: String)
    /// Another use case, or a template this build cannot read.
    case nothing
    /// Network or envelope failure; retried on the next refresh.
    case failed
}

/// A fetch after the plug-in's decode.
internal enum TriggerConfigResult<Config: Equatable & Sendable>: Equatable, Sendable {
    case config(TriggerVariant, Config)
    /// A null template for this trigger; see ``TriggerFetch/heldOut(_:)``.
    case heldOut(TriggerVariant)
    /// See ``TriggerFetch/hidden(_:)``.
    case hidden(TriggerVariant)
    /// See ``TriggerFetch/unknownStep(_:)``.
    case unknownStep(TriggerVariant)
    /// See ``TriggerFetch/foreign(_:trigger:)``.
    case foreign(TriggerVariant, trigger: String)
    case nothing
    case failed
}

extension TriggerFetch where Template: Decodable {
    init(decoding data: Data, trigger: String, renders: Set<String> = []) {
        guard let envelope = try? JSONCoding.decoder.decode(TriggerEnvelope<Template>.self, from: data) else {
            self = .failed
            return
        }
        self.init(envelope: envelope, trigger: trigger, renders: renders)
    }

    /// `renders`: the other triggers whose looks `trigger` may draw (vocab ALLOW `renders`).
    init(envelope: TriggerEnvelope<Template>, trigger: String, renders: Set<String> = []) {
        // A 2xx body that is not a /config envelope (no `ui`, or `success: false`) is a
        // failure to retry, never a cached "nothing".
        guard envelope.success != false, let ui = envelope.ui else {
            self = .failed
            return
        }
        var variant = TriggerVariant(
            variantId: ui.variantId, experimentId: ui.experimentId, locale: envelope.locale, portal: ui.portal, servedLayout: ui.servedLayout,
            step: ui.step, stepExperimentId: ui.stepExperimentId
        )
        if ui.templateIsNull {
            switch ui.step {
            case nil: self = .heldOut(variant)
            case TriggerWire.Step.afterComplete?: self = .hidden(variant)
            default: self = .unknownStep(variant)
            }
            return
        }
        // A sheet template (no trigger key) from a pod that does not know triggers: nothing.
        guard let drawn = ui.trigger else {
            self = .nothing
            return
        }
        guard drawn == trigger || renders.contains(drawn) else {
            self = .foreign(variant, trigger: drawn)
            return
        }
        if drawn != trigger { variant.drawnTrigger = drawn }
        // A drawn look's step this SDK does not know is read as no step.
        if let step = variant.step, !TriggerWire.Step.known.contains(step) { variant.step = nil }
        guard let template = ui.template else {
            Logger.warn(.configuration, "[TRIGGER] \(trigger) variant \(ui.variantId ?? "nil") template does not decode; rendering nothing")
            self = .nothing
            return
        }
        self = .template(variant, template)
    }
}

extension TriggerPlugin {
    func configResult(from fetch: TriggerFetch<Template>) -> TriggerConfigResult<Config> {
        switch fetch {
        case .template(let variant, let template):
            guard let config = decode(template) else {
                // Cached as nothing by the caller, so this logs once per variant fetch.
                Logger.warn(.configuration, "[TRIGGER] \(Self.id) variant \(variant.variantId ?? "nil") is not readable by this SDK; rendering nothing")
                return .nothing
            }
            return .config(variant, config)
        case .heldOut(let variant):
            return .heldOut(variant)
        case .hidden(let variant):
            return .hidden(variant)
        case .unknownStep(let variant):
            return .unknownStep(variant)
        case .foreign(let variant, let trigger):
            return .foreign(variant, trigger: trigger)
        case .nothing:
            return .nothing
        case .failed:
            return .failed
        }
    }
}

// MARK: - Envelope

/// `/config` as a trigger reads it. Every field is optional and a malformed one
/// reads as absent, so no server shape can throw into the host app.
internal struct TriggerEnvelope<Template: Decodable & Sendable>: Decodable {
    let ui: UI?
    let success: Bool?
    let locale: String?

    private enum CodingKeys: String, CodingKey { case ui, success, locale }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ui = try? container.decodeIfPresent(UI.self, forKey: .ui)
        success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        locale = try? container.decodeIfPresent(String.self, forKey: .locale)
    }

    struct UI: Decodable {
        let variantId: String?
        let experimentId: String?
        /// `template.trigger`, read apart from the plug-in's own decode.
        let trigger: String?
        /// `template.layout` as served, read the same way.
        let servedLayout: String?
        let template: Template?
        /// `template` is absent or JSON null.
        let templateIsNull: Bool
        /// The app's portal theme and icon from `values`; nil when absent or empty.
        let portal: TriggerPortalTheme?
        let step: String?
        let stepExperimentId: String?

        private enum CodingKeys: String, CodingKey { case variantId, experimentId, template, values, step, stepExperimentId }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            variantId = try? container.decodeIfPresent(String.self, forKey: .variantId)
            experimentId = try? container.decodeIfPresent(String.self, forKey: .experimentId)
            let header = try? container.decodeIfPresent(Header.self, forKey: .template)
            trigger = header?.trigger
            servedLayout = header?.layout
            template = try? container.decodeIfPresent(Template.self, forKey: .template)
            templateIsNull = !container.contains(.template) || ((try? container.decodeNil(forKey: .template)) ?? false)
            portal = (try? container.decodeIfPresent(TriggerPortalTheme.self, forKey: .values)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
            step = (try? container.decodeIfPresent(String.self, forKey: .step)) ?? nil
            stepExperimentId = (try? container.decodeIfPresent(String.self, forKey: .stepExperimentId)) ?? nil
        }
    }

    private struct Header: Decodable {
        let trigger: String?
        let layout: String?

        private struct Key: CodingKey {
            let stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            trigger = try? container.decodeIfPresent(String.self, forKey: Key(stringValue: TriggerWire.templateTriggerKey))
            layout = try? container.decodeIfPresent(String.self, forKey: Key(stringValue: "layout"))
        }
    }
}

// MARK: - Loader

/// Fetches one trigger's variant. Never throws.
internal struct TriggerConfigLoader: Sendable {
    let client: HTTPClientProtocol

    func load<Template: Decodable & Sendable>(
        _ template: Template.Type,
        trigger: String,
        request: TriggerRequest,
        identity: TriggerIdentity,
        sdkVersion: String,
        placement: String?,
        renders: Set<String> = []
    ) async -> TriggerFetch<Template> {
        var query: [String: String?] = [
            "userId": identity.userId,
            "sdkVersion": sdkVersion,
            // Always sent, churn included: the server has no default for a trigger.
            TriggerWire.useCaseQuery: request.useCase.rawValue,
            TriggerWire.triggerQuery: trigger,
        ]
        if let layout = request.layout { query[TriggerWire.layoutQuery] = layout }
        if request.autoOpenOff { query[TriggerWire.autoOpenQuery] = AutoOpen.off.rawValue }
        if let state = request.state { query[TriggerWire.stateQuery] = state.rawValue }
        for (key, value) in request.tally?.query ?? [:] { query[key] = value }
        if let language = identity.language, !language.isEmpty { query["language"] = language }
        if let placement = PlacementLabel.sanitized(placement) { query["placementId"] = placement }
        do {
            let envelope: TriggerEnvelope<Template> = try await client.request(path: TriggerWire.path, method: "GET", query: query)
            return TriggerFetch(envelope: envelope, trigger: trigger, renders: renders)
        } catch {
            Logger.debug(.configuration, "[TRIGGER] \(trigger) config fetch failed: \(error)")
            return .failed
        }
    }
}
