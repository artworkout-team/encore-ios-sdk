// State behind one mounted trigger: runs the plug-in's pre-config gate, fetches the
// variant, presents, and reports impression / clicked / dismissed. Generic over the plug-in.

import Foundation
import Combine
import UIKit

/// `impression` timing, shared by every trigger.
internal enum TriggerViewed {
    /// How long a trigger must stay half visible before `impression` fires.
    static let defaultDwellNanoseconds: UInt64 = 1_000_000_000
}

@MainActor
internal final class TriggerHostModel<Plugin: TriggerPlugin>: ObservableObject {

    /// What the view shows. Nil means render nothing.
    struct Shown: Equatable {
        let presentation: TriggerPresentation<Plugin.Model>
        let variant: TriggerVariant
    }

    struct Dependencies {
        /// The configured SDK's API client; nil before `configure()`.
        var client: @MainActor () -> HTTPClientProtocol?
        var sdkVersion: String
        /// The current user and language. A change refetches: the arm is assigned per
        /// user and the copy is served per language. Nil before `configure()`.
        var identity: @MainActor () -> TriggerIdentity?
        var storage: KeyValueStore
        var track: @MainActor (TriggerEvent) -> Void
        var now: @MainActor () -> Date
        /// Presents the regular sheet, under the given presentation id when there is one.
        var presentSheet: @MainActor (TriggerSheetRequest, _ presentationId: String?) async -> PresentationResult
        var cache: TriggerConfigCache
        /// Local days, for once-a-day `eligible_not_shown`.
        var calendar: Calendar = .autoupdatingCurrent
        /// How long the view must stay half visible before `impression` fires.
        var viewDwellNanoseconds: UInt64 = TriggerViewed.defaultDwellNanoseconds
        /// Whether the app is active: an auto tap fires only then, never while inactive (Control
        /// Center, a call banner, the app switcher) or in the background.
        var isActive: @MainActor () -> Bool = { true }
        /// Whether the app is in the background: an auto tap is not even armed then.
        var isInBackground: @MainActor () -> Bool = { false }
    }

    @Published private(set) var shown: Shown?
    /// A tap action is in flight.
    @Published private(set) var isActing = false
    /// The first refresh has ended, whatever it found: a slot waits for this before drawing.
    @Published private(set) var answered = false
    /// Hidden inside a slot: no impression, no auto tap and no not-shown report until shown again.
    var suppressed = false {
        didSet {
            guard suppressed != oldValue else { return }
            if suppressed {
                dwellTask?.cancel()
                dwellTask = nil
                waitingUncovered = false
            } else {
                if isVisible { startDwellIfNeeded() }
                fireAutoTapIfNeeded()
            }
        }
    }

    /// Passed to every sheet this trigger opens, as `placement(...).publisherReward(_:)` would.
    var publisherReward: PublisherReward?
    /// Gets each sheet's result once, after it closes, for a tap and an auto tap alike.
    var onResult: ((PresentationResult) -> Void)?

    let plugin: Plugin
    let placement: String
    let settings: TriggerMountSettings
    private(set) var appearance: AppearanceConfig?
    /// The mount's checked publisher values; not part of any request or cache key.
    private(set) var values: [String: String] = [:]
    /// The values as last passed, so an unchanged set is not checked (or logged) again.
    private var passedValues: [String: String] = [:]
    /// The app's slot text; not part of any request or cache key, and never sent.
    private(set) var texts: [TriggerTextSlot: String] = [:]
    private let deps: Dependencies
    private let dismissals: TriggerDismissals

