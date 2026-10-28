// Public entry points for every embeddable trigger: a SwiftUI view and a UIKit view,
// both rendering nothing (zero height) unless the trigger has something to show.

import SwiftUI
import UIKit
import Combine

// MARK: - Alignment

/// Where a trigger's look sits in a container wider than the look (an iPad, a wide phone,
/// landscape). The host places the look, at most its designed width, at this alignment, in the app's
/// layout direction; a container no wider than the look is filled whatever the alignment.
public enum EncoreAlignment: String, Sendable, CaseIterable {
    case leading
    case center
    case trailing

    /// Placed by the app's direction: inside a look laid out in another direction, leading and
    /// trailing swap so the look still sits at the app's leading or trailing edge.
    func horizontal(app: LayoutDirection?, look: LayoutDirection) -> HorizontalAlignment {
        let flipped = app.map { $0 != look } ?? false
        switch self {
        case .leading: return flipped ? .trailing : .leading
        case .center: return .center
        case .trailing: return flipped ? .leading : .trailing
        }
    }
}

private struct EncoreTriggerAlignmentKey: EnvironmentKey {
    static let defaultValue = EncoreAlignment.center
}

private struct EncoreTriggerAppDirectionKey: EnvironmentKey {
    static let defaultValue: LayoutDirection? = nil
}

extension EnvironmentValues {
    /// The mount's ``EncoreAlignment``, read where the look is placed.
    var encoreTriggerAlignment: EncoreAlignment {
        get { self[EncoreTriggerAlignmentKey.self] }
        set { self[EncoreTriggerAlignmentKey.self] = newValue }
    }

    /// The app's layout direction, set outside the look's own (served) direction.
    var encoreTriggerAppDirection: LayoutDirection? {
        get { self[EncoreTriggerAppDirectionKey.self] }
        set { self[EncoreTriggerAppDirectionKey.self] = newValue }
    }
}

// MARK: - SwiftUI

/// An Encore trigger, e.g. `"claimReminder"`. Renders nothing when there is nothing
/// to show, the id is unknown to this SDK version, or anything fails.
public struct EncoreTrigger: View {
    private let id: String
    private let placement: String
    private let settings: TriggerMountSettings
    private let appearance: AppearanceConfig?
    private let publisherReward: PublisherReward?
    private let onResult: ((PresentationResult) -> Void)?
    private let values: [String: String]
    private let alignment: EncoreAlignment
    private let registry: () -> TriggerRegistry
    /// The app's slot text, set with ``headline(_:)``, ``subheadline(_:)`` and ``cta(_:)``.
    private var texts: [TriggerTextSlot: String] = [:]

    /// - Parameters:
    ///   - id: The trigger id, e.g. `"giftsButton"`.
    ///   - placement: Your label for where it sits, e.g. "home".
    ///   - useCase: The moment it serves: the sheet it opens and its experiments. Churn renders nothing.
    ///   - autoOpen: `.off` forbids a look that opens the sheet by itself (GiftsButton only); nil lets Encore decide.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize, passed to any sheet the trigger opens, as `placement(_:).publisherReward(_:)`.
    ///   - onResult: Called once per sheet the trigger opens, after it closes, with what `show()` returns.
    ///   - values: Your values for the look to show, e.g. `["minutes": "60"]` for a look that says
    ///     "${values.minutes} min". Each key is lowerCamel; each value 1 to 64 characters of plain text.
    ///     A changed value redraws in place. Values never leave the device.
    ///   - alignment: Where the look sits when the container is wider than the look (an iPad);
    ///     centred by default. A changed value moves the look in place.
    public init(
        _ id: String,
        placement: String,
        useCase: UseCase = .rewardUsers,
        autoOpen: AutoOpen? = nil,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(id, placement: placement, useCase: useCase, layout: nil, autoOpen: autoOpen, icon: icon, appearance: appearance, publisherReward: publisherReward, onResult: onResult, values: values, alignment: alignment)
    }

