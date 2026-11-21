import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shadow evaluation of drafts (migration 0179; RUNTIME.md "Shadow evaluation of drafts"; same rules and wire format as
// the JS SDK's `src/shadow.ts`).
//
// While a change waits for approval in an environment whose admin turned shadow evaluation on, the edge announces a
// signed shadow bundle (`X-NanoFlags-Shadow` on `/v1/bundle`, the bundle itself on `/v1/shadow`). For a sample of the
// evaluations of the flags the draft changes, the client evaluates the draft as well and counts, per flag, how often
// the value would change. Only those counters leave the device, with the next `/v1/events` report:
//
//   { sessionId, checksum, version?, flags: [{ flag, samples, flips, pairs: [{ live, shadow, count }], rules: { "<i>" | "default": n } }] }
//
// No context, attribute, key or identifier is ever part of it. Values are the flag's own configured values as JSON
// text with object keys sorted, at most 100 characters (longer ones are replaced by a hash); a side that used the
// app's own default (flag missing there, evaluation error, wrong type) is reported as "<fallback>", never as the
// value. The shadow bundle is NEVER applied: the app always gets the live value, and the client refuses any bundle
// that carries a `shadow` member as configuration (`isBundle`). Client keys receive the client view of the draft
// (client-exposed flags only); the server counts their reports only for flags the draft exposes to clients.

enum ShadowWire {
    static let maxFlags = 100
    static let maxPairs = 10
    static let maxRules = 50
    static let maxValueChars = 100
    /// The edge accepts counts up to 10^7; a flag's counter stops there (the next report starts from zero again).
    static let maxCount = 10_000_000
    /// The edge accepts flag keys of 1–63 characters (UTF-16 code units) in a report.
    static let maxFlagKey = 63
    /// Shadow counters go out with the events report at most this often (and on `flush()`, `pause()` and `close()`).
    static let flushInterval: TimeInterval = 60
    /// A failed shadow fetch is not retried for the same announcement before this.
    static let retryInterval: TimeInterval = 60
    /// Reported instead of a value that did not come from a bundle: the application's own default.
    static let fallbackToken = "<fallback>"

    static func isHex(_ c: UInt8, upper: Bool) -> Bool {
        (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (upper && c >= 65 && c <= 70)
    }

    /// A UUID (any letter case).
    static func isUUID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 36 else { return false }
        for (i, c) in u.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return false }
            } else if !isHex(c, upper: true) {
                return false
            }
        }
        return true
    }

    static func isChecksum(_ s: String, upper: Bool = false) -> Bool {
        let u = Array(s.utf8)
        return u.count == 32 && u.allSatisfy { isHex($0, upper: upper) }
    }

    /// `X-NanoFlags-Shadow: <sessionId>.<checksum>` → its parts (lowercased), or nil.
    static func parseHeader(_ v: String?) -> (sessionId: String, checksum: String)? {
        guard let v else { return nil }
        let t = v.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let id = String(parts[0]), sum = String(parts[1])
        guard isUUID(id), isChecksum(sum, upper: true) else { return nil }
        return (id.lowercased(), sum.lowercased())
    }

    /// The `shadow` member of a signed shadow bundle: `{ sessionId, checksum, environmentId, baseRevision }`.
    static func isMarker(_ v: JSValue) -> Bool {
        guard case .object = v, case .string(let id) = v.field("sessionId"), isUUID(id),
              case .string(let sum) = v.field("checksum"), isChecksum(sum),
              case .string = v.field("environmentId"), case .number = v.field("baseRevision")
        else { return false }
        return true
    }

    /// The bundle shape plus its `shadow` marker (inside the signed bytes).
    static func isShadowBundle(_ v: JSValue) -> Bool {
        guard case .object(let o) = v, case .number(let schema) = o["schema"] ?? .undefined, schema == 1,
              case .number = o["revision"] ?? .undefined, case .object = o["flags"] ?? .undefined,
              case .object = o["segments"] ?? .undefined
        else { return false }
        return isMarker(o["shadow"] ?? .undefined)
    }

    /// JSON text with object keys sorted (UTF-16 order, like JavaScript's `sort()`), so two configurations compare
    /// equal whatever their key order.
    static func stableStringify(_ v: JSValue) -> String {
        var out = ""
        write(v, &out)
        return out
    }

    private static func write(_ v: JSValue, _ out: inout String) {
        switch v {
        case .object(let o):
            out += "{"
            var first = true
            for k in o.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                guard let x = o[k] else { continue }
                if case .undefined = x { continue }
                if case .function = x { continue }
                if !first { out += "," }
                first = false
                out += jsonQuote(k)
                out += ":"
                write(x, &out)
            }
            out += "}"
        case .array(let a):
            out += "["
            for (i, x) in a.enumerated() {
                if i > 0 { out += "," }
                write(x, &out)
            }
            out += "]"
        default:
            out += v.json ?? "null"
        }
    }

    /// A value as it is reported: canonical JSON text, at most 100 characters (longer: `#<murmur3 hex>`).
    static func reprValue(_ v: JSValue) -> String {
        let text = stableStringify(v)
        if text.utf16.count <= maxValueChars { return text }
        let h = String(Engine.murmur3(text), radix: 16)
        return "#" + String(repeating: "0", count: max(0, 8 - h.count)) + h
    }

    private static func object(_ v: JSValue) -> JSObject {
        if case .object(let o) = v { return o }
        return JSObject.empty
    }

    /// Segment keys a list of conditions references directly (segment / not_segment).
    private static func conditionRefs(_ conditions: JSValue) -> [String] {
        guard case .array(let list) = conditions else { return [] }
        var out: [String] = []
        for c in list {
            guard case .string(let op) = c.field("op"), op == "segment" || op == "not_segment", case .string(let s) = c.field("value") else { continue }
            out.append(s)
        }
        return out
    }

    /// Segment keys a flag's rules reference directly.
    private static func segmentRefs(_ flag: JSValue) -> [String] {
        guard case .array(let rules) = flag.field("rules") else { return [] }
        return rules.flatMap { conditionRefs($0.field("conditions")) }
    }

    /// Segments whose evaluation can differ between the live and the shadow bundle: the definition differs (new, edited
    /// or removed in the draft), or one of its conditions references such a segment, transitively (to a fixpoint).
    /// Same rule as the database (`app.shadow_changed_segments`).
    static func changedSegments(live: JSValue, shadow: JSValue) -> Set<String> {
        let ls = object(live.field("segments"))
        let ss = object(shadow.field("segments"))
        var changed = Set<String>()
        for k in ss.keys {
            if let l = ls[k], let s = ss[k], stableStringify(l) == stableStringify(s) { continue }
            changed.insert(k)
        }
        for k in ls.keys where ss[k] == nil { changed.insert(k) }
        var grew = true
        while grew {
            grew = false
            for k in ss.keys where !changed.contains(k) {
                if conditionRefs((ss[k] ?? .undefined).field("conditions")).contains(where: { changed.contains($0) }) {
                    changed.insert(k)
                    grew = true
                }
            }
        }
        return changed
    }

    /// Keys of the shadow bundle's flags that the draft changes: a different configuration, or a referenced segment
    /// that differs. Same rule as the database (`app.shadow_flags`).
    static func changedFlags(live: JSValue, shadow: JSValue) -> Set<String> {
        let segs = changedSegments(live: live, shadow: shadow)
        let lf = object(live.field("flags"))
        let sf = object(shadow.field("flags"))
        var out = Set<String>()
        for k in sf.keys {
            let s = sf[k] ?? .undefined
            if let l = lf[k], stableStringify(l) == stableStringify(s), !segmentRefs(s).contains(where: { segs.contains($0) }) { continue }
            out.insert(k)
        }
        return out
    }
}

