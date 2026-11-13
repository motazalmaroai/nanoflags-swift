# Releasing nanoflags-swift

The source of truth is the NanoFlags monorepo (`packages/sdk-swift`); this repository is synced from it with
`scripts/export-swift-repos.sh` (which also vendors the parity fixtures into `Tests/Fixtures/`). Fix code there, export,
then release here.

Tags are **bare semver** — `0.1.0`, `0.2.0`, `1.0.0-rc.1` — with no `v` prefix: Swift Package Manager resolves
`from: "0.1.0"` against tags of exactly that form.

1. Bump `nanoFlagsSDKVersion` in `Sources/NanoFlags/Version.swift` (the User-Agent and the telemetry label use it) and
   add a `CHANGELOG.md` entry (in the monorepo), export, commit, push `main`.
2. Wait for `mobile-swift.yml` to pass on that commit (Linux, macOS, iOS simulator).
3. Tag the tested commit and push the tag:

   ```sh
   git tag -a 0.1.0 -m "NanoFlags Swift 0.1.0"
   git push origin 0.1.0
   ```

4. Release the OpenFeature provider (`motazalmaroai/nanoflags-openfeature-swift`) afterwards: it depends on this
   package `from: "0.1.0"`, so the core tag must exist first.

Tags are immutable for SwiftPM users (resolved versions are cached and pinned in `Package.resolved`): never move or
delete a published tag; release a new patch version instead.
