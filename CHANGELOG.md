# Changelog

## 0.1.0 — unreleased

First release of the NanoFlags SDK for Apple platforms (iOS 14+, macOS 12+, tvOS 14+, watchOS 7+; core on Linux).

- Evaluation engine ported from `@nanoflags/engine` (engine version 1): all 21,998 shared parity cases, the murmur3 /
  bucket / `supportsEngine` / browser-view vectors, and the Go port's extra cases with V8's error messages.
- `NanoFlags.start(key:options:)`, typed variations (`bool`, `string`, `number`, `int`, `json`), `variationDetail`,
  `allFlags`, `identify(context:)`; client (`nf_pub_`) keys only.
- Ed25519 bundle verification by key id (CryptoKit / swift-crypto), embedded production keys, `/v1/keys` refresh on an
  unknown kid (at most once a minute), unsigned and tampered bundles refused by default; bundles for a newer engine refused.
- Live updates over `URLSessionWebSocketTask` (`/v1/live`), SSE and ETag polling fallbacks, jittered backoff, close
  code 4004, socket rotation, safety poll.
- Offline-first persistence (Application Support / UserDefaults / custom), re-verified at launch; `bootstrap`.
- Background pause / foreground catch-up, Low Data Mode handling.
- Telemetry: service report + sampled evaluations with attribute names and types only; opt-out.
- `onChange` closures and AsyncSequences (`changes`, `values(key:default:)`), status and error listeners.
- SwiftUI: `@FeatureFlag`, `NanoFlagsObservable`, `NanoFlagsModel` (Observation), `.onFlagChange`.
- OpenFeature provider package `NanoFlagsOpenFeature` (OpenFeature Swift SDK 0.7, iOS 15+).