    private var content: Plugin.Content?
    /// The last result this host presented from; the source of truth is the shared cache.
    private var config: TriggerConfigResult<Plugin.Config>?
    /// Content keys this host already auto-tapped for the current user.
    private var autoTapped = Set<String>()
    /// Bumped only on a user or language change, so a tap result from before one is dropped.
    private var identityEpoch = 0
    /// Bumped per refresh, so a slower earlier refresh cannot overwrite a newer one.
    private var generation = 0
    private var viewed = Set<String>()
    private var isVisible = false
    private var dwellTask: Task<Void, Never>?
    private var refreshAtTask: Task<Void, Never>?
    private var regateTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    /// The held offers expired: the next appear, foreground or tap runs the gate first.
    private(set) var isStale = false
    /// The auto tap in flight. Cancelled when the view goes away or the user changes, so a
    /// pop waiting behind another sheet never opens one for a mount that is gone.
    private var autoTapTask: Task<Void, Never>?
    /// A pending auto tap's observers: it fires once the app is active, or is cancelled in the background.
    private var activeObservers: [NSObjectProtocol] = []
    /// Set by the view: whether it is at least half visible and uncovered right now.
    var visibilityCheck: (@MainActor () -> Bool)?
    /// `dwellTask` is checking for a cover to go, not timing a dwell.
    private var waitingUncovered = false
    /// The offers the shown item stands for may be gone (new targeting, an evicted set):
    /// taps wait for the gate that runs next.
    private(set) var regatePending = false
    /// The re-gate started for changed offers. ``regatePending`` clears when the newest
    /// refresh, whichever started it, completes.
    private var heldRegate: Task<Void, Never>?
    /// Its view went away (``stop()``) and has not appeared again (``start()``): notifications
    /// leave it alone, so a host off screen never loads, re-arms its timers or pops a sheet.
    private(set) var isStopped = false
    /// Until its view first appears (``start()``), no notification loads the host: a mount below
    /// the fold or a view not yet in a window sends nothing.
    private(set) var hasAppeared = false

    /// Re-presents when any host of this trigger on this device is dismissed.
    nonisolated(unsafe) private var dismissObserver: NSObjectProtocol?
    /// Runs the gate again when the claim log changes, for a plug-in that asks.
    nonisolated(unsafe) private var claimLogObserver: NSObjectProtocol?
    /// DEBUG: redraws when the demo edits a string.
    nonisolated(unsafe) private var debugStringsObserver: NSObjectProtocol?
    /// The impression dwell runs only while the app is active: resigning stops it, becoming active starts it afresh.
    nonisolated(unsafe) private var appStateObservers: [NSObjectProtocol] = []

