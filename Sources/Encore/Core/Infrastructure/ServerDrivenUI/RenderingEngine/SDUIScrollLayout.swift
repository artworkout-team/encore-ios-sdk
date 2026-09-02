//
//  Scroll-alignment geometry for SDUI scroll views, kept out of the renderer
//  so the margin rule is unit-testable without one.
//

import SwiftUI

/// Pure geometry for `SDUIScrollView.scrollAlignment`. No renderer, no state,
/// so every rule here is unit-testable on its own.
enum SDUIScrollLayout {
    static func centeredContentMargin(for config: SDUIScrollView, viewportWidth: CGFloat) -> CGFloat? {
        guard let itemWidth = offerItemWidth(for: config) else { return nil }
        let authoredMargin = config.contentMargins?.edgeInsets.leading ?? 0
        return max(authoredMargin, (viewportWidth - itemWidth) / 2)
    }

    static func offerItemWidth(for config: SDUIScrollView) -> CGFloat? {
        guard case .hStack(let stack) = config.content,
              stack.children.count == 1,
              case .forEach(let loop) = stack.children[0],
              case .offers = loop.dataSource,
              let itemWidth = fixedWidth(of: loop.itemTemplate)
        else { return nil }
        return itemWidth
    }

    /// The horizontal content margin that centers an `itemWidth` card in a
    /// `viewportWidth` viewport, clamped at zero when the card is wider than the
    /// viewport. `fallback` when either width is unknown (`<= 0`).
    ///
    /// Not floored at the authored margin: a key named `center` must center, and
    /// preserving the authored gutter on a narrow screen leaves the card off to
    /// one side.
    nonisolated static func horizontalMargin(
        viewportWidth: CGFloat,
        itemWidth: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard viewportWidth > 0, itemWidth > 0 else { return fallback }
        return max(0, (viewportWidth - itemWidth) / 2)
    }

    private static func fixedWidth(of element: SDUIElement) -> CGFloat? {
        switch element {
        case .button(let config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case .group(let config):
            return config.style?.frame?.width ?? fixedWidth(of: config.content)
        case .vStack(let config), .hStack(let config), .zStack(let config):
            if let width = config.style?.frame?.width {
                return width
            }
            return config.children.lazy.compactMap(fixedWidth(of:)).first
        default:
            return nil
        }
    }
}

/// Kept off the wire enum on purpose. `UnitPoint` is a rendering concern, and
/// putting it on the decoded type is what pulls presentation-only cases into a
/// vocabulary the backend enforces.
extension SDUIScrollAlignment {
    var unitPoint: UnitPoint {
        switch self {
        case .leading: return .leading
        case .center: return .center
        }
    }
}
