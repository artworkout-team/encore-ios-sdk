// EncoreClaim's router: one handle over the claim reminder's gate and the gifts button's, giving the
// app the reminder while this user has an open claim the sheet still holds and the gifts otherwise.
// The device's claim log picks which one loads first. It asks for no look: GiftsButton's own mount
// gets its steps from the server instead (GiftsSpotTrigger).

import SwiftUI
import Combine

/// What a gifts spot does once the user claims an offer (a look's or the handle's rule, never the app's).
internal enum AfterClaim: String, Sendable, CaseIterable {
    /// Turn into the claim reminder while that claim is open, then back into the gifts button.
    case showReminder
    /// Stay the gifts button.
    case stay

    /// The mount's choice, carried in its options (`"afterClaim"`); on by default.
    init(settings: TriggerMountSettings) {
        self = settings.options[Self.optionKey].flatMap(AfterClaim.init(rawValue:)) ?? .showReminder
    }

    static let optionKey = "afterClaim"
    /// The pinned reminder look, in the options.
    static let reminderLayoutKey = "reminderLayout"
}

/// What a gifts spot does once the user completes a claim (verified, granted or self-reported); a rule, never the app's.
internal enum AfterComplete: String, Sendable, CaseIterable {
    /// Stay the gifts button while the sheet has offers.
    case gifts
    /// Draw nothing until the user's next claim or the next local day, whichever comes first. It hides
    /// live, as the completion is recorded; holding no timer, it shows again on its next load after
    /// the day turns (a foreground, a new screen) or at once on the next claim.
    case hide
    /// Draw the thanks look (it opens the sheet like the gifts button) until the user taps it, makes
    /// their next claim, or the next local day; then the gifts button again.
    case thanks

    /// The mount's choice, carried in its options (`"afterComplete"`); gifts by default.
    init(settings: TriggerMountSettings) {
        self = settings.options[Self.optionKey].flatMap(AfterComplete.init(rawValue:)) ?? .gifts
    }

    static let optionKey = "afterComplete"
}

/// What one host in a slot has settled on: whether it has answered, and its height.
internal struct TriggerSlotState: Equatable {
    var answered: Bool
    var height: CGFloat
}

@MainActor
internal final class EncoreClaimRouter: ObservableObject, TriggerHosting {
    enum Showing: Equatable {
        /// Waiting for the reminder's first answer, so the gifts button never flashes in first.
        case nothing
        case gifts
        case reminder
    }

    let gifts: TriggerHosting
    let reminder: TriggerHosting
    /// Whether a host may load: one `/config` per screen open in the common case. The on-device
    /// claim log picks the host at mount; the other stays dormant (renders and fetches nothing).
    @Published private(set) var giftsActive: Bool
    @Published private(set) var reminderActive: Bool
    @Published private(set) var showing: Showing = .nothing
    @Published private(set) var height: CGFloat = 0
    private let hasOpenClaim: @MainActor () -> Bool
    /// The mount's placement, for the DEBUG trace.
    private let placement: String
    private var cancellables = Set<AnyCancellable>()
    private var waitCap: Task<Void, Never>?
    private let reminderWait: TimeInterval
    /// The cap runs while the slot's view is on screen (armed on appear, cancelled on disappear),
    /// so a screen pushed over it within the wait never wakes the gifts button behind it. Off for a
    /// slot with no view of its own (EncoreClaim), whose cap runs from init.
    private let waitsForView: Bool

    /// The cap: a reminder that has not answered by then gives way to the gifts button, so a slow
    /// network costs at most one more request and never an empty spot.
    static let reminderWait: TimeInterval = 2.5

