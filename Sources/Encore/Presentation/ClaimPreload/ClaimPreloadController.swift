// State for the `inAppPreload` claim: a claim screen from the tap, a WKWebView
// created and loaded once AFTER the transaction starts, and the reveal rule.
// A steps-screen preload builds the same controller before the Continue tap, off screen.

import SwiftUI
import WebKit

/// Owns one `inAppPreload` claim, from the claim tap (or a steps-screen preload) to the browser's ×.
///
/// Money path: the destination is an affiliate click link, so the web view is
/// never built before `load(_:)`, and `load(_:)` navigates at most once per web view.
@MainActor
@available(iOS 17.0, *)
final class ClaimPreloadController: ObservableObject, Identifiable {

    enum Phase: Equatable {
        /// Claim screen up, transaction in flight, no web view yet.
        case claiming
        /// Web view built and loading behind the claim screen.
        case loading
        /// Claim screen faded out, the in-app browser is showing.
        case revealed
    }

    /// What the claim screen draws, read off the offer at tap time.
    struct Content: Equatable {
        /// Nil draws no logo box and no gap.
        let logoUrl: URL?
        /// "Finish on <domain>", nil draws no line.
        let domain: String?
        /// At most `ClaimPreloadTokens.maxCheckRows` rows.
        let checks: [String]

        init(logoUrl: URL?, domain: String?, checks: [String]) {
            self.logoUrl = logoUrl
            self.domain = domain
            self.checks = Array(checks.prefix(ClaimPreloadTokens.maxCheckRows))
        }

