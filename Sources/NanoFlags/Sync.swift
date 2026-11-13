import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func isBundle(_ v: JSValue) -> Bool {
    guard case .object(let o) = v else { return false }
    guard case .number(let schema) = o["schema"] ?? .undefined, schema == 1 else { return false }
    guard case .number = o["revision"] ?? .undefined else { return false }
    guard case .object = o["flags"] ?? .undefined else { return false }
    switch o["segments"] ?? .undefined {
    case .object, .array: return true
    default: return false
    }
}

func bundleRevision(_ v: JSValue) -> Int {
    let r = v.field("revision").numberValue ?? 0
    return r.isFinite ? Int(r) : 0
}

func engineError(_ b: JSValue) -> NanoFlagsError {
    NanoFlagsError(.engine, "Bundle r\(b.field("revision").jsString) needs evaluation engine \(b.field("engine").json ?? "undefined"); this SDK supports up to \(Engine.version). Update the NanoFlags package. The configuration in use is unchanged.")
}

func sleep(seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

extension NanoFlagsClient {
    // MARK: - Requests

    func request(_ path: String, method: String = "GET", authorized: Bool = true) -> URLRequest {
        var r = URLRequest(url: URL(string: baseURL + path)!)
        r.httpMethod = method
        r.timeoutInterval = options.requestTimeout
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if authorized { r.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func fetchSigningKeys() async throws -> [ImportedKey] {
        // Public endpoint: the SDK key is deliberately not sent.
        let res = try await net.send(request("/v1/keys", authorized: false))
        guard res.status == 200 else { throw NanoFlagsError(.signature, "Signing keys request failed with HTTP \(res.status).", httpStatus: res.status) }
        struct Body: Decodable { let keys: [SigningKey]? }
        let body = try? JSONDecoder().decode(Body.self, from: res.body)
        let keys = importKeys(body?.keys ?? [])
        if keys.isEmpty { throw NanoFlagsError(.signature, "The edge returned no usable signing keys.") }
        return keys
    }

    // MARK: - Adopting a configuration

    func adopt(_ next: Snapshot, status: NanoFlagsStatus, source: FlagChange.Source, transport: NanoFlagsTransport, latencyMs: Double?) {
        let ctx = locked { contextJS }
        let nextValues = evaluateAll(next, ctx)
        lock.lock()
        let previous = snapshot
        let isNew = previous == nil || previous!.revision != next.revision || previous!.checksum != next.checksum
        snapshot = next // a single assignment: every evaluation sees one consistent revision
        let oldValues = values
        values = nextValues
        let changed = Set(oldValues.keys).union(nextValues.keys).filter { oldValues[$0] != nextValues[$0] }.sorted()
        lock.unlock()
        setStatus(status)
        resolveReady()
        if isNew {
            emitChange(FlagChange(revision: next.revision, previousRevision: previous?.revision, checksum: next.checksum, source: source,
                                  transport: transport, latencyMs: latencyMs, changedFlags: changed))
        }
    }

    func applyBootstrap(_ data: Data) {
        guard let v = try? JSValue.parse(data), isBundle(v) else {
            emitError(NanoFlagsError(.invalidBundle, "The bootstrap bundle is invalid and was ignored."))
            return
        }
        guard Engine.supportsEngine(v.field("engine")) else { return emitError(engineError(v)) }
        adopt(Snapshot(value: v, revision: bundleRevision(v), raw: nil, sig: nil, etag: nil, checksum: nil),
              status: .ready, source: .bootstrap, transport: .poll, latencyMs: nil)
    }

    // MARK: - Persistence

    func persist() {
        guard let storage, let snap = locked({ snapshot }) else { return }
        var b = JSObjectBuilder()
        b.set("v", .number(1))
        b.set("id", .string(storageID))
        b.set("etag", snap.etag.map(JSValue.string) ?? .null)
        b.set("checksum", snap.checksum.map(JSValue.string) ?? .null)
        b.set("savedAt", .string(isoNow()))
        // The exact text the signature covers, so a restored copy can be verified again.
        let raw = snap.raw.map { String(decoding: $0, as: UTF8.self) } ?? (snap.value.json ?? "null")
        b.set("raw", .string(raw))
        if let sig = snap.sig { b.set("sig", sig.toJS()) }
        let text = JSValue.object(b.build()).json ?? "{}"
        do { try storage.save(Data(text.utf8), id: storageID) } catch {
            emitError(NanoFlagsError(.storage, "Could not persist the configuration: \(error)"))
        }
    }

    func restore() async {
        guard let storage, let data = storage.load(id: storageID) else { return }
        guard let p = try? JSValue.parse(data), p.field("v").numberValue == 1, p.field("id").isString(storageID),
              case .string(let raw) = p.field("raw"), let bundle = try? JSValue.parse(raw), isBundle(bundle)
        else {
            return emitError(NanoFlagsError(.storage, "The persisted configuration could not be read and was ignored."))
        }
        guard Engine.supportsEngine(bundle.field("engine")) else { return emitError(engineError(bundle)) }
        let revision = bundleRevision(bundle)
        // Never replace something newer (the bootstrap bundle) with the stored copy.
        if let cur = locked({ snapshot }), cur.revision >= revision { return }
        let rawData = Data(raw.utf8)
        var sig: SignatureInfo?
        if let ring = keyRing {
            // The store is outside the trust boundary: a signed copy must verify again, and with `require`
            // an unsigned copy is not used at all.
            if let s = SignatureInfo(p.field("sig")), s.revision == revision {
                let keys = (try? await ring.keys(for: s.kid)) ?? []
                guard verifyBundleText(keys: keys, info: s, bundleText: rawData) else {
                    return emitError(NanoFlagsError(.signature, "The persisted configuration failed signature verification and was ignored."))
                }
                sig = s
            } else if verifyRequire {
                return
            }
        }
        if isClosed { return }
        if let cur = locked({ snapshot }), cur.revision >= revision { return }
        locked { if let sig, pinnedEnvironment == nil { pinnedEnvironment = sig.environmentId } }
        // Usable, but not known to be current: stale until the edge confirms it.
        adopt(Snapshot(value: bundle, revision: revision, raw: rawData, sig: sig, etag: p.field("etag").stringValue,
                       checksum: p.field("checksum").stringValue),
              status: .stale, source: .storage, transport: .poll, latencyMs: nil)
    }

    // MARK: - Polling (`/v1/bundle`, ETag)

    /// Single-flight: concurrent triggers (poll, stream, foreground) share one request.
    func sync() async {
        let task: Task<Void, Never>? = locked {
            if closed { return nil }
            if let t = inFlight { return t }
            let t = Task { [weak self] in
                await self?.syncOnce()
                self?.locked { self?.inFlight = nil }
            }
            inFlight = t
            return t
        }
        await task?.value
    }

    func syncOnce() async {
        let (etag, transport): (String?, NanoFlagsTransport) = locked {
            lastSyncAt = Date()
            let t: NanoFlagsTransport = streamTriggered ? .stream : .poll
            streamTriggered = false
            return (snapshot?.etag, t)
        }
        do {
            var req = request("/v1/bundle")
            if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let res = try await net.send(req)
            if isClosed { return }
            let servedStale = res.header("x-nanoflags-stale") == "true"
            if res.status == 304 {
                let has = locked { failures = 0; return snapshot != nil }
                if has { setStatus(servedStale ? .stale : .ready) }
                return
            }
            if res.status == 401 || res.status == 403 {
                throw NanoFlagsError(.unauthorized, "The SDK key was rejected (unknown or revoked).", httpStatus: res.status)
            }
            guard (200..<300).contains(res.status) else { throw NanoFlagsError(.http, "Bundle request failed with HTTP \(res.status).", httpStatus: res.status) }
            guard let body = try? JSValue.parse(res.body), isBundle(body.field("bundle")) else {
                throw NanoFlagsError(.invalidBundle, "The edge returned an invalid bundle.")
            }
            let (bundle, raw, sig) = try await checkSignature(res, body)
            if isClosed { return }
            guard Engine.supportsEngine(bundle.field("engine")) else { throw engineError(bundle) }
            let revision = bundleRevision(bundle)
            let skip: Bool = locked {
                failures = 0
                guard let cur = snapshot else { return false }
                // The edge is serving its last-known-good copy: never go backwards because of it.
                if servedStale && cur.revision >= revision { return true }
                // A revision that was pushed while this request was under way (or that KV does not point at
                // yet) wins.
                if revision < liveRevision && cur.revision >= liveRevision { return true }
                return false
            }
            if skip {
                if servedStale { setStatus(.stale) }
                return
            }
            adopt(Snapshot(value: bundle, revision: revision, raw: raw, sig: sig, etag: res.header("etag"), checksum: body.field("checksum").stringValue),
                  status: servedStale ? .stale : .ready, source: .network, transport: transport, latencyMs: nil)
            persist()
        } catch {
            if isClosed { return }
            let e = error as? NanoFlagsError ?? NanoFlagsError(.network, "Could not reach the NanoFlags edge: \(error.localizedDescription)")
            // A bundle for a newer engine: nothing to retry quickly.
            if e.code == .engine { return emitError(e) }
            let hasBundle = locked { failures += 1; return snapshot != nil }
            // Catch up quickly (1 s, 2 s, 4 s … capped at the poll interval), whatever triggered this request.
            schedulePoll()
            // A rejected update changes nothing: same bundle, same status. Polling retries with backoff.
            if e.code == .signature { return emitError(e) }
            // A rejected key must not keep a socket.
            if e.code == .unauthorized { locked { liveConn }?.close() }
            if hasBundle { setStatus(.stale) }
            emitError(e)
        }
    }

    /// Returns the bundle to adopt (with the signed text and signature), or throws `.signature`.
    func checkSignature(_ res: HTTPResponse, _ body: JSValue) async throws -> (JSValue, Data?, SignatureInfo?) {
        let bundle = body.field("bundle")
        let rawText = rawMember(res.body, "bundle")
        guard let ring = keyRing else { return (bundle, rawText, nil) }
        let revisionInBundle = bundleRevision(bundle)
        func reject(_ why: String) -> NanoFlagsError {
            NanoFlagsError(.signature, "Bundle r\(revisionInBundle) was rejected: \(why) The configuration in use is unchanged.")
        }
        if res.header("x-nanoflags-signed") != "true" {
            if verifyRequire { throw reject("it is not signed (the edge is still distributing it) and unsigned bundles are refused; fetching again shortly.") }
            return (bundle, rawText, nil)
        }
        guard let signature = res.header("x-nanoflags-signature"), let environmentId = res.header("x-nanoflags-environment-id"),
              case .string(let checksum) = body.field("checksum")
        else { throw reject("the signature headers are incomplete.") }
        let revision: Int
        if case .number(let r) = body.field("revision") { revision = r.isFinite ? Int(r) : -1 } else { revision = revisionInBundle }
        guard revision == revisionInBundle else { throw reject("the signed revision does not match the bundle.") }
        if let pinned = locked({ pinnedEnvironment }), pinned != environmentId { throw reject("it was signed for a different environment.") }
        let info = SignatureInfo(signature: signature, kid: res.header("x-nanoflags-key-id"), environmentId: environmentId, revision: revision, checksum: checksum)
        let keys: [ImportedKey]
        do { keys = try await ring.keys(for: info.kid) } catch {
            throw reject("the signing keys could not be loaded (\(error)).")
        }
        // The edge embeds the stored bundle text byte-for-byte: hash exactly those bytes. JSON.stringify of the
        // parsed bundle reproduces them too (this module serialises like JavaScript), as a fallback.
        if let raw = rawText, verifyBundleText(keys: keys, info: info, bundleText: raw) {
            locked { pinnedEnvironment = environmentId }
            return (bundle, raw, info)
        }
        if let again = bundle.json.map({ Data($0.utf8) }), again != rawText, verifyBundleText(keys: keys, info: info, bundleText: again) {
            locked { pinnedEnvironment = environmentId }
            return (bundle, again, info)
        }
        throw reject("its signature does not verify.")
    }

    func nextDelay() -> TimeInterval {
        locked {
            let poll = options.pollInterval
            let jitter = Double.random(in: 0.8...1.2)
            var interval = poll
            if lowData { interval = max(poll, options.lowDataPollInterval) } else if liveOpen { interval = max(poll, options.livePollInterval) }
            // After failures, catch up quickly (1 s, 2 s, 4 s … capped at the poll interval).
            let base = failures > 0 ? min(poll, pow(2, Double(min(failures - 1, 10)))) : interval
            return max(0.25, base * jitter)
        }
    }

    func schedulePoll() {
        lock.lock()
        defer { lock.unlock() }
        if closed || paused || options.pollInterval <= 0 { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let delay = self?.nextDelay() else { return }
            do { try await sleep(seconds: delay) } catch { return }
            guard let self, !self.locked({ self.paused || self.closed }) else { return }
            await self.sync()
            if Task.isCancelled { return }
            self.schedulePoll()
        }
    }

    // MARK: - Realtime

    var liveWanted: Bool {
        options.transport == .automatic && (baseURL.hasPrefix("https://") || baseURL.hasPrefix("http://"))
    }

    func startRealtime() {
        let (skip, unsupported) = locked { (closed || paused || lowData || environmentDeleted, liveUnsupported) }
        if skip || options.transport == .polling { return }
        if liveWanted && !unsupported { connectLive() } else { startStream() }
    }

    func stopRealtime() {
        let (conn, retry) = locked { () -> (LiveConnection?, Task<Void, Never>?) in
            let c = liveConn, r = liveRetry
            liveRetry = nil
            return (c, r)
        }
        retry?.cancel()
        conn?.close()
        stopStream()
    }

    // MARK: SSE (`/v1/stream`): the stream only says "revision N exists"; the bundle is fetched conditionally.

    func startStream() {
        lock.lock()
        defer { lock.unlock() }
        if closed || paused || lowData || environmentDeleted || streamTask != nil || options.transport == .polling { return }
        streamTask = Task { [weak self] in await self?.streamLoop() }
    }

    func stopStream() {
        let t = locked { () -> Task<Void, Never>? in
            let t = streamTask
            streamTask = nil
            return t
        }
        t?.cancel()
    }

    func streamLoop() async {
        var attempt = 0
        while !Task.isCancelled && !isClosed {
            let startedAt = Date()
            var stop = false
            var req = request("/v1/stream")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 120
            do {
                var parser = SSEParser()
                for try await part in net.stream(req) {
                    if Task.isCancelled { break }
                    switch part {
                    case .status(let s):
                        if s == 401 || s == 403 { stop = true } // polling keeps reporting the error
                        if !(200..<300).contains(s) { throw URLError(.badServerResponse) }
                    case .bytes(let d):
                        for (event, data) in parser.feed(d) {
                            if event == "revision" { onRevision(data) } else if event == "revoked" {
                                stop = true
                                Task { await self.sync() }
                            }
                        }
                    }
                    if stop { break }
                }
            } catch {
                // reconnect below
            }
            if Task.isCancelled || isClosed { return }
            if stop {
                locked { streamTask = nil }
                return
            }
            attempt = Date().timeIntervalSince(startedAt) > 30 ? 0 : attempt + 1
            let wait = min(30, pow(2, Double(min(attempt, 5)))) * Double.random(in: 0.5...1.5)
            do { try await sleep(seconds: wait) } catch { return }
        }
    }

    func onRevision(_ data: String) {
        guard let m = try? JSValue.parse(data) else { return }
        let announcedChecksum = m.field("checksum").stringValue
        let announcedRevision = Int(m.field("revision").numberValue ?? 0)
        let behind: Bool = locked {
            guard let cur = snapshot else { return true }
            return (announcedRevision != cur.revision && announcedChecksum != cur.checksum) || statusValue != .ready
        }
        guard behind else { return }
        Task {
            // The stream reads the live revision, which is ahead of the edge's KV pointer for a moment after a
            // publish: a fetch right away can still answer 304 for the previous configuration. Try again a few
            // times (1, 2, 4, 8, 16 s …, about a minute: an edge isolate may keep the previous pointer for up to 60 s) until the announced configuration is served.
            for attempt in 0..<8 {
                if attempt > 0 {
                    do { try await sleep(seconds: min(16, pow(2, Double(attempt - 1)))) } catch { return }
                }
                if self.isClosed || self.locked({ self.paused }) { return }
                self.locked { self.streamTriggered = true }
                await self.sync()
                let done: Bool = self.locked {
                    guard let cur = self.snapshot else { return false }
                    return cur.checksum == announcedChecksum || cur.revision >= announcedRevision
                }
                if done { return }
            }
        }
    }
}

func isoNow() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return f.string(from: Date())
}