    /// - Parameters:
    ///   - id: The trigger id, e.g. `"giftsButton"`.
    ///   - placement: Your label for where it sits, e.g. "home".
    ///   - useCase: The moment it serves: the sheet it opens and its experiments. Churn renders nothing.
    ///   - layout: Pins one look (demos and tests). Apps never pin: Encore picks looks per placement.
    ///   - autoOpen: `.off` forbids a look that opens the sheet by itself (GiftsButton only); nil lets Encore decide.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize, passed to any sheet the trigger opens, as `placement(_:).publisherReward(_:)`.
    ///   - onResult: Called once per sheet the trigger opens, after it closes, with what `show()` returns.
    ///   - values: Your values for the look to show, e.g. `["minutes": "60"]` for a look that says
    ///     "${values.minutes} min". Each key is lowerCamel; each value 1 to 64 characters of plain text.
    ///     A changed value redraws in place. Values never leave the device.
    ///   - alignment: Where the look sits when the container is wider than the look (an iPad);
    ///     centred by default. A changed value moves the look in place.
    @_spi(EncoreDemo) public init(
        _ id: String,
        placement: String,
        useCase: UseCase = .rewardUsers,
        layout: String?,
        autoOpen: AutoOpen? = nil,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(
            id, placement: placement,
            settings: TriggerMountSettings(useCase: useCase, layout: layout, autoOpen: autoOpen, icon: icon),
            appearance: appearance, publisherReward: publisherReward, onResult: onResult, values: values, alignment: alignment,
            registry: { .shared }
        )
    }

    internal init(
        _ id: String,
        placement: String,
        settings: TriggerMountSettings = TriggerMountSettings(),
        appearance: AppearanceConfig?,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center,
        registry: @escaping () -> TriggerRegistry
    ) {
        self.id = id
        self.placement = placement
        self.settings = settings
        self.appearance = appearance
        self.publisherReward = publisherReward
        self.onResult = onResult
        self.values = values
        self.alignment = alignment
        self.registry = registry
    }

    public var body: some View {
        TriggerMount(
            id: id, placement: placement, settings: settings, appearance: appearance, publisherReward: publisherReward, onResult: onResult,
            values: values, texts: texts, alignment: alignment, registry: registry
        )
            // A new id, placement or setting is a new trigger: start over.
            .id(TriggerMountKey(id: id, placement: placement, settings: settings))
    }
}

// MARK: - Text

extension EncoreTrigger {
    /// Your headline, over the look's own (a blank or nil one keeps the look's). Plain text, at most
    /// 120 UTF-16 units, no line breaks; a look that draws no headline ignores it. A change redraws in
    /// place, with no new request. Text never leaves the device.
    public func headline(_ text: String?) -> Self { withText(text, for: .headline) }

    /// Your subheadline, over the look's own; as ``headline(_:)``.
    public func subheadline(_ text: String?) -> Self { withText(text, for: .subheadline) }

    /// Your button label, over the look's own; as ``headline(_:)``. Only looks that draw a label take it.
    public func cta(_ text: String?) -> Self { withText(text, for: .cta) }

    func withText(_ text: String?, for slot: TriggerTextSlot) -> Self {
        var copy = self
        copy.texts[slot] = text
        return copy
    }
}

private struct TriggerMountKey: Hashable {
    let id: String
    let placement: String
    let settings: TriggerMountSettings
}

/// Owns the host for the lifetime of one mount.
@MainActor
private final class TriggerHostBox: ObservableObject {
    let host: TriggerHosting?

    init(host: TriggerHosting?) { self.host = host }
}

@MainActor
private struct TriggerMount: View {
    @StateObject private var box: TriggerHostBox
    @State private var height: CGFloat = 0
    @State private var maxWidth: CGFloat?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    private let appearance: AppearanceConfig?
    private let publisherReward: PublisherReward?
    private let onResult: ((PresentationResult) -> Void)?
    private let values: [String: String]
    private let texts: [TriggerTextSlot: String]
    private let alignment: EncoreAlignment

