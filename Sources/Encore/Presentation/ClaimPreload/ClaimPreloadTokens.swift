// Design tokens for the `inAppPreload` claim screen and in-app browser.
// Claim screen values are from Figma node 19575:37963 (file UpWstaeKjV0zUGN3BvGElO).

import SwiftUI
import UIKit

enum ClaimPreloadTokens {
    // MARK: Timing (product values, not in Figma)

    /// MIN_CLAIM_SCREEN_MS.
    static let minClaimScreenSeconds: TimeInterval = 1.2
    /// MAX_CLAIM_SCREEN_MS. Also when the claiming-phase × appears.
    static let maxClaimScreenSeconds: TimeInterval = 8.0
    /// A live steps-screen preload re-sends its reservation this long after the last success. The
    /// server keeps the id for 30 min after the last preload POST (Android: PRELOAD_REFRESH_INTERVAL_MS).
    static let preloadRefreshIntervalSeconds: TimeInterval = 20 * 60
    /// After a refresh with no HTTP answer (timeout, offline), the next try (Android: PRELOAD_REFRESH_RETRY_MS).
    static let preloadRefreshRetrySeconds: TimeInterval = 60
    /// The server's reservation window, counted from the SEND of the last successful preload POST.
    static let preloadReservationWindowSeconds: TimeInterval = 30 * 60
    /// Fade-out of the claim screen on reveal. The screen has no entrance motion.
    static let revealFadeSeconds: Double = 0.25
    static let spinnerRevolutionSeconds: Double = 0.96

    // MARK: Copy

    /// Served `claim.loading`, else "Loading your FREE offer".
    static func title(_ strings: SDKStrings) -> String { strings[.claimLoading] }
    /// Served `claim.finishOn` with the domain substituted, never translated.
    /// A template, not a prefix: some languages put the domain first.
    static func finishOn(_ domain: String, _ strings: SDKStrings) -> String {
        strings.format(.claimFinishOn, ["domain": domain])
    }
    /// Served `modal.close`, else the catalog's "Close modal", as web reads it.
    static func closeLabel(_ strings: SDKStrings) -> String { strings[.modalClose] }
    /// Served `browser.secure`, else "Secure connection": the lock icon's spoken name.
    static func secureLabel(_ strings: SDKStrings) -> String { strings[.browserSecure] }
    static let maxCheckRows = 3

    // MARK: Backdrop (the reward sheet, blurred and washed out)

    static let backdropWashColor = Color.white
    static let backdropWashOpacity: Double = 0.65

    // MARK: Column

    static let columnWidth: CGFloat = 353
    static let columnPaddingTop: CGFloat = 30
    static let columnPaddingBottom: CGFloat = 20
    static let columnPaddingHorizontal: CGFloat = 26
    /// The column is centred, then lifted this far above centre.
    static let columnOffsetAboveCentre: CGFloat = 27.39
    static let logoToTextSpacing: CGFloat = 10
    static let textToChecksSpacing: CGFloat = 32

    // MARK: Logo

    static let logoWrapperSize: CGFloat = 84.43
    static let logoSize: CGFloat = 80
    static let logoCornerRadius: CGFloat = 16
    static let logoShadowColor = Color(red: 7 / 255, green: 119 / 255, blue: 1).opacity(0.35)
    static let logoShadowY: CGFloat = 4
    /// Figma blur 44; SwiftUI's shadow radius is half a CSS/Figma blur.
    static let logoShadowRadius: CGFloat = 22

    // MARK: Title row

    static let titleRowPaddingTop: CGFloat = 16
    static let titleFont = Font.system(size: 21, weight: .bold)
    static let titleLineHeight: CGFloat = 25.62
    static let titleTracking: CGFloat = -0.4
    static let textColor = Color(red: 11 / 255, green: 10 / 255, blue: 13 / 255)
    static let titleToSpinnerSpacing: CGFloat = 10
    static let spinnerSize: CGFloat = 30.78
    /// Measured off the Figma GIF: about 0.13 of the diameter.
    static let spinnerLineWidth: CGFloat = 4
    /// Measured: the arc covers about 80% of the circle.
    static let spinnerArcFraction: CGFloat = 0.8
    static let spinnerArcColor = Color(red: 2 / 255, green: 175 / 255, blue: 239 / 255)
    static let spinnerTrackColor = Color(red: 212 / 255, green: 241 / 255, blue: 252 / 255)

    // MARK: Domain line

    static let titleToDomainSpacing: CGFloat = 8
    static let domainFont = Font.system(size: 14.5, weight: .regular)
    static let domainLineHeight: CGFloat = 19.14

    // MARK: Check rows

    static let checkRowSpacing: CGFloat = 8
    static let checkRowHeight: CGFloat = 26
    static let checkIconBox: CGFloat = 20
    /// The filled circle inside the 20pt icon box (r 8.125).
    static let checkCircleDiameter: CGFloat = 16.25
    static let checkIconColor = Color(red: 53 / 255, green: 53 / 255, blue: 53 / 255)
    static let checkIconToTextSpacing: CGFloat = 10
    static let checkFont = Font.system(size: 16, weight: .bold)
    static let checkTracking: CGFloat = -0.4

    // MARK: Claiming-phase escape (not drawn in Figma)

    static let escapeSize: CGFloat = 36
    static let escapeFill = Color.black.opacity(0.06)
    static let escapeGlyphColor = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255)
    static let escapeGlyphSize: CGFloat = 14
    static let escapeInset: CGFloat = 16

    // MARK: In-app browser chrome (frame 3, not specified yet)

    static let chromeHeight: CGFloat = 44
    static let chromeBackground = Color(UIColor.systemBackground)
    static let chromeDividerColor = Color(UIColor.separator)
    static let closeGlyphSize: CGFloat = 17
    static let closeHitSize: CGFloat = 44
    static let closeColor = Color(UIColor.label)
    static let lockGlyphSize: CGFloat = 11
    static let browserDomainFont = Font.system(size: 15, weight: .semibold)
    static let browserDomainColor = Color(UIColor.label)
    static let lockToDomainSpacing: CGFloat = 4
}
