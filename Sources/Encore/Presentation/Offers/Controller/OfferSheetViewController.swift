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
        if let navigationController {
            guard navigationController.topViewController === self else { return }
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
        }
    }

    #if DEBUG
    func warnIfRetainedWithoutPresentation() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self,
                  viewIfLoaded?.window == nil,
                  navigationController == nil,
                  presentingViewController == nil else { return }
            Logger.warn(
                .presentation,
                "Host-owned offer controller was retained without being pushed or presented. "
                    + "Present it immediately after makeViewController() returns, or release it to avoid blocking future placements."
            )
        }
    }
    #endif
}

@MainActor
@available(iOS 16.0, *)
final class OfferSheetViewControllerDismissalRelay {
    weak var viewController: OfferSheetViewController?

    func requestDismissal() {
        viewController?.requestDismissal()
    }
}
