// A handle for the app's own gifts button or claim reminder: Encore decides what it shows, counts
// its views and taps, and opens the sheet. GiftsButton's after-claim slot over two hosts with no look,
// following the rules Encore serves for the placement (customClaim).

import SwiftUI
import UIKit
import Combine

/// Your own gifts button or claim reminder, for when the drop-in ``GiftsButton`` and
/// ``ClaimReminder`` don't fit your design. Read ``state`` and draw it; attach your view with
/// `.encoreClaim(_:)` (SwiftUI) or ``bind(_:handlesTap:)`` (UIKit). What it does after a claim or a
/// completion is Encore's, set per placement on the server and tested like a look.
@MainActor
public final class EncoreClaim: ObservableObject {

    /// What to draw.
    public enum State: Equatable, Sendable {
        /// Draw nothing: no offers, the sheet holds this user out, not configured yet, a failure,
        /// the churn use case, or (when Encore's rules say so) a completed claim.
        case hidden
        case gifts(Gifts)
        /// An open claim the sheet still lists.
        case reminder(Reminder)
        /// After a completed claim, when Encore's rules say so: thank the user; a tap opens the sheet,
        /// whose offers these are, until that tap, the next claim or the next local day.
        case thanks(Gifts)
    }

    /// The sheet's offers.
    public struct Gifts: Equatable, Sendable {
        public let offerCount: Int
        /// Up to eight logos, one per brand, in the sheet's order.
        public let logoURLs: [URL]
    }

    /// The newest open claim.
    public struct Reminder: Equatable, Sendable {
        public let advertiserName: String
        public let logoURL: URL?
        /// The claimed offer's perk as the sheet showed it.
        public let perk: String?
        public let claimedAt: Date
        /// When the reminder ends: 24 hours after the claim. The claim itself stays open.
        public let deadline: Date
        /// Open claims on show, this one included.
        public let claimCount: Int
        public let transactionId: String
    }

    /// What the user tapped, as analytics reports it. On gifts and thanks every tap is `button`; on a
    /// reminder `button` reports as `card`, the whole view.
    public enum Target: String, Sendable, CaseIterable {
        case button, card, arrow
    }

    @Published public private(set) var state: State = .hidden

    /// Called once per sheet a tap opens, after it closes, with what `show()` returns.
    public var onResult: ((PresentationResult) -> Void)?

    /// Your prize on every sheet a tap opens, as `placement(_:).publisherReward(_:)`. For an
    /// identified user that sheet asks `/offers/search` again on tap for the prize promise.
    public var publisherReward: PublisherReward? {
        didSet {
            gifts.publisherReward = publisherReward
            reminder?.publisherReward = publisherReward
        }
    }

    let placement: String
    let useCase: UseCase
    /// The app's `autoOpen`: `.off` forbids opening the sheet by itself.
    let autoOpen: AutoOpen?
    private(set) var gifts: TriggerHostModel<CustomGiftsTrigger>
    /// Nil when the rules say ``AfterClaim/stay``.
    private(set) var reminder: TriggerHostModel<CustomReminderTrigger>?
    private(set) var slot: EncoreClaimRouter?
    /// The rules the hosts follow: today's until the placement's read answers.
    var rules: CustomClaimRules { box.rules }
    /// Shared by the hosts' plug-ins, so ids and `autoOpen` change in place.
    private let box: CustomClaimRulesBox
    /// One gifts button state (its once-per-mount pop) for the handle's life, across host rebuilds.
    private let giftsTrigger: GiftsButtonTrigger
    private let environment: Environment
    /// The rules were asked for this identity (once the view first showed).
    private var rulesAsked = false

    /// The hosts' subscriptions, replaced when the rules rebuild them.
    private var hostCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var fraction: Double = 0
    /// The bound view's probe, and which binding owns it (a new view may appear before the old goes).
    private weak var probe: TriggerVisibilityProbeView?
    private var binding: UUID?
    private var tapping = false