    init(plugin: Plugin, placement: String, settings: TriggerMountSettings = TriggerMountSettings(), appearance: AppearanceConfig? = nil, dependencies: Dependencies) {
        self.plugin = plugin
        self.placement = placement
        self.settings = settings
        self.appearance = appearance
        self.deps = dependencies
        self.dismissals = TriggerDismissals(trigger: Plugin.dismissalTrigger, storage: dependencies.storage)
        let id = Plugin.dismissalTrigger
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .encoreTriggerDismissed, object: nil, queue: nil
        ) { [weak self] note in
            guard note.userInfo?["trigger"] as? String == id else { return }
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return }
                self.reevaluate()
            }
        }
        #if DEBUG
        debugStringsObserver = NotificationCenter.default.addObserver(forName: .encoreTriggerDebugStringsChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
        #endif
        let center = NotificationCenter.default
        appStateObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelDwell() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.startDwellIfNeeded()
                }
            },
        ]
        if Plugin.regatesOnClaimLogChange {
            claimLogObserver = NotificationCenter.default.addObserver(forName: .encoreClaimLogDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.notifiedRefresh() }
            }
        }
    }

    deinit {
        dismissObserver.map(NotificationCenter.default.removeObserver)
        claimLogObserver.map(NotificationCenter.default.removeObserver)
        debugStringsObserver.map(NotificationCenter.default.removeObserver)
        activeObservers.forEach(NotificationCenter.default.removeObserver)
        appStateObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Loading

    /// Runs the plug-in's gate, then reads the variant from the shared cache (fetched once
    /// per trigger, placement and identity) only when something could show: the fetch
    /// assigns the arm, so a user with nothing to show is never counted as exposed.
    /// Runs on appear and on every foreground.
    func refresh() async {
        generation += 1
        let current = generation
        // The newest gate to finish, and only that one, lifts a block on taps for changed offers.
        defer {
            if current == generation, !Task.isCancelled {
                regatePending = false
                answered = true
                // An auto tap held back by the pending gate may go now.
                fireAutoTapIfNeeded()
            }
        }
        // Churn is not supported yet (its sheet runs the NCL intercept): nothing, no request, no event.
        guard settings.useCase != .reduceChurn else {
            TriggerLog.once("\(Plugin.id).churn", "\(Plugin.id) does not support the churn use case yet; rendering nothing")
            return clear()
        }
        guard var request = plugin.request(for: settings) else { return clear() }
        guard let identity = deps.identity() else { return clear() }

        let prepareContext = TriggerPrepareContext(placement: placement, now: deps.now(), dismissed: dismissals.keys(now: deps.now()), settings: settings)
        let gate = await plugin.prepare(prepareContext)
        // Cancelled with its view: apply nothing (and so fire no auto tap).
        guard current == generation, !Task.isCancelled else { return }
        // `/config` assigns an arm to the user it names. If the user or language changed
        // during the gate, this content is not that user's: send nothing.
        guard deps.identity() == identity else { return clear() }
        switch gate {
        case .show(let content):
            self.content = content
            request.state = plugin.state(content, context: prepareContext)
        case .nothing:
            return clear()
        case .notShown(let reason):
            clear()
            return reportNotShown(reason: reason, variant: nil, fields: plugin.notShownFields)
        }
        // The app draws its own view: no look to fetch, so no arm and no holdout.
        if let local = plugin.localConfig(for: settings) {
            config = .config(plugin.localVariant, local)
            return reevaluate()
        }

        request.tally = plugin.tally(for: request, placement: placement, now: deps.now())
        let result = await cachedConfig(request, identity: identity, reason: request.state?.rawValue ?? "mount")
        // The result belongs to `identity`; a user who changed meanwhile gets their own.
        guard deps.identity() == identity, current == generation, !Task.isCancelled else { return }
        config = result
        // Holdout means the experiment held this user out; a null template with no
        // experiment (nothing configured, kill switch) is not a counterfactual.
        // It carries the holdout's own experiment and never a variant: the user saw no arm.
        if case .heldOut(let variant) = result, variant.experimentId != nil {
            let holdout = TriggerVariant(variantId: nil, experimentId: variant.experimentId, locale: variant.locale)
            reportNotShown(reason: TriggerWire.NotShownReason.holdout, variant: holdout, fields: TriggerEventFields())
        }
        // The look's behavior hides it after a completion: never a holdout, once per completion here.
        if case .hidden(let variant) = result {
            reportHidden(variant: variant, completion: content.flatMap(plugin.completionKey))
        }
        // A step this SDK does not know chose nothing: reported as such, never as a holdout.
        if case .unknownStep(let variant) = result {
            reportNotShown(reason: TriggerWire.NotShownReason.unknownStep, variant: TriggerVariant(
                variantId: variant.variantId, experimentId: variant.experimentId, locale: variant.locale,
                step: variant.step, stepExperimentId: variant.stepExperimentId
            ), fields: TriggerEventFields())
        }
        if case .foreign(let variant, let trigger) = result {
            reportUnrenderable(
                TriggerUnrenderable(path: "trigger", detail: "\(trigger) is not a look \(Plugin.id) may draw"),
                variant: variant, layout: variant.servedLayout
            )
        }
        // A served look this SDK cannot draw is reported now, as the config is read, whatever the
        // content would show (as on Android).
        if case .config(let variant, let loaded) = result, let failure = plugin.unrenderable(loaded, settings: settings) {
            reportUnrenderable(failure, variant: variant, layout: variant.servedLayout)
        }
        reevaluate()
    }

    /// `request`'s result from the shared cache, else one fetch.
    private func cachedConfig(_ request: TriggerRequest, identity: TriggerIdentity, reason: String) async -> TriggerConfigResult<Plugin.Config> {
        let key = TriggerConfigCache.Key(trigger: Plugin.id, request: request, placement: PlacementLabel.sanitized(placement), identity: identity)
        // Captures values, not this host: the shared fetch serves every host asking, so it
        // must not depend on the first one staying mounted.
        let (plugin, client, sdkVersion, placement) = (plugin, deps.client, deps.sdkVersion, placement)
        return await deps.cache.result(for: key) {
            await Self.fetchConfig(plugin: plugin, client: client(), request: request, sdkVersion: sdkVersion, placement: placement, identity: identity, reason: reason)
        }
    }

    /// `reason` (why this host asked) is for the DEBUG trace only.
    private static func fetchConfig(
        plugin: Plugin, client: HTTPClientProtocol?, request: TriggerRequest, sdkVersion: String, placement: String, identity: TriggerIdentity,
        reason: String
    ) async -> TriggerConfigResult<Plugin.Config> {
        guard let client else { return .failed }
        #if DEBUG
        EncoreDebugTrace.record("config.fetch", ["trigger": Plugin.id, "placement": placement, "layout": request.layout ?? "-", "reason": reason])
        #endif
        let fetch = await TriggerConfigLoader(client: client).load(
            Plugin.Template.self,
            trigger: Plugin.id,
            request: request,
            identity: identity,
            sdkVersion: sdkVersion,
            placement: placement,
            renders: Plugin.renders
        )
        return plugin.configResult(from: fetch)
    }

    /// The SDK user or language changed: drop the previous variant and content at once.
    /// The caller refreshes next. (`TriggerIdentityChange.post()` already emptied the cache.)
    func userChanged() {
        generation += 1
        config = nil
        viewed = []
        autoTapped = []
        autoTapTask?.cancel()
        autoTapTask = nil
        heldRegate?.cancel()
        heldRegate = nil
        regatePending = false
        plugin.identityChanged()
        identityEpoch += 1
        isActing = false
        clear()
    }

    func setAppearance(_ appearance: AppearanceConfig?) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        reevaluate()
    }

    /// Redraws what is on show with the new values: no gate, no fetch, the same item.
    func setValues(_ values: [String: String]) {
        guard values != passedValues else { return }
        passedValues = values
        let checked = TriggerValues.mountValues(values)
        guard checked != self.values else { return }
        self.values = checked
        reevaluate()
    }

    /// Redraws what is on show with the new slot text: no gate, no fetch, the same item.
    func setTexts(_ texts: [TriggerTextSlot: String]) {
        guard texts != self.texts else { return }
        self.texts = texts
        reevaluate()
    }

    /// Presents again against the current time, dismissals and appearance.
    func reevaluate() {
        guard case .config(let variant, let config) = config, let content else { return apply(nil) }
        let context = TriggerPresentContext(
            placement: placement, now: deps.now(), dismissed: dismissals.keys(now: deps.now()), appearance: appearance,
            settings: settings, portal: variant.portal, values: values, stringOverrides: Self.debugStringOverrides(placement),
            texts: texts
        )
        let presentation = plugin.present(content, config: config, context: context)
        if let presentation, let failure = presentation.unrenderable {
            apply(nil)
            // The served look itself was reported when its config was read.
            guard plugin.unrenderable(config, settings: settings) == nil else { return }
            return reportUnrenderable(failure, variant: variant, layout: presentation.eventFields.layout)
        }
        apply(presentation.map { Shown(presentation: $0, variant: variant) })
    }

    /// The demo's text edits for `placement`; always empty in a release build.
    private static func debugStringOverrides(_ placement: String) -> [String: String] {
        #if DEBUG
        return TriggerDebugStrings.overrides(placement: placement)
        #else
        return [:]
        #endif
    }

    private func clear() {
        content = nil
        apply(nil)
    }

    private func apply(_ next: Shown?) {
        let changedKey = next?.presentation.contentKey != shown?.presentation.contentKey
        if next != shown { shown = next }
        isStale = false
        scheduleRefreshAt()
        scheduleRegate()
        scheduleStale()
        if changedKey {
            dwellTask?.cancel()
            dwellTask = nil
            waitingUncovered = false
            if isVisible { startDwellIfNeeded() }
        }
        fireAutoTapIfNeeded()
    }

    private func fireAutoTapIfNeeded() {
        // Once per content key per mount, then the trigger's own (cross-mount) say. Never while hidden,
        // in the background, or for a view that went away; the next foreground's gate presents again.
        guard !suppressed, !isStopped, let shown, let target = shown.presentation.autoTap,
              !autoTapped.contains(shown.presentation.contentKey) else { return }
        // A tap in flight or a gate pending: not now (and no day claimed); the next present tries again.
        guard !isActing, !regatePending else { return }
        // In the background (a gate that finished there): never armed; the next foreground's gate arms it.
        guard !deps.isInBackground() else { return }
        // Not active yet (the gate runs at willEnterForeground, before the app is active): wait.
        guard deps.isActive() else { return waitUntilActive() }
        // Only after this item's impression counted (half on screen, uncovered, for the dwell): never for
        // a mount nobody saw. The impression fires it then.
        guard viewed.contains(shown.presentation.contentKey) else { return }
        autoTapped.insert(shown.presentation.contentKey)
        switch plugin.claimAutoTap(shown.presentation.model, target: target) {
        case .fire:
            let model = shown.presentation.model
            autoTapTask = Task { [weak self] in
                guard let self else { return }
                // Stopped before it ran, or refused at the tap's own guard: give the claimed day back.
                if await self.tap(target, auto: true) == nil { self.plugin.autoTapAborted(model) }
            }
        case .held(let reason):
            reportNotShown(reason: reason, variant: shown.variant, fields: shown.presentation.eventFields)
            // Present again without the auto tap: the same look, now only tapped by the user.
            reevaluate()
        }
    }

    /// Arms the auto tap the gate found (at willEnterForeground, before the app is active): it fires
    /// on didBecomeActive, and is cancelled on didEnterBackground (the next foreground's gate arms it
    /// again). Removed when it fires, is cancelled, or the view goes.
    private func waitUntilActive() {
        guard activeObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activeObservers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopWaitingUntilActive()
                    self.fireAutoTapIfNeeded()
                }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopWaitingUntilActive() }
            },
        ]
    }

    private func stopWaitingUntilActive() {
        activeObservers.forEach(NotificationCenter.default.removeObserver)
        activeObservers = []
    }

    private func scheduleRefreshAt() {
        refreshAtTask?.cancel()
        guard let at = shown?.presentation.refreshAt else { return refreshAtTask = nil }
        let delay = max(0, at.timeIntervalSince(deps.now()))
        refreshAtTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 7 * 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }

    private func scheduleRegate() {
        regateTask?.cancel()
        guard let at = shown?.presentation.regateAt else { return regateTask = nil }
        let delay = max(0, at.timeIntervalSince(deps.now()))
        regateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 7 * 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Marks the shown item stale when its held offers expire. No request: whoever can see or tap
    /// it next (an appear, a foreground, a tap) runs the gate.
    private func scheduleStale() {
        staleTask?.cancel()
        guard let at = shown?.presentation.staleAt else { return staleTask = nil }
        let delay = max(0, at.timeIntervalSince(deps.now()))
        staleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 7 * 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isStale = true
        }
    }

    // MARK: - Actions

    /// Hides the shown item on this device for good. No server write.
    func dismiss() {
        // Like a second tap, a dismiss waits for the tap action in flight.
        guard !isActing, let shown, shown.presentation.dismissible else { return }
        dismissals.add(shown.presentation.contentKey, now: deps.now())
        for key in shown.presentation.dismissAlso { dismissals.add(key, now: deps.now()) }
        deps.track(.dismissed(eventContext(for: shown)))
        // Every mounted host of this trigger, this one included, presents again.
        NotificationCenter.default.post(name: .encoreTriggerDismissed, object: nil, userInfo: ["trigger": Plugin.dismissalTrigger])
    }

    /// The offer set behind the shown item may no longer be what a tap would open: block taps
    /// at once, then run the gate again (the variant stays cached).
    func heldOffersChanged() {
        regatePending = true
        // Off screen: taps stay blocked, and the next appearance's gate lifts it.
        guard hasAppeared, !isStopped else { return }
        heldRegate?.cancel()
        heldRegate = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// A notification asks for a fresh gate (foreground, configure, a user change). A host whose
    /// view went away waits for its next appearance instead.
    func notifiedRefresh() {
        guard hasAppeared, !isStopped else { return }
        Task { [weak self] in await self?.refresh() }
    }

    /// The view appeared (again): notifications may refresh it from here on.
    func start() {
        hasAppeared = true
        isStopped = false
    }

    /// The view went away: drop refreshes in flight, stop the auto tap and the timers. Until its
    /// next appearance (``start()``), notifications do not load it again.
    func stop() {
        isStopped = true
        generation += 1
        autoTapTask?.cancel()
        autoTapTask = nil
        stopWaitingUntilActive()
        // Taps stay blocked: the next appearance's gate is the one that lifts it.
        heldRegate?.cancel()
        heldRegate = nil
        refreshAtTask?.cancel()
        refreshAtTask = nil
        regateTask?.cancel()
        regateTask = nil
        staleTask?.cancel()
        staleTask = nil
        visibilityChanged(false)
    }

    /// Reports the click and runs the plug-in's action. One action at a time. A user's click
    /// goes out first; an auto tap that opens a sheet is reported only once that sheet shows.
    /// Returns what ``onResult`` got, or nil when nothing was handed to it.
    @discardableResult
    func tap(_ target: String, auto: Bool = false) async -> PresentationResult? {
        // The held offers expired: the tap waits for a fresh gate, then acts on what it shows.
        if isStale, !auto, !isActing, !regatePending {
            isActing = true
            await refresh()
            isActing = false
        }
        guard !isActing, !regatePending, let shown else { return nil }
        #if DEBUG
        EncoreDebugTrace.record("tap", ["trigger": Plugin.id, "placement": placement, "target": target])
        #endif
        let presentationId = plugin.opensSheet(shown.presentation.model, target: target) ? UUID().uuidString : nil
        // A look's own pop is its own event (no target); a tap is a click.
        let clicked = auto
            ? TriggerEvent.autoOpened(eventContext(for: shown), presentationId: presentationId)
            : TriggerEvent.clicked(eventContext(for: shown), target: target, presentationId: presentationId)
        var showingObserver: NSObjectProtocol?
        if auto, let presentationId {
            let track = deps.track
            showingObserver = NotificationCenter.default.addObserver(forName: .encoreSheetShowingDidChange, object: nil, queue: nil) { note in
                guard note.userInfo?["presentationId"] as? String == presentationId else { return }
                MainActor.assumeIsolated { track(clicked) }
            }
        } else {
            deps.track(clicked)
        }
        defer { showingObserver.map(NotificationCenter.default.removeObserver) }
        isActing = true
        let epoch = identityEpoch
        // Retries of one presentation (a pop waiting behind another sheet) are one sheet: keep the last result.
        let sheetResult = TriggerSheetResultBox()
        let context = TriggerTapContext(
            placement: placement,
            settings: settings,
            appearance: appearance,
            variant: shown.variant,
            presentationId: presentationId,
            presentSheet: { [weak self, presentSheet = deps.presentSheet] request in
                var request = request
                if request.publisherReward == nil { request.publisherReward = self?.publisherReward }
                request.cancelsWithTask = auto
                let result = await presentSheet(request, presentationId)
                sheetResult.value = result
                return result
            },
            isCurrent: { [weak self] in self?.identityEpoch == epoch && !Task.isCancelled },
            isSameIdentity: { [weak self] in self.map { $0.identityEpoch == epoch } ?? true },
            now: deps.now()
        )
        let outcome = await plugin.onTap(shown.presentation.model, target: target, context: context)
        // An automatic open aborted before it showed (its view went away) opened nothing to report.
        var reported: PresentationResult?
        if let result = sheetResult.value, result != .notPresented(.error(OfferSheetCoordinator.cancelledByCaller)) {
            reported = result
            onResult?(result)
        }
        // A user change meanwhile already released the guard; this result is not the new user's.
        guard epoch == identityEpoch else { return reported }
        isActing = false
        if outcome == .refresh { await refresh() } else { fireAutoTapIfNeeded() }
        return reported
    }

    // MARK: - Viewed

    /// The view crossed the half-visible line (geometry; covers are checked apart). `impression` fires after a full dwell.
    func visibilityChanged(_ visible: Bool) {
        isVisible = visible
        // A fresh report starts over: stop waiting and check from now.
        if waitingUncovered {
            waitingUncovered = false
            dwellTask?.cancel()
            dwellTask = nil
        }
        if visible {
            startDwellIfNeeded()
        } else {
            cancelDwell()
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        waitingUncovered = false
    }

    /// While the trigger stays in view but covered, checks again every quarter second.
    private func waitUntilUncovered() {
        #if DEBUG
        EncoreDebugTrace.record("impression.covered", ["trigger": Plugin.id, "placement": placement])
        #endif
        waitingUncovered = true
        dwellTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.isVisible else { return }
                if self.visibilityCheck?() ?? true {
                    self.dwellTask = nil
                    self.waitingUncovered = false
                    return self.startDwellIfNeeded()
                }
            }
        }
    }

    private func startDwellIfNeeded() {
        // Nothing drawn (zero height) is never viewed, nor anything while the app is not active
        // (background, Control Center, a call banner): becoming active starts it.
        guard !suppressed, dwellTask == nil, deps.isActive(), let shown, shown.presentation.height > 0,
              !viewed.contains(shown.presentation.contentKey) else { return }
        // Covered already (a sheet or modal over it): wait for it to go before timing.
        guard visibilityCheck?() ?? true else { return waitUntilUncovered() }
        let key = shown.presentation.contentKey
        let dwell = deps.viewDwellNanoseconds
        #if DEBUG
        EncoreDebugTrace.record("impression.dwellStart", ["trigger": Plugin.id, "placement": placement])
        #endif
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: dwell)
            guard !Task.isCancelled else { return }
            self?.dwellElapsed(for: key)
        }
    }

    private func dwellElapsed(for key: String) {
        dwellTask = nil
        guard isVisible, deps.isActive(), let shown, shown.presentation.contentKey == key else { return }
        // A sheet or modal may have covered it during the dwell without moving it. A host's
        // own modal sends no signal when it goes, so keep checking, then dwell afresh.
        guard visibilityCheck?() ?? true else { return waitUntilUncovered() }
        guard viewed.insert(key).inserted else { return }
        #if DEBUG
        EncoreDebugTrace.record("impression.fired", ["trigger": Plugin.id, "placement": placement, "key": key])
        #endif
        deps.track(.impression(eventContext(for: shown)))
        plugin.impressed(shown.presentation.model, variant: shown.variant, placement: placement, now: deps.now())
        // An auto tap waits for this impression.
        fireAutoTapIfNeeded()
    }

    /// A look this SDK cannot draw: logged once per variant, and reported as Android does, with the
    /// served layout and the variant's ids and no item fields.
    private func reportUnrenderable(_ failure: TriggerUnrenderable, variant: TriggerVariant, layout: String?) {
        TriggerLog.once("\(Plugin.id).unrenderable.\(variant.variantId ?? "nil").\(layout ?? "-")",
                        "\(Plugin.id) variant \(variant.variantId ?? "nil") is unrenderable at \(failure.path): \(failure.detail); rendering nothing")
        reportNotShown(reason: TriggerWire.NotShownReason.unrenderable, variant: variant, fields: TriggerEventFields(layout: layout))
    }

    /// Reports that the trigger would have rendered but did not, once per (trigger,
    /// placement, reason) per local day on this device.
    private func reportNotShown(reason: String, variant: TriggerVariant?, fields: TriggerEventFields) {
        // A host hidden inside a slot was never the one the user reached.
        guard !suppressed else { return }
        let parts = deps.calendar.dateComponents([.year, .month, .day], from: deps.now())
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let key = TriggerNotShownRecords.key(trigger: Plugin.id, placement: PlacementLabel.sanitized(placement) ?? "", reason: reason)
        guard (deps.storage.load(key) as String?) != day else { return }
        deps.storage.save(day, to: key)
        sendNotShown(reason: reason, variant: variant, fields: fields)
    }

    /// A behavior's hide after a completion (`after_complete_hide`): once per completion per
    /// (trigger, placement), keyed on the completion, never on the day.
    private func reportHidden(variant: TriggerVariant, completion: String?) {
        guard !suppressed else { return }
        let reason = TriggerWire.NotShownReason.afterCompleteHide
        let key = TriggerNotShownRecords.key(trigger: Plugin.id, placement: PlacementLabel.sanitized(placement) ?? "", reason: reason)
        // Only a completion is marked: a later empty read with none marks nothing.
        guard let completion else { return }
        guard (deps.storage.load(key) as String?) != completion else { return }
        deps.storage.save(completion, to: key)
        // The response's variant when it names one (as Android sends it); nil otherwise.
        sendNotShown(reason: reason, variant: TriggerVariant(
            variantId: variant.variantId, experimentId: variant.experimentId, locale: variant.locale,
            step: variant.step, stepExperimentId: variant.stepExperimentId
        ), fields: TriggerEventFields())
    }

    private func sendNotShown(reason: String, variant: TriggerVariant?, fields: TriggerEventFields) {
        var context = TriggerEventContext(
            trigger: Plugin.id,
            useCase: settings.useCase,
            placementId: PlacementLabel.sanitized(placement),
            variantId: variant?.variantId,
            experimentId: variant?.experimentId,
            fields: fields,
            servedLocale: variant?.locale,
            hostTrigger: TriggerEventContext.hostTrigger(of: Plugin.id, settings: settings)
        )
        context.step = variant?.step
        context.stepExperimentId = variant?.stepExperimentId
        deps.track(.eligibleNotShown(context, reason: reason))
    }

    /// The look drawn names the event; a look drawn in another trigger's spot names that spot as its host.
    private func eventContext(for shown: Shown) -> TriggerEventContext {
        let drawn = shown.variant.drawnTrigger
        var context = TriggerEventContext(
            trigger: drawn ?? Plugin.id,
            useCase: settings.useCase,
            placementId: PlacementLabel.sanitized(placement),
            variantId: shown.variant.variantId,
            experimentId: shown.variant.experimentId,
            fields: shown.presentation.eventFields,
            servedLocale: shown.variant.locale,
            hostTrigger: drawn != nil ? Plugin.id : TriggerEventContext.hostTrigger(of: Plugin.id, settings: settings)
        )
        context.step = shown.variant.step
        context.stepExperimentId = shown.variant.stepExperimentId
        return context
    }
}