    init(
        id: String, placement: String, settings: TriggerMountSettings, appearance: AppearanceConfig?,
        publisherReward: PublisherReward?, onResult: ((PresentationResult) -> Void)?, values: [String: String],
        texts: [TriggerTextSlot: String], alignment: EncoreAlignment, registry: @escaping () -> TriggerRegistry
    ) {
        _box = StateObject(wrappedValue: {
            let host = registry().host(id: id, placement: placement, settings: settings, appearance: appearance)
            // Before the first gate, so the first draw already has them.
            host?.setValues(values)
            host?.setTexts(texts)
            return TriggerHostBox(host: host)
        }())
        self.appearance = appearance
        self.publisherReward = publisherReward
        self.onResult = onResult
        self.values = values
        self.texts = texts
        self.alignment = alignment
    }

    var body: some View {
        if let host = box.host {
            // Read when a sheet opens, so the latest values always apply; neither redraws anything.
            let _ = { host.publisherReward = publisherReward; host.onResult = onResult }()
            // The look lives in a UIKit view the size of the mount, as in EncoreTriggerView: UIKit
            // never delivers a touch outside a view's bounds, so no tap outside the mount ever
            // reaches the look (offsets, the pulse ring), while its drawing may still overflow.
            TriggerHitBounds(content: AnyView(
                host.makeView()
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.locale, locale)
                    .environment(\.encoreTriggerAlignment, alignment)
                    .ignoresSafeArea()
            ))
            .frame(height: height)
            // Sized to an ideal-width proposal (fixedSize, a stack sizing to ideal) at its look's
            // cap rather than collapsing; otherwise it takes the container's width.
            .frame(idealWidth: maxWidth)
            .onReceive(host.heightPublisher) { height = $0 }
            .onReceive(host.maxWidthPublisher) { maxWidth = $0 }
            .onChange(of: appearance) { host.setAppearance($0) }
            .onChange(of: values) { host.setValues($0) }
            .onChange(of: texts) { host.setTexts($0) }
        }
    }
}

/// A SwiftUI mount's look, hosted in a UIKit view the mount's size. Taps are bounded by UIKit's
/// rule (a touch outside a view's bounds never reaches it or its subviews); nothing is clipped.
private struct TriggerHitBounds: UIViewControllerRepresentable {
    let content: AnyView

    func makeUIViewController(context: Context) -> TriggerBoundedHostingController {
        let controller = TriggerBoundedHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.view.clipsToBounds = false
        controller.view.tag = TriggerBoundedHostingController.viewTag
        return controller
    }

    func updateUIViewController(_ controller: TriggerBoundedHostingController, context: Context) {
        controller.rootView = content
    }
}

/// The hosting controller behind ``TriggerHitBounds``.
internal final class TriggerBoundedHostingController: UIHostingController<AnyView> {
    /// Marks its view, so tests can find the bounded look in a hierarchy.
    static let viewTag = 0x454E_434F
}

// MARK: - UIKit

/// UIKit twin of ``EncoreTrigger``. Sizes itself: its intrinsic height is the
/// trigger's height while it shows and 0 otherwise. Pin its width; leave its height free.
public class EncoreTriggerView: UIView {
    private let triggerId: String?
    private let placement: String
    private let registry: TriggerRegistry?
    private var host: TriggerHosting?
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var height: CGFloat = 0
    private var maxWidth: CGFloat?
    private var cancellable: AnyCancellable?

    /// Brand colours; setting it restyles the trigger in place.
    public var appearance: AppearanceConfig? {
        didSet { if appearance != oldValue { host?.setAppearance(appearance) } }
    }

    /// The mount's settings; changing any of them starts the trigger over.
    private var settings: TriggerMountSettings {
        didSet { if settings != oldValue { rebuild() } }
    }

    /// The moment it serves; setting a new value starts the trigger over.
    public var useCase: UseCase {
        get { settings.useCase }
        set { settings.useCase = newValue }
    }

    /// A pinned look (layout wire value), for demos and tests; nil lets Encore choose. Setting it starts the trigger over.
    @_spi(EncoreDemo) public var layout: String? {
        get { settings.layout }
        set { settings.layout = newValue }
    }

    /// `.off` forbids a look that opens the sheet by itself; nil lets Encore decide. Setting it starts the trigger over.
    public var autoOpen: AutoOpen? {
        get { settings.autoOpen }
        set { settings.autoOpen = newValue }
    }

    /// The icon the look draws in its gift spot; setting it starts the trigger over.
    public var icon: TriggerIcon {
        get { settings.icon }
        set { settings.icon = newValue }
    }

