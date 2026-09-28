//
//  CachedAsyncImage.swift
//  Encore
//
//  AsyncImage replacement that checks URLCache synchronously before going async.
//  Eliminates the placeholder flash when images are already cached (e.g. after pre-warming).
//  Shows a subtle shimmer skeleton while loading, then cross-fades the image in.
//

import SwiftUI

/// Loads an image from a URL with synchronous cache-first resolution.
///
/// SwiftUI's `AsyncImage` always starts in the `.empty` phase — even when the
/// image bytes are sitting in `URLCache`. This causes a visible placeholder
/// flash on every view appearance. `CachedAsyncImage` checks the shared URL
/// cache synchronously on init; if the image is already cached it renders
/// immediately with zero placeholder frames.
///
/// When loading async, shows a subtle animated shimmer skeleton instead of a
/// solid color placeholder, then cross-fades the image in.
/// The session `CachedAsyncImage` fetches through.
///
/// A seam, not a feature: `URLSession.shared` ignores `URLProtocol.registerClass`,
/// so with it hard-coded no test could count a fetch or serve a body that is not
/// an image. Production never assigns this.
enum SDUIImageLoader {
    nonisolated(unsafe) static var session: URLSession = .shared
}

/// Why an image did not render.
///
/// Split because the two want different handling: bytes that are not an
/// image are a creative someone has to fix, while an unreachable host is
/// usually the user's own connection and is not worth reporting as a fault.
enum SDUIImageLoadFailure {
    case undecodable(detail: String, url: URL)
    case unreachable(Error, URL)

    /// The dedup IDENTITY, carrying the full url. Two creatives can share a
    /// path and differ only by query, so collapsing them would hide one. Not
    /// for sending: see `reason`.
    var ledgerKey: String {
        switch self {
        case .undecodable(let detail, let url):
            return "\(detail)\(url.absoluteString)"
        case .unreachable(let error, let url):
            return "\(error.localizedDescription) for \(url.absoluteString)"
        }
    }

    /// What is safe to SEND, with the query removed. `Logger.error` reaches the
    /// errors service, and a creative url's query can carry a signed token.
    /// Android strips it at the same seam, and in `CustomTabsPresenter` before
    /// any url reaches a log.
    var reason: String {
        switch self {
        case .undecodable(let detail, let url):
            return "\(detail)\(Self.withoutQuery(url))"
        case .unreachable(let error, let url):
            return "\(error.localizedDescription) for \(Self.withoutQuery(url))"
        }
    }

    private static func withoutQuery(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        // The fallback truncates rather than returning the raw url: a url
        // `URLComponents` cannot parse is exactly the one whose query is most
        // likely to be strange, so it is the last thing to send verbatim.
        return components?.string
            ?? String(url.absoluteString.prefix { $0 != "?" && $0 != "#" })
    }

    /// True when the device could not reach the host at all. Being offline
    /// is a routine user condition, not an SDK fault.
    var isOffline: Bool {
        guard case .unreachable(let error, _) = self else { return false }
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}

/// Reports a primary creative that did not render, at most once per reason.
///
/// `Logger.error` reaches the backend errors service, which batches nothing, and
/// a row remounts on every scroll recycle and state change. A CDN outage across
/// a five-offer sheet would otherwise send a report per row per remount for the
/// life of the session. Mirrors Android's `SduiCreativeFailureReporter`.
@MainActor
enum SDUICreativeFailureReporter {

    private static var reported: Set<String> = []

    /// Returns the message actually sent, or nil when nothing was.
    ///
    /// It returns the MESSAGE rather than a Bool so a test can see what leaves
    /// the device. `Logger.error` reaches the errors service through the
    /// service container, which a unit test cannot stub, so a Bool left the
    /// redaction unprovable: swapping the sent string for the unredacted one
    /// changed nothing any test could observe.
    @discardableResult
    static func report(_ failure: SDUIImageLoadFailure) -> String? {
        guard !failure.isOffline else { return nil }
        guard reported.insert(failure.ledgerKey).inserted else { return nil }
        let message = "Primary creative failed to load: \(failure.reason)"
        // `presentOfferInitialization`, not `logImpression`: Sentry fingerprints
        // on [errorType, context], so filing a creative download failure under
        // the impression API's own context both splits it from Android's copy of
        // this report and pollutes the metric used to chase missing impressions.
        Logger.error(.domain(message), context: .presentOfferInitialization)
        return message
    }

    /// Test seam: the ledger outlives any one view by design.
    static func reset() { reported.removeAll() }
}

struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    @ViewBuilder let placeholder: () -> Placeholder
    /// Invoked when the *loaded* image (not the placeholder) is visible
    /// at the default `View.onVisible` threshold (≥ 50% of its own area
    /// in the active window). A failed load never fires this.
    ///
    /// This is the FALLBACK impression probe, for a creative drawn outside an
    /// offer row. Inside a row the row reports instead, and it reports whether
    /// or not this image loaded. Stateless; callers dedupe higher up.
    var onLoadedVisible: (() -> Void)? = nil
    /// Invoked when the image does not render. The caller decides what a failed
    /// creative means and how to report it.
    var onLoadFailed: ((SDUIImageLoadFailure) -> Void)? = nil

