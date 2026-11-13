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

let checkoutFlags = """
{"new-checkout":{"type":"boolean","enabled":true,"clientExposed":true,"default":false,"off":false,"rules":[{"id":"pro","match":"all","conditions":[{"attribute":"plan","op":"eq","value":"pro"}],"serve":{"type":"fixed","value":true}}]},"accent":{"type":"string","enabled":true,"clientExposed":true,"default":"blue","off":"blue","rules":[{"id":"half","match":"all","conditions":[],"serve":{"type":"rollout","percentage":50,"value":"orange","otherwise":"green"}}]},"limit":{"type":"number","enabled":true,"clientExposed":true,"default":3,"off":0,"rules":[]},"theme":{"type":"json","enabled":true,"clientExposed":true,"default":{"dark":true,"sizes":[1,2]},"off":null,"rules":[]}}
"""

final class ClientTests: XCTestCase {
    func testPollingLoadsAVerifiedBundleAndEvaluatesLocally() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.context = ["key": "user-1", "plan": "pro"] }
        defer { c.close() }
        let ready = await c.ready(timeout: 5)
        XCTAssertTrue(ready)
        XCTAssertEqual(c.status, .ready)
        XCTAssertEqual(c.revision, 1)
        XCTAssertTrue(c.boolVariation(key: "new-checkout", default: false))
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 3)
        XCTAssertEqual(c.intVariation(key: "limit", default: 0), 3)
        XCTAssertEqual(c.jsonVariation(key: "theme", default: nil), ["dark": true, "sizes": [1, 2]])
        XCTAssertEqual(c.stringVariation(key: "missing", default: "fb"), "fb")
        // Wrong type: the default, with reason error.
        let d = c.variationDetail(key: "limit", default: "x")
        XCTAssertEqual(d.value, "x")
        XCTAssertEqual(d.reason, .error)
        XCTAssertEqual(d.errorMessage, "Flag \"limit\" has a number value, which does not match the requested type.")
        let detail = c.variationDetail(key: "new-checkout", default: false)
        XCTAssertEqual(detail.reason, .ruleMatch)
        XCTAssertEqual(detail.ruleId, "pro")
        XCTAssertEqual(detail.revision, 1)
        // The rollout bucket equals the engine's (and therefore every other SDK's).
        let accent = c.variationDetail(key: "accent", default: "")
        XCTAssertEqual(accent.bucket, NanoFlagsEngine.Engine.bucketOf(seed: "accent", identity: "user-1"))
        XCTAssertEqual(Set(c.allFlags().keys), ["new-checkout", "accent", "limit", "theme"])

        // Headers: custom User-Agent (the edge answers 403 to library defaults), the key as a bearer token.
        let req = try XCTUnwrap(edge.requests.first { $0.url?.path == "/v1/bundle" })
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")!.hasPrefix("nanoflags-swift/0.1.0 ("))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(TestKeys.client)")

        // A revalidation sends the ETag and gets a 304.
        await c.refresh()
        let last = try XCTUnwrap(edge.requests.last { $0.url?.path == "/v1/bundle" })
        XCTAssertEqual(last.value(forHTTPHeaderField: "If-None-Match"), "\"\(edge.checksum)-client\"")
        XCTAssertEqual(c.revision, 1)
    }

    func testRejectsTamperedAndUnsignedBundles() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling }
        defer { c.close() }
        await c.ready(timeout: 5)
        XCTAssertEqual(c.revision, 1)
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }

        edge.tamper = true
        edge.publish(flags: "{}")
        await c.refresh()
        XCTAssertEqual(c.revision, 1, "a bundle whose signature does not verify must not replace the one in use")
        XCTAssertEqual(errors.items.last?.code, .signature)

        edge.tamper = false
        edge.signed = false
        await c.refresh()
        XCTAssertEqual(c.revision, 1, "unsigned bundles are refused with require")
        XCTAssertTrue(errors.items.last?.message.contains("not signed") ?? false)

        edge.signed = true
        await c.refresh()
        XCTAssertEqual(c.revision, 2)
        XCTAssertEqual(c.status, .ready)
    }

    func testUnknownKeyIdLoadsTheKeyListOnceAMinute() async throws {
        let edge = FakeEdge()
        let pinned = edge.publicJWK
        edge.publish(flags: checkoutFlags)
        // Rotation: the edge now signs with k2 and lists it at /v1/keys.
        edge.signingKey = Curve25519.Signing.PrivateKey()
        edge.kid = "k2"
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.verify = .enabled(VerifyOptions(publicKeys: [pinned], fetchKeys: true, require: true)) }
        defer { c.close() }
        await c.ready(timeout: 5)
        XCTAssertEqual(c.revision, 2)
        XCTAssertEqual(edge.keysRequests, 1)
        // A third, unknown key id: no second /v1/keys within the minute; the bundle is refused.
        edge.signingKey = Curve25519.Signing.PrivateKey()
        edge.kid = "k3"
        edge.publish(flags: "{}")
        await c.refresh()
        XCTAssertEqual(edge.keysRequests, 1)
        XCTAssertEqual(c.revision, 2)
    }

    func testRefusesServerKeysWithoutAnyRequest() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let errors = Collector<NanoFlagsError>()
        var o = NanoFlagsOptions(baseURL: URL(string: "https://edge.test")!, storage: .none, events: .disabled)
        o.transport = .polling
        // Collect the config error: it is emitted during init, so subscribe through the shared hook below.
        let c = NanoFlagsClient(key: "nf_srv_not-a-real-key", options: o, network: edge, startPlatformObservers: false)
        c.onError { errors.add($0) }
        let ready = await c.ready(timeout: 2)
        XCTAssertFalse(ready)
        XCTAssertEqual(c.status, .notReady)
        XCTAssertFalse(c.boolVariation(key: "new-checkout", default: false))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(edge.requests.isEmpty, "a server key must never be sent anywhere")
        c.close()
    }

    func testLiveWebSocketAppliesPushedRevisions() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.context = ["key": "user-1"] }
        defer { c.close() }
        let changes = Collector<FlagChange>()
        c.onChange { changes.add($0) }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .live })
        let socketRequest = try XCTUnwrap(edge.requests.first { $0.url?.path == "/v1/live" })
        XCTAssertEqual(socketRequest.url?.scheme, "wss")
        XCTAssertEqual(socketRequest.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "nanoflags.v1")
        XCTAssertEqual(socketRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(TestKeys.client)")
        let polls = edge.bundleRequests

        let flipped = checkoutFlags.replacingOccurrences(of: "\"default\":3", with: "\"default\":7")
        edge.publish(flags: flipped, committedAt: Date().timeIntervalSince1970 * 1000 - 120)
        await assertEventually({ c.revision == 2 })
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 7)
        XCTAssertEqual(edge.bundleRequests, polls, "a pushed revision needs no request")
        let e = try XCTUnwrap(changes.items.last)
        XCTAssertEqual(e.transport, .live)
        XCTAssertEqual(e.changedFlags, ["limit"])
        XCTAssertGreaterThanOrEqual(e.latencyMs ?? 0, 120)

        // A pushed bundle with a bad signature changes nothing.
        edge.tamper = true
        edge.publish(flags: "{}")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.revision, 2)
    }

    func testEnvironmentDeletedStopsReconnectingAndKeepsTheConfiguration() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge)
        defer { c.close() }
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .live })
        edge.openSockets.first!.serverClose(code: 4004, reason: "environment deleted")
        await assertEventually({ c.status == .stale })
        XCTAssertEqual(errors.items.last?.code, .environmentDeleted)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(edge.locked { edge.sockets.count }, 1, "no reconnect after 4004")
        XCTAssertNil(c.locked { c.streamTask }, "no SSE fallback after 4004")
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 3)
    }

    func testFallsBackToSSEWhenWebSocketsAreUnsupported() async throws {
        let edge = FakeEdge()
        edge.webSocketsSupported = false // swift-corelibs-foundation on Linux: libcurl without WebSockets
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge)
        defer { c.close() }
        let changes = Collector<FlagChange>()
        c.onChange { changes.add($0) }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .stream })
        await assertEventually({ edge.locked { edge.requests.contains { $0.url?.path == "/v1/stream" } } })
        let stream = try XCTUnwrap(edge.locked { edge.requests.first { $0.url?.path == "/v1/stream" } })
        XCTAssertEqual(stream.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        edge.publish(flags: checkoutFlags.replacingOccurrences(of: "\"default\":3", with: "\"default\":4"))
        await assertEventually({ c.revision == 2 })
        XCTAssertEqual(changes.items.last?.transport, .stream)
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 4)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(edge.locked { edge.sockets.count }, 1, "WebSocket is not retried once the platform says it is unsupported")
    }

    func testPauseClosesTheSocketAndResumeCatchesUp() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge)
        defer { c.close() }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .live })
        c.pause() // what UIApplication.didEnterBackgroundNotification triggers
        await assertEventually({ edge.openSockets.isEmpty && c.transport == .poll })
        edge.publish(flags: checkoutFlags.replacingOccurrences(of: "\"default\":3", with: "\"default\":9"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(c.revision, 1, "nothing is received in the background")
        c.resume() // UIApplication.willEnterForegroundNotification
        await assertEventually({ c.revision == 2 && c.transport == .live })
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 9)
    }

    func testLowDataModeDropsTheSocketAndTelemetry() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.events = EventsOptions(sampleRate: 1) }
        defer { c.close() }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .live })
        c.networkChanged(constrained: true, available: true)
        await assertEventually({ edge.openSockets.isEmpty })
        _ = c.boolVariation(key: "new-checkout", default: false)
        await c.flush()
        XCTAssertTrue(edge.eventBodies.isEmpty)
        c.networkChanged(constrained: false, available: true)
        await assertEventually({ c.transport == .live })
    }

    func testPersistsAndRestoresAVerifiedBundleOffline() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let storage = MemoryBundleStorage()
        let c1 = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.storage = .custom(storage) }
        await c1.ready(timeout: 5)
        await assertEventually({ storage.load(id: c1.storageID) != nil })
        c1.close()

        edge.offline = true
        let changes = Collector<FlagChange>()
        let c2 = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.storage = .custom(storage) }
        c2.onChange { changes.add($0) }
        defer { c2.close() }
        let ready = await c2.ready(timeout: 5)
        XCTAssertTrue(ready)
        XCTAssertEqual(c2.status, .stale, "a restored configuration is not known to be current")
        XCTAssertEqual(c2.revision, 1)
        XCTAssertEqual(c2.numberVariation(key: "limit", default: 0), 3)

        // A tampered stored copy is ignored.
        let text = String(decoding: storage.load(id: c1.storageID)!, as: UTF8.self).replacingOccurrences(of: "\\\"default\\\":3", with: "\\\"default\\\":5")
        try storage.save(Data(text.utf8), id: c1.storageID)
        let errors = Collector<NanoFlagsError>()
        let c3 = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.storage = .custom(storage) }
        c3.onError { errors.add($0) }
        defer { c3.close() }
        await c3.ready(timeout: 5)
        XCTAssertNil(c3.revision)
        XCTAssertEqual(c3.numberVariation(key: "limit", default: 0), 0)
        await assertEventually({ errors.items.contains { $0.code == .signature } })
    }

    func testBootstrapIdentifyAndChangeStreams() async throws {
        let edge = FakeEdge()
        edge.offline = true
        let boot = Data("{\"schema\":1,\"project\":\"p\",\"environment\":\"e\",\"revision\":0,\"flags\":\(checkoutFlags),\"segments\":{}}".utf8)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.bootstrap = boot }
        defer { c.close() }
        XCTAssertNotEqual(c.status, .notReady) // ready, then stale once the (offline) edge cannot confirm it
        XCTAssertEqual(c.revision, 0)
        XCTAssertFalse(c.boolVariation(key: "new-checkout", default: true))

        let changes = Collector<FlagChange>()
        c.onChange { changes.add($0) }
        let values = Collector<Bool>()
        let task = Task { for await v in c.values(key: "new-checkout", default: false) { values.add(v) } }
        await assertEventually({ values.items == [false] })
        c.identify(context: ["key": "user-9", "plan": "pro"])
        XCTAssertTrue(c.boolVariation(key: "new-checkout", default: false), "identify is synchronous")
        XCTAssertEqual(changes.items.last?.source, .context)
        XCTAssertTrue(changes.items.last?.changedFlags.contains("new-checkout") ?? false)
        await assertEventually({ values.items == [false, true] })
        task.cancel()
        // Per-call context override.
        XCTAssertFalse(c.boolVariation(key: "new-checkout", default: false, context: ["plan": "free"]))
    }

    func testRefusesBundlesForANewerEngine() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling }
        defer { c.close() }
        await c.ready(timeout: 5)
        let errors = Collector<NanoFlagsError>()
        c.onError { errors.add($0) }
        edge.publish(flags: "{}", engine: 2)
        await c.refresh()
        XCTAssertEqual(c.revision, 1)
        XCTAssertEqual(errors.items.last?.code, .engine)
        XCTAssertEqual(c.status, .ready)
    }

    func testTelemetrySendsAttributeNamesAndTypesNeverValues() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        let c = NanoFlagsClient.test(edge: edge) {
            $0.transport = .polling
            $0.events = EventsOptions(sampleRate: 1)
            $0.context = ["key": "user-secret-1", "plan": "pro", "email": "a@b.example"]
        }
        defer { c.close() }
        await c.ready(timeout: 5)
        _ = c.boolVariation(key: "new-checkout", default: false)
        _ = c.stringVariation(key: "accent", default: "")
        await c.flush()
        let body = try XCTUnwrap(edge.eventBodies.last)
        XCTAssertEqual(body["sdk"], "swift/0.1.0")
        XCTAssertEqual(body["service"], "swift-tests")
        XCTAssertEqual(body["revision"], 1)
        let events = try XCTUnwrap(body["events"]?.arrayValue)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["context"], ["plan": "string"])
        XCTAssertEqual(events[1]["context"], ["key": "string"])
        XCTAssertEqual(events[0]["sampleRate"], 1)
        let text = body.jsonString
        XCTAssertFalse(text.contains("user-secret-1"))
        XCTAssertFalse(text.contains("a@b.example"))
    }
}