    /// Your prize, passed to any sheet the trigger opens, as `placement(_:).publisherReward(_:)`.
    public var publisherReward: PublisherReward? {
        didSet { host?.publisherReward = publisherReward }
    }

    /// Called once per sheet the trigger opens, after it closes, with what `show()` returns.
    public var onResult: ((PresentationResult) -> Void)? {
        didSet { host?.onResult = onResult }
    }

    /// Your values for the look to show, e.g. `["minutes": "60"]` for a look that says
    /// "${values.minutes} min". Setting it redraws in place. Values never leave the device.
    public var values: [String: String] = [:] {
        didSet { if values != oldValue { host?.setValues(values) } }
    }

    /// Your headline, over the look's own (a blank or nil one keeps the look's). Plain text, at most
    /// 120 UTF-16 units, no line breaks; a look that draws no headline ignores it. Setting it redraws in
    /// place, with no new request. Text never leaves the device.
    public var headline: String? {
        didSet { if headline != oldValue { host?.setTexts(texts) } }
    }

    /// Your subheadline, over the look's own; as ``headline``.
    public var subheadline: String? {
        didSet { if subheadline != oldValue { host?.setTexts(texts) } }
    }

    /// Your button label, over the look's own; as ``headline``. Only looks that draw a label take it.
    public var cta: String? {
        didSet { if cta != oldValue { host?.setTexts(texts) } }
    }

    /// The three slots as the host takes them.
    private var texts: [TriggerTextSlot: String] {
        var texts: [TriggerTextSlot: String] = [:]
        texts[.headline] = headline
        texts[.subheadline] = subheadline
        texts[.cta] = cta
        return texts
    }

    /// Where the look sits when this view is wider than the look (an iPad); centred by default.
    /// Setting it moves the look in place, with no new request.
    public var alignment: EncoreAlignment = .center {
        didSet { if alignment != oldValue { hosting.rootView = makeRootView() } }
    }

    /// For the React Native and Flutter bridges only; apps never set it. The share (0...1) of
    /// this view's on-screen part that the embedding framework draws, after its own clipping
    /// and covers, which UIKit cannot see. Window clipping is applied separately and multiplied
    /// in, so the host must not count the off-screen part again. 0 stops a running dwell.
    /// Defaults to 1 (no override); out-of-range values are clamped, a non-finite one counts as 1.
    @_spi(EncoreBridge) public var hostVisibleFraction: Double = 1 {
        didSet { Self.measureAgain(in: self) }
    }

    /// Asks every visibility probe inside `view` to measure again.
    private static func measureAgain(in view: UIView) {
        for child in view.subviews {
            if let probe = child as? TriggerVisibilityProbeView { probe.setNeedsMeasure() }
            measureAgain(in: child)
        }
    }

    /// The mounted host. For tests.
    internal var currentHost: TriggerHosting? { host }

    /// How often the intrinsic size was invalidated. For tests.
    internal private(set) var intrinsicSizeInvalidations = 0

    /// - Parameters:
    ///   - id: The trigger id, e.g. `"giftsButton"`.
    ///   - placement: Your label for where it sits, e.g. "home".
    ///   - useCase: The moment it serves: the sheet it opens and its experiments. Churn renders nothing.
    ///   - autoOpen: `.off` forbids a look that opens the sheet by itself (GiftsButton only); nil lets Encore decide.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - values: Your values for the look to show; also settable later (see ``values``).
    ///   - alignment: Where the look sits in a wider view; also settable later (see ``alignment``).
    public convenience init(
        id: String,
        placement: String,
        useCase: UseCase = .rewardUsers,
        autoOpen: AutoOpen? = nil,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(id: id, placement: placement, useCase: useCase, layout: nil, autoOpen: autoOpen, icon: icon, appearance: appearance, values: values, alignment: alignment)
    }

