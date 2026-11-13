import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One live WebSocket (`/v1/live`). The edge pushes the signed bundle itself: nothing is fetched.
final class LiveConnection: @unchecked Sendable {
    let socket: WebSocketConnection
    private let lock = NSLock()
    private var _opened = false
    private var _openedAt: Date?
    private var _done = false
    private var _rotating = false
    private var _lastMessageAt = Date()

    init(socket: WebSocketConnection) { self.socket = socket }

    var opened: Bool { lock.lock(); defer { lock.unlock() }; return _opened }
    var openedAt: Date? { lock.lock(); defer { lock.unlock() }; return _openedAt }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var rotating: Bool { lock.lock(); defer { lock.unlock() }; return _rotating }
    var lastMessageAt: Date { lock.lock(); defer { lock.unlock() }; return _lastMessageAt }

    /// Marks the socket open (first message); returns true the first time.
    func markMessage() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _lastMessageAt = Date()
        if _opened { return false }
        _opened = true
        _openedAt = Date()
        return true
    }

    func rotate() {
        lock.lock()
        _rotating = true
        lock.unlock()
        close()
    }

    func close() {
        lock.lock()
        let wasDone = _done
        _done = true
        lock.unlock()
        if !wasDone { socket.close(code: 1000) }
    }
}

