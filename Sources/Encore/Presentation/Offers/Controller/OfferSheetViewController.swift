import SwiftUI
import UIKit

@MainActor
@available(iOS 16.0, *)
final class OfferSheetViewController: UIHostingController<OfferSheetContainer> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
    }

    func requestDismissal() {
        if let navigationController, navigationController.topViewController === self {
            if navigationController.viewControllers.count > 1 {
                navigationController.popViewController(animated: true)
            } else if navigationController.presentingViewController != nil {
                navigationController.dismiss(animated: true)
            } else {
                Logger.warn(.presentation, "Host-owned offer controller is the navigation root and cannot dismiss itself")
            }
            return
        }

        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            Logger.warn(.presentation, "Host-owned offer controller is not currently pushed or presented")
        }
    }
}

@MainActor
@available(iOS 16.0, *)
final class OfferSheetViewControllerDismissalRelay {
    weak var viewController: OfferSheetViewController?

    func requestDismissal() {
        viewController?.requestDismissal()
    }
}
