//
//  DominantColorExtractor.swift
//  Encore
//
//  Computes a representative ("dominant") color from an offer logo image so
//  variant JSON can bind chrome (gradients, borders, accents) to each offer's
//  brand color. Downsamples the bitmap to a tiny grid, picks the most-saturated
//  non-extreme pixel (falling back to the average), and caches the result by
//  image URL. Never blocks: callers read a neutral fallback until the async
//  fetch lands, then re-read.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Thread-safe, URL-keyed cache of dominant colors extracted from offer logos.
///
/// Resolution strategy mirrors the existing image path: it reuses the same
/// `URLCache.shared` that `CachedAsyncImage` warms, so once a logo has loaded
/// the dominant color computes from the cached bytes without a second fetch.
///
/// All public surface is safe to call from `@MainActor` render code. The heavy
/// pixel work runs off the main thread; results are published back on the main
/// thread so SwiftUI observers update.
@MainActor
final class DominantColorStore: ObservableObject {
    static let shared = DominantColorStore()

    /// Neutral fallback returned before extraction completes (or when an image
    /// can't be decoded). A mid grey reads acceptably under most chrome.
    static let fallbackHex = "FF8E8E93"

    /// urlString -> ARGB hex (8-digit, matching `Color(hex:)` semantics).
    @Published private(set) var colors: [String: String] = [:]

    /// URLs with an extraction in flight, to dedupe concurrent requests.
    private var inFlight: Set<String> = []

    private init() {}

    /// Returns the cached dominant hex for `urlString`, or `nil` if not yet
    /// computed. Pure read — does not kick off work.
    func cachedHex(for urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return colors[urlString]
    }

    /// Returns the dominant hex if available, otherwise the neutral fallback,
    /// and (when not already cached/in-flight) schedules async extraction.
    /// Safe to call every render — idempotent and non-blocking.
    @discardableResult
    func dominantHex(for urlString: String?, fallback: String = fallbackHex) -> String {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else {
            return fallback
        }
        if let cached = colors[urlString] {
            return cached
        }
        scheduleExtraction(urlString: urlString, url: url)
        return fallback
    }

    private func scheduleExtraction(urlString: String, url: URL) {
        guard !inFlight.contains(urlString) else { return }
        inFlight.insert(urlString)

        Task.detached(priority: .utility) {
            let hex = await Self.extractHex(from: url)
            await self.finishExtraction(key: urlString, hex: hex)
        }
    }

    /// Publish an extraction result on the main actor. Centralizes the mutation
    /// so the detached extraction tasks never assign into the actor-isolated
    /// `colors`/`inFlight` across the async boundary, which trips strict-
    /// concurrency exclusivity checks (`inout` to an async call).
    private func finishExtraction(key: String, hex: String?) {
        inFlight.remove(key)
        if let hex {
            colors[key] = hex
        }
    }

    #if canImport(UIKit)
    /// Cache key for the host app's own icon. The bundle icon is fixed for the
    /// process lifetime, so a single constant key caches the one result.
    private static let hostAppIconKey = "hostAppIcon"

    /// Returns the dominant hex of the HOST APP's own bundle icon if already
    /// computed, otherwise `nil` — scheduling a one-shot async extraction on the
    /// first miss. Reuses the exact offer extractor (`dominantHex(from:)`), so
    /// white/near-white icons are excluded identically: a genuinely white host
    /// icon (or a host with no bundled icon) yields `nil`, letting the JSON
    /// `fallback` win at the call site. Non-blocking — the pixel work runs off
    /// the main thread and the result is published on the main thread, so
    /// observers re-render from fallback → real brand color. Safe to call every
    /// render (idempotent, deduped).
    func dominantHexForHostAppIcon() -> String? {
        if let cached = colors[Self.hostAppIconKey] {
            return cached
        }
        guard let icon = Bundle.hostAppIcon else { return nil }
        scheduleHostAppIconExtraction(icon)
        return nil
    }

    private func scheduleHostAppIconExtraction(_ image: UIImage) {
        let key = Self.hostAppIconKey
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task.detached(priority: .utility) {
            let hex = Self.dominantHex(from: image)
            await self.finishExtraction(key: key, hex: hex)
        }
    }
    #endif

