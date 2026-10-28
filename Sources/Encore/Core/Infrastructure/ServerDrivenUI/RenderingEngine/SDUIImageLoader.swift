// The SDK's one image path: width-ladder URL resolution, a dedicated URLSession
// with its own URLCache, and the record behind `image_cache_hit`.
// Android and web mirror these names and numbers.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Widths the CDN serves at `https://assets.encorekit.com/w/{W}/{object path}`.
let imageWidthLadder: [Int] = [320, 640, 960, 1280]
let imageLadderHost = "assets.encorekit.com"
/// Every prefix the resize route serves; must match PUBLIC_ROOTS in the backend.
/// A prefix missing here is not an error anywhere: the image is just fetched at
/// full size forever. 256 of the 320 bucket-hosted creative logos are under /organizations/.
let imageLadderPathPrefixes = ["/creatives/", "/apps/", "/campaigns/", "/organizations/", "/sdk-assets/", "/website-assets/"]

/// Rewrites a CDN image URL to the smallest ladder width that covers the drawn pixels.
/// Any other scheme, port, host or path, or a URL already on the ladder, comes back unchanged.
func resolveImageURL(_ url: URL, renderedWidthPoints: CGFloat, scale: CGFloat) -> URL {
    guard isLadderOrigin(url),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    let path = components.percentEncodedPath
    guard imageLadderPathPrefixes.contains(where: path.hasPrefix) else { return url }

    let pixels = renderedWidthPoints * scale
    let cap = imageWidthLadder[imageWidthLadder.count - 1]
    let width = pixels.isFinite ? (imageWidthLadder.first { CGFloat($0) >= pixels } ?? cap) : cap
    components.percentEncodedPath = "/w/\(width)" + path
    return components.url ?? url
}

/// The ladder contract covers `https://assets.encorekit.com` only: an `http` or ported URL passes through.
private func isLadderOrigin(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.lowercased() == imageLadderHost && url.port == nil
}

enum SDUIImageLoader {
    static let memoryCapacity = 8 * 1024 * 1024
    static let diskCapacity = 20 * 1024 * 1024

    /// Separate from `URLCache.shared`, which is small and evicts large images first.
    static let defaultSession: URLSession = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.encorekit.images", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: directory)
        // HTTP freshness by default; only ladder URLs, which are immutable, skip it. See `request(_:)`.
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Image hosts get no cookies or credentials from the host app.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Test seam: tests swap in a stub session. Production never assigns this.
    nonisolated(unsafe) static var session: URLSession = defaultSession

    /// A `/w/{W}/` width on the asset host, which has an original to fall back to.
    static func isLadderURL(_ url: URL) -> Bool {
        isLadderOrigin(url) && url.path.hasPrefix("/w/")
    }

