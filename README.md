# AppSynk iOS SDK

Lightweight Swift SDK for iOS install attribution, event measurement, revenue & SKAdNetwork — no
external dependencies.

- **Deterministic + privacy-safe attribution**: ATT-gated install (IDFA when granted), Apple Search
  Ads (AdServices) token, SKAdNetwork, and probabilistic fallback.
- **Never loses an event**: on-disk queue survives app kills; exponential retry; idempotent dedup.
- **Server-piloted SKAdNetwork**: you only ever toggle `disableSKAdNetwork` — the backend decides
  conversion values.
- **Automatic lifecycle events**: install / reinstall / session / app_open / app_update.
- **GDPR-ready**: consent + anonymization + privacy toggles.

## Requirements

- iOS 14+
- Swift 5.9+ / Xcode 15+

## Installation

### Swift Package Manager

Xcode: **File → Add Package Dependencies…** and paste the repo URL, or add to `Package.swift`:

```swift
.package(url: "https://github.com/appsynk/appsynk-ios-sdk", from: "1.0.0")
```

Then add `AppSynk` to your target's dependencies.

### CocoaPods

Add to your `Podfile`, then run `pod install`:

```ruby
pod 'AppSynk', '~> 1.0.0'
```

### Info.plist

```xml
<!-- Required to show the ATT prompt -->
<key>NSUserTrackingUsageDescription</key>
<string>We use your data to measure ad performance.</string>
```

For deep links add an **Associated Domain** (`applinks:go.appsynk.io`) and/or a custom URL scheme
(`appsynk`). For SKAdNetwork, add your ad networks' IDs under `SKAdNetworkItems`.

## Quick Start (≈ 5 minutes)

```swift
import AppSynk

// 1. Configure once, on the main thread (AppDelegate didFinishLaunching or App.init).
AppSynkSDK.configure(apiKey: "ak_live_xxx")   // or ak_sandbox_xxx

// 2. Track custom events
AppSynkSDK.trackEvent("level_complete", properties: ["level": 5, "score": 1200])

// 3. Track revenue (orderId is REQUIRED — it dedups purchases for 24h)
AppSynkSDK.trackRevenue(
    amount: 4.99, currency: "USD",
    productId: "premium_monthly", orderId: "txn_12345"
)

// 4. Identify the user (optional)
AppSynkSDK.setUserId("user-42")
AppSynkSDK.setUserProperties(["plan": "pro"])
```

That's it — install, sessions and SKAdNetwork are handled automatically.

## The ATT flow (recommended)

For the strongest attribution, **let the SDK gate the install on the ATT decision**. The SDK never
shows the prompt itself — you do, at the right moment:

```
configure()  →  app presents its UI / onboarding  →  requestTrackingAuthorization()
                                                              │
                                  the install fires once ATT resolves (or after a timeout),
                                  enriched with the IDFA when the user grants it.
```

```swift
// After onboarding, when it makes sense to ask:
AppSynkSDK.requestTrackingAuthorization { status in
    // The install was waiting for this; it now includes the IDFA if `.authorized`.
}
```

The wait is bounded by `options.attWaitTimeout` (default 60s): if the user never answers, the
install is sent anyway (without the IDFA). Other events flow normally during the wait.

## Automatic events

| Event | When | Key properties |
|---|---|---|
| `install` | First launch (ATT-gated) | `referrer`, `version`, `att_status` |
| `reinstall` | First launch after a prior install (Keychain) | `referrer`, `version` |
| `session_start` | Cold launch / foreground after `sessionTimeout` | `session_id`, `time_since_install`, `day_since_install` |
| `session_end` | App backgrounded | `session_duration_seconds` |
| `app_open` | Each foreground | `source`, `session_number` |
| `app_update` | App version changed | `previous_version`, `new_version` |

Automatic and revenue events never count against your custom-event quota.

## Revenue & SKAdNetwork

`trackRevenue` records the purchase **and** drives SKAdNetwork automatically — the backend computes
the conversion value and the SDK applies it (monotonic guard, version gating). You never set
conversion values yourself; your only lever is `disableSKAdNetwork`.

