import Foundation

/// The NanoFlags evaluation engine: a port of the TypeScript engine (`@nanoflags/engine`) that the
/// dashboard, the edge Worker and every SDK share.
///
/// Pure and deterministic: the same bundle, flag key and context always produce the same result,
/// including the bucket of percentage rollouts (MurmurHash3 x86 32-bit over the NFC-normalised UTF-8
/// bytes of "seed:identity"). Rules are data; no user code ever runs. The cross-language parity fixtures
/// (packages/engine/fixtures/parity.json) pin the behaviour, malformed configurations included.
public enum Engine {
    /// The engine version this module implements (ENGINE_VERSION of the TypeScript engine). Bundles whose
    /// `engine` is newer are refused by the SDK.
    public static let version = 1
}

/// Why an evaluation produced its value.
public enum Reason: String, Sendable, Codable, CaseIterable {
    case ruleMatch = "rule_match"
    case `default` = "default"
    case off = "off"
    case flagNotFound = "flag_not_found"
    case error = "error"
}

/// One line of the human-readable explanation of an evaluation.
public struct TraceStep: Sendable, Equatable, Codable {
    /// "config", "rule", "allocation" or "result".
    public let kind: String
    public let title: String
    public let detail: String
    /// Set for rule and allocation steps.
    public let matched: Bool?

    public init(kind: String, title: String, detail: String, matched: Bool? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.matched = matched
    }
}

/// The full outcome of `Engine.evaluate`, mirroring the TypeScript engine's Evaluation object.
public struct EngineResult: Sendable {
    public var flagKey: String
    /// The served value; `.undefined` when the configuration served nothing (a malformed flag without
    /// an `off` value, for example).
    public var value: JSValue
    public var reason: Reason
    /// Zero-based index of the matching rule.
    public var ruleIndex: Int?
    /// The matching rule's `id` (`.undefined` when it has none).
    public var ruleId: JSValue
    /// For rollout rules: whether the context fell inside the allocation, and its bucket (0–99.99).
    public var inRollout: Bool?
    public var bucket: Double?
    /// The bundle's `revision` (0 without a bundle).
    public var revision: JSValue
    public var trace: [TraceStep]
    /// The evaluation error message (reason `error` only).
    public var error: String?

    public init(flagKey: String, value: JSValue, reason: Reason, ruleIndex: Int? = nil, ruleId: JSValue = .undefined, inRollout: Bool? = nil,
                bucket: Double? = nil, revision: JSValue, trace: [TraceStep], error: String? = nil) {
        self.flagKey = flagKey
        self.value = value
        self.reason = reason
        self.ruleIndex = ruleIndex
        self.ruleId = ruleId
        self.inRollout = inRollout
        self.bucket = bucket
        self.revision = revision
        self.trace = trace
        self.error = error
    }
}

// MARK: - Hashing

extension Engine {
    /// `TextEncoder.encode(input.normalize("NFC"))`.
    static func hashInput(_ s: String) -> [UInt8] {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return Array(s.utf8) } // ASCII is always NFC
        return Array(s.precomposedStringWithCanonicalMapping.utf8)
    }

    /// MurmurHash3 x86 32-bit over the NFC-normalised UTF-8 bytes of `input`. Used for distribution only —
    /// never for security.
    public static func murmur3(_ input: String, seed: UInt32 = 0) -> UInt32 {
        let data = hashInput(input)
        let c1: UInt32 = 0xcc9e_2d51
        let c2: UInt32 = 0x1b87_3593
        var h = seed
        let n = data.count
        let blocks = n / 4
        for b in 0..<blocks {
            let o = b * 4
            var k = UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
            k = k &* c1
            k = k << 15 | k >> 17
            k = k &* c2
            h ^= k
            h = h << 13 | h >> 19
            h = h &* 5 &+ 0xe654_6b64
        }
        var k: UInt32 = 0
        let tail = blocks * 4
        let rest = n & 3
        if rest == 3 { k ^= UInt32(data[tail + 2]) << 16 }
        if rest >= 2 { k ^= UInt32(data[tail + 1]) << 8 }
        if rest >= 1 {
            k ^= UInt32(data[tail])
            k = k &* c1
            k = k << 15 | k >> 17
            k = k &* c2
            h ^= k
        }
        h ^= UInt32(truncatingIfNeeded: n)
        h ^= h >> 16
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    /// Bucket in [0, 100) with two decimals of resolution. Stable for a given seed + identity.
    public static func bucketOf(seed: String, identity: String) -> Double {
        Double(murmur3(seed + ":" + identity) % 10000) / 100
    }
}

