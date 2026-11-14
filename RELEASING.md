# Releasing nanoflags-swift

The source of truth is the NanoFlags monorepo (`packages/sdk-swift`); this repository is synced from it with
`scripts/export-swift-repos.sh` (which also vendors the parity fixtures into `Tests/Fixtures/`). Fix code there, export,
then release here.

Tags are **bare semver** — `0.1.0`, `0.2.0`, `1.0.0-rc.1` — with no `v` prefix: Swift Package Manager resolves
`from: "0.1.0"` against tags of exactly that form.

Releases are automated by `.github/workflows/release.yml`:

1. Bump `nanoFlagsSDKVersion` in `Sources/NanoFlags/Version.swift` (the User-Agent and the telemetry label use it) and
   add a dated `CHANGELOG.md` entry (`## 0.2.0 — 2026-12-01`; while it says `unreleased`, nothing is released), in the
   monorepo; export, commit, push `main`.
2. The release workflow sees the new dated version without a tag, runs the full test workflow (Linux, macOS, iOS
   simulator) on that commit and, only if it passes, creates the tag `0.2.0` and a GitHub release with the CHANGELOG
   section as notes. It refuses to run if `Version.swift` and the CHANGELOG disagree.
3. Release the OpenFeature provider (`motazalmaroai/nanoflags-openfeature-swift`) afterwards: it depends on this
   package `from: "0.1.0"`, and its release workflow waits for that core tag to exist.

Tags are immutable for SwiftPM users (resolved versions are cached and pinned in `Package.resolved`): never move or
delete a published tag; release a new patch version instead.
