# Changelog

## 0.2.0 — 2026-11-21

- A shadow bundle is checked against the environment of the verified live configuration even when it arrives before
  that configuration's first verification finishes (it waits for it, and is skipped if none verifies). Before, a
  shadow bundle fetched in that window was not bound to the environment, so one signed for another environment of
  the same project could be used for shadow counters (Linux showed it reliably). Shadow bundles are never applied as
  configuration, so served values were never affected.
- New condition operators: `semver_eq`, `semver_neq`, `semver_gt`, `semver_gte`, `semver_lt`, `semver_lte` compare
  semantic versions (SemVer 2.0 precedence: `4.10.0` > `4.9.0`, `1.0.0-alpha` < `1.0.0-alpha.1` < `1.0.0-beta` <
  `1.0.0-rc.1` < `1.0.0`, build metadata ignored; leniently, a leading `v` is allowed, missing minor / patch are 0 so
  `4.10` = `4.10.0`, and leading zeros are ignored); `before` / `after` compare points in time (`YYYY-MM-DD` as
  00:00 UTC, RFC 3339 timestamps with `Z` or an offset, or Unix time: seconds below 1e12, milliseconds from 1e12).
  A value that cannot be read on either side makes the condition false; evaluation never throws.
- `gt` / `gte` / `lt` / `lte` are unchanged (numeric), so existing rules evaluate exactly as before.
- Verified against the shared conformance vectors (`packages/engine/fixtures/operators.json`, embedded in
  `parity.json`) that every NanoFlags SDK passes. No bundle-format change (`engine` stays 1).
- Earlier releases evaluate conditions with these operators as not matching (they never fail on them): upgrade before
  publishing rules that use them.
- Shadow evaluation of drafts (same rules and wire format as `@nanoflags/sdk` 0.7.1): while a change waits for
  approval in an environment with shadow evaluation on, the client loads the signed shadow bundle announced by
  `X-NanoFlags-Shadow` (`GET /v1/shadow`, Ed25519 over `nanoflags-shadow-v1`, marker checked), evaluates the draft for
  a sample of the evaluations of the flags it changes (`ShadowOptions.sampleRate`, default 0.1) and reports bounded
  counters only with the events report, at most once a minute (always on `flush()`, `pause()` and `close()`; kept
  while Low Data Mode pauses telemetry). The app always gets the live value; any bundle with a `shadow` member is
  refused as configuration (HTTP, push, storage, bootstrap). New options `shadow` and `serviceVersion` (default: the
  app's `CFBundleShortVersionString`); new error code `.shadow`. Off with `shadow: .disabled` or `events: .disabled`.
- Shadow reports always pass the edge's validation of `POST /v1/events`: flag keys over 63 characters (UTF-16
  code units) are not counted and a flag's counters stop at 10^7 samples until the next report.

## 0.1.0 — 2026-11-14

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
