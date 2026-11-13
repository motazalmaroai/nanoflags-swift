import Foundation

/// The entry point: `NanoFlags.start(key:options:)`.
public enum NanoFlags {
    public typealias Options = NanoFlagsOptions
    public typealias Context = NanoFlagsContext

    /// The SDK version (sent as `sdk: "swift/<version>"` with telemetry and in the User-Agent).
    public static let sdkVersion = nanoFlagsSDKVersion

    /// Newest bundle format (`bundle.engine`) this SDK can evaluate. Newer bundles are refused; the
    /// configuration in use stays.
    public static let supportedEngineVersion = Engine.version

    /// WebSocket close code of the edge for an environment that was deleted: the client stops reconnecting.
    public static let closeEnvironmentDeleted = 4004

    private final class SharedState: @unchecked Sendable {
        var client: NanoFlagsClient?
        var observers: [(NanoFlagsClient) -> Void] = []
    }
    private static let sharedLock = NSLock()
    private static let sharedState = SharedState()

    /// Starts a client for a browser/mobile SDK key (`nf_pub_…`) and returns immediately. Flags evaluate
    /// at once — against the persisted configuration of the last launch, the `bootstrap` bundle, or your
    /// defaults — while the client loads the current configuration and keeps it live in the background.
    ///
    /// The returned client also becomes `NanoFlags.shared` (used by the SwiftUI helpers).
    @discardableResult
    public static func start(key: String, options: Options = Options()) -> NanoFlagsClient {
        let client = NanoFlagsClient(key: key, options: options)
        sharedLock.lock()
        let previous = sharedState.client
        sharedState.client = client
        let observers = sharedState.observers
        sharedLock.unlock()
        if previous !== client { previous?.close() }
        for o in observers { o(client) }
        return client
    }

    /// The client of the last `start(key:options:)` call, if any.
    public static var shared: NanoFlagsClient? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedState.client
    }

    /// Calls `body` with the shared client now (if there is one) and whenever `start` replaces it.
    static func observeShared(_ body: @escaping (NanoFlagsClient) -> Void) {
        sharedLock.lock()
        sharedState.observers.append(body)
        let current = sharedState.client
        sharedLock.unlock()
        if let current { body(current) }
    }

    /// A random identifier created on first use and kept in `UserDefaults`: a stable bucketing key for users
    /// who are not signed in (`NanoFlagsContext(key: NanoFlags.anonymousKey)`). It survives app updates, not
    /// reinstalls. It never leaves the device.
    public static var anonymousKey: String {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        let defaults = UserDefaults.standard
        if let k = defaults.string(forKey: "nanoflags.anonymousKey"), !k.isEmpty { return k }
        let k = "anon-" + UUID().uuidString.lowercased()
        defaults.set(k, forKey: "nanoflags.anonymousKey")
        return k
    }
}

/// How new configurations reach the app.
public enum TransportPreference: Sendable {
    /// The live WebSocket (`/v1/live`: the edge pushes the signed bundle itself), falling back to
    /// Server-Sent Events (`/v1/stream`) and polling with ETags (`/v1/bundle`) when a socket cannot be
    /// opened. The default. On Linux, where URLSession has no WebSocket support, SSE + polling.
    case automatic
    /// SSE notifications + conditional polling; no WebSocket.
    case serverSentEvents
    /// Polling with ETags only.
    case polling
}

/// Sampled evaluation telemetry and the periodic service report ("this app runs revision N").
public struct EventsOptions: Sendable {
    /// Default true. `false` sends nothing at all (no events, no service report).
    public var enabled: Bool
    /// Fraction of evaluations reported, 0–1. Default 0.1.
    public var sampleRate: Double
    /// How often queued events are sent. Default 10 s.
    public var flushInterval: TimeInterval
    /// While nothing is queued, the service report goes out at this interval. Default 60 s.
    public var reportInterval: TimeInterval
    /// What part of the context leaves the device with a sampled event. Default (nil): no attribute values
    /// — only the names of the attributes the flag's rules use that were present, mapped to the value's
    /// JSON type (`["plan": "string"]`).
    public var redact: (@Sendable (NanoFlagsContext) -> [String: JSONValue])?
    /// Random source for sampling (tests).
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

    public init(enabled: Bool = true, sampleRate: Double = 0.1, flushInterval: TimeInterval = 10, reportInterval: TimeInterval = 60,
                redact: (@Sendable (NanoFlagsContext) -> [String: JSONValue])? = nil) {
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.flushInterval = flushInterval
        self.reportInterval = reportInterval
        self.redact = redact
    }

    /// No telemetry.
    public static let disabled = EventsOptions(enabled: false)
}

