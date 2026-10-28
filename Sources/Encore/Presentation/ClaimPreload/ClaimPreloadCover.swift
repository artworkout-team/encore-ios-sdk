// The full-screen `inAppPreload` presentation: the claim screen over the blurred
// sheet, the hidden web view loading behind it, then the in-app browser.

import SwiftUI
import WebKit

@available(iOS 17.0, *)
struct ClaimPreloadCover: View {
    @ObservedObject var controller: ClaimPreloadController
    /// The presentation's strings snapshot.
    let strings: SDKStrings
    let onClose: () -> Void
    /// The claim screen's ×, offered only once the cap passes with no transaction.
    let onEscape: () -> Void

    var body: some View {
        ZStack {
            // Kept in the tree from load to close, so it lays out at full size while hidden.
            if let webView = controller.webView {
                InAppBrowserView(webView: webView, host: controller.currentHost, isSecure: controller.isSecure, strings: strings, onClose: onClose)
                    .opacity(controller.phase == .revealed ? 1 : 0)
                    .allowsHitTesting(controller.phase == .revealed)
                    .accessibilityHidden(controller.phase != .revealed)
            }
            if controller.phase != .revealed {
                ClaimScreenView(content: controller.content, strings: strings, onEscape: controller.canEscape ? onEscape : nil)
                    // No entrance motion in the design; it only fades out on reveal.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeOut(duration: ClaimPreloadTokens.revealFadeSeconds), value: controller.phase)
        // The backdrop is the sheet underneath, blurred and washed out.
        .presentationBackground {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(ClaimPreloadTokens.backdropWashColor.opacity(ClaimPreloadTokens.backdropWashOpacity))
                .opacity(controller.phase == .revealed ? 0 : 1)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Claim screen

@available(iOS 17.0, *)
struct ClaimScreenView: View {
    typealias T = ClaimPreloadTokens
    let content: ClaimPreloadController.Content
    let strings: SDKStrings
    var onEscape: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Figma centres on the whole 393x852 frame, not the safe area.
            ClaimScreenColumn(content: content, strings: strings, animated: !reduceMotion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            if let onEscape {
                Button(action: onEscape) {
                    Image(systemName: "xmark")
                        .font(.system(size: T.escapeGlyphSize, weight: .semibold))
                        .foregroundColor(T.escapeGlyphColor)
                        .frame(width: T.escapeSize, height: T.escapeSize)
                        .background(Circle().fill(T.escapeFill))
                }
                .accessibilityLabel(Text(verbatim: ClaimPreloadTokens.closeLabel(strings)))
                .padding(T.escapeInset)
            }
        }
    }
}

/// The centred column: logo, title and spinner, domain line, check rows.
@available(iOS 17.0, *)
struct ClaimScreenColumn: View {
    typealias T = ClaimPreloadTokens
    let content: ClaimPreloadController.Content
    let strings: SDKStrings
    let animated: Bool

    var body: some View {
        VStack(spacing: T.logoToTextSpacing) {
            // No logo URL: no box, and no gap above the title.
            if let logoUrl = content.logoUrl {
                logo(logoUrl)
            }
            VStack(spacing: 0) {
                VStack(spacing: T.titleToDomainSpacing) {
                    HStack(spacing: T.titleToSpinnerSpacing) {
                        Text(verbatim: T.title(strings))
                            .font(T.titleFont)
                            .tracking(T.titleTracking)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(minHeight: T.titleLineHeight)
                        ClaimSpinner(animated: animated)
                    }
                    .padding(.top, T.titleRowPaddingTop)

                    if let domain = content.domain {
                        Text(verbatim: T.finishOn(domain, strings))
                            .font(T.domainFont)
                            .frame(maxWidth: .infinity, minHeight: T.domainLineHeight)
                    }
                }
                .multilineTextAlignment(.center)

                if !content.checks.isEmpty {
                    VStack(alignment: .leading, spacing: T.checkRowSpacing) {
                        ForEach(Array(content.checks.enumerated()), id: \.offset) { _, check in
                            CheckRow(text: check)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, T.textToChecksSpacing)
                }
            }
        }
        .foregroundColor(T.textColor)
        .padding(.top, T.columnPaddingTop)
        .padding(.bottom, T.columnPaddingBottom)
        .padding(.horizontal, T.columnPaddingHorizontal)
        .frame(maxWidth: T.columnWidth)
        .offset(y: -T.columnOffsetAboveCentre)
        .accessibilityElement(children: .combine)
    }

    /// The image sits top-left of a slightly larger wrapper, as in the frame.
    private func logo(_ url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: T.logoCornerRadius, style: .continuous)
        return CachedAsyncImage(url: url, contentMode: .fill,
                                placeholder: { shape.fill(Color(UIColor.secondarySystemFill)) },
                                widthPoints: SDUIImageLoader.logoWidthPoints)
        .frame(width: T.logoSize, height: T.logoSize)
        .clipShape(shape)
        .shadow(color: T.logoShadowColor, radius: T.logoShadowRadius, x: 0, y: T.logoShadowY)
        .frame(width: T.logoWrapperSize, height: T.logoWrapperSize, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

@available(iOS 17.0, *)
private struct CheckRow: View {
    typealias T = ClaimPreloadTokens
    let text: String

    var body: some View {
        HStack(spacing: T.checkIconToTextSpacing) {
            // The check is knocked out of the circle, as in the Figma icon.
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(T.checkIconColor)
                .frame(width: T.checkCircleDiameter, height: T.checkCircleDiameter)
                .frame(width: T.checkIconBox, height: T.checkIconBox)
                .accessibilityHidden(true)
            Text(text)
                .font(T.checkFont)
                .tracking(T.checkTracking)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: T.checkRowHeight)
    }
}

/// Arc on a pale track, one turn per 0.96s. Static under Reduce Motion.
@available(iOS 17.0, *)
private struct ClaimSpinner: View {
    typealias T = ClaimPreloadTokens
    let animated: Bool
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(T.spinnerTrackColor, lineWidth: T.spinnerLineWidth)
            Circle()
                .trim(from: 0, to: T.spinnerArcFraction)
                .stroke(T.spinnerArcColor, style: StrokeStyle(lineWidth: T.spinnerLineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .padding(T.spinnerLineWidth / 2)
        .frame(width: T.spinnerSize, height: T.spinnerSize)
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: T.spinnerRevolutionSeconds).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - In-app browser

@available(iOS 17.0, *)
struct InAppBrowserView: View {
    let webView: WKWebView
    let host: String?
    let isSecure: Bool
    let strings: SDKStrings
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let host {
                    HStack(spacing: ClaimPreloadTokens.lockToDomainSpacing) {
                        if isSecure {
                            Image(systemName: "lock.fill")
                                .font(.system(size: ClaimPreloadTokens.lockGlyphSize, weight: .semibold))
                                .accessibilityLabel(Text(verbatim: ClaimPreloadTokens.secureLabel(strings)))
                        }
                        Text(Campaign.displayHost(host) ?? host)
                            .font(ClaimPreloadTokens.browserDomainFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(ClaimPreloadTokens.browserDomainColor)
                    .padding(.horizontal, ClaimPreloadTokens.closeHitSize)
                }
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: ClaimPreloadTokens.closeGlyphSize, weight: .semibold))
                            .foregroundColor(ClaimPreloadTokens.closeColor)
                            .frame(width: ClaimPreloadTokens.closeHitSize, height: ClaimPreloadTokens.closeHitSize)
                    }
                    .accessibilityLabel(Text(verbatim: ClaimPreloadTokens.closeLabel(strings)))
                    Spacer()
                }
            }
            .frame(height: ClaimPreloadTokens.chromeHeight)
            .background(ClaimPreloadTokens.chromeBackground)
            .overlay(alignment: .bottom) {
                ClaimPreloadTokens.chromeDividerColor.frame(height: 1 / UIScreen.main.scale)
            }

            WebViewHost(webView: webView)
        }
        .background(ClaimPreloadTokens.chromeBackground.ignoresSafeArea())
    }
}

/// Hosts an existing WKWebView; never creates one.
@available(iOS 17.0, *)
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