extension NanoFlagsClient {
    func connectLive() {
        lock.lock()
        if closed || paused || lowData || environmentDeleted || liveUnsupported || liveConn != nil || !liveWanted {
            lock.unlock()
            return
        }
        var req = request("/v1/live")
        req.url = URL(string: baseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/v1/live")
        // The key travels in the Authorization header (never in the URL); the subprotocol names the format.
        req.setValue("nanoflags.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let conn = LiveConnection(socket: net.webSocket(req))
        liveConn = conn
        lock.unlock()
        Task { [weak self] in await self?.runLive(conn) }
        Task { [weak self] in await self?.keepAlive(conn) }
    }

    /// Connect timeout, ping/pong and the periodic replacement of a healthy socket.
    func keepAlive(_ conn: LiveConnection) async {
        do {
            try await sleep(seconds: NanoFlagsClient.liveConnectTimeout)
            if conn.done { return }
            if !conn.opened { return conn.close() }
            while !conn.done {
                try await sleep(seconds: NanoFlagsClient.livePing * Double.random(in: 0.9...1.1))
                if conn.done { return }
                if let at = conn.openedAt, Date().timeIntervalSince(at) > NanoFlagsClient.liveRotate * Double.random(in: 0.9...1.1) {
                    return conn.rotate()
                }
                let sentAt = Date()
                do { try await conn.socket.send("ping") } catch { return conn.close() }
                // The edge answers `pong` without waking anything up; silence means the connection is dead.
                try await sleep(seconds: NanoFlagsClient.livePongTimeout)
                if conn.done { return }
                if conn.lastMessageAt < sentAt { return conn.close() }
            }
        } catch {
            return
        }
    }

    func runLive(_ conn: LiveConnection) async {
        var unsupported = false
        while true {
            let text: String
            do { text = try await conn.socket.receive() } catch {
                unsupported = error is WebSocketUnsupported
                break
            }
            if conn.done { break }
            if conn.markMessage() {
                // Open: SSE is not used while the socket is healthy; polling becomes a safety net.
                locked { liveOpen = true; failures = 0 }
                stopStream()
                schedulePoll()
            }
            if text == "pong" || text.isEmpty { continue }
            guard let m = try? JSValue.parse(text), case .object = m else { continue }
            // One at a time, in arrival order.
            await applyPush(m)
        }
        conn.close()
        let reason = conn.socket.closeReason ?? ""
        let deleted = conn.socket.closeCode == NanoFlags.closeEnvironmentDeleted || reason.contains("environment deleted")
        let opened = conn.opened
        let openFor = conn.openedAt.map { Date().timeIntervalSince($0) } ?? 0
        locked {
            if liveConn === conn { liveConn = nil }
            liveOpen = false
            if deleted { environmentDeleted = true }
            if unsupported { liveUnsupported = true }
        }
        liveEnded(opened: opened, openFor: openFor, rotating: conn.rotating)
    }

    func liveEnded(opened: Bool, openFor: TimeInterval, rotating: Bool) {
        let (closed, paused, deleted, unsupported, lowData) = locked { (self.closed, self.paused, environmentDeleted, liveUnsupported, self.lowData) }
        if closed { return }
        if deleted {
            // Keep evaluating the last configuration; it can no longer be updated. No socket, no stream; the
            // regular poll stays (it reports the key as rejected, and recovers if the environment exists after all).
            stopStream()
            if locked({ snapshot != nil }) { setStatus(.stale) }
            emitError(NanoFlagsError(.environmentDeleted, "The environment of this SDK key was deleted. The last configuration stays in use; it will not be updated."))
            schedulePoll()
            return
        }
        if paused || lowData { return }
        if unsupported {
            // URLSession cannot open WebSockets here (Linux): SSE + polling, for good.
            startStream()
            schedulePoll()
            return
        }
        if rotating { return connectLive() } // planned replacement: no fallback, no backoff
        let attempt: Int = locked {
            liveAttempt = opened && openFor > 30 ? 1 : liveAttempt + 1
            return liveAttempt
        }
        // Never got through (socket cap, proxy without WebSocket support), or lost it: SSE + polling take over
        // until a socket opens again.
        if !opened { startStream() } else { schedulePoll() }
        let wait = min(NanoFlagsClient.liveMaxBackoff, pow(2, Double(min(attempt - 1, 10)))) * Double.random(in: 0.5...1.5)
        let t = Task { [weak self] in
            do { try await sleep(seconds: wait) } catch { return }
            self?.locked { self?.liveRetry = nil }
            self?.connectLive()
        }
        locked {
            liveRetry?.cancel()
            liveRetry = t
        }
    }

    /// Applies one `rev` / `hello` message. A message that cannot be trusted changes nothing.
    func applyPush(_ m: JSValue) async {
        guard !isClosed, m.field("t").isString("rev") || m.field("t").isString("hello") else { return }
        // Revision 0 / no bundle: nothing is published yet.
        guard case .number(let r) = m.field("revision"), r == r.rounded(), r >= 1, r < 9e15, case .string(let text) = m.field("bundle") else { return }
        let revision = Int(r)
        if let cur = locked({ snapshot }), revision < cur.revision { return } // never backwards
        let pushedChecksum = m.field("checksum").stringValue
        let bundleText = Data(text.utf8)
        var info: SignatureInfo?
        if let ring = keyRing {
            func reject(_ why: String) async {
                emitError(NanoFlagsError(.signature, "Pushed bundle r\(revision) was rejected: \(why) The configuration in use is unchanged."))
                // Whatever sent this, the regular (verified) request path says what is really current.
                Task { await self.sync() }
            }
            guard case .string(let signature) = m.field("signature"), case .string(let env) = m.field("environmentId"), let checksum = pushedChecksum else {
                return await reject("it carries no complete signature.")
            }
            if let pinned = locked({ pinnedEnvironment }), pinned != env { return await reject("it was signed for a different environment.") }
            let i = SignatureInfo(signature: signature, kid: m.field("kid").stringValue, environmentId: env, revision: revision, checksum: checksum)
            let keys = (try? await ring.keys(for: i.kid)) ?? []
            if isClosed { return }
            guard verifyBundleText(keys: keys, info: i, bundleText: bundleText) else { return await reject("its signature does not verify.") }
            info = i
        }
        guard let parsed = try? JSValue.parse(bundleText), isBundle(parsed), bundleRevision(parsed) == revision else {
            return emitError(NanoFlagsError(.invalidBundle, "The edge pushed an invalid bundle; it was ignored."))
        }
        guard Engine.supportsEngine(parsed.field("engine")) else { return emitError(engineError(parsed)) }
        let current: Snapshot? = locked { failures = 0; return snapshot }
        if let cur = current {
            if revision < cur.revision { return }
            if revision == cur.revision {
                // Already in use: the push only confirms that it is current.
                if cur.checksum == nil || cur.checksum == pushedChecksum { setStatus(.ready) }
                return
            }
        }
        locked {
            if let info { pinnedEnvironment = info.environmentId }
            liveRevision = revision
        }
        var latency: Double?
        if case .number(let committedAt) = m.field("committedAt"), committedAt.isFinite {
            latency = Date().timeIntervalSince1970 * 1000 - committedAt
        }
        adopt(Snapshot(value: parsed, revision: revision, raw: bundleText, sig: info,
                       // What `/v1/bundle` would send as ETag for this revision, so the safety poll gets a 304.
                       etag: pushedChecksum.map { "\"\($0)-client\"" }, checksum: pushedChecksum),
              status: .ready, source: .network, transport: .live, latencyMs: latency)
        persist()
    }
}
