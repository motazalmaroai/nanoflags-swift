import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sampled evaluations and the periodic service report (`POST /v1/events`). Off the hot path: an
/// evaluation only appends to a bounded array; telemetry is never retried and never affects evaluation.
struct EventQueue {
    static let maxQueue = 500
    static let maxBatch = 50
    static let maxValueChars = 1024

    var queue: [JSValue] = []
    var lastReport: Date?
}

extension NanoFlagsClient {
    var eventsEnabled: Bool { options.events.enabled && keyValid }

    func record(_ r: EngineResult, _ ctx: NanoFlagsContext, _ snap: Snapshot?) {
        let ev = options.events
        let rate = min(1, max(0, ev.sampleRate))
        guard eventsEnabled, rate > 0, ev.random() < rate else { return }
        let full = locked { closed || events.queue.count >= EventQueue.maxQueue }
        if full { return }
        var context: [String: JSONValue] = [:]
        if let redact = ev.redact {
            context = redact(ctx)
        } else if let snap {
            // No attribute values: only the names of the attributes the flag's rules use that were present,
            // mapped to the value's JSON type.
            for name in snap.attrs.names(snap.value, r.flagKey) {
                if let v = ctx[name] { context[name] = .string(v.typeName) }
            }
        }
        var b = JSObjectBuilder()
        b.set("flagKey", .string(r.flagKey))
        b.set("value", eventValue(r.value))
        b.set("reason", .string(r.reason.rawValue))
        if let i = r.ruleIndex { b.set("ruleIndex", .number(Double(i))) }
        let rev = r.revision.jsNumber
        b.set("revision", .number(rev.isFinite ? rev : 0))
        b.set("context", JSONValue.object(context).toJS())
        b.set("at", .string(isoNow()))
        b.set("sampleRate", .number(rate))
        let e = JSValue.object(b.build())
        locked { if events.queue.count < EventQueue.maxQueue { events.queue.append(e) } }
    }

    func eventValue(_ v: JSValue) -> JSValue {
        switch v {
        case .string(let s):
            if s.utf16.count > EventQueue.maxValueChars {
                return .string(String(decoding: Array(s.utf16.prefix(EventQueue.maxValueChars)), as: UTF16.self))
            }
            return v
        case .array, .object:
            guard let t = v.json, t.utf16.count <= EventQueue.maxValueChars else { return .null }
            return v
        case .undefined, .function:
            return .null
        default:
            return v
        }
    }

    /// Sends queued telemetry now (the service report plus up to one batch of events).
    public func flush() async {
        guard eventsEnabled else { return }
        let (batch, revision, low): ([JSValue], Int, Bool) = locked {
            let n = min(events.queue.count, EventQueue.maxBatch)
            let b = Array(events.queue.prefix(n))
            events.queue.removeFirst(n)
            events.lastReport = Date()
            return (b, snapshot?.revision ?? 0, lowData)
        }
        if low { return } // Low Data Mode: nothing leaves the device
        let trimmed: [JSValue] = batch.map { e in
            guard case .object(let o) = e, case .string(let k) = o["flagKey"] ?? .undefined, k.utf16.count > 63 else { return e }
            var b = JSObjectBuilder()
            for (key, v) in o.entries { b.set(key, key == "flagKey" ? .string(String(decoding: Array(k.utf16.prefix(63)), as: UTF16.self)) : v) }
            return .object(b.build())
        }
        var body = JSObjectBuilder()
        body.set("service", .string(service))
        body.set("sdk", .string("swift/\(nanoFlagsSDKVersion)"))
        body.set("revision", .number(Double(revision)))
        body.set("events", .array(trimmed))
        var req = request("/v1/events", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((JSValue.object(body.build()).json ?? "{}").utf8)
        _ = try? await net.send(req) // dropped on failure, by design
    }

    func startFlushLoop() {
        lock.lock()
        defer { lock.unlock() }
        let interval = options.events.flushInterval
        if closed || !eventsEnabled || interval <= 0 || flushTask != nil { return }
        flushTask = Task { [weak self] in
            while true {
                do { try await sleep(seconds: interval) } catch { return }
                guard let self, !self.isClosed else { return }
                let idle: Bool = self.locked {
                    if self.paused || self.lowData { return true }
                    // Nothing queued: the service report alone goes out once per report interval.
                    let sinceReport = self.events.lastReport.map { Date().timeIntervalSince($0) } ?? .infinity
                    return self.events.queue.isEmpty && sinceReport < self.options.events.reportInterval
                }
                if !idle { await self.flush() }
            }
        }
    }
}