public struct NanoFlagsOptions: Sendable {
    /// The edge. Default: the hosted edge `https://edge.nanoflags.io`.
    public var baseURL: URL
    /// The context flags are evaluated for until `identify(context:)` changes it.
    public var context: NanoFlagsContext
    /// Name shown in "which revision is this app running". Default: the bundle identifier.
    public var service: String?
    public var transport: TransportPreference
    /// Poll interval while no live socket is open. Default 30 s; 0 disables polling.
    public var pollInterval: TimeInterval
    /// Safety-poll interval while the live socket is healthy. Default 300 s.
    public var livePollInterval: TimeInterval
    /// In Low Data Mode (`NWPath.isConstrained`): no socket or stream, telemetry paused, and the configuration
    /// is polled at this interval. Default 900 s. Set `respectLowDataMode` to false to ignore Low Data Mode.
    public var lowDataPollInterval: TimeInterval
    public var respectLowDataMode: Bool
    /// Close the live connection when the app goes to the background and reconnect (and catch up) when it
    /// returns. Default true.
    public var pauseInBackground: Bool
    public var verify: VerifyMode
    /// Where the last verified bundle is kept. Default: Application Support.
    public var storage: StorageOption
    /// A bundle document (JSON) shipped with the app, used until something newer is loaded. It is not
    /// signature-checked: it comes from your build.
    public var bootstrap: Data?
    public var events: EventsOptions
    /// Timeout of each HTTP request. Default 10 s.
    public var requestTimeout: TimeInterval
    /// Queue for `onChange` / `onStatusChange` / `onError` callbacks. Default nil: called on the SDK's own
    /// thread, right after the change. The SwiftUI helpers deliver on the main actor themselves.
    public var callbackQueue: DispatchQueue?
    /// Appended to the SDK's User-Agent (`nanoflags-swift/<version> (<os> <version>)`), e.g. "MyApp/2.1".
    public var userAgentSuffix: String?

    public init(
        baseURL: URL = NanoFlags.officialEdgeURL,
        context: NanoFlagsContext = .empty,
        service: String? = nil,
        transport: TransportPreference = .automatic,
        pollInterval: TimeInterval = 30,
        livePollInterval: TimeInterval = 300,
        lowDataPollInterval: TimeInterval = 900,
        respectLowDataMode: Bool = true,
        pauseInBackground: Bool = true,
        verify: VerifyMode = .automatic,
        storage: StorageOption = .applicationSupport,
        bootstrap: Data? = nil,
        events: EventsOptions = EventsOptions(),
        requestTimeout: TimeInterval = 10,
        callbackQueue: DispatchQueue? = nil,
        userAgentSuffix: String? = nil
    ) {
        self.baseURL = baseURL
        self.context = context
        self.service = service
        self.transport = transport
        self.pollInterval = pollInterval
        self.livePollInterval = livePollInterval
        self.lowDataPollInterval = lowDataPollInterval
        self.respectLowDataMode = respectLowDataMode
        self.pauseInBackground = pauseInBackground
        self.verify = verify
        self.storage = storage
        self.bootstrap = bootstrap
        self.events = events
        self.requestTimeout = requestTimeout
        self.callbackQueue = callbackQueue
        self.userAgentSuffix = userAgentSuffix
    }
}

/// Whether the configuration in use is known to be current.
public enum NanoFlagsStatus: String, Sendable {
    /// Nothing loaded yet: every flag returns its default.
    case notReady = "not-ready"
    /// The configuration is current.
    case ready
    /// A configuration is in use but is not known to be current (offline, restored from storage, edge
    /// unreachable, environment deleted).
    case stale
}

/// How updates reach the client right now.
public enum NanoFlagsTransport: String, Sendable {
    /// Pushed over the live WebSocket.
    case live
    /// Announced over SSE, then fetched.
    case stream
    /// Polled.
    case poll
}

public struct NanoFlagsError: Error, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case network, unauthorized, http, invalidBundle = "invalid_bundle", storage, config, signature, engine
        case environmentDeleted = "environment_deleted"
    }

    public let code: Code
    public let message: String
    public let httpStatus: Int?

    public init(_ code: Code, _ message: String, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }

    public var description: String { "NanoFlagsError(\(code.rawValue)): \(message)" }
}

/// A configuration change or a context change.
public struct FlagChange: Sendable {
    public enum Source: String, Sendable {
        /// A new revision from the edge.
        case network
        /// The configuration persisted on the device was loaded.
        case storage
        /// The `bootstrap` bundle was applied.
        case bootstrap
        /// `identify(context:)` changed the context.
        case context
    }

    /// Revision now in use (nil when nothing is loaded).
    public let revision: Int?
    public let previousRevision: Int?
    public let checksum: String?
    public let source: Source
    /// How the revision arrived (`live`, `stream` or `poll`).
    public let transport: NanoFlagsTransport
    /// Milliseconds from the commit of the revision to this event — only for revisions pushed over the live
    /// socket that carry the commit time; it compares the database's clock with the device's.
    public let latencyMs: Double?
    /// Flags whose value for the current context changed (added and removed flags included), sorted.
    public let changedFlags: [String]
}

/// The result of an evaluation with the reason behind it.
public struct EvaluationDetail<Value: FlagValue>: Sendable {
    public let flagKey: String
    public let value: Value
    public let reason: Reason
    /// Zero-based index of the matching rule.
    public let ruleIndex: Int?
    /// The matching rule's id.
    public let ruleId: String?
    /// For percentage rollouts: whether the context fell inside the allocation, and its bucket (0–99.99).
    public let inRollout: Bool?
    public let bucket: Double?
    /// The revision evaluated (0 when nothing is loaded).
    public let revision: Int
    /// Human-readable explanation, step by step.
    public let trace: [TraceStep]
    /// Why the default was returned (reason `error`): an evaluation error or a type mismatch.
    public let errorMessage: String?
}
