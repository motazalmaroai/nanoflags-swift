import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NanoFlags

// Shadow evaluation of drafts (migration 0179): the draft of a change waiting for approval is evaluated next to the
// live bundle for a sample of evaluations; only counters leave the device; the shadow bundle is never applied. Same
// cases as the JS SDK's test/shadow.test.ts.

private let session = "6f1c2a4e-8b1d-4c3e-9f00-1234567890ab"
private let draftSum = "0123456789abcdef0123456789abcdef"

final class ShadowTests: XCTestCase {
    /// The draft: new-checkout is on by default (live: off by default, on for plan "pro"). Everything else as live.
    func draft(_ edge: FakeEdge) -> String {
        edge.locked { edge.bundleText }.replacingOccurrences(of: "\"default\":false,\"off\":false,\"rules\":[{\"id\":\"pro\"", with: "\"default\":true,\"off\":false,\"rules\":[{\"id\":\"pro\"")
    }

    func makeEdge() -> FakeEdge {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        return edge
    }

    func announce(_ edge: FakeEdge, checksum: String = draftSum, _ answer: HTTPResponse? = nil) {
        let a = answer ?? edge.shadowResponse(bundle: draft(edge), sessionId: session, checksum: checksum)
        edge.locked {
            edge.shadowHeader = "\(session).\(checksum)"
            edge.shadowAnswer = a
        }
    }

    func client(_ edge: FakeEdge, _ configure: (inout NanoFlagsOptions) -> Void = { _ in }) -> NanoFlagsClient {
        NanoFlagsClient.test(edge: edge) { o in
            o.transport = .polling
            o.pollInterval = 0
            o.service = "checkout-service"
            o.serviceVersion = "3.1.0"
            o.events = EventsOptions(enabled: true, sampleRate: 0, flushInterval: 3600)
            o.shadow = ShadowOptions(sampleRate: 1)
            configure(&o)
        }
    }

    func free(_ i: Int = 0) -> NanoFlagsContext { ["key": .string("u\(i)"), "plan": "free", "email": .string("person\(i)@example.test"), "region": "DE"] }
    let pro: NanoFlagsContext = ["key": "u", "plan": "pro"]

    func active(_ c: NanoFlagsClient) -> Bool { c.locked { c.shadowState != nil } }
    func activeChecksum(_ c: NanoFlagsClient) -> String? { c.locked { c.shadowState?.checksum } }

    func flagsOf(_ report: JSONValue?) -> [JSONValue] { report?["flags"]?.arrayValue ?? [] }

