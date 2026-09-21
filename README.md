# CookieMunch iOS SDK

The native Swift SDK for [Cookie Munch](../../README.md) — a Consent
Management Platform. It gives your iOS/macOS/tvOS/watchOS app the same consent model as
the web embed and the React Native SDK: the four standard categories, an implied default
until the user chooses, offline-safe sync to your CookieMunch API, and a `gate` helper
that is the native equivalent of the web SDK's prior-blocking.

> This SDK was formerly published as **ForgeConsent**. It is now **CookieMunch** (a clean
> 0.x rename): the SwiftPM product/target and the public `CookieMunchConsent` client.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and point at this repo, or add it to your
own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/cookiemunch", from: "0.1.0")
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "CookieMunch", package: "cookiemunch")
    ])
]
```

Then `import CookieMunch`.

## Quick start

```swift
import CookieMunch

// Persist the record in the Keychain (see "Keychain note" below).
let consent = CookieMunchConsent(
    cbid: "your-site-id",
    apiURL: "https://cmp.example.com",
    storage: KeychainConsentStorage(),
    region: "EU"                       // sent as the X-CookieMunch-Region header
)

// Restore any prior decision at launch.
await consent.load()

// Record decisions:
await consent.accept()                                  // grant all
await consent.decline()                                 // deny all non-necessary
await consent.set(statistics: true)                     // merge one category
await consent.submit(Choices(preferences: true,
                             statistics: false,
                             marketing: true))           // fully custom
```

Every decision is persisted locally **first**, then POSTed to `POST /api/v1/consent`. The
network call never throws back into your code — an offline decision is kept and can be
re-synced on next launch. A consent decision is never lost to a bad network.

## SwiftUI banner

```swift
struct RootView: View {
    @StateObject private var consent = CookieMunchConsent(
        cbid: "your-site-id",
        apiURL: "https://cmp.example.com",
        storage: KeychainConsentStorage()
    )

    var body: some View {
        HomeView()
            .overlay(alignment: .bottom) {
                ConsentBannerView(consent: consent)   // shows until the user responds
            }
            .task { await consent.load() }
    }
}
```

`CookieMunchConsent` is an `ObservableObject`; observe `$state` in SwiftUI, or subscribe
imperatively:

```swift
let cancel = consent.onChange { state in
    print("marketing granted:", state.marketing)
}
// later…
cancel()
```

## The `gate` pattern (native prior-blocking)

On the web, Cookie Munch blocks third-party scripts until consent lands. The native
equivalent is `gate(_:_:)`: it runs a closure **exactly once**, the moment a category is
(or already is) granted. Use it to defer initializing any SDK that must not run before
consent — analytics, ad SDKs, crash reporters with PII, etc.

```swift
// Runs now if statistics is already granted, otherwise the instant it is.
consent.gate(.statistics) {
    Analytics.start()
}

consent.gate(.marketing) {
    AdSDK.initialize()
}
```

Each gated closure fires at most once. `.necessary` is always granted, so a
`gate(.necessary)` closure runs immediately.

### App Tracking Transparency

When the marketing category is granted, the client automatically calls
`ATTrackingManager.requestTrackingAuthorization` (on platforms where it exists) so the OS
prompt stays consistent with the consent banner. Add an `NSUserTrackingUsageDescription`
to your `Info.plist`.

## Storage backends

`ConsentStorage` is a pluggable async protocol (the equivalent of RN's `MobileStorage`):

| Backend | Use |
|---|---|
| `InMemoryConsentStorage()` | default; volatile — tests and previews |
| `UserDefaultsConsentStorage(suiteName:)` | conventional non-sensitive persistence |
| `KeychainConsentStorage(service:accessGroup:)` | secure, Keychain-backed |

Implement the protocol yourself to back onto anything else.

### Keychain note

`KeychainConsentStorage` (Security framework) stores the consent record as a
generic-password item with `kSecAttrAccessibleAfterFirstUnlock` — readable after the
first device unlock, and **not** synced to iCloud Keychain. Pass an `accessGroup` to
share the record across an app group / extensions. Because it is Keychain-backed, the
record survives app reinstalls on the same device; call `removeItem` (or reset your
storage) if you need a hard clear.

## Testing

The network is injectable via the `ConsentTransport` protocol, so the core client is fully
unit-testable with no real API:

```swift
let consent = CookieMunchConsent(
    cbid: "t", apiURL: "https://x", transport: MyMockTransport()
)
```

## Building & testing this package

```bash
cd native/ios
swift build     # compiles the library (core client builds on macOS; UI is guarded)
swift test      # runs the core-client test suite
```

The core `CookieMunchConsent` client compiles on macOS; the SwiftUI `ConsentBannerView`
is guarded behind `#if canImport(SwiftUI)` (and picks a platform-appropriate background)
so the library builds everywhere.
