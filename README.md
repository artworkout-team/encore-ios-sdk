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
| Calls `identify()` / `setUserAttributes()` | Identifiers > User ID, plus the attribute types you pass (email, name, phone, address, location) |

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
- **`UserAttributes.custom`** is free-form, so the SDK cannot classify it. Whatever you put
  there, declare under the matching Apple data type.
- **Nothing is used for tracking.** `NSPrivacyTracking` is `false`, there are no tracking
  domains, and the SDK never reads the advertising identifier, so no ATT prompt is required.

The SDK's only required-reason API is `UserDefaults` (reason `CA92.1`, its own container).

---

## Support

- **Documentation**: [docs.encore.com/ios](https://docs.encorekit.com)
- **Email**: sdk-bot@encorekit.com


