// AsyncImage replacement that reads the SDK image cache synchronously first, so a
// prefetched image draws at once instead of flashing a placeholder.

import SwiftUI

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

/// Loads an image with a synchronous cache probe first, so a cached image
/// renders on the first frame instead of after a placeholder flash.
struct CachedAsyncImage<Placeholder: View>: View {
    /// The unresolved URL. The load resolves it to a ladder width.
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

    /// Off for a decorative image, where a load that never finishes would
    /// otherwise shimmer for as long as it is on screen.
    var shimmers: Bool = true
    /// The drawn width the url resolves at. nil is the card width.
    var widthPoints: CGFloat? = nil

    /// What the slot shows. `absent` never shimmers: nothing will load, so a
    /// shimmer would read as loading forever. `waiting` is a load without one.
    enum Phase: Equatable { case loaded, absent, loading, waiting }

    init(
        url: URL?,
        contentMode: ContentMode,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        onLoadedVisible: (() -> Void)? = nil,
        onLoadFailed: ((SDUIImageLoadFailure) -> Void)? = nil,
        shimmers: Bool = true,
        widthPoints: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.onLoadedVisible = onLoadedVisible
        self.onLoadFailed = onLoadFailed
        self.shimmers = shimmers
        self.widthPoints = widthPoints
        // Seed from the in-memory cache so a recycled carousel card renders its
        // creative on the first frame instead of flashing the shimmer.
        let resolved = url.map { SDUIImageLoader.resolve($0, widthPoints: widthPoints) }
        let seeded = resolved.flatMap(Self.cachedImage(for:))
        if let resolved, seeded != nil {
            SDUIImageLoader.recordDraw(resolved, fromCache: true)
        }
        _image = State(initialValue: seeded)
    }

    static func phase(url: URL?, hasImage: Bool, shimmers: Bool = true) -> Phase {
        if hasImage { return .loaded }
        if url == nil { return .absent }
        return shimmers ? .loading : .waiting
    }

    var body: some View {
        Group {
            switch Self.phase(url: url, hasImage: image != nil, shimmers: shimmers) {
            case .loaded:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .modifier(OptionallyOnVisible(action: onLoadedVisible))
                }
            case .absent, .waiting:
                placeholder()
            case .loading:
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

        // Synchronous cache probe (decoded memory first, then the SDK's fresh
        // URLCache entry, which `OffersManager` prefetches), so cached images
        // render on the first frame with no placeholder.
        let resolved = SDUIImageLoader.resolve(url, widthPoints: widthPoints)
        if let uiImage = Self.cachedImage(for: resolved) {
            SDUIImageLoader.recordDraw(resolved, fromCache: true)
            cancelInFlight()
            image = uiImage
            return
        }
        SDUIImageLoader.recordDraw(resolved, fromCache: false)

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
                let (data, response) = try await SDUIImageLoader.load(resolved)
                // Superseded. Its bytes are for the previous url.
                guard !Task.isCancelled else { return }
                guard let uiImage = UIImage(data: data) else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    let detail = status.map { "HTTP \($0), " } ?? ""
                    onLoadFailed?(.undecodable(detail: "\(detail)not an image: ", url: url))
                    return
                }
                CachedImageMemoryCache.images.setObject(uiImage, forKey: resolved as NSURL)
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

    /// `url` is already resolved to its ladder width, so memory and URLCache
    /// share the key the load stores under.
    private static func cachedImage(for url: URL) -> UIImage? {
        if let image = CachedImageMemoryCache.images.object(forKey: url as NSURL) {
            return image
        }
        guard let data = SDUIImageLoader.cachedData(for: url),
              let image = UIImage(data: data)
        else { return nil }
        CachedImageMemoryCache.images.setObject(image, forKey: url as NSURL)
        return image
    }
}

@MainActor
private enum CachedImageMemoryCache {
    static let images = NSCache<NSURL, UIImage>()
}

// MARK: - Logo Tile

/// The picture slot of an offer that has none: its logo centred on a tile, as
/// web and Android draw it. The tile, not the logo, carries the impression
/// probe: a logo that fails to load still leaves the ad on screen.
struct SDUILogoTile: View {
    let logoURL: URL?
    let background: Color
    let aspectRatio: CGFloat?
    let contentMode: ContentMode
    var onVisible: (() -> Void)? = nil

    /// Never shimmers: a logo that fails to load leaves a still tile.
    static let logoShimmers = false

    /// Web's 72pt logo on a 120pt tile, scaled to the same share of a smaller slot's short side.
    static func logoSide(in size: CGSize) -> CGFloat {
        let shortSide = [size.width, size.height].filter { $0.isFinite && $0 > 0 }.min()
        return shortSide.map { min(72, $0 * 72 / 120) } ?? 72
    }

    /// Web rounds its 72pt logo by 16pt; a smaller logo keeps that proportion.
    static func logoCornerRadius(forSide side: CGFloat) -> CGFloat { side * 16 / 72 }

    var body: some View {
        background
            .aspectRatio(aspectRatio, contentMode: contentMode)
            .overlay(GeometryReader { geo in
                let side = Self.logoSide(in: geo.size)
                CachedAsyncImage(url: logoURL, contentMode: .fit, placeholder: { Color.clear },
                                 shimmers: Self.logoShimmers, widthPoints: SDUIImageLoader.logoWidthPoints)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: Self.logoCornerRadius(forSide: side)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Decorative: the advertiser is named elsewhere on the card.
                    .accessibilityHidden(true)
            })
            .modifier(OptionallyOnVisible(action: onVisible))
    }
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