// MARK: - Conditions

func looseEq(_ a: JSValue, _ b: JSValue) -> Bool {
    if a.isUndefined || b.isUndefined { return false }
    func isObject(_ v: JSValue) -> Bool {
        switch v {
        case .null, .array, .object: return true
        default: return false
        }
    }
    if isObject(a) || isObject(b) {
        let x = a.json, y = b.json
        switch (x, y) {
        case (nil, nil): return true
        case (let x?, let y?): return bytesEqual(x, y)
        default: return false
        }
    }
    return strictEq(a, b)
}

func strictEq(_ a: JSValue, _ b: JSValue) -> Bool {
    switch (a, b) {
    case (.undefined, .undefined), (.null, .null): return true
    case (.bool(let x), .bool(let y)): return x == y
    case (.number(let x), .number(let y)): return x == y
    case (.string(let x), .string(let y)): return bytesEqual(x, y)
    default: return false // objects compare by identity; looseEq never compares them this way
    }
}

func num(_ v: JSValue) -> Double? {
    switch v {
    case .number(let n) where n.isFinite: return n
    case .string(let s) where !jsTrim(s).isEmpty:
        let n = jsStringToNumber(s)
        return n.isFinite ? n : nil
    default: return nil
    }
}

/// Code-unit substring search. For well-formed strings, a UTF-16 code-unit match is a UTF-8 byte match.
func bytesContains(_ h: String, _ n: String) -> Bool {
    let hb = Array(h.utf8), nb = Array(n.utf8)
    if nb.isEmpty { return true }
    if nb.count > hb.count { return false }
    let first = nb[0]
    var i = 0
    let last = hb.count - nb.count
    while i <= last {
        if hb[i] == first {
            var j = 1
            while j < nb.count && hb[i + j] == nb[j] { j += 1 }
            if j == nb.count { return true }
        }
        i += 1
    }
    return false
}

func bytesHasPrefix(_ s: String, _ p: String) -> Bool {
    s.utf8.count >= p.utf8.count && s.utf8.prefix(p.utf8.count).elementsEqual(p.utf8)
}

func bytesHasSuffix(_ s: String, _ p: String) -> Bool {
    s.utf8.count >= p.utf8.count && s.utf8.suffix(p.utf8.count).elementsEqual(p.utf8)
}

extension Engine {
    static func lookup(_ ctx: JSValue, _ name: String) -> JSValue {
        if case .object(let o) = ctx { return o[name] ?? .undefined }
        return .undefined
    }