/// In-memory counters of one shadow session. Bounded: 100 flags × (10 value pairs + 50 rule counters). Not
/// thread-safe: the client guards it with its lock.
final class ShadowCounters {
    private final class Pair {
        let live: String
        let shadow: String
        var count = 0
        init(_ live: String, _ shadow: String) {
            self.live = live
            self.shadow = shadow
        }
    }

    private final class Counter {
        var samples = 0
        var flips = 0
        var pairOrder: [String] = []
        var pairs: [String: Pair] = [:]
        var ruleOrder: [String] = []
        var rules: [String: Int] = [:]
    }

    let sessionId: String
    let checksum: String
    /// Samples per flag before its counter stops (`ShadowWire.maxCount`; lower only in tests).
    private let maxCount: Int
    private var order: [String] = []
    private var flags: [String: Counter] = [:]

    init(sessionId: String, checksum: String, maxCount: Int = ShadowWire.maxCount) {
        self.sessionId = sessionId
        self.checksum = checksum
        self.maxCount = maxCount
    }

    var count: Int { order.count }

    /// One sampled evaluation: the value the app got, what the draft would give, and which draft rule matched. A
    /// side whose value is the app's default (`liveFallback` / `shadowFallback`) is reported as "<fallback>".
    func add(_ flag: String, live: JSValue, shadow: JSValue, ruleIndex: Int?, liveFallback: Bool = false, shadowFallback: Bool = false) {
        // The edge refuses the whole report (400) over one flag key outside 1–63 characters (UTF-16, as JS counts).
        let keyLength = flag.utf16.count
        if keyLength == 0 || keyLength > ShadowWire.maxFlagKey { return }
        let c: Counter
        if let x = flags[flag] {
            c = x
        } else {
            if order.count >= ShadowWire.maxFlags { return }
            c = Counter()
            flags[flag] = c
            order.append(flag)
        }
        // Every count of a flag (flips, pair and rule counters) is ≤ samples, so stopping samples keeps them all ≤ 10^7.
        if c.samples >= maxCount { return }
        c.samples += 1
        let rk: String
        if let i = ruleIndex, i >= 0, i < 10_000 { rk = String(i) } else { rk = "default" }
        if let n = c.rules[rk] {
            c.rules[rk] = n + 1
        } else if c.ruleOrder.count < ShadowWire.maxRules {
            c.rules[rk] = 1
            c.ruleOrder.append(rk)
        }
        if ShadowWire.stableStringify(live) == ShadowWire.stableStringify(shadow) { return }
        let a = liveFallback ? ShadowWire.fallbackToken : ShadowWire.reprValue(live)
        let b = shadowFallback ? ShadowWire.fallbackToken : ShadowWire.reprValue(shadow)
        c.flips += 1
        var key = a + "\u{0}" + b
        if c.pairs[key] == nil && c.pairOrder.count >= ShadowWire.maxPairs - 1 { key = "*\u{0}*" }
        let p: Pair
        if let x = c.pairs[key] {
            p = x
        } else {
            p = key == "*\u{0}*" ? Pair("*", "*") : Pair(a, b)
            c.pairs[key] = p
            c.pairOrder.append(key)
        }
        p.count += 1
    }