    @State private var image: UIImage?
    /// The load in flight, and the url it is for. Kept so a url change can
    /// cancel it: a late response for the previous url would otherwise render
    /// over the new one.
    @State private var loadTask: Task<Void, Never>?
    @State private var loadingURL: URL?

    init(
        url: URL?,
        contentMode: ContentMode,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        onLoadedVisible: (() -> Void)? = nil,
        onLoadFailed: ((SDUIImageLoadFailure) -> Void)? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.onLoadedVisible = onLoadedVisible
        self.onLoadFailed = onLoadFailed
        // Seed from the in-memory cache so a recycled carousel card renders its
        // creative on the first frame instead of flashing the shimmer.
        _image = State(initialValue: Self.cachedImage(for: url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .modifier(OptionallyOnVisible(action: onLoadedVisible))
            } else {
                placeholder()
                    .overlay(ShimmerView())
            }
        }
        .onAppear { loadIfNeeded(url) }
        // The url comes from the CLOSURE, not from `self`. `onChange` runs the
        // action captured by the previous body, so `self.url` here is still the
        // old one, which is the desync: the load kept resolving the old offer.
        .onChange(of: url) { newURL in
            image = nil
            loadIfNeeded(newURL)
        }
    }

    private func loadIfNeeded(_ url: URL?) {
        // A url cleared to nil drops the load in flight too. Returning without
        // cancelling left the previous creative's response to land on a view
        // that now has no url, which is the same stale render from the other end.
        guard let url else {
            cancelInFlight()
            return
        }
        guard image == nil else { return }

        // Synchronous cache probe (memory first, then `URLCache.shared`, which
        // `OffersManager.preloadImages` pre-warms), so cached images render on
        // the first frame with no placeholder.
        if let uiImage = Self.cachedImage(for: url) {
            cancelInFlight()
            image = uiImage
            return
        }

        // Only a load for the SAME url is already covered. A different url
        // supersedes, so it cancels rather than returning: returning was the
        // desync, because the old load then rendered over the new selection.
        if loadingURL == url, loadTask != nil { return }
        cancelInFlight()

        loadingURL = url
        loadTask = Task { @MainActor in
            // A cancelled task never clears, or it would orphan the load that
            // superseded it.
            defer { if !Task.isCancelled, loadingURL == url { cancelInFlight() } }
            // Decodability decides, not the status code. A CDN that answers a
            // 4xx with a real bitmap used to render it, and gating on status
            // would have replaced that with a permanent shimmer.
            //
            // A 404 does not throw: it returns an error page, which
            // `UIImage(data:)` rejects. That is the path this reports on, along
            // with a thrown transport error, so a creative that never rendered
            // is an error and not a silence.
            do {
                let (data, response) = try await SDUIImageLoader.session.data(from: url)
                // Superseded. Its bytes are for the previous url.
                guard !Task.isCancelled else { return }
                guard let uiImage = UIImage(data: data) else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    let detail = status.map { "HTTP \($0), " } ?? ""
                    onLoadFailed?(.undecodable(detail: "\(detail)not an image: ", url: url))
                    return
                }
                CachedImageMemoryCache.images.setObject(uiImage, forKey: url as NSURL)
                image = uiImage
            } catch {
                // Cancellation throws here too, and a superseded load is not a
                // creative fault.
                guard !Task.isCancelled else { return }
                onLoadFailed?(.unreachable(error, url))
            }
        }
    }

    private func cancelInFlight() {
        loadTask?.cancel()
        loadTask = nil
        loadingURL = nil
    }

    private static func cachedImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let image = CachedImageMemoryCache.images.object(forKey: url as NSURL) {
            return image
        }

        let request = URLRequest(url: url)
        guard let cached = URLCache.shared.cachedResponse(for: request),
              let image = UIImage(data: cached.data)
        else { return nil }
        CachedImageMemoryCache.images.setObject(image, forKey: url as NSURL)
        return image
    }
}

@MainActor
private enum CachedImageMemoryCache {
    static let images = NSCache<NSURL, UIImage>()
}

// MARK: - Shimmer Skeleton

/// Subtle animated shimmer overlay for loading placeholders.
/// Adapts to light/dark mode automatically via system colors.
private struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color(UIColor.systemFill).opacity(0),
                    Color(UIColor.systemFill).opacity(0.3),
                    Color(UIColor.systemFill).opacity(0)
                ],
                startPoint: .init(x: phase, y: 0.5),
                endPoint: .init(x: phase + 0.7, y: 0.5)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
        }
        .allowsHitTesting(false)
    }
}