    /// The original a ladder URL was resolved from, for when its variant cannot be served.
    static func originalURL(fromLadder url: URL) -> URL? {
        guard isLadderURL(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "w", Int(parts[1]) != nil else { return nil }
        components.percentEncodedPath = "/" + parts[2]
        return components.url
    }

    /// Cached bytes to draw at once while their own headers say they are fresh, or nil.
    /// Ladder widths copy their original's header, so a hand-placed image replaced in place refreshes too.
    static func cachedData(for url: URL) -> Data? {
        guard let cached = cachedImage(for: url) else { return nil }
        return isFresh(cached.response) ? cached.data : nil
    }

    /// Explicit HTTP freshness only: Cache-Control, else Expires. With neither, freshness is
    /// unknown, so the load goes through URLSession, which applies validators and heuristics.
    static func isFresh(_ response: URLResponse, now: Date = Date()) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        guard let control = http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() else {
            guard let expires = http.value(forHTTPHeaderField: "Expires").flatMap(httpDateFormatter.date(from:)) else { return false }
            return expires > now
        }
        if control.contains("no-store") || control.contains("no-cache") { return false }
        // Anything this cannot establish is unknown, and unknown is not fresh: URLSession decides.
        guard let range = control.range(of: #"max-age=(\d+)"#, options: .regularExpression),
              let maxAge = Double(control[range].dropFirst("max-age=".count)),
              let date = http.value(forHTTPHeaderField: "Date").flatMap(httpDateFormatter.date(from:)) else { return false }
        // `now - Date` already spans the time a cache held it, which `Age` reports, so the larger wins.
        let age = max(now.timeIntervalSince(date), Double(http.value(forHTTPHeaderField: "Age") ?? "") ?? 0)
        return age < maxAge
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Whether an image for `url` is in the cache at all, fresh or not. What the metric reads.
    static func isCached(_ url: URL) -> Bool {
        cachedImage(for: url) != nil
    }

    /// Cache first for ladder URLs, then network. A ladder variant the CDN cannot serve
    /// (a 404, a shed 503) falls back to the original rather than to a placeholder.
    /// Any other URL that fails falls back to its stale cached copy, so offline still draws.
    static func load(_ url: URL) async throws -> (Data, URLResponse) {
        let session = self.session
        // Taken before the request: URLSession may replace a stale entry with an error page it caches.
        let stale = cachedImage(for: url)
        if let stale, isFresh(stale.response) { return (stale.data, stale.response) }
        do {
            let (data, response) = try await session.data(for: request(url))
            if isImage(response, data) {
                // Stored explicitly, because a data task skips responses over 5% of the
                // disk capacity. The stored headers keep their own freshness for non-ladder URLs.
                session.configuration.urlCache?.storeCachedResponse(
                    CachedURLResponse(response: response, data: data), for: request(url))
                return (data, response)
            }
            if let original = originalURL(fromLadder: url) { return try await load(original) }
            if let stale { return (stale.data, stale.response) }
            return (data, response)
        } catch {
            // A network error is not a missing rung: the original shares the host, so
            // trying it would only wait out the same outage twice.
            if let stale { return (stale.data, stale.response) }
            throw error
        }
    }

    /// The cached 2xx image for `url`. The data task also caches other responses
    /// (an error page), which would otherwise be served, so they are dropped.
    private static func cachedImage(for url: URL) -> CachedURLResponse? {
        guard let cache = session.configuration.urlCache,
              let cached = cache.cachedResponse(for: request(url)) else { return nil }
        guard isImage(cached.response, cached.data) else {
            cache.removeCachedResponse(for: request(url))
            return nil
        }
        return cached
    }

    /// A 2xx response whose bytes are an image. Sniffed, not trusted from the MIME type:
    /// storage defaults like `binary/octet-stream` would otherwise re-download on every
    /// appearance, and an HTML captive portal or an SVG would be pinned as an image.
    private static func isImage(_ response: URLResponse, _ data: Data) -> Bool {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return looksLikeImage(data)
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(64))
        guard b.count >= 4 else { return false }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }               // PNG
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }                     // JPEG
        if b.starts(with: Array("GIF8".utf8)) { return true }                     // GIF
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)),
           Array(b[8..<12]) == Array("WEBP".utf8) { return true }                 // WebP
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return hasImageBrand(b) } // HEIC, AVIF
        return false
    }

    /// `ftyp` is the ISO media container, which MP4 and MOV share; only an image brand makes it an image.
    private static let imageBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"]

    private static func hasImageBrand(_ b: [UInt8]) -> Bool {
        let boxSize = b[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let end = min(boxSize, b.count)
        // The major brand at 8, then compatible brands from 16 to the end of the box.
        let offsets = [8] + Array(stride(from: 16, to: end - 3, by: 4))
        return offsets.contains { $0 + 4 <= b.count && imageBrands.contains(String(decoding: b[$0..<$0 + 4], as: UTF8.self)) }
    }

    /// Every image follows its own HTTP headers, ladder widths included.
    static func request(_ url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
    }

    // MARK: - image_cache_hit

    /// Every image an offer can draw, each at its drawn width. Prefetch and render share these keys.
    static func imageURLs(for offer: Offer, cardWidthPoints: CGFloat, scale: CGFloat) -> [URL] {
        func resolved(_ strings: [String?], _ points: CGFloat) -> [URL] {
            strings.compactMap { SDUIImageSlotPlan.nonBlank($0).flatMap { URL(string: $0) } }
                .map { resolveImageURL($0, renderedWidthPoints: points, scale: scale) }
        }
        let primary = SDUIImageSlotPlan.nonBlank(offer.displayPrimaryImageUrl)
        // With no primary image the card draws `tileLogoUrl` on a tile instead.
        let urls = resolved([primary, offer.displayHeroImageUrl], cardWidthPoints)
            + resolved([offer.displayLogoUrl, primary == nil ? offer.tileLogoUrl : nil], logoWidthPoints)
        // The hero coalesces to the creative, so a campaign without one repeats a URL.
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Ready when shown: true when the offer's picture is in the image cache as the
    /// impression fires, whoever fetched it, so a prefetched image counts as the hit it
    /// is. Nil when the offer has no picture, so it never inflates the rate.
    @MainActor static func imageCacheHit(for offer: Offer) -> Bool? {
        pictureURL(for: offer).map { drewFromCache[$0] ?? isCached($0) }
    }

    /// Whether each url drew straight from the cache when a view last asked for it. The impression
    /// reads this: by the time a featured creative reports, the load it waited on has filled the cache.
    @MainActor private static var drewFromCache: [URL: Bool] = [:]

    @MainActor static func recordDraw(_ url: URL, fromCache: Bool) {
        drewFromCache[url] = fromCache
    }

    #if DEBUG
    @MainActor static func drewFromCacheForTesting(_ url: URL) -> Bool? { drewFromCache[url] }
    #endif

    /// What every layout draws in the picture slot: the creative, else the tile logo.
    /// Logo and hero are not required, since some layouts never draw them.
    @MainActor private static func pictureURL(for offer: Offer) -> URL? {
        if let primary = SDUIImageSlotPlan.nonBlank(offer.displayPrimaryImageUrl) {
            return URL(string: primary).map { resolve($0) }
        }
        return SDUIImageSlotPlan.nonBlank(offer.tileLogoUrl).flatMap { URL(string: $0) }
            .map { resolve($0, widthPoints: logoWidthPoints) }
    }

    // MARK: - Display metrics

    /// `url` at the screen scale and its drawn width (the card width by default), so prefetch and render share a cache key.
    @MainActor static func resolve(_ url: URL, widthPoints: CGFloat? = nil) -> URL {
        resolveImageURL(url, renderedWidthPoints: widthPoints ?? defaultCardWidthPoints, scale: screenScale)
    }

    /// Logos draw at 96pt or less (web's 96 CSS px), so they resolve at this width, not the card's.
    static let logoWidthPoints: CGFloat = 96

    /// The width card images resolve at: the screen width, since cards span the sheet. Logos use `logoWidthPoints`.
    @MainActor static var defaultCardWidthPoints: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return 390
        #endif
    }

    @MainActor static var screenScale: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.scale
        #else
        return 2
        #endif
    }
}
