#if canImport(NanoFlagsEngine)
// SwiftPM: the engine is its own module, re-exported. (CocoaPods compiles both directories into one module.)
@_exported import NanoFlagsEngine
#endif

/// The SDK version, sent as `sdk: "swift/<version>"` with telemetry and in the User-Agent.
public let nanoFlagsSDKVersion = "0.1.0"