    func report(version: String?) -> JSValue {
        var list: [JSValue] = []
        for flag in order {
            guard let c = flags[flag] else { continue }
            var f = JSObjectBuilder()
            f.set("flag", .string(flag))
            f.set("samples", .number(Double(c.samples)))
            f.set("flips", .number(Double(c.flips)))
            f.set("pairs", .array(c.pairOrder.compactMap { (k: String) -> JSValue? in
                guard let p = c.pairs[k] else { return nil }
                var o = JSObjectBuilder()
                o.set("live", .string(p.live))
                o.set("shadow", .string(p.shadow))
                o.set("count", .number(Double(p.count)))
                return .object(o.build())
            }))
            var rules = JSObjectBuilder()
            for k in c.ruleOrder { rules.set(k, .number(Double(c.rules[k] ?? 0))) }
            f.set("rules", .object(rules.build()))
            list.append(.object(f.build()))
        }
        var b = JSObjectBuilder()
        b.set("sessionId", .string(sessionId))
        b.set("checksum", .string(checksum))
        if let version { b.set("version", .string(version)) }
        b.set("flags", .array(list))
        return .object(b.build())
    }
}

/// The verified shadow bundle in use and the flags it changes compared with the live bundle (recomputed per live bundle).
final class ShadowState {
    let bundle: JSValue
    let sessionId: String
    let checksum: String
    var liveID: ObjectIdentifier?
    var changed: Set<String> = []

