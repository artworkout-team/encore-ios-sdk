// Public conveniences for the claim reminder, a trigger on the generic host. Both render
// nothing (zero height) unless there is a claim to remind about.

import SwiftUI
import UIKit

/// A banner reminding the user of an offer they claimed but have not finished. Tapping it
/// opens the Encore sheet for `useCase`, which holds that offer. Renders nothing otherwise.
public struct ClaimReminder: View {
    private let placement: String
    private let useCase: UseCase
    private let layout: ClaimReminderLayout?
    private let appearance: AppearanceConfig?
    private let publisherReward: PublisherReward?
    private let icon: TriggerIcon
    private let onResult: ((PresentationResult) -> Void)?
    private let values: [String: String]
    private let alignment: EncoreAlignment
    private var texts: [TriggerTextSlot: String] = [:]

    /// - Parameters:
    ///   - placement: Your label for where the banner sits, e.g. "home".
    ///   - useCase: The sheet it opens and the experiments it joins. Churn renders nothing for now.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize on the sheet it opens, as `placement(_:).publisherReward(_:)`.
    ///   - onResult: Called once per sheet it opens, after it closes, with what `show()` returns.
    ///   - values: Your values for the look to show, e.g. `["minutes": "60"]` for a look that says
    ///     "${values.minutes} min". Each key is lowerCamel; each value 1 to 64 characters of plain text.
    ///     A changed value redraws in place. Values never leave the device.
    ///   - alignment: Where the look sits when the container is wider than the look (an iPad);
    ///     centred by default.
    public init(
        placement: String,
        useCase: UseCase = .rewardUsers,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(placement: placement, useCase: useCase, layout: nil, icon: icon, appearance: appearance, publisherReward: publisherReward, onResult: onResult, values: values, alignment: alignment)
    }

    /// - Parameters:
    ///   - placement: Your label for where the banner sits, e.g. "home".
    ///   - useCase: The sheet it opens and the experiments it joins. Churn renders nothing for now.
    ///   - layout: Pins one look (demos and tests). Apps never pin: Encore picks looks per placement.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize on the sheet it opens, as `placement(_:).publisherReward(_:)`.
    ///   - onResult: Called once per sheet it opens, after it closes, with what `show()` returns.
    ///   - values: Your values for the look to show, e.g. `["minutes": "60"]` for a look that says
    ///     "${values.minutes} min". Each key is lowerCamel; each value 1 to 64 characters of plain text.
    ///     A changed value redraws in place. Values never leave the device.
    ///   - alignment: Where the look sits when the container is wider than the look (an iPad);
    ///     centred by default.
    @_spi(EncoreDemo) public init(
        placement: String,
        useCase: UseCase = .rewardUsers,
        layout: ClaimReminderLayout?,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.placement = placement
        self.useCase = useCase
        self.layout = layout
        self.appearance = appearance
        self.publisherReward = publisherReward
        self.icon = icon
        self.onResult = onResult
        self.values = values
        self.alignment = alignment
    }

    public var body: some View {
        EncoreTrigger(
            ClaimReminderTrigger.id, placement: placement, useCase: useCase, layout: layout?.rawValue,
            icon: icon, appearance: appearance, publisherReward: publisherReward, onResult: onResult, values: values,
            alignment: alignment
        )
        .headline(texts[.headline]).subheadline(texts[.subheadline]).cta(texts[.cta])
    }

    /// Your headline, over the look's own (a blank or nil one keeps the look's). Plain text, at most
    /// 120 UTF-16 units, no line breaks; a look that draws no headline ignores it. A change redraws in
    /// place, with no new request. Text never leaves the device.
    public func headline(_ text: String?) -> Self { withText(text, for: .headline) }

    /// Your subheadline, over the look's own; as ``headline(_:)``.
    public func subheadline(_ text: String?) -> Self { withText(text, for: .subheadline) }

    /// Your button label, over the look's own; as ``headline(_:)``. Only looks that draw a label take it.
    public func cta(_ text: String?) -> Self { withText(text, for: .cta) }

    private func withText(_ text: String?, for slot: TriggerTextSlot) -> Self {
        var copy = self
        copy.texts[slot] = text
        return copy
    }
}

/// UIKit twin of ``ClaimReminder``: an ``EncoreTriggerView`` for the claim reminder.
public final class ClaimReminderView: EncoreTriggerView {
    /// - Parameters:
    ///   - placement: Your label for where the banner sits, e.g. "home".
    ///   - useCase: The sheet it opens and the experiments it joins. Churn renders nothing for now.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize on the sheet it opens; also settable later.
    ///   - onResult: Called once per sheet it opens, after it closes; also settable later.
    ///   - values: Your values for the look to show; also settable later (see ``EncoreTriggerView/values``).
    ///   - alignment: Where the look sits in a wider view; also settable later (see ``EncoreTriggerView/alignment``).
    public convenience init(
        placement: String,
        useCase: UseCase = .rewardUsers,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(placement: placement, useCase: useCase, layout: nil, icon: icon, appearance: appearance, publisherReward: publisherReward, onResult: onResult, values: values, alignment: alignment)
    }

    /// - Parameters:
    ///   - placement: Your label for where the banner sits, e.g. "home".
    ///   - useCase: The sheet it opens and the experiments it joins. Churn renders nothing for now.
    ///   - layout: Pins one look (demos and tests). Apps never pin: Encore picks looks per placement.
    ///   - icon: The icon its look draws: the gift (default), your app's icon, or none.
    ///   - appearance: Brand colours; unset fields use the server's, then Encore's defaults.
    ///   - publisherReward: Your prize on the sheet it opens; also settable later.
    ///   - onResult: Called once per sheet it opens, after it closes; also settable later.
    ///   - values: Your values for the look to show; also settable later (see ``EncoreTriggerView/values``).
    ///   - alignment: Where the look sits in a wider view; also settable later (see ``EncoreTriggerView/alignment``).
    @_spi(EncoreDemo) public convenience init(
        placement: String,
        useCase: UseCase = .rewardUsers,
        layout: ClaimReminderLayout?,
        icon: TriggerIcon = .gift,
        appearance: AppearanceConfig? = nil,
        publisherReward: PublisherReward? = nil,
        onResult: ((PresentationResult) -> Void)? = nil,
        values: [String: String] = [:],
        alignment: EncoreAlignment = .center
    ) {
        self.init(
            id: ClaimReminderTrigger.id, placement: placement, useCase: useCase, layout: layout?.rawValue, icon: icon, appearance: appearance,
            values: values, alignment: alignment
        )
        self.publisherReward = publisherReward
        self.onResult = onResult
    }
}