    /// - Parameters:
    ///   - id: The trigger id, e.g. `"giftsButton"`.
    ///   - placement: Your label for where it sits, e.g. "home".
    ///   - useCase: The moment it serves: the sheet it opens and its experiments. Churn renders nothing.
    ///   - layout: Pins one look (demos and tests). Apps never pin: Encore picks looks per placement.
    ///   - autoOpen: `.off` forbids a look that opens the sheet by itself (GiftsButton only); nil lets Encore decide.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - values: Your values for the look to show; also settable later (see ``values``).
    ///   - alignment: Where the look sits in a wider view; also settable later (see ``alignment``).
    @_spi(EncoreDemo) public convenience init(
        id: String,
        placement: String,
        useCase: UseCase = .rewardUsers,
        layout: String?,
        autoOpen: AutoOpen? = nil,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        // Through the designated init: an own property set in an initializer runs no didSet, so the
        // host and the look would never see them.
        self.init(
            id: id, placement: placement,
            settings: TriggerMountSettings(useCase: useCase, layout: layout, autoOpen: autoOpen, icon: icon),
            appearance: appearance, values: values, alignment: alignment, registry: .shared
        )
    }

    internal init(
        id: String, placement: String, settings: TriggerMountSettings = TriggerMountSettings(), appearance: AppearanceConfig?,
        values: [String: String] = [:], alignment: EncoreAlignment = .center, registry: TriggerRegistry
    ) {
        self.triggerId = id
        self.placement = placement
        self.registry = registry
        self.appearance = appearance
        self.settings = settings
        self.values = values
        self.alignment = alignment
        super.init(frame: .zero)
        setUp()
        rebuild()
    }

    /// A view over a host built elsewhere (tests). Settings changes do not rebuild it.
    internal init(host: TriggerHosting?, appearance: AppearanceConfig?) {
        self.triggerId = nil
        self.placement = ""
        self.registry = nil
        self.appearance = appearance
        self.settings = TriggerMountSettings()
        super.init(frame: .zero)
        setUp()
        attach(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Whether the trigger is on show.
    internal var isShowingTrigger: Bool { height > 0 }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen: a pop waiting behind another sheet must not open one later.
        if window == nil { host?.stop() }
    }

    /// The trigger's height; its width is the look's cap when it has one (none otherwise), so a
    /// compressed fitting size or an unpinned width never collapses it.
    public override var intrinsicContentSize: CGSize {
        CGSize(width: maxWidth ?? UIView.noIntrinsicMetric, height: height)
    }

    /// At most the width offered, and at most the look's cap.
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, maxWidth ?? size.width), height: height)
    }

    public override func invalidateIntrinsicContentSize() {
        intrinsicSizeInvalidations += 1
        super.invalidateIntrinsicContentSize()
    }

    private func rebuild() {
        guard let triggerId, let registry else { return }
        attach(registry.host(id: triggerId, placement: placement, settings: settings, appearance: appearance))
    }

    private func attach(_ next: TriggerHosting?) {
        host?.stop()
        host = next
        next?.publisherReward = publisherReward
        next?.onResult = onResult
        next?.setValues(values)
        next?.setTexts(texts)
        hosting.rootView = makeRootView()
        cancellable = nil
        setSize(TriggerSize(height: 0, maxWidth: nil))
        cancellable = next?.sizePublisher.sink { [weak self] in self?.setSize($0) }
    }

    /// The trigger fills this view's fixed-height box; the window's safe area must not
    /// push it down inside the box (a view under the status bar would clip it).
    private func makeRootView() -> AnyView {
        guard let host else { return AnyView(EmptyView()) }
        return AnyView(host.makeView().environment(\.encoreTriggerAlignment, alignment).ignoresSafeArea())
    }

    /// One invalidation per change of either.
    private func setSize(_ next: TriggerSize) {
        guard next.height != height || next.maxWidth != maxWidth else { return }
        height = next.height
        maxWidth = next.maxWidth
        invalidateIntrinsicContentSize()
    }

    private func setUp() {
        backgroundColor = .clear
        clipsToBounds = false
        if #available(iOS 16.0, *) {
            hosting.sizingOptions = []
        }
        guard let content = hosting.view else { return }
        content.backgroundColor = .clear
        content.translatesAutoresizingMaskIntoConstraints = false
        // This view owns the height; the hosted content never pushes back.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            content.setContentHuggingPriority(.init(1), for: axis)
            content.setContentCompressionResistancePriority(.init(1), for: axis)
        }
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