    init(bundle: JSValue, sessionId: String, checksum: String) {
        self.bundle = bundle
        self.sessionId = sessionId
        self.checksum = checksum
    }
}

extension NanoFlagsClient {
    var shadowEnabled: Bool { options.shadow.enabled && eventsEnabled }

    /// Takes the pending shadow report: when `force`, or when the last one went out at least a minute ago. Must be
    /// called with the lock held. Counters restart.
    func lockedTakeShadowReport(force: Bool) -> JSValue? {
        guard let c = shadowCounters, c.count > 0 else { return nil }
        if !force && Date().timeIntervalSince(shadowFlushedAt) < ShadowWire.flushInterval { return nil }
        shadowCounters = ShadowCounters(sessionId: c.sessionId, checksum: c.checksum)
        shadowFlushedAt = Date()
        return c.report(version: serviceVersion)
    }

    /// Whether counters are due with the next timer flush. Must be called with the lock held.
    var lockedShadowDue: Bool {
        (shadowCounters?.count ?? 0) > 0 && Date().timeIntervalSince(shadowFlushedAt) >= ShadowWire.flushInterval
    }

    /// Sends the pending counters now (the session they belong to ends).
    func sendPendingShadow() {
        guard let report = locked({ lockedTakeShadowReport(force: true) }) else { return }
        Task { await self.flush(shadowNow: false, shadowReport: report) }
    }

    func dropShadow() {
        sendPendingShadow()
        locked {
            shadowState = nil
            shadowCounters = nil
        }
    }

    /// `X-NanoFlags-Shadow` of a fresh `/v1/bundle` answer (200 or 304): fetch the announced shadow bundle, or drop
    /// the one in use.
    func noteShadow(_ header: String?) {
        guard shadowEnabled, !isClosed else { return }
        guard let want = ShadowWire.parseHeader(header) else { return dropShadow() }
        let id = "\(want.sessionId).\(want.checksum)"
        let start: Bool = locked {
            if let st = shadowState, st.sessionId == want.sessionId, st.checksum == want.checksum { return false }
            if let f = shadowFetch, f.id == id, f.running || Date().timeIntervalSince(f.at) < ShadowWire.retryInterval { return false }
            shadowFetch = (id, Date(), true)
            return true
        }
        guard start else { return }
        Task {
            await self.fetchShadow(sessionId: want.sessionId, checksum: want.checksum)
            self.locked {
                if let f = self.shadowFetch, f.id == id { self.shadowFetch = (id, Date(), false) }
            }
        }
    }

    /// Keys a shadow bundle is checked with: the configured ones, or (verification off for this edge) `/v1/keys`.
    func shadowKeys(for kid: String?) async throws -> [ImportedKey] {
        if let ring = keyRing { return try await ring.keys(for: kid) }
        let ring: KeyRing = locked {
            if let r = shadowKeyRing { return r }
            let box = WeakClient()
            box.client = self
            let r = KeyRing(base: [], require: false, refetch: true, fetchKeys: {
                guard let c = box.client else { throw CancellationError() }
                return try await c.fetchSigningKeys()
            })
            shadowKeyRing = r
            return r
        }
        return try await ring.keys(for: kid)
    }