    /// Loads bytes (cache-first, matching `CachedAsyncImage`) and computes the
    /// dominant color. Returns nil if the image can't be decoded.
    nonisolated private static func extractHex(from url: URL) async -> String? {
        #if canImport(UIKit)
        let data: Data?
        let request = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: request) {
            data = cached.data
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        return Self.dominantHex(from: image)
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    /// Synchronous extraction from an already-decoded image. Exposed for
    /// deterministic unit testing on a known bitmap. `nonisolated` so the
    /// off-main extraction task can call it without hopping to the main actor.
    nonisolated static func dominantHex(from image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        // Downsample to a small fixed grid — enough signal for a representative
        // color, cheap to scan. 24x24 = 576 samples.
        let side = 24
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * side
        let bitsPerComponent = 8
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Heuristic: find the BRAND color — the obvious saturated color a human
        // would name — not whatever single pixel is most vivid, and never a
        // washed-out near-white. We bucket meaningful pixels by hue and pick the
        // bucket with the most "saturated mass" (Σ saturation), which balances
        // vividness AND prominence so a noisy minority pixel can't win and a
        // large white background can't drag the result toward grey.
        //
        // Thresholds (tuned for app-icon logos):
        // - near-white: lightness > 0.92, OR lightness > 0.82 with saturation
        //   < 0.15 — excluded from brand AND non-white tiers.
        // - meaningful brand candidate: saturation ≥ 0.22 and lightness in
        //   [0.10, 0.90] (drops near-white highlights and near-black outlines).
        let hueBucketCount = 12 // 30° per bucket
        var bucketSatMass = [Double](repeating: 0, count: hueBucketCount)
        var bucketR = [Double](repeating: 0, count: hueBucketCount)
        var bucketG = [Double](repeating: 0, count: hueBucketCount)
        var bucketB = [Double](repeating: 0, count: hueBucketCount)
        var bucketWeight = [Double](repeating: 0, count: hueBucketCount)

        // Tier-2 fallback accumulators: average of all NON-near-white pixels.
        var nwR = 0.0, nwG = 0.0, nwB = 0.0, nwCount = 0.0

        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let a = Double(pixels[i + 3]) / 255.0
            if a < 0.5 { continue } // skip transparent pixels (logo padding)
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let lightness = (maxC + minC) / 2
            let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))

            let isNearWhite = lightness > 0.92 || (lightness > 0.82 && saturation < 0.15)
            if isNearWhite { continue }

            // Tier-2: any non-near-white pixel (even low saturation / dark).
            nwR += r; nwG += g; nwB += b; nwCount += 1

            // Tier-1: meaningful, reasonably-saturated, mid-lightness brand pixel.
            guard saturation >= 0.22, lightness >= 0.10, lightness <= 0.90 else { continue }

            // Hue in [0,360) → bucket. Weight each pixel's color contribution by
            // its saturation so vivid pixels steer the bucket's mean color.
            var hue: Double = 0
            if delta != 0 {
                if maxC == r {
                    hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
                } else if maxC == g {
                    hue = 60 * (((b - r) / delta) + 2)
                } else {
                    hue = 60 * (((r - g) / delta) + 4)
                }
                if hue < 0 { hue += 360 }
            }
            let bucket = min(hueBucketCount - 1, Int(hue / (360.0 / Double(hueBucketCount))))
            bucketSatMass[bucket] += saturation
            bucketR[bucket] += r * saturation
            bucketG[bucket] += g * saturation
            bucketB[bucket] += b * saturation
            bucketWeight[bucket] += saturation
        }

        let chosen: (Double, Double, Double)
        // Tier 1: dominant saturated hue bucket.
        if let best = bucketSatMass.indices.max(by: { bucketSatMass[$0] < bucketSatMass[$1] }),
           bucketSatMass[best] > 0, bucketWeight[best] > 0 {
            chosen = (bucketR[best] / bucketWeight[best],
                      bucketG[best] / bucketWeight[best],
                      bucketB[best] / bucketWeight[best])
        // Tier 2: most prominent non-near-white color (monochrome/desaturated
        // logos with a tint but little saturation).
        } else if nwCount > 0 {
            chosen = (nwR / nwCount, nwG / nwCount, nwB / nwCount)
        // Tier 3: genuinely white/transparent logo → neutral fallback at caller.
        } else {
            return nil
        }

        let ri = UInt8(max(0, min(255, chosen.0 * 255)))
        let gi = UInt8(max(0, min(255, chosen.1 * 255)))
        let bi = UInt8(max(0, min(255, chosen.2 * 255)))
        return String(format: "FF%02X%02X%02X", ri, gi, bi)
    }
    #endif
}