/// The last result of the sheet one tap action opened.
@MainActor
private final class TriggerSheetResultBox {
    var value: PresentationResult?
}

// MARK: - The sheet a trigger opens

extension TriggerSheetRequest {
    /// The placement a tap opens, exactly as the app's own `placement(_:).useCase(_:).show()` would,
    /// with no appearance: the sheet's is the portal's, then the variant's defaults.
    @MainActor
    func placementBuilder(presentationId: String?) -> PlacementBuilder {
        var builder = Encore.shared.makePlacementBuilder(placement).useCase(useCase)
        if let presentationId { builder = builder.presentationId(presentationId) }
        if let publisherReward { builder = builder.publisherReward(publisherReward) }
        if cancelsWithTask { builder = builder.cancellingWithTask() }
        return builder
    }
}

// MARK: - Live Dependencies

extension TriggerHostModel.Dependencies {
    /// The configured SDK's client, user, analytics and sheet. Before `configure()`,
    /// there is no identity and every trigger renders nothing.
    @MainActor
    static var live: Self {
        Self(
            client: { Encore.shared.services?.oltpClient },
            sdkVersion: Encore.sdkVersion,
            identity: {
                guard let user = Encore.shared.services?.user else { return nil }
                return TriggerIdentity(userId: user.currentUserId, language: user.language)
            },
            storage: UserDefaultsStore(),
            track: { $0.track(on: analyticsClient) },
            now: { Date() },
            presentSheet: { request, presentationId in await request.placementBuilder(presentationId: presentationId).show() },
            cache: .shared,
            calendar: .autoupdatingCurrent,
            isActive: { UIApplication.shared.applicationState == .active },
            isInBackground: { UIApplication.shared.applicationState == .background }
        )
    }
}

/// The eligible_not_shown "once" records: per (trigger, placement, reason), the day or the
/// completion last reported. ``Encore/reset()`` clears them with the claim log.
internal enum TriggerNotShownRecords {
    private static let prefix = "encore.trigger."
    private static let marker = ".not_shown."

    static func key(trigger: String, placement: String, reason: String) -> String {
        "\(prefix)\(trigger)\(marker)\(placement).\(reason)"
    }

    static func isRecord(_ key: String) -> Bool {
        key.hasPrefix(prefix) && key.contains(marker)
    }

    /// Removes every record in `defaults` (the live hosts' store).
    static func clear(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where isRecord(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
