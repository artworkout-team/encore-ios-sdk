//
//  Host-owned offer controller. The publisher places it in its own navigation
//  stack, so the SDK asks for dismissal rather than owning a window.
//

import SwiftUI
import UIKit

@MainActor
@available(iOS 17.0, *)
internal final class OfferSheetViewController: UIHostingController<OfferSheetContainer> {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
    }

    /// Removes the controller the way it was added, and does nothing when the
    /// host owns the only way out. Popping a controller that is not on top, or
    /// dismissing a navigation root, would take the host's own screens with it.
    func requestDismissal() {
        // Pushed means the parent is the stack itself. A controller merely
        // embedded inside a stacked screen also reports a navigationController,
        // and popping that stack would take the host's screen with it.
        if let nav = navigationController, parent === nav {
            guard nav.topViewController === self else { return }
            if nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
            } else if nav.presentingViewController != nil {
                nav.dismiss(animated: true)
            } else {
                Logger.warn(.presentation, "Host-owned offer controller is the navigation root and cannot dismiss itself")
            }
            return
        }
        if presentingViewController != nil {
            dismiss(animated: true)
            return
        }
        // An `addChild` embed. `isHeldByHost` counts one as placed, so leaving
        // it here would let the two disagree about whether the flow is placed.
        if parent != nil {
            willMove(toParent: nil)
            view.removeFromSuperview()
            removeFromParent()
        }
    }
}