    /// `rules`: the rules in force before the placement's read answers (today's; tests start elsewhere).
    init(placement: String, useCase: UseCase, autoOpen: AutoOpen? = nil, rules: CustomClaimRules = .defaults, environment: Environment) {
        self.placement = placement
        self.useCase = useCase
        self.autoOpen = autoOpen
        self.environment = environment
        let box = CustomClaimRulesBox(rules)
        self.box = box
        let giftsTrigger = GiftsButtonTrigger(environment: GiftsButtonEnvironment(
            sheet: environment.sheet, sheetBusy: environment.sheetBusy, isActive: environment.isActive, storage: environment.storage,
            calendar: environment.calendar, claimLog: environment.claimLog
        ))
        self.giftsTrigger = giftsTrigger
        (gifts, reminder, slot) = Self.hosts(
            placement: placement, useCase: useCase, box: box, giftsTrigger: giftsTrigger, mayPop: autoOpen != .off, environment: environment
        )
        wireHosts()
        wireNotifications()
        Task { [weak self] in await self?.load() }
    }

    /// The hosts for `rules`: the slot over gifts and the reminder, or gifts alone with `stay`.
    private static func hosts(
        placement: String, useCase: UseCase, box: CustomClaimRulesBox, giftsTrigger: GiftsButtonTrigger, mayPop: Bool, environment: Environment
    ) -> (TriggerHostModel<CustomGiftsTrigger>, TriggerHostModel<CustomReminderTrigger>?, EncoreClaimRouter?) {
        let rules = box.rules
        var settings = TriggerMountSettings(useCase: useCase)
        if rules.afterComplete != .gifts { settings.options[AfterComplete.optionKey] = rules.afterComplete.rawValue }
        let giftsPlugin = CustomGiftsTrigger(gifts: giftsTrigger, box: box, mayPop: mayPop)
        let gifts: TriggerHostModel<CustomGiftsTrigger>
        var reminder: TriggerHostModel<CustomReminderTrigger>?
        var slot: EncoreClaimRouter?
        if rules.afterClaim == .showReminder {
            // The slot's settings without its slot tag: the handle's events name no host trigger.
            var (giftsSettings, reminderSettings) = TriggerRegistry.slotSettings(settings)
            giftsSettings.options[TriggerRegistry.slotOption] = nil
            reminderSettings.options[TriggerRegistry.slotOption] = nil
            gifts = TriggerHostModel(plugin: giftsPlugin, placement: placement, settings: giftsSettings, dependencies: environment.gifts)
            let host = TriggerHostModel(
                plugin: CustomReminderTrigger(reminder: ClaimReminderTrigger(source: environment.claims, sheet: environment.sheet), box: box),
                placement: placement, settings: reminderSettings, dependencies: environment.reminder
            )
            reminder = host
            slot = EncoreClaimRouter(
                gifts: gifts, reminder: host, placement: placement, hasOpenClaim: environment.hasOpenClaim, reminderWait: environment.reminderWait
            )
        } else {
            gifts = TriggerHostModel(plugin: giftsPlugin, placement: placement, settings: settings, dependencies: environment.gifts)
        }
        // No view of its own: the handle is live from the start.
        gifts.start()
        reminder?.start()
        return (gifts, reminder, slot)
    }

    /// Follows `rules` from now on. New ids or a new `autoOpen` apply in place (a load re-reads the
    /// ids); only a new afterClaim or afterComplete needs new hosts (the old ones stop). The gifts
    /// button's pop state is the handle's, so a rebuild never pops again.
    private func apply(_ rules: CustomClaimRules) {
        guard rules != box.rules else { return }
        let steps = rules.afterClaim != box.rules.afterClaim || rules.afterComplete != box.rules.afterComplete
        box.rules = rules
        if steps {
            gifts.stop()
            reminder?.stop()
            (gifts, reminder, slot) = Self.hosts(
                placement: placement, useCase: useCase, box: box, giftsTrigger: giftsTrigger, mayPop: autoOpen != .off, environment: environment
            )
            gifts.publisherReward = publisherReward
            reminder?.publisherReward = publisherReward
            wireHosts()
            for host in hosts { host.visibilityChanged(fraction >= 0.5) }
        }
        reload()
    }

    /// Asks for the placement's rules once per identity, the first time the view shows. A failed or
    /// empty read keeps today's rules.
    private func askForRulesIfNeeded() {
        let deps = environment.gifts
        // Before configure() there is no one to ask for: asked once configure runs.
        guard !rulesAsked, fraction > 0, let identity = deps.identity(), deps.client() != nil else { return }
        rulesAsked = true
        Task { [weak self] in
            guard let self else { return }
            let rules = await CustomClaimRulesLoader.load(
                placement: placement, useCase: useCase, autoOpenOff: autoOpen == .off,
                client: deps.client(), identity: identity, sdkVersion: deps.sdkVersion, cache: deps.cache
            )
            // A user change meanwhile: these rules are the previous user's. Nothing read: keep today's.
            guard let rules, deps.identity() == identity, rulesAsked else { return }
            apply(rules)
        }
    }