    /// Loads and verifies a shadow bundle. Only a bundle signed for this session, with a matching marker inside, is used.
    func fetchShadow(sessionId: String, checksum: String) async {
        func reject(_ why: String) {
            emitError(NanoFlagsError(.shadow, "The shadow bundle of session \(sessionId) was ignored: \(why) Nothing changes for the app (shadow bundles are never applied)."))
        }
        var req = request("/v1/shadow")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let res = try? await net.send(req) else { return }
        if isClosed { return }
        if res.status == 404 { return dropShadow() }
        guard (200..<300).contains(res.status), let body = try? JSValue.parse(res.body) else { return }
        // Already replaced by a newer session: the next bundle answer announces that one.
        guard body.field("sessionId").isString(sessionId), body.field("checksum").isString(checksum) else { return }
        guard let raw = rawMember(res.body, "bundle"), let signature = res.header("x-nanoflags-signature"),
              let environmentId = res.header("x-nanoflags-environment-id"), !signature.isEmpty, !environmentId.isEmpty
        else { return reject("it is not signed.") }
        if let pinned = locked({ pinnedEnvironment }), pinned != environmentId { return reject("it was signed for a different environment.") }
        let kid = res.header("x-nanoflags-key-id")
        let keys = (try? await shadowKeys(for: kid)) ?? []
        if isClosed { return }
        guard verifyShadowText(keys: keys, signature: signature, kid: kid, environmentId: environmentId, sessionId: sessionId, checksum: checksum, bundleText: raw) else {
            return reject("its signature does not verify.")
        }
        guard let parsed = try? JSValue.parse(raw), ShadowWire.isShadowBundle(parsed) else { return reject("it is not a shadow bundle.") }
        let m = parsed.field("shadow")
        guard m.field("sessionId").isString(sessionId), m.field("checksum").isString(checksum), m.field("environmentId").isString(environmentId) else {
            return reject("its shadow marker does not match.")
        }
        guard Engine.supportsEngine(parsed.field("engine")) else { return }
        sendPendingShadow()
        locked {
            shadowState = ShadowState(bundle: parsed, sessionId: sessionId, checksum: checksum)
            shadowCounters = ShadowCounters(sessionId: sessionId, checksum: checksum)
        }
    }

    /// After a live evaluation: for a sample of the flags the draft changes, evaluate the draft too and count.
    func shadowEvaluate(_ key: String, fallback: JSValue, context: JSValue, accepts: (JSValue) -> Bool, live: EngineResult, liveSnapshot: Snapshot) {
        let rate = options.shadow.sampleRate.isFinite ? min(1, max(0, options.shadow.sampleRate)) : 0.1
        guard rate > 0 else { return }
        let liveID = ObjectIdentifier(liveSnapshot.attrs)
        let st: ShadowState? = locked {
            guard let st = shadowState else { return nil }
            if st.liveID != liveID {
                st.liveID = liveID
                st.changed = ShadowWire.changedFlags(live: liveSnapshot.value, shadow: st.bundle)
            }
            return st.changed.contains(key) ? st : nil
        }
        guard let st, options.shadow.random() < rate else { return }
        let r = Engine.evaluate(bundle: st.bundle, flagKey: key, context: context, fallback: fallback)
        // A side that used the app's own default is reported as "<fallback>" (flag missing on that side, evaluation
        // error, or a value of the wrong type, which evaluate() already turned into an error).
        let liveFallback = live.reason == .flagNotFound || live.reason == .error
        let shadowFallback = r.reason == .flagNotFound || r.reason == .error || !accepts(r.value)
        locked {
            guard shadowState === st else { return }
            shadowCounters?.add(key, live: live.value, shadow: shadowFallback ? fallback : r.value,
                                ruleIndex: r.reason == .ruleMatch ? r.ruleIndex : nil, liveFallback: liveFallback, shadowFallback: shadowFallback)
        }
    }
}
