# NanoFlags for iOS, macOS, tvOS and watchOS

Feature flags for Swift apps, evaluated **on the device**: every flag read is local and synchronous, works offline,
and never blocks on the network. The configuration arrives signed (Ed25519) and is verified before it is used; new
revisions are pushed over a live WebSocket in well under a second.

- iOS 14+, macOS 12+, tvOS 14+, watchOS 7+ (the core also builds and is tested on Linux)
- Swift 5.9+ (Xcode 15+); `async`/`await`, `Sendable` types, AsyncSequence and closure listeners
- SwiftUI: `@FeatureFlag` property wrapper, `ObservableObject` and `@Observable` models
- OpenFeature provider (separate package, iOS 15+)
- Version 0.1.0 · Apache-2.0

## Install

Swift Package Manager (Xcode: *File → Add Package Dependencies…*):

```swift
.package(url: "https://github.com/motazalmaroai/nanoflags-swift.git", from: "0.1.0")
// target dependency:
.product(name: "NanoFlags", package: "nanoflags-swift")
```

Releases are tagged with bare semver (`0.1.0`); see the [releases](https://github.com/motazalmaroai/nanoflags-swift/releases).

## Quickstart

Use the environment's **browser/mobile key** (`nf_pub_…`). A mobile app ships its key to every device, so the SDK
only accepts client keys: they receive the client view (client-exposed flags and only the segments those flags use).
Server keys (`nf_srv_…`) are refused without a single request.

```swift
import NanoFlags

let flags = NanoFlags.start(key: "nf_pub_…", options: .init(
    context: NanoFlagsContext(key: NanoFlags.anonymousKey, attributes: ["plan": "free", "appVersion": "2.4.0"])
))

// Synchronous, local, never throws: your default until a configuration is loaded.
if flags.boolVariation(key: "new-checkout", default: false) { showNewCheckout() }
let accent = flags.stringVariation(key: "accent", default: "blue")
let limit = flags.numberVariation(key: "upload-limit", default: 10)
let theme = flags.jsonVariation(key: "theme", default: ["dark": false])

// Why? (matched rule, rollout bucket, revision, a step-by-step trace)
let detail = flags.variationDetail(key: "new-checkout", default: false)
print(detail.reason, detail.ruleId ?? "-", detail.revision)

// Signed in: change the context. Local and synchronous — no network round trip.
flags.identify(context: ["key": "user-42", "plan": "pro"])

// Optional: wait for the first configuration (offline starts use the persisted one).
await flags.ready(timeout: 3)
```

### Listening for changes

```swift
// Closures (keep the subscription to cancel it later).
let sub = flags.onChange { change in print(change.revision ?? 0, change.changedFlags, change.transport) }
flags.onChange(key: "new-checkout", default: false) { on in print("new-checkout is now", on) }

// AsyncSequence.
for await change in flags.changes { print(change) }
for await on in flags.values(key: "new-checkout", default: false) { updateUI(on) }

flags.onStatusChange { print($0) }   // .notReady / .ready / .stale
flags.onError { print($0) }          // a rejected key, a bundle that failed verification, the network, …
```

`changedFlags` lists the flags whose value *for the current context* changed. Callbacks run on the SDK's thread
unless you set `options.callbackQueue` (for example `.main`).

### SwiftUI

```swift
struct CheckoutButton: View {
    @FeatureFlag("new-checkout", default: false) var newCheckout   // follows NanoFlags.shared
    var body: some View { Button(newCheckout ? "Pay now" : "Checkout") { … } }
}

// ObservableObject (iOS 14+)
@StateObject var flags = NanoFlagsObservable.shared          // or NanoFlagsObservable(client: client)
Text(flags.string("accent", default: "blue"))
    .onFlagChange("accent", default: "blue") { print("accent →", $0) }

// Observation (iOS 17+)
@State var model = NanoFlagsModel(client: NanoFlags.shared!)
if model.bool("new-checkout", default: false) { NewCheckout() }
```

Views re-render when the configuration, the context (`identify`) or the status changes.

## How it works

| | |
| --- | --- |
| **Evaluation** | A Swift port of `@nanoflags/engine`, the engine the dashboard, the edge and every SDK share. It reproduces JavaScript semantics (number formatting, `String()` coercion, `JSON.stringify` key order, MurmurHash3 over NFC-normalised UTF-8) and passes all 21,998 shared parity cases, so a user gets the same value and rollout bucket on iOS as in the browser, on the server and in CI. |
| **Verification** | Bundles are Ed25519-signed by the publisher. With the default edge the SDK verifies against the embedded production keys (CryptoKit on Apple platforms, swift-crypto elsewhere) and **refuses unsigned or tampered bundles**; a bundle signed with an unknown key id loads `GET /v1/keys` once (at most once a minute). The SDK hashes the exact bytes the edge signed. |
| **Live updates** | `URLSessionWebSocketTask` to `/v1/live` (key in the `Authorization` header, never in the URL): the edge pushes the signed bundle itself. Text ping/pong every ~30 s, the socket is replaced every ~50 min, reconnects use jittered exponential backoff (1 s · 2ⁿ up to 5 min). If no socket can be opened the SDK falls back to Server-Sent Events (`/v1/stream`) and polling with ETags (`/v1/bundle`, 304 when nothing changed). While the socket is healthy polling is only a 5-minute safety net. Close code 4004 (environment deleted) stops reconnecting and keeps the last configuration (status `stale`). |
| **Offline first** | The last verified bundle is stored in Application Support (excluded from backups; `.userDefaults`, a directory or your own `BundleStorage` also work) and loaded — and verified again — at the next launch. `bootstrap:` takes a bundle shipped with the app. |
| **Lifecycle** | In the background the live connection is closed and polling stops (`UIApplication` / `WKExtension` / `NSApplication` notifications); on return to the foreground the SDK reconnects and catches up. `pause()` / `resume()` do the same manually. |
| **Low Data Mode** | When `NWPath.isConstrained`, no socket or stream is kept, telemetry is paused and the configuration is polled every 15 min (`lowDataPollInterval`). |
| **Telemetry** | A service report ("this app runs revision N") every 60 s and 10 % sampled evaluations every 10 s, carrying the **names and JSON types** of the attributes a flag's rules use — never their values. `events: .disabled` turns it off; `redact:` customises it. |

Every request sends `User-Agent: nanoflags-swift/0.1.0 (<OS> <version>)` (the edge refuses default library agents);
`userAgentSuffix` appends your app's.

### Options

```swift
NanoFlagsOptions(
    baseURL: NanoFlags.officialEdgeURL,  // your own edge for self-hosting
    context: .empty,
    service: nil,                        // default: the bundle identifier
    transport: .automatic,               // .serverSentEvents, .polling
    pollInterval: 30, livePollInterval: 300, lowDataPollInterval: 900,
    respectLowDataMode: true, pauseInBackground: true,
    verify: .automatic,                  // .enabled(VerifyOptions(publicKeys:fetchKeys:require:)), .disabled
    storage: .applicationSupport,        // .userDefaults(suiteName:), .directory(url), .custom(...), .none
    bootstrap: nil,                      // bundle JSON shipped with the app
    events: EventsOptions(),             // .disabled
    requestTimeout: 10, callbackQueue: nil, userAgentSuffix: nil)
```

## OpenFeature

The [OpenFeature Swift SDK](https://github.com/open-feature/swift-sdk) (0.7.x) is supported by the
`NanoFlagsOpenFeature` package, published as [motazalmaroai/nanoflags-openfeature-swift](https://github.com/motazalmaroai/nanoflags-openfeature-swift):

```swift
.package(url: "https://github.com/motazalmaroai/nanoflags-openfeature-swift.git", from: "0.1.0")
// target dependency:
.product(name: "NanoFlagsOpenFeature", package: "nanoflags-openfeature-swift")
```

It is a separate package because OpenFeature requires iOS 15 /
tvOS 15 / watchOS 8 and Combine (and Swift 6.1, Xcode 16.3+), while this package supports iOS 14 and Linux.

```swift
import NanoFlagsOpenFeature
import OpenFeature

let provider = NanoFlagsProvider(client: NanoFlags.start(key: "nf_pub_…"))
await OpenFeatureAPI.shared.setProviderAndWait(provider: provider, initialContext: ImmutableContext(targetingKey: "user-42"))
let on = OpenFeatureAPI.shared.getClient().getBooleanValue(key: "new-checkout", defaultValue: false)
```

Mapping (as in the Go, Python and JS providers): targeting key → NanoFlags `key`; off → `DISABLED`, default →
`DEFAULT`, fixed rule → `TARGETING_MATCH`, rollout → `SPLIT`; variant = rule id; metadata `revision`, `ruleIndex`;
errors `PROVIDER_NOT_READY`, `FLAG_NOT_FOUND`, `TYPE_MISMATCH`, `GENERAL`; events READY, STALE, ERROR,
CONFIGURATION_CHANGED (with the changed flags), CONTEXT_CHANGED. The edge also speaks OFREP, so the OpenFeature OFREP
provider works too (remote evaluation instead of local).

## Platform notes

- **Linux**: swift-corelibs-foundation's URLSession uses libcurl, which is usually built without WebSocket support
  ("WebSockets not supported by libcurl"). The SDK detects this once and uses SSE + polling for good. SSE
  notifications arrive within seconds; the fetch that follows can see the edge's previous configuration for up to
  about a minute after a publish (edge caching), so updates on Linux take seconds to a minute instead of
  sub-second. Lifecycle and SwiftUI code compiles to nothing there.
- **Strings**: Swift strings cannot hold lone UTF-16 surrogates; the engine's JSON parser turns them into U+FFFD.
  Real configurations never contain them (all shared parity cases pass); 14 of the Go port's 60 synthetic
  lone-surrogate cases render differently.
- **Numbers** are IEEE-754 doubles, as in JavaScript (`intVariation` accepts whole numbers only).

## Development

```sh
swift build
swift test                                   # parity suite, verification, fake-edge transport tests
NANOFLAGS_PRODUCTION_TESTS=1 NANOFLAGS_SDK_KEY=<public demo key> swift test --filter ProductionTests
swift test --package-path OpenFeature        # Apple platforms only (monorepo layout: the provider next to the core)
```

What runs where:

| | Linux (`swift test`) | macOS (`swift test`) | iOS simulator (`xcodebuild test`) |
| --- | --- | --- | --- |
| Engine parity (21,998 cases + hashing + browser view), Go extra cases | ✓ | ✓ | ✓ |
| Signature verification (production vector, tampering, kid rotation) | ✓ swift-crypto | ✓ CryptoKit | ✓ CryptoKit |
| Transports against a fake signing edge (WebSocket, 4004, SSE fallback, polling/ETag, persistence, pause/resume, Low Data, telemetry, OpenFeature mapping) | ✓ | ✓ | ✓ |
| Observation model | ✓ | ✓ (macOS 14+) | ✓ (iOS 17+) |
| Lifecycle via notifications, SwiftUI helpers | — | ✓ AppKit | ✓ UIKit |
| Production: verified bundle + live update after a demo toggle | ✓ SSE | ✓ WebSocket | ✓ WebSocket |
| OpenFeature provider | — | ✓ | ✓ |

CI: `.github/workflows/mobile-swift.yml` (macOS `swift test`, iOS simulator `xcodebuild test`, tvOS/watchOS builds,
Linux `swift test`). The parity fixtures are vendored into `Tests/Fixtures/` (generated from the TypeScript engine in
the NanoFlags repository; do not edit them by hand).
