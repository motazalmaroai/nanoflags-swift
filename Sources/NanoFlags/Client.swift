import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A NanoFlags client: local, synchronous evaluation against a verified configuration that is kept live
/// in the background. Create it with `NanoFlags.start(key:options:)`.
///
/// Flag reads never perform I/O, never block on the network and never throw: until a configuration is
/// loaded they return your defaults. Thread-safe.
public final class NanoFlagsClient: @unchecked Sendable {
    // MARK: Configuration
    let sdkKey: String
    let options: NanoFlagsOptions
    let baseURL: String
    let service: String
    let userAgent: String
    /// Non-secret fingerprint binding a persisted bundle to this key + edge.
    let storageID: String
    let storage: BundleStorage?
    let net: NetworkTransport
    let keyRing: KeyRing?
    let verifyRequire: Bool
    let official: Bool
    let keyValid: Bool

    // MARK: State (guarded by `lock`)
    let lock = NSLock()
    struct Snapshot {
        let value: JSValue
        let revision: Int
        let raw: Data?
        let sig: SignatureInfo?
        let etag: String?
        let checksum: String?
        let attrs = AttributeCache()
    }

    var snapshot: Snapshot?
    var context: NanoFlagsContext
    var contextJS: JSValue
    var values: [String: JSONValue] = [:]
    var statusValue: NanoFlagsStatus = .notReady
    var closed = false
    var paused = false
    var lowData = false
    var failures = 0
    var lastSyncAt: Date?
    var inFlight: Task<Void, Never>?
    var streamTriggered = false
    var pinnedEnvironment: String?
    var liveRevision = 0
    var environmentDeleted = false
    var liveUnsupported = false
    var liveOpen = false
    var liveAttempt = 0
    var liveConn: LiveConnection?
    var liveRetry: Task<Void, Never>?
    var streamTask: Task<Void, Never>?
    var pollTask: Task<Void, Never>?
    var flushTask: Task<Void, Never>?
    var readyResolved = false
    var readyWaiters: [CheckedContinuation<Void, Never>] = []
    var changeListeners: [UUID: @Sendable (FlagChange) -> Void] = [:]
    var statusListeners: [UUID: @Sendable (NanoFlagsStatus) -> Void] = [:]
    var errorListeners: [UUID: @Sendable (NanoFlagsError) -> Void] = [:]
    var events = EventQueue()
    var platformObservers: [Any] = []

    static let liveConnectTimeout: TimeInterval = 10
    static let livePing: TimeInterval = 30
    static let livePongTimeout: TimeInterval = 10
    static let liveMaxBackoff: TimeInterval = 300
    /// A healthy socket is replaced after about this long, so the edge validates the key again (it drops
    /// sockets older than 2 h).
    static let liveRotate: TimeInterval = 50 * 60

    convenience init(key: String, options: NanoFlagsOptions) {
        let transport = URLSessionTransport(configuration: nil, requestTimeout: options.requestTimeout)
        self.init(key: key, options: options, network: transport, startPlatformObservers: true)
    }