    /// The engine's matchCondition(c, ctx, segments, depth).
    static func matchCondition(_ c: JSValue, _ ctx: JSValue, _ segments: JSValue, _ depth: Int) throws -> Bool {
        let op = try c.get("op")
        if op.isString("segment") || op.isString("not_segment") {
            let value = c.getOrUndefined("value")
            var seg = JSValue.undefined
            if case .string(let s) = value { seg = own(segments, s) }
            var inSeg = false
            if !seg.isUndefined && depth < 4 {
                let match = try seg.get("match")
                let conds = seg.getOrUndefined("conditions")
                inSeg = try matchAll(match, conds, ctx, segments, depth + 1)
            }
            if op.isString("segment") { return inSeg }
            return !seg.isUndefined && !inSeg
        }
        let attribute = c.getOrUndefined("attribute")
        let actual = lookup(ctx, attribute.jsString)
        let value = c.getOrUndefined("value")
        guard case .string(let o) = op else { return false }
        switch o {
        case "exists": return !actual.isNullish
        case "not_exists": return actual.isNullish
        case "eq": return looseEq(actual, value)
        case "neq": return !actual.isUndefined && !looseEq(actual, value)
        case "in":
            guard case .array(let list) = value else { return false }
            return list.contains { looseEq(actual, $0) }
        case "not_in":
            guard !actual.isUndefined, case .array(let list) = value else { return false }
            return !list.contains { looseEq(actual, $0) }
        case "contains":
            if case .string(let a) = actual, case .string(let b) = value { return bytesContains(a, b) }
            return false
        case "starts_with":
            if case .string(let a) = actual, case .string(let b) = value { return bytesHasPrefix(a, b) }
            return false
        case "ends_with":
            if case .string(let a) = actual, case .string(let b) = value { return bytesHasSuffix(a, b) }
            return false
        case "gt", "gte", "lt", "lte":
            guard let a = num(actual), let b = num(value) else { return false }
            switch o {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        default:
            return false
        }
    }

    /// The engine's matchAll(mode, conditions, …), including its failure modes.
    static func matchAll(_ mode: JSValue, _ conditions: JSValue, _ ctx: JSValue, _ segments: JSValue, _ depth: Int) throws -> Bool {
        let length = try conditions.get("length")
        if case .number(let n) = length, n == 0 { return true }
        let any = mode.isString("any")
        guard case .array(let list) = conditions else {
            throw EngineError(message: "conditions.\(any ? "some" : "every") is not a function")
        }
        for c in list {
            let ok = try matchCondition(c, ctx, segments, depth)
            if any && ok { return true }
            if !any && !ok { return false }
        }
        return !any
    }

    static let opWords: [String: String] = [
        "eq": "=", "neq": "≠", "in": "in", "not_in": "not in", "contains": "contains", "starts_with": "starts with", "ends_with": "ends with",
        "gt": ">", "gte": "≥", "lt": "<", "lte": "≤", "exists": "exists", "not_exists": "does not exist", "segment": "in segment", "not_segment": "not in segment",
    ]

    static func describeCondition(_ c: JSValue) throws -> String {
        let value = try c.get("value")
        let v: String
        switch value {
        case .array(let a): v = jsJoin(a, ", ")
        case .undefined: v = ""
        default: v = value.jsString
        }
        let op = c.getOrUndefined("op")
        let key = op.jsString
        let word = opWords[key] ?? objectProtoStrings[key] ?? "undefined"
        if op.isString("segment") || op.isString("not_segment") { return word + " " + v }
        let attribute = c.getOrUndefined("attribute").jsString
        if op.isString("exists") || op.isString("not_exists") { return attribute + " " + word }
        return attribute + " " + word + " " + v
    }

    /// The engine's fmt(v): strings as they are, everything else as JSON.
    public static func fmt(_ v: JSValue) -> String {
        if case .string(let s) = v { return s }
        return v.json ?? "undefined"
    }
}

// MARK: - Evaluation

extension Engine {
    /// Evaluates one flag of `bundle` (a parsed bundle document; `.undefined` or `.null` means "no
    /// configuration loaded") for `context` (an object value). Never throws: on any problem it returns
    /// `fallback` with reason `flagNotFound` or `error`.
    public static func evaluate(bundle: JSValue, flagKey: String, context: JSValue, fallback: JSValue) -> EngineResult {
        var revision = JSValue.number(0)
        if !bundle.isNullish {
            let r = bundle.getOrUndefined("revision")
            if !r.isNullish { revision = r }
        }
        var res = EngineResult(flagKey: flagKey, value: .undefined, reason: .default, ruleIndex: nil, ruleId: .undefined,
                               inRollout: nil, bucket: nil, revision: revision, trace: [], error: nil)
        do {
            return try run(bundle: bundle, flagKey: flagKey, ctx: context, fallback: fallback, res: &res)
        } catch {
            let msg = (error as? EngineError)?.message ?? String(describing: error)
            res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(fallback), detail: "Evaluation error: \(msg). The application fallback applies."))
            return EngineResult(flagKey: flagKey, value: fallback, reason: .error, ruleIndex: nil, ruleId: .undefined, inRollout: nil,
                                bucket: nil, revision: revision, trace: res.trace, error: msg)
        }
    }

    private static func run(bundle: JSValue, flagKey: String, ctx: JSValue, fallback: JSValue, res: inout EngineResult) throws -> EngineResult {
        var flag = JSValue.undefined
        if !bundle.isNullish { flag = own(bundle.getOrUndefined("flags"), flagKey) }
        if !bundle.truthy || !flag.truthy {
            let detail = bundle.truthy ? "Flag is not in this configuration. The application fallback applies." : "No configuration is loaded. The application fallback applies."
            res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(fallback), detail: detail))
            res.value = fallback
            res.reason = .flagNotFound
            return res
        }
        res.trace.append(TraceStep(kind: "config", title: "Configuration loaded", detail: res.revision.jsNumber > 0 ? "r" + res.revision.jsString : "draft"))
        let enabled = try flag.get("enabled")
        if !enabled.truthy {
            let off = try flag.get("off")
            res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(off), detail: "Flag is disabled in this environment."))
            res.value = off
            res.reason = .off
            return res
        }
        let rules = try flag.get("rules")
        let segments = bundle.getOrUndefined("segments")
        var i = 0
        while true {
            let length = try rules.get("length")
            if !(Double(i) < length.jsNumber) { break }
            let rule = try rules.get(String(i))
            let match = try rule.get("match")
            let conditions = rule.getOrUndefined("conditions")
            let matched = try matchAll(match, conditions, ctx, segments, 0)
            let label = "Rule " + (i + 1 < 10 ? "0" : "") + String(i + 1)
            var summary = "all contexts"
            if conditions.getOrUndefined("length").truthy, case .array(let list) = conditions {
                let parts = try list.map { try describeCondition($0) }
                summary = parts.joined(separator: match.isString("any") ? " OR " : " AND ")
            }
            res.trace.append(TraceStep(kind: "rule", title: label + (matched ? " matched" : " did not match"), detail: summary, matched: matched))
            if !matched {
                i += 1
                continue
            }
            let serve = try rule.get("serve")
            let serveType = try serve.get("type")
            res.ruleIndex = i
            res.ruleId = try rule.get("id")
            res.reason = .ruleMatch
            if serveType.isString("fixed") {
                let value = try serve.get("value")
                res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(value), detail: label + " serves a fixed value."))
                res.value = value
                return res
            }
            let attrV = try serve.get("bucketBy")
            let attr = attrV.isNullish ? "key" : attrV.jsString
            let identity = lookup(ctx, attr)
            let otherwise = try serve.get("otherwise")
            if identity.isNullish || identity.isString("") {
                res.trace.append(TraceStep(kind: "allocation", title: "Allocation skipped", detail: "Context has no \"\(attr)\" to bucket by; treated as outside the allocation.", matched: false))
                res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(otherwise), detail: "Remaining eligible users."))
                res.value = otherwise
                res.inRollout = false
                return res
            }
            let seedV = try serve.get("seed")
            let seed = seedV.isNullish ? flagKey : seedV.jsString
            let raw = murmur3(seed + ":" + identity.jsString) % 10000
            let bucket = Double(raw) / 100
            let percentage = try serve.get("percentage")
            let inRollout = bucket < percentage.jsNumber
            let pct = percentage.jsString
            let fixed2 = String(raw / 100) + "." + (raw % 100 < 10 ? "0" : "") + String(raw % 100)
            res.trace.append(TraceStep(kind: "allocation", title: "Allocation evaluated", detail: "\(pct)% rollout · \(attr) \(inRollout ? "inside" : "outside") allocation (bucket \(fixed2))", matched: inRollout))
            let value = inRollout ? try serve.get("value") : otherwise
            res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(value), detail: inRollout ? "Inside the \(pct)% allocation." : "Remaining eligible users."))
            res.value = value
            res.inRollout = inRollout
            res.bucket = bucket
            return res
        }
        let def = try flag.get("default")
        res.trace.append(TraceStep(kind: "result", title: "Returned " + fmt(def), detail: "No rule matched. The flag default applies."))
        res.value = def
        res.reason = .default
        return res
    }

    /// True when this engine can evaluate a bundle whose `engine` member is `engine` (`.undefined` when the
    /// bundle has none): absent, or an integer between 1 and `Engine.version`.
    public static func supportsEngine(_ engine: JSValue) -> Bool {
        switch engine {
        case .undefined: return true
        case .number(let n): return n == n.rounded(.towardZero) && n >= 1 && n <= Double(version)
        default: return false
        }
    }
}