    func testEvaluatesTheDraftNeverAppliesItAndReportsOnlyCounters() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge)
        defer { c.close() }
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        XCTAssertEqual(edge.shadowRequests, 1)

        // Zero behaviour change: the app always gets the live value.
        for i in 0..<30 { XCTAssertFalse(c.boolVariation(key: "new-checkout", default: true, context: free(i))) }
        for _ in 0..<10 { XCTAssertTrue(c.boolVariation(key: "new-checkout", default: false, context: pro)) }
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 3) // unchanged flag: not shadowed
        XCTAssertEqual(c.revision, 1)
        XCTAssertTrue(errors.items.isEmpty)

        await c.flush()
        let report = try XCTUnwrap(edge.lastShadowReport)
        XCTAssertEqual(report, try JSONValue(jsonText: """
        {"sessionId":"\(session)","checksum":"\(draftSum)","version":"3.1.0","flags":[{"flag":"new-checkout","samples":40,"flips":30,"pairs":[{"live":"false","shadow":"true","count":30}],"rules":{"0":10,"default":30}}]}
        """))
        // No context, attribute or identifier leaves the device with the shadow report.
        let text = report.jsonString
        for s in ["example.test", "person", "u1", "plan", "free", "region", "DE", "email"] { XCTAssertFalse(text.contains(s), s) }

        // Counters restart after a report: the next flush carries no shadow member.
        await c.flush()
        XCTAssertNil(edge.lastShadowReport)
    }

    func testSamplesAtTheConfiguredRateAndOnlyTheFlagsTheDraftChanges() async throws {
        let edge = makeEdge()
        announce(edge)
        let draws = Collector<Int>()
        let c = client(edge) { o in
            o.shadow.sampleRate = 0.25
            o.shadow.random = { draws.add(1); return Double((draws.items.count - 1) % 4) / 4 }
        }
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        for _ in 0..<100 { _ = c.boolVariation(key: "new-checkout", default: false, context: free()) }
        for _ in 0..<50 { _ = c.intVariation(key: "limit", default: 0) }
        XCTAssertEqual(draws.items.count, 100) // unchanged flags never draw
        await c.flush()
        XCTAssertEqual(flagsOf(edge.lastShadowReport), [try JSONValue(jsonText: """
        {"flag":"new-checkout","samples":25,"flips":25,"pairs":[{"live":"false","shadow":"true","count":25}],"rules":{"default":25}}
        """)])
    }

    func testATamperedShadowBundleIsIgnored() async throws {
        let edge = makeEdge()
        announce(edge, edge.shadowResponse(bundle: draft(edge), sessionId: session, checksum: draftSum, tamper: {
            $0.replacingOccurrences(of: "\"default\":true", with: "\"default\":\"evil\"")
        }))
        let c = client(edge)
        defer { c.close() }
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }
        _ = await c.ready(timeout: 5)
        await assertEventually({ !errors.items.isEmpty })
        for _ in 0..<5 { XCTAssertFalse(c.boolVariation(key: "new-checkout", default: true, context: free())) }
        await c.flush()
        XCTAssertNil(edge.lastShadowReport)
        XCTAssertEqual(errors.items.map(\.code), [.shadow])
        XCTAssertEqual(c.revision, 1)
    }

    func testRejectsForgedOrMismatchedShadowBundles() async throws {
        let otherEnv = "6f0c7c1e-0000-4000-8000-000000000999"
        let cases: [(String, (FakeEdge, String) -> HTTPResponse)] = [
            ("signed by an unknown key", { e, d in e.shadowResponse(bundle: d, sessionId: session, checksum: draftSum, key: Curve25519.Signing.PrivateKey()) }),
            ("signed as a normal bundle", { e, d in e.shadowResponse(bundle: d, sessionId: session, checksum: draftSum, bundleDomain: true) }),
            ("marker of another session", { e, d in e.shadowResponse(bundle: d, sessionId: session, checksum: draftSum, markerSession: "11111111-2222-4333-8444-555555555555") }),
            ("marker of another environment", { e, d in e.shadowResponse(bundle: d, sessionId: session, checksum: draftSum, markerEnv: otherEnv) }),
            ("signed for another environment", { e, d in e.shadowResponse(bundle: d, sessionId: session, checksum: draftSum, markerEnv: otherEnv, env: otherEnv) }),
        ]
        for (name, make) in cases {
            let edge = makeEdge()
            announce(edge, make(edge, draft(edge)))
            let c = client(edge)
            let errors = Collector<NanoFlagsError>()
            c.onError { errors.add($0) }
            _ = await c.ready(timeout: 5)
            await assertEventually({ !errors.items.isEmpty })
            _ = c.boolVariation(key: "new-checkout", default: true, context: free())
            await c.flush()
            XCTAssertNil(edge.lastShadowReport, name)
            XCTAssertEqual(errors.items.map(\.code), [.shadow], name)
            c.close()
        }
    }

    func testAShadowBundleIsNeverAppliedAsConfiguration() async throws {
        let edge = makeEdge()
        let c = client(edge)
        defer { c.close() }
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }
        _ = await c.ready(timeout: 5)
        XCTAssertEqual(c.revision, 1)
        // An attacker (or a bug) serves the shadow bundle on /v1/bundle with a valid bundle signature over its bytes.
        edge.publish(flags: #"{"new-checkout":{"type":"boolean","enabled":true,"clientExposed":true,"default":true,"off":false,"rules":[]}}"#)
        edge.locked {
            edge.bundleText = String(edge.bundleText.dropLast()) + #","shadow":{"sessionId":"\#(session)","checksum":"\#(draftSum)","environmentId":"\#(edge.environmentId)","baseRevision":1}}"#
        }
        await c.refresh()
        XCTAssertEqual(c.revision, 1)
        XCTAssertFalse(c.boolVariation(key: "new-checkout", default: true, context: free()))
        XCTAssertEqual(errors.items.last?.code, .invalidBundle)
        // Nor as a bootstrap.
        let shadowText = edge.locked { edge.bundleText }
        edge.locked { edge.offline = true }
        let boot = NanoFlagsClient.test(edge: edge) { o in
            o.transport = .polling
            o.bootstrap = Data(shadowText.utf8)
        }
        defer { boot.close() }
        XCTAssertNil(boot.revision)
        XCTAssertFalse(isBundle(try JSValue.parse(shadowText)))
    }

    func testIsWithdrawnWhenTheEdgeStopsAnnouncingItPendingCountersGoFirst() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge)
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        edge.locked { edge.shadowHeader = nil }
        await c.refresh() // 304 without the header
        await assertEventually({ edge.lastShadowReport != nil })
        await assertEventually({ !self.active(c) })
        XCTAssertEqual(flagsOf(edge.lastShadowReport).first?["samples"], 1)
        let before = edge.locked { edge.eventBodies.count }
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        await c.flush()
        XCTAssertEqual(edge.locked { edge.eventBodies.count }, before + 1)
        XCTAssertNil(edge.lastShadowReport)
    }

    func testA404FromTheShadowEndpointDropsTheSession() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge)
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        edge.locked {
            edge.shadowHeader = "\(session).\(String(repeating: "f", count: 32))"
            edge.shadowAnswer = nil
        }
        await c.refresh()
        await assertEventually({ !self.active(c) })
    }

    func testANewDraftReplacesTheSessionTheOldCountersGoOutFirst() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge)
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        let next = String(repeating: "f", count: 32)
        announce(edge, checksum: next)
        await c.refresh()
        await assertEventually({ edge.lastShadowReport != nil })
        XCTAssertEqual(edge.lastShadowReport?["checksum"], .string(draftSum))
        await assertEventually({ self.activeChecksum(c) == next })
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        await c.flush()
        XCTAssertEqual(edge.lastShadowReport?["checksum"], .string(next))
        XCTAssertEqual(flagsOf(edge.lastShadowReport).first?["samples"], 1)
    }

    func testCountersRideWithTimerFlushesAtMostOnceAMinute() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge) { o in o.events = EventsOptions(enabled: true, sampleRate: 1, flushInterval: 0.02) }
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        await assertEventually({ edge.locked { !edge.eventBodies.isEmpty } })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(edge.locked { edge.eventBodies.allSatisfy { $0["shadow"] == nil } })
        await c.flush()
        XCTAssertEqual(flagsOf(edge.lastShadowReport).first?["samples"], 1)
    }

    func testPauseSendsPendingCounters() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge)
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        c.pause() // the app goes to the background
        await assertEventually({ edge.locked { edge.eventBodies.contains { $0["shadow"] != nil } } })
    }

    func testShadowOffOrEventsOffNeverFetchTheShadowBundle() async throws {
        let configs: [(inout NanoFlagsOptions) -> Void] = [{ $0.shadow = .disabled }, { $0.events = .disabled }]
        for configure in configs {
            let edge = makeEdge()
            announce(edge)
            let c = client(edge, configure)
            _ = await c.ready(timeout: 5)
            await c.refresh()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(edge.shadowRequests, 0)
            XCTAssertFalse(active(c))
            c.close()
        }
    }

    func testWithoutVerificationTheShadowBundleIsStillCheckedWithV1Keys() async throws {
        let edge = makeEdge()
        announce(edge)
        let c = client(edge) { $0.verify = .disabled }
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        XCTAssertEqual(edge.keysRequests, 1)
        _ = c.boolVariation(key: "new-checkout", default: false, context: free())
        await c.flush()
        XCTAssertEqual(flagsOf(edge.lastShadowReport).first?["samples"], 1)
        // The SDK key is never sent to the public keys endpoint.
        let keysReq = try XCTUnwrap(edge.locked { edge.requests.last { $0.url?.path == "/v1/keys" } })
        XCTAssertNil(keysReq.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheAppsOwnDefaultNeverLeavesTheDevice() async throws {
        let edge = makeEdge()
        // A flag only in the draft, and a flag whose draft value has the wrong type.
        let text = draft(edge)
            .replacingOccurrences(of: "\"flags\":{", with: "\"flags\":{\"brand-new\":{\"type\":\"string\",\"enabled\":true,\"clientExposed\":true,\"default\":\"x\",\"off\":\"off\",\"rules\":[]},")
            .replacingOccurrences(of: "\"default\":3,", with: "\"default\":\"three\",")
        announce(edge, edge.shadowResponse(bundle: text, sessionId: session, checksum: draftSum))
        let c = client(edge)
        defer { c.close() }
        _ = await c.ready(timeout: 5)
        await assertEventually({ self.active(c) })
        XCTAssertEqual(c.stringVariation(key: "brand-new", default: "alice@example.test"), "alice@example.test")
        XCTAssertEqual(c.numberVariation(key: "limit", default: 42.5), 3)
        await c.flush()
        let report = try XCTUnwrap(edge.lastShadowReport)
        XCTAssertFalse(report.jsonString.contains("example.test"))
        XCTAssertFalse(report.jsonString.contains("42.5"))
        let flags = Dictionary(uniqueKeysWithValues: flagsOf(report).map { ($0["flag"]?.stringValue ?? "", $0) })
        XCTAssertEqual(flags["brand-new"]?["pairs"], try JSONValue(jsonText: #"[{"live":"<fallback>","shadow":"\"x\"","count":1}]"#))
        XCTAssertEqual(flags["limit"]?["pairs"], try JSONValue(jsonText: #"[{"live":"3","shadow":"<fallback>","count":1}]"#))
    }

    // MARK: - Helpers

    func testParsesTheAnnouncementHeader() {
        XCTAssertEqual(ShadowWire.parseHeader("\(session).\(draftSum)")?.sessionId, session)
        XCTAssertEqual(ShadowWire.parseHeader(" \(session.uppercased()).\(draftSum.uppercased()) ")?.checksum, draftSum)
        for bad in [nil, "", "x.y", session, "\(session).\(draftSum)x", "not-a-uuid-not-a-uuid-not-a-uuid-xxx.\(draftSum)"] as [String?] {
            XCTAssertNil(ShadowWire.parseHeader(bad), bad ?? "nil")
        }
    }

    func parse(_ s: String) -> JSValue { try! JSValue.parse(s) }

    func testChangedFlagsConfigurationDifferencesAndChangedSegmentsWhateverTheKeyOrder() {
        let edge = makeEdge()
        let liveText = edge.locked { edge.bundleText }
        let live = parse(liveText)
        XCTAssertEqual(ShadowWire.changedFlags(live: live, shadow: live), [])
        let reordered = parse(liveText.replacingOccurrences(of: "\"type\":\"number\",\"enabled\":true", with: "\"enabled\":true,\"type\":\"number\""))
        XCTAssertEqual(ShadowWire.changedFlags(live: live, shadow: reordered), [])
        XCTAssertEqual(ShadowWire.changedFlags(live: live, shadow: parse(draft(edge))), ["new-checkout"])
        let added = parse(liveText.replacingOccurrences(of: "\"flags\":{", with: "\"flags\":{\"brand_new\":{\"type\":\"boolean\",\"enabled\":true,\"default\":true,\"off\":false,\"rules\":[]},"))
        XCTAssertEqual(ShadowWire.changedFlags(live: live, shadow: added), ["brand_new"])
    }

    func testChangedFlagsSegmentsInsideSegmentsAndRemovedSegmentsCount() {
        func flag(_ op: String, _ v: String) -> String {
            #"{"type":"boolean","enabled":true,"default":false,"off":false,"rules":[{"id":"r","match":"all","conditions":[{"attribute":"","op":"\#(op)","value":"\#(v)"}],"serve":{"type":"fixed","value":true}}]}"#
        }
        let g = #"{"type":"boolean","enabled":true,"default":false,"off":false,"rules":[]}"#
        func bundle(_ flags: String, _ segments: String) -> JSValue {
            parse(#"{"schema":1,"project":"p","environment":"e","revision":1,"flags":\#(flags),"segments":\#(segments)}"#)
        }
        func nested(_ v: Int) -> JSValue {
            bundle(#"{"f":\#(flag("segment", "a")),"g":\#(g)}"#, #"{"a":{"match":"all","conditions":[{"attribute":"","op":"segment","value":"b"}]},"b":{"match":"all","conditions":[{"attribute":"x","op":"eq","value":\#(v)}]}}"#)
        }
        XCTAssertEqual(ShadowWire.changedFlags(live: nested(1), shadow: nested(2)), ["f"])
        XCTAssertEqual(ShadowWire.changedFlags(live: nested(1), shadow: nested(1)), [])
        let withC = bundle(#"{"f":\#(flag("not_segment", "a")),"g":\#(g)}"#, #"{"a":{"match":"any","conditions":[{"attribute":"","op":"segment","value":"c"}]},"c":{"match":"all","conditions":[]}}"#)
        let withoutC = bundle(#"{"f":\#(flag("not_segment", "a")),"g":\#(g)}"#, #"{"a":{"match":"any","conditions":[{"attribute":"","op":"segment","value":"c"}]}}"#)
        XCTAssertEqual(ShadowWire.changedFlags(live: withC, shadow: withoutC), ["f"])
        // A cycle terminates.
        func cyc(_ extra: Bool) -> JSValue {
            let x = extra ? #",{"attribute":"x","op":"eq","value":1}"# : ""
            return bundle(#"{"f":\#(flag("segment", "a")),"g":\#(g)}"#, #"{"a":{"match":"all","conditions":[{"attribute":"","op":"segment","value":"b"}]},"b":{"match":"all","conditions":[{"attribute":"","op":"segment","value":"a"}\#(x)]}}"#)
        }
        XCTAssertEqual(ShadowWire.changedFlags(live: cyc(false), shadow: cyc(true)), ["f"])
    }

    func testFlipsAreDecidedIndependentlyOfObjectKeyOrder() {
        let c = ShadowCounters(sessionId: session, checksum: draftSum)
        c.add("cfg", live: parse(#"{"a":1,"b":2}"#), shadow: parse(#"{"b":2,"a":1}"#), ruleIndex: nil)
        c.add("cfg", live: parse(#"{"a":1,"b":{"e":1,"c":2}}"#), shadow: parse(#"{"b":{"c":2,"e":1},"a":1}"#), ruleIndex: nil)
        XCTAssertEqual(c.report(version: nil).field("flags").arrayValue?.first?.json, #"{"flag":"cfg","samples":2,"flips":0,"pairs":[],"rules":{"default":2}}"#)
        XCTAssertEqual(ShadowWire.reprValue(parse(#"{"b":2,"a":1}"#)), #"{"a":1,"b":2}"#)
    }

    func testValuesAreJsonTextUpTo100CharactersLongerOnesHashed() {
        XCTAssertEqual(ShadowWire.reprValue(.bool(true)), "true")
        XCTAssertEqual(ShadowWire.reprValue(.string("blue")), "\"blue\"")
        XCTAssertEqual(ShadowWire.reprValue(parse(#"{"a":1}"#)), #"{"a":1}"#)
        XCTAssertEqual(ShadowWire.reprValue(.number(1.5)), "1.5")
        XCTAssertEqual(ShadowWire.reprValue(.undefined), "null")
        // Same hashes as the JS SDK (murmur3 of the canonical JSON text).
        XCTAssertEqual(ShadowWire.reprValue(.string(String(repeating: "x", count: 200))), "#6685751d")
        var o = JSObjectBuilder()
        o.set("long", .string(String(repeating: "é", count: 120)))
        o.set("a", .number(1))
        XCTAssertEqual(ShadowWire.reprValue(.object(o.build())), "#e30d3d0f")
    }

    func testCountersAreBounded() {
        let c = ShadowCounters(sessionId: session, checksum: draftSum)
        for i in 0..<(ShadowWire.maxFlags + 20) { c.add("f\(i)", live: .bool(false), shadow: .bool(true), ruleIndex: 0) }
        XCTAssertEqual(c.count, ShadowWire.maxFlags)
        let p = ShadowCounters(sessionId: session, checksum: draftSum)
        for i in 0..<50 { p.add("color", live: .string("a"), shadow: .string("b\(i)"), ruleIndex: i) }
        let r = p.report(version: nil).field("flags").arrayValue![0]
        XCTAssertEqual(r.field("samples").numberValue, 50)
        XCTAssertEqual(r.field("flips").numberValue, 50)
        let pairs = r.field("pairs").arrayValue!
        XCTAssertEqual(pairs.count, ShadowWire.maxPairs)
        XCTAssertEqual(pairs.last?.json, #"{"live":"*","shadow":"*","count":\#(50 - (ShadowWire.maxPairs - 1))}"#)
        XCTAssertEqual(pairs.reduce(0) { $0 + ($1.field("count").numberValue ?? 0) }, 50)
        XCTAssertEqual(r.field("rules").objectValue?.count, 50)
        XCTAssertTrue(p.report(version: nil).field("version").isUndefined)
    }

    func testSkipsFlagKeysTheEdgeWouldRefuseAndStopsAFlagsCountersAtTheCap() {
        XCTAssertEqual(ShadowWire.maxFlagKey, 63)
        XCTAssertEqual(ShadowWire.maxCount, 10_000_000)
        let c = ShadowCounters(sessionId: session, checksum: draftSum)
        c.add(String(repeating: "k", count: 64), live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        c.add("", live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        XCTAssertEqual(c.count, 0)
        c.add(String(repeating: "k", count: 63), live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        // Counted in UTF-16 code units, as the edge does: 31 emoji (surrogate pairs) + 1 = 63; 32 emoji = 64.
        c.add(String(repeating: "\u{1F600}", count: 31) + "x", live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        c.add(String(repeating: "\u{1F600}", count: 32), live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        XCTAssertEqual(c.count, 2)
        // The cap itself (ShadowWire.maxCount in production; a small one here to keep the test fast).
        let big = ShadowCounters(sessionId: session, checksum: draftSum, maxCount: 5)
        big.add("big", live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        for _ in 1..<5 { big.add("big", live: .bool(true), shadow: .bool(true), ruleIndex: 0) }
        big.add("big", live: .bool(false), shadow: .bool(true), ruleIndex: 0)
        big.add("big", live: .bool(true), shadow: .bool(true), ruleIndex: 1)
        XCTAssertEqual(
            big.report(version: nil).field("flags").arrayValue?[0].json,
            #"{"flag":"big","samples":5,"flips":1,"pairs":[{"live":"false","shadow":"true","count":1}],"rules":{"0":5}}"#
        )
    }
}
