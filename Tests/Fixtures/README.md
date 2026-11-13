# Parity fixtures (vendored)

`parity.json` (shared by every NanoFlags SDK port) is generated from the TypeScript engine; `extra.json` holds the
Go port's JavaScript corner cases. Both are copied from the NanoFlags monorepo by `scripts/export-swift-repos.sh`;
do not edit them here. `Tests/NanoFlagsEngineTests/ParityTests.swift` reads them (or `NANOFLAGS_PARITY_JSON` /
`NANOFLAGS_EXTRA_JSON`) and fails if they are missing.