```swift
AppSynkSDK.trackRevenue(amount: 9.99, currency: "EUR",
                        productId: "coins_500", orderId: "txn_67890")

// Ad revenue (mediation)
AppSynkSDK.trackAdRevenue(network: "applovin", amount: 0.0021, currency: "USD",
                          adUnit: "rewarded_main", adType: "rewarded")
```

## Deep linking & attribution

```swift
// AppDelegate
func application(_ app: UIApplication, open url: URL, options: ...) -> Bool {
    AppSynkSDK.handleOpenURL(url); return true
}
func application(_ app: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: ...) -> Bool {
    AppSynkSDK.handleUniversalLink(userActivity); return true
}

// Get the deep-link / attribution data. Buffered + replayed: if the link resolves before you
// register the callback (cold start), it fires the moment you do. Always on the main thread.
AppSynkSDK.getDeepLinkData { attribution in
    if let path = attribution?.deepLink { /* route the user */ }
}

// Best-known attribution (deep link if any, else organic).
AppSynkSDK.getAttributionData { attribution in
    print(attribution?.channel ?? "organic")
}
```

## Privacy & GDPR

```swift
// Declare consent — attached to every subsequent event.
AppSynkSDK.setConsent(
    isUserSubjectToGDPR: true,
    hasConsentForDataUsage: true,
    hasConsentForAdsPersonalization: false
)

// Anonymize: strips IDFA/IDFV and flags events as anonymized (persists across launches).
AppSynkSDK.anonymizeUser(true)

// Reset identity (e.g. on logout). The stable device id is preserved.
AppSynkSDK.reset()
```

Fine-grained opt-outs live in `AppSynkOptions` (see below).

## Configuration (`AppSynkOptions`)

```swift
var options = AppSynkOptions()
options.environment = .sandbox        // .production (default) | .sandbox
options.logLevel = .debug             // .none (default) | .error | .debug
options.attWaitTimeout = 60           // seconds to wait for ATT before sending install
options.batchSize = 10                // events per flush
options.flushInterval = 30            // seconds between flushes
options.disableSKAdNetwork = false    // your only SKAN lever
options.disableIdfa = false
options.disableIdfv = false
options.disableAdServices = false
options.anonymizeUserByDefault = false
options.hmacSecretKey = nil           // optional HMAC-SHA256 request signing
options.hmacKeyId = nil
options.customApiUrl = nil            // override host (data residency)

AppSynkSDK.configure(apiKey: "ak_live_xxx", options: options)
```

The backend detects sandbox vs live from the **API key prefix** (`ak_sandbox_` / `ak_live_`).

## Public API

`configure(apiKey:options:)` · `trackEvent(_:properties:)` ·
`trackRevenue(amount:currency:productId:orderId:receipt:)` ·
`trackAdRevenue(network:amount:currency:adUnit:adType:)` · `setUserId(_:)` ·
`setUserProperties(_:)` · `reset()` ·
`setConsent(isUserSubjectToGDPR:hasConsentForDataUsage:hasConsentForAdsPersonalization:)` ·
`anonymizeUser(_:)` · `requestTrackingAuthorization(completion:)` · `handleOpenURL(_:)` ·
`handleUniversalLink(_:)` · `getDeepLinkData(callback:)` · `getAttributionData(callback:)`

## Debugging

```swift
AppSynkSDK.debug.testConnection { result in print(result) }  // pings the API + checks the key
AppSynkSDK.debug.dumpDeviceData()                            // prints the device/attribution JSON
AppSynkSDK.debug.dumpQueue()                                 // prints the pending event queue
AppSynkSDK.debug.simulateInstall(source: "test", campaign: "qa")
AppSynkSDK.debug.simulateRevenue(amount: 0.99, currency: "USD")
```

On startup the SDK calls `GET /v1/sdk/init` to validate your key + bundleId and (with
`logLevel = .debug`) logs the resolved plan and environment. A bad key (401) or mismatched bundleId
(404) is logged as a clear warning — it never crashes your app.

## Versioning

The SDK version is a single source of truth: `AppSynkConstants.sdkVersion` (in
`Sources/AppSynk/Core/Constants.swift`). It's sent on every request as `X-SDK-Version`. Keep it in
sync with your published SPM tag.

## License

MIT