    /// `hasOpenClaim` nil reads the claim log; `reminderWait` nil is the 2.5 s cap. (Resolved here, not
    /// as default arguments: Swift 6.0 evaluates those outside the main actor.)
    init(
        gifts: TriggerHosting, reminder: TriggerHosting, placement: String = "",
        hasOpenClaim: (@MainActor () -> Bool)? = nil,
        reminderWait: TimeInterval? = nil,
        waitsForView: Bool = false
    ) {
        self.reminderWait = reminderWait ?? Self.reminderWait
        self.waitsForView = waitsForView
        self.gifts = gifts
        self.reminder = reminder
        self.hasOpenClaim = hasOpenClaim ?? Self.logHasOpenClaim
        self.placement = placement
        // An open claim on this device: the reminder answers first. Otherwise only the gifts load.
        let claim = self.hasOpenClaim()
        reminderActive = claim
        giftsActive = !claim
        gifts.suppressed = claim
        trace(claim ? "reminder" : "gifts", claim ? "openClaim" : "noClaim")
        Publishers.CombineLatest(gifts.slotStatePublisher, reminder.slotStatePublisher)
            .sink { [weak self] giftsState, reminderState in self?.update(gifts: giftsState, reminder: reminderState) }
            .store(in: &cancellables)
        // A claim in any sheet: the reminder looks (woken if it was dormant), so the slot turns as the sheet closes.
        NotificationCenter.default.publisher(for: .encoreClaimLogDidChange)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.claimLogChanged() } }
            .store(in: &cancellables)
        // A new user (or the first one, mounted before configure) may have an open claim of their own.
        Publishers.Merge(
            NotificationCenter.default.publisher(for: .encoreIdentityDidChange),
            NotificationCenter.default.publisher(for: .encoreDidConfigure)
        )
        .sink { [weak self] _ in MainActor.assumeIsolated { self?.wakeReminderIfClaimed() } }
        .store(in: &cancellables)
        if claim, !waitsForView { armWaitCap() }
    }

    /// Starts the cap while the slot still waits for the reminder's first answer.
    private func armWaitCap() {
        guard waitCap == nil, reminderActive, !giftsActive, showing == .nothing else { return }
        #if DEBUG
        EncoreDebugTrace.record("d7.start", ["placement": placement, "seconds": String(max(0, reminderWait))])
        #endif
        let wait = reminderWait
        waitCap = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reminderTookTooLong()
        }
    }

    /// The slot's view appeared: the cap runs from now.
    func viewAppeared() {
        guard waitsForView else { return }
        armWaitCap()
    }

    /// The slot's view went away (a screen pushed over it): the cap stops, and the next appearance
    /// starts it again if the reminder still has not answered.
    func viewDisappeared() {
        guard waitsForView else { return }
        waitCap?.cancel()
        waitCap = nil
    }

    private func reminderTookTooLong() {
        waitCap = nil
        guard !giftsActive, showing == .nothing else { return }
        #if DEBUG
        EncoreDebugTrace.record("d7.fire", ["placement": placement])
        #endif
        giftsActive = true
        showing = .gifts
        gifts.suppressed = false
    }

    /// The current user's claim log holds an open claim the reminder can name and the user has not
    /// hidden with ×.
    static func logHasOpenClaim() -> Bool {
        guard let userId = Encore.shared.services?.user.currentUserId else { return false }
        let open = openClaims(in: ClaimLog.shared.entries(userId: userId), dismissed: ClaimReminderSources.dismissed())
        #if DEBUG
        EncoreDebugTrace.record("claimLog.read", ["user": userId, "open": String(open.count)])
        #endif
        return !open.isEmpty
    }

    /// The rows that route the slot to the reminder: open, with a transaction and an advertiser,
    /// and not dismissed (× hid them, so the reminder would have nothing to show).
    static func openClaims(in rows: [ClaimLogEntry], dismissed: Set<String>) -> [ClaimLogEntry] {
        rows.filter { row in
            guard !row.finished, let id = row.transactionId, !dismissed.contains(id) else { return false }
            return !row.advertiserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func claimLogChanged() {
        // The gifts gate reads the log too (afterComplete: a completion hides it or turns it into
        // thanks), so an active gifts host runs it again rather than keep a stale card.
        if giftsActive { gifts.reload() }
        if reminderActive {
            reminder.reload()
        } else if hasOpenClaim() {
            // Its first fetch: the view's load runs it; the gifts keep showing until it has something.
            reminderActive = true
            trace("reminder", "claimWoke")
        }
    }

    /// Wakes a dormant reminder when the current user has an open claim; each host reloads itself
    /// for the new user.
    private func wakeReminderIfClaimed() {
        guard !reminderActive, hasOpenClaim() else { return }
        reminderActive = true
        trace("reminder", "identityWoke")
    }

    /// The reminder once it shows something; else the gifts once they are loading; else nothing.
    static func showing(giftsActive: Bool, reminderActive: Bool, reminder: TriggerSlotState) -> Showing {
        if reminderActive, reminder.answered, reminder.height > 0 { return .reminder }
        return giftsActive ? .gifts : .nothing
    }

    private func update(gifts giftsState: TriggerSlotState, reminder reminderState: TriggerSlotState) {
        // The reminder has nothing (the claim completed or was hidden server-side): the gifts load now.
        if reminderActive, reminderState.answered, reminderState.height == 0, !giftsActive {
            giftsActive = true
            trace("gifts", "reminderEmpty")
        }
        let next = Self.showing(giftsActive: giftsActive, reminderActive: reminderActive, reminder: reminderState)
        // Hidden, the gifts host counts no view, never pops and spends no day (D-9).
        gifts.suppressed = next != .gifts
        if next != showing { showing = next }
        let nextHeight: CGFloat
        switch next {
        case .nothing: nextHeight = 0
        case .gifts: nextHeight = giftsState.height
        case .reminder: nextHeight = reminderState.height
        }
        if nextHeight != height { height = nextHeight }
    }

    /// The host the slot loads, and why; DEBUG only.
    private func trace(_ loads: String, _ reason: String) {
        #if DEBUG
        EncoreDebugTrace.record("slot.route", ["placement": placement, "loads": loads, "reason": reason])
        #endif
    }

    // MARK: TriggerHosting

    var heightPublisher: AnyPublisher<CGFloat, Never> { $height.removeDuplicates().eraseToAnyPublisher() }
    /// The shown host's cap.
    var maxWidthPublisher: AnyPublisher<CGFloat?, Never> {
        Publishers.CombineLatest3($showing, gifts.maxWidthPublisher, reminder.maxWidthPublisher)
            .map { showing, gifts, reminder -> CGFloat? in
                switch showing {
                case .nothing: return nil
                case .gifts: return gifts
                case .reminder: return reminder
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    var slotStatePublisher: AnyPublisher<TriggerSlotState, Never> {
        $height.map { TriggerSlotState(answered: true, height: $0) }.eraseToAnyPublisher()
    }
    var suppressed: Bool {
        get { gifts.suppressed }
        set { gifts.suppressed = newValue }
    }

    func makeView() -> AnyView { AnyView(EncoreClaimRouterView(slot: self)) }

    func setAppearance(_ appearance: AppearanceConfig?) {
        gifts.setAppearance(appearance)
        reminder.setAppearance(appearance)
    }

    func setValues(_ values: [String: String]) {
        gifts.setValues(values)
        reminder.setValues(values)
    }

    func setTexts(_ texts: [TriggerTextSlot: String]) {
        gifts.setTexts(texts)
        reminder.setTexts(texts)
    }

    var publisherReward: PublisherReward? {
        get { gifts.publisherReward }
        set {
            gifts.publisherReward = newValue
            reminder.publisherReward = newValue
        }
    }

    var onResult: ((PresentationResult) -> Void)? {
        get { gifts.onResult }
        set {
            gifts.onResult = newValue
            reminder.onResult = newValue
        }
    }

    /// Only an active host loads again; a dormant one never fetches.
    func reload() {
        if giftsActive { gifts.reload() }
        if reminderActive { reminder.reload() }
    }

    func stop() {
        waitCap?.cancel()
        waitCap = nil
        gifts.stop()
        reminder.stop()
    }
}

/// An active host stays mounted (so it keeps loading); a dormant one is not mounted, so it fetches
/// nothing. Only the one shown is visible, tappable and heard by VoiceOver. The height snaps; the
/// content crossfades over 200 ms, not under reduce motion (D-10).
private struct EncoreClaimRouterView: View {
    @ObservedObject var slot: EncoreClaimRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if slot.giftsActive { layer(slot.gifts.makeView(), shown: slot.showing == .gifts) }
            if slot.reminderActive { layer(slot.reminder.makeView(), shown: slot.showing == .reminder) }
        }
        .frame(height: slot.height, alignment: .top)
        .clipped()
        .onAppear { slot.viewAppeared() }
        .onDisappear { slot.viewDisappeared() }
    }

    private func layer(_ view: AnyView, shown: Bool) -> some View {
        view
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

extension Notification.Name {
    /// The claim log changed: a sheet ended in a claim, or the log was cleared.
    static let encoreClaimLogDidChange = Notification.Name("encore.claimLog.didChange")
}
