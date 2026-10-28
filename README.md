# Encore SDK for iOS

[![Swift Version](https://img.shields.io/badge/Swift-5.5+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2013.0+-lightgrey.svg)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A lightweight, non-invasive SDK for presenting targeted retention offers and managing promotional entitlements in iOS apps.

---

## Overview

Encore helps you reduce churn by presenting personalized retention offers (free trials, discounts, credits) at critical moments like cancellation flows or feature paywalls. The SDK provides:

- ✅ **SwiftUI-native** presentation methods
- ✅ **Automatic user ID generation** - zero boilerplate
- ✅ **Real-time entitlement tracking** with Combine publishers
- ✅ **Type-safe attributes** for personalized targeting
- ✅ **Crash-safe design** - SDK errors never crash your app
- ✅ **Robust error handling** with comprehensive error types

---

## Components

Tell Encore where a gift button and a claim reminder sit; Encore decides the look, what happens
after a claim, and counts views and taps.

```swift
import Encore

Encore.shared.identify(userId: user.uid)

GiftsButton(placement: "talk_milestone")

ClaimReminder(placement: "discover_reminder")
    .headline("60 min talking today!")
```

- **Text:** `.headline(_:)`, `.subheadline(_:)` and `.cta(_:)` set your own copy over the look's
  (UIKit: the `headline`, `subheadline` and `cta` properties). A blank value keeps the look's text.
- **Colours:** pass `appearance:` to style the component only; the sheet it opens keeps its own.
- **Width:** a look keeps its design width on wide screens, centred; `alignment:` moves it to the
  leading or trailing edge, in your app's layout direction.
- **Opening by itself:** Encore may test a look that opens the sheet once by itself. Pass
  `autoOpen: .off` to forbid it.

### Your own view

When the components don't fit your design, draw your own and let Encore drive it:

```swift
@StateObject private var claim = Encore.claim(placement: "streak")

var body: some View {
    switch claim.state {
    case .gifts(let gifts), .thanks(let gifts): MyGiftButton(count: gifts.offerCount).encoreClaim(claim)
    case .reminder(let reminder): MyReminder(reminder).encoreClaim(claim)
    case .hidden: EmptyView()
    }
}
```

What it shows after a claim or a completion is set by Encore per placement, like a look. UIKit
views attach with `let unbind = claim.bind(view)` (call `unbind()` when the view goes).

---

## Privacy

The SDK ships `PrivacyInfo.xcprivacy` in every distribution (SwiftPM, XCFramework, CocoaPods).
Xcode folds it into your app's privacy report when you archive.

**The manifest lists what the SDK *can* collect. Your App Store label only needs what your
integration actually sends.** Out of the box that is a random per-install identifier, offer and
app-lifecycle events, and purchase links. Everything else arrives only when you pass it.

| If your integration | Declare |
|:--|:--|
| Any use of the SDK | Identifiers > Device ID; Usage Data > Product Interaction; Usage Data > Advertising Data |
| Leaves `transactionLinking` on (default) | Purchases > Purchase History |
| Calls `identify()` / `setUserAttributes()` | Identifiers > User ID, plus the attribute types you pass (email, name, phone, address, location, age) |

Data the SDK collects on its own is declared **not linked to the user**: it carries a random
per-install identifier and Apple's app-account identifier, neither of which tells us anything
about the person. Data you pass through `identify()` is declared linked, because you supplied
the identity. Offer surfaces and the attributes used to pick offers also carry Apple's
**Third-Party Advertising** purpose, since the offers come from third-party brands. That purpose
is not tracking: see below.

Four things worth knowing before you fill the label in:

- **`transactionLinking: false`** stops the StoreKit history scan and the transaction-chain
  uploads. While it is on, the linked purchases include purchases made outside Encore
  (organic, renewals, restores), because lift measurement needs the control group.
  Apple's `app_account_id` still accompanies analytics events either way.
- **`reset()`** clears the user id, attributes and cached entitlements on device. It does not
  clear Apple's app transaction identifier, which is Apple-Account-scoped and survives reinstall
  by design.
- **`UserAttributes.age`** is whole years, 0 to 120; any other value is dropped with a warning.
  If you hold only a range, pass its lowest end (`13-17` is 13). **`dateOfBirth`** is kept on
  the device and sent only as the whole-year age it gives that day, the lower one if `age` is set too.
- **`UserAttributes.custom`** is free-form, so the SDK cannot classify it. Whatever you put
  there, declare under the matching Apple data type.
- **Nothing is used for tracking.** `NSPrivacyTracking` is `false`, there are no tracking
  domains, and the SDK never reads the advertising identifier, so no ATT prompt is required.

The SDK's only required-reason API is `UserDefaults` (reason `CA92.1`, its own container).

---

## Support

- **Documentation**: [docs.encore.com/ios](https://docs.encorekit.com)
- **Email**: sdk-bot@encorekit.com


