import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NanoFlags

/// Opt-in checks against the hosted edge with the public demo browser key:
///
///     NANOFLAGS_PRODUCTION_TESTS=1 NANOFLAGS_SDK_KEY=<nf_pub_…> swift test --filter ProductionTests
///
/// The live test toggles a demo flag through `POST /v1/demo/toggle` (rate limited, shared with every visitor of
/// the demo page), waits for the update, and restores the original value.
final class ProductionTests: XCTestCase {
    var key: String = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NANOFLAGS_PRODUCTION_TESTS"] == "1", let k = env["NANOFLAGS_SDK_KEY"], !k.isEmpty else {
            throw XCTSkip("production tests are opt-in (NANOFLAGS_PRODUCTION_TESTS=1 NANOFLAGS_SDK_KEY=…)")
        }
        key = k
    }

    func production(_ transport: TransportPreference = .automatic) -> NanoFlagsClient {
        let o = NanoFlagsOptions(service: "swift-sdk-ci", transport: transport, storage: .none, events: .disabled)
        return NanoFlagsClient(key: key, options: o, network: URLSessionTransport(configuration: nil, requestTimeout: 15), startPlatformObservers: false)
    }

    func testVerifiedBundleOverPollingWithETag() async throws {
        let c = production(.polling)
        defer { c.close() }
        // Right after a publish the edge can briefly serve an unsigned fallback, which is refused: allow for retries.
        await assertEventually({ c.status == .ready }, timeout: 40)
        XCTAssertEqual(c.status, .ready)
        let snap = try XCTUnwrap(c.locked { c.snapshot })
        XCTAssertEqual(snap.sig?.kid, "k1", "accepted only because the signature verified with the embedded key")
        XCTAssertNotNil(snap.etag)
        // Browser view only: client-exposed flags.
        XCTAssertNotNil(c.allFlags()["demo-new-checkout"])
        await c.refresh() // conditional request: 304 keeps everything
        XCTAssertEqual(c.status, .ready)
        XCTAssertGreaterThanOrEqual(c.revision ?? 0, snap.revision)
        print("production: polling r\(snap.revision), kid \(snap.sig?.kid ?? "-"), etag \(snap.etag ?? "-"), flags \(c.allFlags())")
    }

    func testLiveUpdateAfterADemoToggle() async throws {
        let c = production()
        defer { c.close() }
        // Right after a publish the edge can briefly serve an unsigned fallback, which is refused: allow for retries.
        await assertEventually({ c.status == .ready }, timeout: 40)
        // Apple platforms: the WebSocket. Linux: URLSession has no WebSocket support, so SSE.
        await assertEventually({ c.transport != .poll }, timeout: 20)
        let transport = c.transport
        print("production: transport \(transport.rawValue)")
        #if !canImport(FoundationNetworking)
        // Apple platforms: URLSessionWebSocketTask, the edge pushes the signed bundle itself.
        await assertEventually({ c.transport == .live }, timeout: 20)
        #endif

        let changes = Collector<(Date, FlagChange)>()
        c.onChange { changes.add((Date(), $0)) }
        c.onError { print("production: error \($0)") }
        let original = c.stringVariation(key: "demo-accent", default: "blue")
        var results: [String] = []
        for value in [original == "orange" ? "green" : "orange", original] {
            let sent = Date()
            let toggle = try await demoToggle(flag: "demo-accent", value: value)
            let returned = Date()
            guard let rev = toggle.revision, let checksum = toggle.checksum else {
                print("production: toggle to \(value) → \(toggle.status) (no publish)")
                continue
            }
            // The configuration is identified by its checksum: a toggle back to an earlier value republishes an
            // earlier checksum, which the edge answers with 304 (same content) to a conditional request.
            await assertEventually({ c.locked { c.snapshot?.checksum } == checksum }, timeout: 75)
            print("production: want \(checksum) r\(rev), have \(c.locked { c.snapshot?.checksum } ?? "-") r\(c.revision ?? 0)")
            guard let (at, change) = changes.items.first(where: { $0.1.checksum == checksum && $0.0 > sent }) else { continue }
            XCTAssertEqual(c.stringVariation(key: "demo-accent", default: ""), c.allFlags()["demo-accent"]?.stringValue)
            let line = String(format: "toggle %@ r%d via %@: toggle sent → update %.0f ms, toggle returned → update %.0f ms, commit → update (SDK) %@",
                              value, rev, change.transport.rawValue, at.timeIntervalSince(sent) * 1000, at.timeIntervalSince(returned) * 1000,
                              change.latencyMs.map { String(format: "%.0f ms", $0) } ?? "n/a (not pushed)")
            print("production: " + line)
            results.append(line)
            #if !canImport(FoundationNetworking)
            XCTAssertEqual(change.transport, .live, "pushed over URLSessionWebSocketTask")
            XCTAssertNotNil(change.latencyMs)
            #endif
            try await Task.sleep(nanoseconds: 3_000_000_000) // be gentle with the shared demo
        }
        XCTAssertFalse(results.isEmpty)
    }

    struct Toggle {
        let status: String
        let revision: Int?
        let checksum: String?
    }

    /// `POST /v1/demo/toggle`, waiting out the demo's rate limit when it answers 429.
    func demoToggle(flag: String, value: String) async throws -> Toggle {
        for _ in 0..<6 {
            var r = URLRequest(url: NanoFlags.officialEdgeURL.appendingPathComponent("v1/demo/toggle"))
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("nanoflags-swift-tests/\(NanoFlags.sdkVersion)", forHTTPHeaderField: "User-Agent")
            r.httpBody = Data("{\"flag\":\"\(flag)\",\"value\":\"\(value)\"}".utf8)
            let res = try await URLSessionTransport(configuration: nil, requestTimeout: 15).send(r)
            let body = try JSONValue(jsonData: res.body)
            if res.status == 429 {
                let wait = (body["retryAfterMs"]?.numberValue ?? 5000) / 1000 + 0.5
                print("production: demo rate limited, waiting \(wait) s")
                try await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1e9))
                continue
            }
            XCTAssertEqual(res.status, 200, body.jsonString)
            return Toggle(status: body["status"]?.stringValue ?? "?", revision: body["revision"]?.numberValue.map { Int($0) }, checksum: body["checksum"]?.stringValue)
        }
        throw XCTSkip("the demo stayed rate limited")
    }
}