        init(offer: Offer) {
            self.init(
                logoUrl: offer.displayLogoUrl.flatMap(URL.init(string:)),
                domain: offer.displayExpectedDomain,
                checks: offer.displayInstructions
                    .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    /// A steps-screen preload's hand-over to the claim. `.none` for every tap-time claim.
    enum Handover: Equatable {
        case none
        /// Loading off screen before the Continue tap. Events are held; the claim screen's clock has not started.
        case hidden
        /// On screen after the Continue tap, until the claim's transaction confirms it is the same one.
        case awaitingConfirmation
    }

    struct Timing: Equatable {
        /// The claim screen stays up at least this long, even if the page is ready.
        let minimum: TimeInterval
        /// Reveal regardless once the claim screen has been up this long.
        let cap: TimeInterval

        static let standard = Timing(
            minimum: ClaimPreloadTokens.minClaimScreenSeconds,
            cap: ClaimPreloadTokens.maxClaimScreenSeconds
        )
    }

    typealias WebViewFactory = @MainActor () -> WKWebView

    let id = UUID()
    let content: Content
    /// The tapped campaign, so an abandoned claim can still name it on the funnel.
    let offerId: String?
    @Published private(set) var phase: Phase = .claiming
    /// Nil until `load(_:)`. Never built before the transaction returns.
    private(set) var webView: WKWebView?
    /// The host the browser chrome shows; follows redirects.
    @Published private(set) var currentHost: String?
    /// The chrome's lock is shown only for https; follows redirects with the host.
    @Published private(set) var isSecure = false
    /// The cap passed with no transaction yet: the claim screen offers an ×.
    @Published private(set) var canEscape = false
    /// The user left through that ×. A late transaction must not load anything.
    private(set) var isAbandoned = false
    /// Torn down (failed start, cooldown, abandon or close). Never loads after this.
    private(set) var isCancelled = false
    /// Set for a steps-screen preload until the claim confirms it.
    @Published private(set) var handover: Handover

    var onTrackingEvent: SafariTrackingHandler?
    /// The page left for the system (App Store, a deep link). Its navigation is cancelled,
    /// so no load or redirect reports it.
    var onSystemHandoff: ((URL, _ opened: Bool) -> Void)?
    /// The page's process died with nothing safe to reload. The owner closes the browser.
    var onPageGone: (() -> Void)?
    /// A preloaded page lost its process or tried to leave the app before the claim confirmed it.
    /// Its link was cancelled; the owner drops the preloaded page.
    var onPreloadAborted: ((PreloadAbort) -> Void)?

    /// Why a preloaded page cut itself short.
    enum PreloadAbort: Equatable {
        case pageGone
        case triedToLeave
    }

    private let timing: Timing
    private let makeWebView: WebViewFactory
    private var shownAt: Date
    /// Names this preload's geolocation lift, so page code cannot guess it.
    private let geolocationToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// What the lift must be called with. Lives in the script's closure, never on `window`.
    private let geolocationSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// Tracking events of a preloaded page, held until the claim confirms it.
    private var heldEvents: [SafariTrackingEvent] = []
    /// Where a preloaded web view waits off screen until the claim shows it.
    private weak var parkingWindow: UIWindow?
    private var pageSettled = false
    private var loadStartedAt: Date?
    private var requestedURL: URL?
    /// Where the initial load currently is, so a redirect reports its real origin.
    private var lastInitialURL: URL?
    /// The last page that committed (was shown), as opposed to a redirect hop in flight.
    private var committedURL: URL?
    private var reportedInitialLoad = false
    private var timers: [Task<Void, Never>] = []
    private lazy var observer = NavigationObserver(owner: self)

    /// `makeWebView` nil means `makeDefaultWebView`. It is resolved in the body, not as a default
    /// argument: Swift 6.0 evaluates default arguments nonisolated and rejects the main-actor reference.
    /// `preload` builds a steps-screen preload: nothing is on screen and no clock runs until `showForClaim()`.
    init(content: Content, offerId: String? = nil, timing: Timing = .standard, makeWebView: WebViewFactory? = nil, preload: Bool = false) {
        self.content = content
        self.offerId = offerId
        self.timing = timing
        self.makeWebView = makeWebView ?? Self.makeDefaultWebView
        self.shownAt = Date()
        self.handover = preload ? .hidden : .none
        if !preload { startClock() }
    }

    deinit {
        timers.forEach { $0.cancel() }
        // A preload whose owner went away without discarding it must not stay in the host's window.
        if parkingWindow != nil, let view = webView {
            let unpark = {
                view.stopLoading()
                view.removeFromSuperview()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(unpark)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(unpark) }
            }
        }
    }

    /// The reveal rule: loaded (or failed) AND the minimum elapsed, or the cap.
    nonisolated static func shouldReveal(pageSettled: Bool, elapsed: TimeInterval, timing: Timing) -> Bool {
        elapsed >= timing.cap || (pageSettled && elapsed >= timing.minimum)
    }

    // MARK: - Claim lifecycle

    /// Builds the web view and navigates to the claim link. Only the first call acts.
    func load(_ url: URL) {
        guard webView == nil, phase == .claiming, !isCancelled else { return }
        let view = makeWebView()
        view.navigationDelegate = observer
        view.uiDelegate = observer
        webView = view
        if handover == .hidden {
            parkIfNeeded()
            view.configuration.userContentController.addUserScript(Self.geolocationGuard(token: geolocationToken, secret: geolocationSecret))
        }
        requestedURL = url
        lastInitialURL = url
        noteLocation(url)
        phase = .loading
        emit(.attemptingToOpen(url: url))
        let now = Date()
        loadStartedAt = now
        view.load(URLRequest(url: url))
        emit(.didOpen(url: url, openedAt: now))
        evaluateReveal()
    }

    // MARK: - Steps-screen preload

    /// The claim was tapped on a preload: the claim screen goes up over the preloaded page and
    /// its clock starts now. Nothing is revealed until `confirmHandover()`.
    func showForClaim() {
        guard handover == .hidden, !isCancelled else { return }
        unpark()
        handover = .awaitingConfirmation
        shownAt = Date()
        startClock()
        evaluateReveal()
    }

    /// The claim's transaction is the preload's: the held events go out in today's order, and a
    /// page that already settled shows at once.
    func confirmHandover() {
        guard handover == .awaitingConfirmation, !isCancelled else { return }
        handover = .none
        liftGeolocationGuard()
        // Dwell starts when the claim opens the page for the user, as it does with no preload.
        // The preload's real open time stays on the held `didOpen` event.
        if loadStartedAt != nil { loadStartedAt = Date() }
        let events = heldEvents
        heldEvents = []
        events.forEach { onTrackingEvent?($0) }
        if phase == .loading, pageSettled {
            phase = .revealed
        } else {
            evaluateReveal()
        }
    }

    /// The claim cannot use the preloaded page (another transaction id, or the page aborted):
    /// it is torn down unseen and its events dropped, so `load(_:)` can open the claim's link.
    func discardPreloadedPage() {
        guard handover != .none, !isCancelled else { return }
        releaseWebView()
        heldEvents = []
        handover = .none
        phase = .claiming
        pageSettled = false
        loadStartedAt = nil
        requestedURL = nil
        lastInitialURL = nil
        committedURL = nil
        reportedInitialLoad = false
        currentHost = nil
        isSecure = false
        evaluateReveal()
    }

    /// A claim link is open in this controller's browser (or loading behind its claim screen).
    var hasOpenedClaimLink: Bool {
        phase != .claiming && handover == .none
    }

    /// Before the claim confirmed it, the page is not the user's yet.
    var isUnconfirmedPreload: Bool {
        handover != .none
    }

    /// Stops a preload for good and releases its web view. Idempotent.
    func discard() {
        cancel()
        releaseWebView()
        heldEvents = []
    }

    /// Patches `Geolocation.prototype` so an unseen preload can never raise the location prompt
    /// in the host app's name: every call, however reached, is denied (PERMISSION_DENIED) without
    /// reaching WebKit. The natives stay in the closure; only a call carrying `secret`, which the
    /// page cannot read, restores them.
    static func geolocationGuard(token: String, secret: String) -> WKUserScript {
        WKUserScript(
            source: """
            (function () {
              if (typeof Geolocation === 'undefined') { return; }
              var proto = Geolocation.prototype, get = proto.getCurrentPosition, watch = proto.watchPosition;
              var secret = '\(secret)';
              function deny(error) {
                if (typeof error !== 'function') { return; }
                setTimeout(function () {
                  error({ code: 1, message: 'User denied Geolocation', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
                }, 0);
              }
              proto.getCurrentPosition = function (success, error) { deny(error); };
              proto.watchPosition = function (success, error) { deny(error); return 0; };
              Object.defineProperty(window, '__encoreGeolocationLift_\(token)', {
                configurable: true,
                value: function (key) {
                  if (key !== secret) { return; }
                  proto.getCurrentPosition = get;
                  proto.watchPosition = watch;
                  delete window['__encoreGeolocationLift_\(token)'];
                }
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }

    /// The page is the user's now: later navigations run clean, and the current page's main frame
    /// gets WebKit's own geolocation back. A denial it already received stands, and a cross-origin
    /// iframe on this page keeps its denial until it navigates.
    private func liftGeolocationGuard() {
        guard let view = webView else { return }
        view.configuration.userContentController.removeAllUserScripts()
        let lift = "__encoreGeolocationLift_\(geolocationToken)"
        view.evaluateJavaScript("window['\(lift)'] && window['\(lift)']('\(geolocationSecret)');", completionHandler: nil)
    }

    private func emit(_ event: SafariTrackingEvent) {
        if handover == .none {
            onTrackingEvent?(event)
        } else {
            heldEvents.append(event)
        }
    }

    private func startClock() {
        schedule(after: timing.minimum)
        schedule(after: timing.cap)
    }

    /// WebKit can suspend a web view that is in no window, so an unseen preload loads in one:
    /// behind everything, transparent and untouchable. Called again on foreground, for a preload
    /// that started with no window to park in. A no-op once parked.
    func parkIfNeeded() {
        #if DEBUG
        _testParkAttempts += 1
        #endif
        guard handover == .hidden, !isCancelled, let view = webView else { return }
        park(view)
    }

    #if DEBUG
    private(set) var _testParkAttempts = 0
    #endif

    private func park(_ view: WKWebView) {
        guard view.window == nil, let window = Self.foregroundWindow() else { return }
        view.frame = window.bounds
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.isAccessibilityElement = false
        // A plain subview at the back: no constraints, no safe-area or layout change for the host.
        view.translatesAutoresizingMaskIntoConstraints = true
        window.insertSubview(view, at: 0)
        parkingWindow = window
    }

    private func unpark() {
        guard let view = webView, parkingWindow != nil else { return }
        if view.superview === parkingWindow { view.removeFromSuperview() }
        view.alpha = 1
        view.isUserInteractionEnabled = true
        view.accessibilityElementsHidden = false
        view.isAccessibilityElement = false
        parkingWindow = nil
    }

    private func releaseWebView() {
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        if let parkingWindow, view.superview === parkingWindow { view.removeFromSuperview() }
        parkingWindow = nil
        webView = nil
    }

    #if DEBUG
    /// Test seam: the window a preload parks in (a unit-test host has no foreground scene).
    static var _parkingWindowOverride: (() -> UIWindow?)?
    #endif

    private static func foregroundWindow() -> UIWindow? {
        #if DEBUG
        if let override = _parkingWindowOverride { return override() }
        #endif
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The active scene's window; with the app in the background, any scene's window still holds it.
        let active = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        let windows = active.isEmpty ? scenes.flatMap(\.windows) : active
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Tears down before a web view exists or mid-load. Idempotent.
    func cancel() {
        isCancelled = true
        timers.forEach { $0.cancel() }
        timers.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if let parkingWindow, webView?.superview === parkingWindow { webView?.removeFromSuperview() }
    }

    /// The claim screen's ×, before the claim's link is open. Permanent.
    func abandon() {
        guard !hasOpenedClaimLink else { return }
        isAbandoned = true
        canEscape = false
        cancel()
    }

    /// The browser's × was tapped. Reports time spent like the Safari path.
    func noteClosed() {
        if let loadStartedAt {
            emit(.dismissed(timeSpentSeconds: Date().timeIntervalSince(loadStartedAt)))
        }
        cancel()
    }

    // MARK: - Reveal

    private func schedule(after seconds: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.evaluateReveal()
        }
        timers.append(task)
    }

    private func evaluateReveal() {
        guard handover != .hidden else { return }
        let elapsed = Date().timeIntervalSince(shownAt)
        if !hasOpenedClaimLink, !isAbandoned, elapsed >= timing.cap {
            canEscape = true
        }
        guard phase == .loading, handover == .none else { return }
        if Self.shouldReveal(pageSettled: pageSettled, elapsed: elapsed, timing: timing) {
            phase = .revealed
        }
    }

    fileprivate func pageDidSettle(url: URL?, success: Bool) {
        // A provisional failure never commits, so the web view has no url of its own.
        if !reportedInitialLoad, let url = url ?? webView?.url ?? requestedURL {
            reportedInitialLoad = true
            emit(.initialLoadCompleted(url: url, didLoadSuccessfully: success))
        }
        pageSettled = true
        evaluateReveal()
    }

    func didRedirect(to url: URL) {
        noteLocation(url)
        // By now webView.url is already the target, so the origin comes from our own record.
        if !reportedInitialLoad, let from = lastInitialURL, from != url {
            emit(.initialRedirect(from: from, to: url))
        }
        lastInitialURL = url
    }

    /// Always overwrites both, so a hostless page (about:blank) never keeps the last domain's lock.
    private func noteLocation(_ url: URL) {
        let chrome = Self.chrome(for: url)
        currentHost = chrome.host
        isSecure = chrome.isSecure
    }

    /// What the browser chrome shows for a URL: its host, and the lock only for an https host.
    nonisolated static func chrome(for url: URL) -> (host: String?, isSecure: Bool) {
        let host = url.host.flatMap { $0.isEmpty ? nil : $0 }
        return (host, host != nil && isSecure(url))
    }

    nonisolated static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    /// iOS reclaimed the page's process. Only a page that committed past the claim link reloads:
    /// the link itself, or a redirect hop not yet shown, could book a second click. With nothing
    /// safe to reload the browser closes, as on Android, rather than revealing a blank page.
    func webContentProcessDidTerminate() {
        guard let webView, !isCancelled else { return }
        // Nothing reloads unseen: a reload could book a second click before the Continue tap.
        if isUnconfirmedPreload {
            onPreloadAborted?(.pageGone)
            return
        }
        guard let committed = committedURL, committed != requestedURL else {
            onPageGone?()
            return
        }
        webView.reload()
        pageDidSettle(url: webView.url, success: false)
    }

    /// A navigation replaced by another (a JS redirect, or a hand-off to another app) is not a failure.
    nonisolated static func isSupersededNavigation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        // WebKitErrorFrameLoadInterruptedByPolicyChange
        return nsError.domain == WKErrorDomain && nsError.code == 102
    }

    /// Reported before the open (the app can background before its completion runs), and
    /// again with `opened: false` if the system could not open it.
    /// The affiliate click link this claim loaded. Requesting it again books a second click.
    func isClaimLink(_ url: URL) -> Bool {
        url == requestedURL
    }

    func didHandOffToSystem(_ url: URL, opened: Bool = true) {
        onSystemHandoff?(url, opened)
    }

    /// Camera, microphone and motion prompts: none while the page is an unseen preload.
    nonisolated static func permissionDecision(isUnconfirmedPreload: Bool) -> WKPermissionDecision {
        isUnconfirmedPreload ? .deny : .prompt
    }

    /// A preloaded page tried to open another app. Nothing leaves the app before the claim.
    func preloadTriedToLeave(_ url: URL) {
        Logger.debug(.offers, "Preloaded page tried to open \(url.scheme ?? "a link") before the claim; dropping it")
        onPreloadAborted?(.triedToLeave)
    }

    func didCommit(url: URL?) {
        guard let url else { return }
        committedURL = url
        noteLocation(url)
    }

    #if DEBUG
    /// Test seam: the page settles as WebKit's delegate would report it.
    func _testSettle(_ url: URL?, success: Bool = true) {
        pageDidSettle(url: url, success: success)
    }
    #endif

    // MARK: - Web view

    /// The claim page's own persistent website data store. Fixed, so advertiser sign-ins survive
    /// from one claim to the next, and never the host app's `.default()` store: the app can't read
    /// the advertiser's cookies, and none of the app's cookies go out with the click. That is the
    /// isolation SFSafariViewController gives the other presentations. (Everything here is
    /// iOS 17+, where `WKWebsiteDataStore(forIdentifier:)` exists.)
    static let claimPageStoreIdentifier = UUID(uuidString: "6B1C5E0A-3F2D-4C8E-9A71-5D2E8F4B7C13")!

    static func makeDefaultWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: claimPageStoreIdentifier)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        return view
    }
}

// MARK: - Navigation observer

/// Navigation and UI delegate held by the controller; weak back-reference, no cycle.
@available(iOS 17.0, *)
private final class NavigationObserver: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: ClaimPreloadController?

    init(owner: ClaimPreloadController) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        MainActor.assumeIsolated { owner?.didRedirect(to: url) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { owner?.didCommit(url: url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { owner?.webContentProcessDidTerminate() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { owner?.pageDidSettle(url: url, success: true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !ClaimPreloadController.isSupersededNavigation(error) else { return }
        let url = webView.url
        MainActor.assumeIsolated { owner?.pageDidSettle(url: url, success: false) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !ClaimPreloadController.isSupersededNavigation(error) else { return }
        let url = webView.url
        MainActor.assumeIsolated { owner?.pageDidSettle(url: url, success: false) }
    }

    /// Non-web schemes (App Store, tel:, deep links) leave for the system, as Safari would.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // A back swipe or history.back() onto the click link would request it again unless the
        // page cache still holds it. That is a second click, so history never returns there.
        if navigationAction.navigationType == .backForward, let url = navigationAction.request.url,
           MainActor.assumeIsolated({ self.owner?.isClaimLink(url) ?? false }) {
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme != "http", scheme != "https", scheme != "about", scheme != "data", scheme != "blob"
        else {
            decisionHandler(.allow)
            return
        }
        if Self.isWebKitHandledScheme(scheme, in: webView) {
            decisionHandler(.allow)
            return
        }
        // Only the page itself may leave for an app. An iframe (an ad, a pixel) never launches one.
        guard Self.isFromThePage(navigationAction) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
        let owner = owner
        // A preload is not the user's yet: it never takes them out of the app.
        if MainActor.assumeIsolated({ owner?.isUnconfirmedPreload ?? false }) {
            MainActor.assumeIsolated { owner?.preloadTriedToLeave(url) }
            return
        }
        MainActor.assumeIsolated { owner?.didHandOffToSystem(url) }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            MainActor.assumeIsolated { owner?.didHandOffToSystem(url, opened: false) }
        }
    }

    /// An unseen preload never prompts; a shown page prompts as WebKit would by default.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let unconfirmed = MainActor.assumeIsolated { owner?.isUnconfirmedPreload ?? true }
        decisionHandler(ClaimPreloadController.permissionDecision(isUnconfirmedPreload: unconfirmed))
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let unconfirmed = MainActor.assumeIsolated { owner?.isUnconfirmedPreload ?? true }
        decisionHandler(ClaimPreloadController.permissionDecision(isUnconfirmedPreload: unconfirmed))
    }

    /// `target=_blank` and `window.open` have no second window here; open them in place, as Safari would in one tab.
    /// A hidden preload opens one only from the page itself and onto its own origin, so an ad frame cannot repoint it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let unconfirmed = MainActor.assumeIsolated { owner?.isUnconfirmedPreload ?? true }
        if unconfirmed, !(Self.isFromThePage(navigationAction)
                          && Self.isSameOrigin(navigationAction.request.url, webView.url)) {
            return nil
        }
        webView.load(navigationAction.request)
        return nil
    }

    nonisolated static func isSameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let scheme = a.scheme?.lowercased(), let host = a.host?.lowercased() else { return false }
        return scheme == b.scheme?.lowercased() && host == b.host?.lowercased() && a.port == b.port
    }

    /// The main frame, or a new window (`target=_blank`, `window.open`) the main frame opened.
    private static func isFromThePage(_ action: WKNavigationAction) -> Bool {
        if let target = action.targetFrame { return target.isMainFrame }
        return action.sourceFrame.isMainFrame
    }

    /// A scheme a `WKURLSchemeHandler` on this web view serves (tests register one).
    private static func isWebKitHandledScheme(_ scheme: String, in webView: WKWebView) -> Bool {
        webView.configuration.urlSchemeHandler(forURLScheme: scheme) != nil
    }
}