    init(key: String, options: NanoFlagsOptions, network: NetworkTransport, startPlatformObservers: Bool) {
        sdkKey = key
        self.options = options
        var base = options.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        baseURL = base
        service = options.service ?? Bundle.main.bundleIdentifier ?? "unknown"
        userAgent = "nanoflags-swift/\(nanoFlagsSDKVersion) (\(platformDescription()))" + (options.userAgentSuffix.map { " " + $0 } ?? "")
        let id = String(Engine.murmur3("\(base)|\(key)"), radix: 16)
        storageID = String(repeating: "0", count: max(0, 8 - id.count)) + id
        storage = options.storage.make()
        net = network
        official = base == NanoFlags.officialEdgeURL.absoluteString
        // Mobile apps ship their key to every device: only browser/mobile keys (client view, client-exposed
        // flags) are accepted. A server key would expose every flag and segment of the environment.
        keyValid = key.hasPrefix("nf_pub_") && key.count > 7 && key.allSatisfy { $0.isASCII && !$0.isWhitespace }
        context = options.context
        contextJS = options.context.engineValue()

        var ring: KeyRing?
        var require = false
        var badKeys = false
        let fetcher: @Sendable () async throws -> [ImportedKey]
        let weakBox = WeakClient()
        fetcher = { guard let c = weakBox.client else { throw CancellationError() }; return try await c.fetchSigningKeys() }
        switch options.verify {
        case .disabled:
            break
        case .automatic:
            if base == NanoFlags.officialEdgeURL.absoluteString {
                ring = KeyRing(base: importKeys(NanoFlags.officialSigningKeys), require: true, refetch: true, fetchKeys: fetcher)
                require = true
            }
        case .enabled(let o):
            let isOfficial = base == NanoFlags.officialEdgeURL.absoluteString
            require = o.require ?? isOfficial
            if let keys = o.publicKeys {
                badKeys = keys.contains { !$0.isPublicEd25519 }
                ring = KeyRing(base: importKeys(keys), require: require, refetch: o.fetchKeys, fetchKeys: fetcher)
            } else if isOfficial && !o.fetchKeys {
                ring = KeyRing(base: importKeys(NanoFlags.officialSigningKeys), require: require, refetch: true, fetchKeys: fetcher)
            } else {
                ring = KeyRing(base: isOfficial ? importKeys(NanoFlags.officialSigningKeys) : [], require: require, refetch: true, fetchKeys: fetcher)
            }
        }
        keyRing = ring
        verifyRequire = require
        weakBox.client = self

        if let boot = options.bootstrap { applyBootstrap(boot) }
        if badKeys {
            emitError(NanoFlagsError(.config, "`verify` publicKeys must contain public Ed25519 JWKs only. Other entries (including private keys) were ignored."))
        }
        guard keyValid else {
            let msg = key.hasPrefix("nf_srv_")
                ? "Server keys (nf_srv_…) must never ship in an app: they expose every flag and segment. Use the environment's browser/mobile key (nf_pub_…)."
                : "A browser/mobile SDK key (nf_pub_…) is required."
            emitError(NanoFlagsError(.config, msg))
            resolveReady()
            return
        }
        if startPlatformObservers { startLifecycleObservers() }
        Task { [weak self] in await self?.boot() }
    }

    deinit {
        pollTask?.cancel()
        flushTask?.cancel()
        streamTask?.cancel()
        liveRetry?.cancel()
        liveConn?.close()
    }

    private func boot() async {
        await restore()
        await sync()
        resolveReady()
        if isClosed { return }
        schedulePoll()
        startFlushLoop()
        startRealtime()
    }

    // MARK: - Public state

    /// Whether the configuration in use is known to be current.
    public var status: NanoFlagsStatus { locked { statusValue } }

    /// Revision of the configuration in use, or nil when none is loaded.
    public var revision: Int? { locked { snapshot?.revision } }

    /// How updates reach the client right now.
    public var transport: NanoFlagsTransport {
        locked { liveOpen ? .live : (streamTask != nil ? .stream : .poll) }
    }

    /// The context flags are evaluated for.
    public var currentContext: NanoFlagsContext { locked { context } }