// MARK: - Client view and telemetry helpers

extension Engine {
    /// The engine's clientBundle(bundle): only client-exposed flags (`clientExposed === true`) and the
    /// segments they reference (directly or through other segments).
    public static func clientBundle(_ bundle: JSObject) -> JSObject {
        var flags = JSObjectBuilder()
        var exposed: [JSValue] = []
        if case .object(let f) = bundle["flags"] ?? .undefined {
            for (k, v) in f.entries where v.field("clientExposed").boolValue == true {
                flags.set(k, v)
                exposed.append(v)
            }
        }
        var pending: [String] = []
        func refs(_ conditions: JSValue) {
            guard case .array(let list) = conditions else { return }
            for c in list {
                let op = c.field("op")
                if op.isString("segment") || op.isString("not_segment"), case .string(let s) = c.field("value") { pending.append(s) }
            }
        }
        for f in exposed {
            if case .array(let rules) = f.field("rules") { for r in rules { refs(r.field("conditions")) } }
        }
        let segments = bundle["segments"] ?? .undefined
        var needed = Set<JSKey>()
        while let k = pending.popLast() {
            let seg = own(segments, k)
            if needed.contains(JSKey(k)) || seg.isUndefined { continue }
            needed.insert(JSKey(k))
            refs(seg.field("conditions"))
        }
        var segs = JSObjectBuilder()
        if case .object(let s) = segments {
            for (k, v) in s.entries where needed.contains(JSKey(k)) { segs.set(k, v) }
        }
        var out = JSObjectBuilder()
        for (k, v) in bundle.entries {
            if k == "flags" { out.set(k, .object(flags.build())) } else if k == "segments" { out.set(k, .object(segs.build())) } else { out.set(k, v) }
        }
        if bundle["flags"] == nil { out.set("flags", .object(flags.build())) }
        if bundle["segments"] == nil { out.set("segments", .object(segs.build())) }
        return out.build()
    }