    // MARK: - Public actions

    /// How much of your view is on screen, 0...1. A view counts once at least half of it stays
    /// visible for a second with no sheet over it. The modifier and ``bind(_:handlesTap:)`` call this for you.
    public func setVisible(_ fraction: Double) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        for host in hosts { host.visibilityChanged(self.fraction >= 0.5) }
        askForRulesIfNeeded()
    }

    /// Opens the reward sheet for this placement and returns once it closes. One tap at a time;
    /// while ``state`` is hidden it does nothing and returns `.notPresented(.noOffers)`.
    @discardableResult
    public func tap(target: Target = .button) async -> PresentationResult {
        guard !tapping else { return .notPresented(.alreadyPresenting) }
        let result: PresentationResult?
        switch state {
        case .hidden:
            return .notPresented(.noOffers)
        case .gifts, .thanks:
            tapping = true
            result = await gifts.tap(Target.button.rawValue)
        case .reminder:
            guard let reminder else { return .notPresented(.noOffers) }
            tapping = true
            result = await reminder.tap((target == .button ? Target.card : target).rawValue)
        }
        tapping = false
        return result ?? .notPresented(.alreadyPresenting)
    }

    /// Hides the reminder, every claim it was showing, on this device. Does nothing unless
    /// ``state`` is a reminder.
    public func dismiss() {
        guard case .reminder = state else { return }
        reminder?.dismiss()
    }

    // MARK: - Loading

    /// Runs the gate on every host that may load; never while the app is in the background (a
    /// silent-push launch): the next foreground loads it.
    func load() async {
        guard !environment.isInBackground() else { return }
        for host in activeHosts { await host.refresh() }
    }

    private func reload() {
        Task { [weak self] in await self?.load() }
    }

    private var hosts: [any TriggerClaimHost] { [gifts] + (reminder.map { [$0] } ?? []) }

    /// One request per open in the common case: the claim log picks the host (the slot's routing).
    private var activeHosts: [any TriggerClaimHost] {
        guard let slot, let reminder else { return [gifts] }
        return (slot.giftsActive ? [gifts] : []) + (slot.reminderActive ? [reminder] : [])
    }

    /// Subscribes to the current hosts (again after the rules rebuild them).
    private func wireHosts() {
        hostCancellables = []
        let forward: (PresentationResult) -> Void = { [weak self] in self?.onResult?($0) }
        gifts.onResult = forward
        reminder?.onResult = forward
        let check: @MainActor () -> Bool = { [weak self] in self?.isSeen() ?? false }
        gifts.visibilityCheck = check
        reminder?.visibilityCheck = check

        if let slot, let reminder {
            Publishers.CombineLatest3(slot.$showing, gifts.$shown, reminder.$shown)
                .map { Self.state(showing: $0, gifts: $1?.presentation.model, reminder: $2?.presentation.model) }
                .removeDuplicates()
                .sink { [weak self] in self?.state = $0 }
                .store(in: &hostCancellables)
            // A host the slot wakes (the cap, an empty reminder, a claim) loads now, as a mounting view would.
            slot.$giftsActive.dropFirst().removeDuplicates().filter { $0 }
                .sink { [weak self] _ in Task { await self?.gifts.refresh() } }
                .store(in: &hostCancellables)
            slot.$reminderActive.dropFirst().removeDuplicates().filter { $0 }
                .sink { [weak self] _ in Task { await self?.reminder?.refresh() } }
                .store(in: &hostCancellables)
        } else {
            gifts.$shown
                .map { Self.state(showing: .gifts, gifts: $0?.presentation.model, reminder: nil) }
                .removeDuplicates()
                .sink { [weak self] in self?.state = $0 }
                .store(in: &hostCancellables)
        }
    }

    /// The app-wide signals, once per handle.
    private func wireNotifications() {
        let center = NotificationCenter.default
        let main = { (name: Notification.Name, action: @escaping @MainActor (EncoreClaim) -> Void) in
            center.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self.map(action) } }
                .store(in: &self.cancellables)
        }
        main(UIApplication.willEnterForegroundNotification) { $0.reload() }
        // A scene app reads `.background` until its scene connects, so a cold launch skips the init
        // load and never posts willEnterForeground.
        main(UIApplication.didBecomeActiveNotification) { $0.reload() }
        main(.encoreDidConfigure) { claim in
            claim.reload()
            claim.askForRulesIfNeeded()
        }
        // A completion is a claim-log change: a stay handle has no slot to re-route it, so it runs its
        // gate again here (no /config). The slot already does this for showReminder.
        main(.encoreClaimLogDidChange) { claim in if claim.slot == nil { claim.reload() } }
        main(.encoreOfferTargetingDidChange) { $0.heldOffersChanged() }
        main(.encoreTriggerHeldOffersChanged) { $0.heldOffersChanged() }
        main(.encoreIdentityDidChange) { claim in
            // The rules are per user: today's until the new user's read answers.
            claim.rulesAsked = false
            for host in claim.hosts { host.userChanged() }
            if claim.rules != .defaults { claim.apply(.defaults) } else { claim.reload() }
            claim.askForRulesIfNeeded()
        }
    }

    private func heldOffersChanged() {
        for host in activeHosts { host.heldOffersChanged() }
    }

    static func state(showing: EncoreClaimRouter.Showing, gifts: CustomGiftsShown?, reminder: CustomReminderShown?) -> State {
        switch showing {
        case .nothing:
            return .hidden
        case .gifts:
            guard let shown = gifts else { return .hidden }
            let logos = shown.offers.logos.prefix(TriggerSheetOffers.maxLogos).compactMap { URL(string: $0.logoUrl) }
            let offers = Gifts(offerCount: shown.offers.offerCount, logoURLs: logos)
            return shown.thanks ? .thanks(offers) : .gifts(offers)
        case .reminder:
            guard let shown = reminder else { return .hidden }
            return .reminder(Reminder(
                advertiserName: shown.claim.advertiserName, logoURL: shown.claim.advertiserLogoUrl, perk: shown.claim.perk,
                claimedAt: shown.claim.claimedAt, deadline: shown.deadline, claimCount: shown.claimCount,
                transactionId: shown.claim.transactionId
            ))
        }
    }

    // MARK: - Visibility

    /// Seen now: the bound view's probe when there is one (clipping and covers), else the last
    /// reported share with no Encore sheet up.
    private func isSeen() -> Bool {
        if let probe { return TriggerVisibility.isSeen(probe) }
        return fraction >= 0.5 && !TriggerCoverage.sheetShowing()
    }

    func attach(_ probe: TriggerVisibilityProbeView, binding: UUID) {
        self.probe = probe
        self.binding = binding
    }

    /// A probe measured; only the newest binding's reports count.
    func probeReported(_ fraction: Double, binding: UUID) {
        guard self.binding == binding else { return }
        setVisible(fraction)
    }

    func detach(binding: UUID) {
        guard self.binding == binding else { return }
        self.binding = nil
        probe = nil
        setVisible(0)
    }

    // MARK: - UIKit

    /// Measures `view` for impressions and, with `handlesTap`, opens the sheet on a tap and gives it
    /// the button trait. Returns a closure that undoes all of it.
    public func bind(_ view: UIView, handlesTap: Bool = true) -> () -> Void {
        let id = UUID()
        let probe = TriggerVisibilityProbeView(frame: view.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        probe.followsScrollViews = true
        probe.onChange = { [weak self] fraction, _ in self?.probeReported(fraction, binding: id) }
        attach(probe, binding: id)
        view.insertSubview(probe, at: 0)
        probe.setNeedsMeasure()

        var recognizer: UITapGestureRecognizer?
        let hadButtonTrait = view.accessibilityTraits.contains(.button)
        let hadInteraction = view.isUserInteractionEnabled
        if handlesTap {
            let target = EncoreClaimTapTarget(claim: self)
            let tap = UITapGestureRecognizer(target: target, action: #selector(EncoreClaimTapTarget.tapped))
            target.retain(on: tap)
            view.addGestureRecognizer(tap)
            view.isUserInteractionEnabled = true
            view.accessibilityTraits.insert(.button)
            recognizer = tap
        }
        return { [weak self, weak view, weak probe] in
            probe?.onChange = nil
            probe?.removeFromSuperview()
            if let recognizer { view?.removeGestureRecognizer(recognizer) }
            if handlesTap, !hadButtonTrait { view?.accessibilityTraits.remove(.button) }
            // A label or image view is not interactive by default: left on, it would swallow touches.
            if handlesTap { view?.isUserInteractionEnabled = hadInteraction }
            self?.detach(binding: id)
        }
    }
}

/// The target of a bound view's tap; held by its recognizer, so unbinding releases it.
@MainActor
private final class EncoreClaimTapTarget: NSObject {
    weak var claim: EncoreClaim?
    private static var key = 0

    init(claim: EncoreClaim) { self.claim = claim }

    func retain(on recognizer: UIGestureRecognizer) {
        objc_setAssociatedObject(recognizer, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc func tapped() {
        Task { [weak claim] in await claim?.tap() }
    }
}

/// What the handle drives on each host, over both plug-ins.
@MainActor
internal protocol TriggerClaimHost: AnyObject {
    func refresh() async
    func visibilityChanged(_ visible: Bool)
    func heldOffersChanged()
    func userChanged()
}

extension TriggerHostModel: TriggerClaimHost {}

// MARK: - Factory

extension Encore {
    /// A handle for your own gifts button or claim reminder at `placement`, for when ``GiftsButton``
    /// and ``ClaimReminder`` don't fit your design. Keep it for as long as the view shows (e.g. in
    /// `@StateObject`). What it does after a claim or a completion is Encore's, per placement.
    ///
    /// ```swift
    /// @StateObject private var claim = Encore.claim(placement: "streak")
    ///
    /// var body: some View {
    ///     if case .gifts(let gifts) = claim.state {
    ///         MyGiftButton(count: gifts.offerCount).encoreClaim(claim)
    ///     }
    /// }
    /// ```
    /// - Parameters:
    ///   - placement: Your label for where it sits, e.g. "streak".
    ///   - useCase: The sheet it opens. Churn stays hidden for now.
    ///   - autoOpen: `.off` forbids opening the sheet by itself; nil (the default) lets Encore decide.
    ///   - publisherReward: Your prize on the sheet it opens; also settable later.
    ///   - onResult: Called once per sheet it opens, after it closes; also settable later.
    public static func claim(
        placement: String,
        useCase: UseCase = .rewardUsers,
        autoOpen: AutoOpen? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil
    ) -> EncoreClaim {
        let claim = EncoreClaim(placement: placement, useCase: useCase, autoOpen: autoOpen, environment: .live)
        claim.publisherReward = publisherReward
        claim.onResult = onResult
        return claim
    }
}

// MARK: - Environment

extension EncoreClaim {
    /// The handle's ties to the rest of the SDK, injectable for tests.
    struct Environment {
        var sheet: TriggerSheet
        /// Whether the app is in the background: the handle loads nothing then.
        var isInBackground: @MainActor () -> Bool = { false }
        /// Whether an Encore sheet is up, so a pop waits.
        var sheetBusy: @MainActor () -> Bool = { false }
        /// Whether the app is active, so a waiting pop presents only then.
        var isActive: @MainActor () -> Bool = { true }
        var claims: @MainActor () -> ClaimReminderSource?
        /// Whether the claim log holds an open claim: picks the host that loads first.
        var hasOpenClaim: @MainActor () -> Bool
        /// D-7's cap on waiting for the reminder.
        var reminderWait: TimeInterval
        var storage: KeyValueStore
        var calendar: Calendar
        /// The current user's claim log, for `afterComplete`.
        var claimLog: @MainActor () -> (log: ClaimLog, userId: String)? = { nil }
        var gifts: TriggerHostModel<CustomGiftsTrigger>.Dependencies
        var reminder: TriggerHostModel<CustomReminderTrigger>.Dependencies

        @MainActor
        static var live: Self {
            Self(
                sheet: .live,
                isInBackground: { UIApplication.shared.applicationState == .background },
                sheetBusy: { OfferSheetCoordinator.isPresenting },
                isActive: { UIApplication.shared.applicationState == .active },
                claims: { ClaimReminderSources.resolved },
                hasOpenClaim: EncoreClaimRouter.logHasOpenClaim,
                reminderWait: EncoreClaimRouter.reminderWait,
                storage: UserDefaultsStore(),
                calendar: .autoupdatingCurrent,
                claimLog: { Encore.shared.services.map { (ClaimLog.shared, $0.user.currentUserId) } },
                gifts: .live,
                reminder: .live
            )
        }
    }
}

extension Notification.Name {
    /// `configure()` finished: a handle made before it loads now.
    static let encoreDidConfigure = Notification.Name("EncoreDidConfigure")
}