    /// Waits until a usable configuration is loaded or the first load attempt has finished without one
    /// (then `status` is `.notReady` and flags return their defaults). Returns whether a configuration is in
    /// use. With a timeout, returns early (false while nothing is loaded).
    @discardableResult
    public func ready(timeout: TimeInterval? = nil) async -> Bool {
        if let timeout {
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.waitReady(); return true }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                    return false
                }
                _ = await group.next()
                group.cancelAll()
                return self.status != .notReady
            }
        }
        await waitReady()
        return status != .notReady
    }

    private func waitReady() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if readyResolved {
                lock.unlock()
                cont.resume()
            } else {
                readyWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    func resolveReady() {
        lock.lock()
        if readyResolved {
            lock.unlock()
            return
        }
        readyResolved = true
        let waiters = readyWaiters
        readyWaiters = []
        lock.unlock()
        for w in waiters { w.resume() }
    }

    // MARK: - Evaluation

    /// The value of a boolean flag, or `defaultValue` when the flag is missing, has another type, or no
    /// configuration is loaded.
    public func boolVariation(key: String, default defaultValue: Bool, context: NanoFlagsContext? = nil) -> Bool {
        evaluate(key, defaultValue, context).value
    }

    public func stringVariation(key: String, default defaultValue: String, context: NanoFlagsContext? = nil) -> String {
        evaluate(key, defaultValue, context).value
    }

    public func numberVariation(key: String, default defaultValue: Double, context: NanoFlagsContext? = nil) -> Double {
        evaluate(key, defaultValue, context).value
    }

    /// A number flag read as a whole number (fractional values return `defaultValue`).
    public func intVariation(key: String, default defaultValue: Int, context: NanoFlagsContext? = nil) -> Int {
        evaluate(key, defaultValue, context).value
    }

    public func jsonVariation(key: String, default defaultValue: JSONValue, context: NanoFlagsContext? = nil) -> JSONValue {
        evaluate(key, defaultValue, context).value
    }

    /// The value with the reason behind it (matched rule, rollout bucket, trace). The type is checked like
    /// the typed variations: a value of another type returns `defaultValue` with reason `error`.
    public func variationDetail<T: FlagValue>(key: String, default defaultValue: T, context: NanoFlagsContext? = nil) -> EvaluationDetail<T> {
        evaluate(key, defaultValue, context)
    }

    /// Every flag of the configuration evaluated for the current context (flags that serve nothing are
    /// left out). No telemetry is recorded.
    public func allFlags(context: NanoFlagsContext? = nil) -> [String: JSONValue] {
        let (snap, ctx) = locked { (snapshot, context.map { $0.engineValue() } ?? contextJS) }
        return evaluateAll(snap, ctx)
    }

    func evaluateAll(_ snap: Snapshot?, _ ctx: JSValue) -> [String: JSONValue] {
        guard let snap, case .object(let flags) = snap.value.field("flags") else { return [:] }
        var out: [String: JSONValue] = [:]
        for k in flags.keys {
            let r = Engine.evaluate(bundle: snap.value, flagKey: k, context: ctx, fallback: .undefined)
            if r.reason != .error && r.reason != .flagNotFound, let v = JSONValue(engine: r.value) { out[k] = v }
        }
        return out
    }

    func evaluate<T: FlagValue>(_ key: String, _ fallback: T, _ ctxOverride: NanoFlagsContext?) -> EvaluationDetail<T> {
        let (snap, ctxValue, ctx) = locked { (snapshot, ctxOverride.map { $0.engineValue() } ?? contextJS, ctxOverride ?? context) }
        let fallbackJS = fallback.jsonValue.toJS()
        var r = Engine.evaluate(bundle: snap?.value ?? .null, flagKey: key, context: ctxValue, fallback: fallbackJS)
        var value = fallback
        if r.reason != .flagNotFound && r.reason != .error {
            if let v = JSONValue(engine: r.value), let typed = T.fromFlag(v) {
                value = typed
            } else {
                let error = "Flag \"\(key)\" has a \(r.value.isUndefined ? "undefined" : r.value.typeName) value, which does not match the requested type."
                r = EngineResult(flagKey: key, value: fallbackJS, reason: .error, ruleIndex: nil, ruleId: .undefined, inRollout: nil, bucket: nil,
                                 revision: r.revision, trace: r.trace + [TraceStep(kind: "result", title: "Returned the fallback", detail: error)], error: error)
            }
        }
        record(r, ctx, snap)
        let rev = r.revision.jsNumber
        return EvaluationDetail(flagKey: key, value: value, reason: r.reason, ruleIndex: r.ruleIndex,
                                ruleId: r.ruleIndex == nil || r.ruleId.isUndefined ? nil : r.ruleId.jsString,
                                inRollout: r.inRollout, bucket: r.bucket, revision: rev.isFinite ? Int(rev) : 0, trace: r.trace, errorMessage: r.error)
    }

    // MARK: - Context

    /// Changes the context flags are evaluated for. Synchronous and local: no network round trip. Change
    /// listeners get a `FlagChange` with source `.context` listing the flags whose value changed.
    public func identify(context newContext: NanoFlagsContext) {
        lock.lock()
        context = newContext
        contextJS = newContext.engineValue()
        let snap = snapshot
        let ctx = contextJS
        lock.unlock()
        let next = evaluateAll(snap, ctx)
        let change = lockedUpdateValues(next) { changed in
            FlagChange(revision: snap?.revision, previousRevision: snap?.revision, checksum: snap?.checksum, source: .context,
                       transport: self.liveOpen ? .live : .poll, latencyMs: nil, changedFlags: changed)
        }
        emitChange(change)
    }

    /// Replaces `values` and returns the change event built from the keys that differ.
    func lockedUpdateValues(_ next: [String: JSONValue], _ build: ([String]) -> FlagChange) -> FlagChange {
        lock.lock()
        let prev = values
        values = next
        let changed = Set(prev.keys).union(next.keys).filter { prev[$0] != next[$0] }.sorted()
        let e = build(changed)
        lock.unlock()
        return e
    }

    // MARK: - Listeners

    /// Calls `handler` for every configuration change and context change. Keep the returned subscription;
    /// cancel it (or let it go) to stop.
    @discardableResult
    public func onChange(_ handler: @escaping @Sendable (FlagChange) -> Void) -> NanoFlagsSubscription {
        let id = UUID()
        locked { changeListeners[id] = handler }
        return NanoFlagsSubscription { [weak self] in self?.locked { self?.changeListeners[id] = nil } }
    }

    /// Calls `handler` with the new value whenever the value of `key` for the current context changes.
    @discardableResult
    public func onChange<T: FlagValue & Equatable>(key: String, default defaultValue: T, _ handler: @escaping @Sendable (T) -> Void) -> NanoFlagsSubscription {
        onChange { [weak self] change in
            guard let self, change.changedFlags.contains(key) else { return }
            handler(self.peek(key, defaultValue))
        }
    }

    /// Every change, as an AsyncSequence: `for await change in client.changes { … }`.
    public var changes: AsyncStream<FlagChange> {
        AsyncStream { continuation in
            let sub = self.onChange { continuation.yield($0) }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    /// The value of `key` now and after every change of it: `for await on in client.values(key: "x", default: false) { … }`.
    public func values<T: FlagValue & Equatable>(key: String, default defaultValue: T) -> AsyncStream<T> {
        AsyncStream { continuation in
            continuation.yield(self.peek(key, defaultValue))
            let sub = self.onChange(key: key, default: defaultValue) { continuation.yield($0) }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    @discardableResult
    public func onStatusChange(_ handler: @escaping @Sendable (NanoFlagsStatus) -> Void) -> NanoFlagsSubscription {
        let id = UUID()
        locked { statusListeners[id] = handler }
        return NanoFlagsSubscription { [weak self] in self?.locked { self?.statusListeners[id] = nil } }
    }

    /// Problems the app may want to log: a rejected key, a bundle that failed verification, the network.
    /// Flags keep working through all of them.
    @discardableResult
    public func onError(_ handler: @escaping @Sendable (NanoFlagsError) -> Void) -> NanoFlagsSubscription {
        let id = UUID()
        locked { errorListeners[id] = handler }
        return NanoFlagsSubscription { [weak self] in self?.locked { self?.errorListeners[id] = nil } }
    }

    /// A value without telemetry (listeners, SwiftUI).
    func peek<T: FlagValue>(_ key: String, _ fallback: T) -> T {
        let (snap, ctx) = locked { (snapshot, contextJS) }
        let r = Engine.evaluate(bundle: snap?.value ?? .null, flagKey: key, context: ctx, fallback: fallback.jsonValue.toJS())
        if r.reason == .error || r.reason == .flagNotFound { return fallback }
        return JSONValue(engine: r.value).flatMap(T.fromFlag) ?? fallback
    }

    func deliver(_ body: @escaping @Sendable () -> Void) {
        if let q = options.callbackQueue { q.async(execute: body) } else { body() }
    }

    func emitChange(_ e: FlagChange) {
        let ls = locked { Array(changeListeners.values) }
        for l in ls { deliver { l(e) } }
    }

    func emitError(_ e: NanoFlagsError) {
        let ls = locked { Array(errorListeners.values) }
        for l in ls { deliver { l(e) } }
    }

    func setStatus(_ s: NanoFlagsStatus) {
        lock.lock()
        if statusValue == s {
            lock.unlock()
            return
        }
        statusValue = s
        let ls = Array(statusListeners.values)
        lock.unlock()
        for l in ls { deliver { l(s) } }
    }

    // MARK: - Lifecycle

    /// Closes the live connection and stops polling and telemetry until `resume()`. Evaluations keep
    /// working. Called automatically when the app goes to the background (`pauseInBackground`).
    public func pause() {
        lock.lock()
        if closed || paused {
            lock.unlock()
            return
        }
        paused = true
        lock.unlock()
        stopRealtime()
        locked { pollTask?.cancel(); pollTask = nil }
        Task { await self.flush() }
    }

    /// Reconnects and catches up after `pause()`. Called automatically when the app returns to the
    /// foreground.
    public func resume() {
        lock.lock()
        if closed || !paused {
            lock.unlock()
            return
        }
        paused = false
        let due = lastSyncAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
        let catchUp = due || failures > 0 || statusValue != .ready
        lock.unlock()
        if catchUp { Task { await self.sync(); self.schedulePoll() } } else { schedulePoll() }
        startRealtime()
    }

    /// Low Data Mode / network reachability changes (from NWPathMonitor on Apple platforms).
    func networkChanged(constrained: Bool, available: Bool) {
        let wasLow = locked { lowData }
        let low = constrained && options.respectLowDataMode
        locked { lowData = low }
        if low && !wasLow {
            stopRealtime()
            schedulePoll()
        } else if !low && wasLow {
            schedulePoll()
            startRealtime()
        }
        if available && !low && locked({ failures > 0 && !paused }) {
            Task { await self.sync(); self.schedulePoll() }
        }
    }

    /// Revalidates now (a conditional request). Returns when it finished, successfully or not.
    public func refresh() async {
        if let t = locked({ inFlight }) { await t.value }
        await sync()
    }

    /// Stops the connection, polling and telemetry (queued events are sent best-effort). Evaluations keep
    /// working on the last configuration.
    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        lock.unlock()
        let finalFlush = Task { await self.flush() }
        _ = finalFlush
        lock.lock()
        closed = true
        pollTask?.cancel()
        flushTask?.cancel()
        liveRetry?.cancel()
        pollTask = nil
        flushTask = nil
        liveRetry = nil
        let observers = platformObservers
        platformObservers = []
        lock.unlock()
        stopRealtime()
        stopLifecycleObservers(observers)
        resolveReady()
    }

    var isClosed: Bool { locked { closed } }

    @inline(__always)
    func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A registered listener. It stays registered until `cancel()` (or until the client is closed); releasing
/// the subscription object does not cancel it.
public final class NanoFlagsSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    public func cancel() {
        lock.lock()
        let c = onCancel
        onCancel = nil
        lock.unlock()
        c?()
    }
}

final class WeakClient: @unchecked Sendable {
    weak var client: NanoFlagsClient?
}

/// Per-bundle cache of the attribute names each flag's rules use (telemetry).
final class AttributeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: [String]] = [:]

    func names(_ bundle: JSValue, _ flagKey: String) -> [String] {
        lock.lock()
        if let n = names[flagKey] {
            lock.unlock()
            return n
        }
        lock.unlock()
        let n = Engine.attributesUsed(bundle: bundle, flagKey: flagKey)
        lock.lock()
        if names.count < 10_000 { names[flagKey] = n }
        lock.unlock()
        return n
    }
}

func platformDescription() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    #if os(iOS)
    return "iOS \(version)"
    #elseif os(tvOS)
    return "tvOS \(version)"
    #elseif os(watchOS)
    return "watchOS \(version)"
    #elseif os(visionOS)
    return "visionOS \(version)"
    #elseif os(macOS)
    return "macOS \(version)"
    #elseif os(Linux)
    return "Linux"
    #else
    return "unknown"
    #endif
}