    /// The context attributes that the rules of `flagKey` reference (through segments up to the engine's
    /// nesting limit) plus the bucketing attribute of rollouts. The SDK reports only these attribute names
    /// — never values — with sampled evaluation events. Nothing for a malformed flag.
    public static func attributesUsed(bundle: JSValue, flagKey: String) -> [String] {
        var names: [String] = []
        var seen = Set<JSKey>()
        func add(_ n: String) {
            if seen.insert(JSKey(n)).inserted { names.append(n) }
        }
        let segments = bundle.field("segments")
        func visit(_ conds: JSValue, _ depth: Int) -> Bool {
            guard case .array(let list) = conds else { return conds.stringValue != nil }
            for c in list {
                guard let op = try? c.get("op") else { return false }
                if op.isString("segment") || op.isString("not_segment") {
                    if case .string(let s) = c.getOrUndefined("value") {
                        let seg = own(segments, s)
                        if seg.truthy && depth < 4 {
                            guard let sc = try? seg.get("conditions"), visit(sc, depth + 1) else { return false }
                        }
                    }
                } else {
                    let attr = c.getOrUndefined("attribute")
                    if attr.truthy { add(attr.jsString) }
                }
            }
            return true
        }
        let flag = own(bundle.field("flags"), flagKey)
        guard case .array(let rules) = flag.getOrUndefined("rules") else { return [] }
        for r in rules {
            guard let conds = try? r.get("conditions"), visit(conds, 0) else { return [] }
            let serve = r.getOrUndefined("serve")
            guard let t = try? serve.get("type") else { return [] }
            if t.isString("rollout") {
                let by = serve.getOrUndefined("bucketBy")
                add(by.isNullish ? "key" : by.jsString)
            }
        }
        return names
    }
}
