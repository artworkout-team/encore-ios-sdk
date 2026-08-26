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
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    @ViewBuilder let placeholder: () -> Placeholder
    /// Invoked when the *loaded* image (not the placeholder) is visible
    /// at the default `View.onVisible` threshold (≥ 50% of its own area
    /// in the active window). A failed load — placeholder branch — never
    /// fires this, so a creative that didn't render isn't recorded as a
    /// viewable. Stateless; callers dedupe at a higher layer if needed.
    var onLoadedVisible: (() -> Void)?

    @State private var image: UIImage?
    @State private var isLoading = false

    init(
        url: URL?,
        contentMode: ContentMode,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        onLoadedVisible: (() -> Void)? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.onLoadedVisible = onLoadedVisible
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
        .onAppear { loadIfNeeded() }
        .onChange(of: url) { _ in
            image = Self.cachedImage(for: url)
            loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard image == nil, let url else { return }

        if let uiImage = Self.cachedImage(for: url) {
            image = uiImage
            return
        }

        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let uiImage = UIImage(data: data)
            else { return }
            CachedImageMemoryCache.images.setObject(uiImage, forKey: url as NSURL)
            image = uiImage
        }
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

// MARK: - Optional Visibility Bridge

/// Conditionally applies `View.onVisible` only when an action is provided.
/// Skips wiring up `GeometryReader` / `onChange` instrumentation entirely
/// when the caller doesn't ask to be notified.
private struct OptionallyOnVisible: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onVisible(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Shimmer Skeleton

/// Subtle animated shimmer overlay for loading placeholders.
/// Adapts to light/dark mode automatically via system colors.
private struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        if #available(iOS 18.0, *) {
            GeometryReader { _ in
                LinearGradient(
                    colors: [
                        Color(UIColor.systemFill).opacity(0),
                        Color(UIColor.systemFill).opacity(0.3),
                        Color(UIColor.systemFill).opacity(0),
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
        } else {
            CoreAnimationShimmerView()
                .allowsHitTesting(false)
        }
    }
}

@available(iOS 17.0, *)
private struct CoreAnimationShimmerView: UIViewRepresentable {
    func makeUIView(context _: Context) -> CoreAnimationShimmerUIView {
        CoreAnimationShimmerUIView()
    }

    func updateUIView(_: CoreAnimationShimmerUIView, context _: Context) {}
}

@available(iOS 17.0, *)
private final class CoreAnimationShimmerUIView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.locations = [-1, -0.65, -0.3]
        updateColors()

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1, -0.65, -0.3]
        animation.toValue = [1.3, 1.65, 2]
        animation.duration = 1.2
        animation.repeatCount = .infinity
        gradientLayer.add(animation, forKey: "encore.shimmer")
    }

    private func updateColors() {
        let fill = UIColor.systemFill.resolvedColor(with: traitCollection)
        gradientLayer.colors = [
            fill.withAlphaComponent(0).cgColor,
            fill.withAlphaComponent(0.3).cgColor,
            fill.withAlphaComponent(0).cgColor,
        ]
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        updateColors()
    }
}
