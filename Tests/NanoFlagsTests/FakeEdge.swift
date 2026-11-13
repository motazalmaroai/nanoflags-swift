import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import NanoFlags

/// An in-process edge that signs like the real one: `/v1/bundle` (ETag, signature headers), `/v1/keys`,
/// `/v1/events`, `/v1/stream` (SSE) and `/v1/live` (WebSocket: `hello` on connect, `rev` on publish,
/// text ping/pong, close codes).
final class FakeEdge: NetworkTransport, @unchecked Sendable {
    let lock = NSLock()
    var signingKey = Curve25519.Signing.PrivateKey()
    var kid = "t1"
    var environmentId = "env-test-0001"
    var revision = 0
    var bundleText = ""
    var checksum = ""
    var signed = true
    var tamper = false
    var stale = false
    var offline = false
    var webSocketsSupported = true
    var refuseWebSocket = false
    var extraKeys: [(String, Curve25519.Signing.PublicKey)] = []
    var keysServed: [SigningKey]?

    var requests: [URLRequest] = []
    var eventBodies: [JSONValue] = []
    var sockets: [FakeSocket] = []
    var streams: [AsyncThrowingStream<StreamPart, Error>.Continuation] = []

    var publicJWK: SigningKey { SigningKey(x: b64url(signingKey.publicKey.rawRepresentation), kid: kid) }

    func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Publishes a new revision with these flags (and segments) and pushes it to sockets and streams.
    @discardableResult
    func publish(flags: String, segments: String = "{}", engine: Int = 1, committedAt: Double? = nil) -> Int {
        let (msg, sockets, streams, rev, ck) = locked { () -> (String, [FakeSocket], [AsyncThrowingStream<StreamPart, Error>.Continuation], Int, String) in
            revision += 1
            bundleText = "{\"schema\":1,\"engine\":\(engine),\"project\":\"p\",\"environment\":\"e\",\"revision\":\(revision),\"flags\":\(flags),\"segments\":\(segments)}"
            checksum = String(format: "%032x", revision)
            return (liveMessage("rev", committedAt: committedAt), self.sockets, self.streams, revision, checksum)
        }
        for s in sockets where !s.isClosed { s.push(msg) }
        for c in streams { c.yield(.bytes(Data("event: revision\ndata: {\"revision\":\(rev),\"checksum\":\"\(ck)\"}\n\n".utf8))) }
        return rev
    }

    func signature(for text: String) -> String {
        let canonical = "nanoflags-bundle-v1\n\(environmentId)\n\(revision)\n\(checksum)\n\(sha256Hex(Data(text.utf8)))"
        var sig = try! signingKey.signature(for: Data(canonical.utf8))
        if tamper { sig = Data(sig.reversed()) }
        return b64url(sig)
    }

    /// Must be called with the lock held.
    func liveMessage(_ t: String, committedAt: Double? = nil) -> String {
        var m: [String: Any] = ["t": t, "revision": revision]
        if revision > 0 {
            m["bundle"] = bundleText
            m["checksum"] = checksum
            if signed {
                m["signature"] = signature(for: bundleText)
                m["kid"] = kid
                m["environmentId"] = environmentId
            }
            m["committedAt"] = committedAt ?? (Date().timeIntervalSince1970 * 1000)
            m["sentAt"] = Date().timeIntervalSince1970 * 1000
        }
        let data = try! JSONSerialization.data(withJSONObject: m)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: NetworkTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url!.path
        let offline = locked { requests.append(request); return self.offline }
        if offline { throw URLError(.notConnectedToInternet) }
        switch path {
        case "/v1/keys":
            let keys = locked { keysServed ?? [publicJWK] }
            let body = try JSONEncoder().encode(["keys": keys])
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
        case "/v1/events":
            let body = try JSONValue(jsonData: request.httpBody ?? Data())
            locked { eventBodies.append(body) }
            return HTTPResponse(status: 202, headers: [:], body: Data("{\"accepted\":0,\"capped\":false}".utf8))
        case "/v1/bundle":
            return locked {
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestKeys.client)" else {
                    return HTTPResponse(status: 401, headers: [:], body: Data())
                }
                let etag = "\"\(checksum)-client\""
                var headers = ["etag": etag, "x-nanoflags-environment-id": environmentId, "x-nanoflags-signed": signed ? "true" : "false"]
                if stale { headers["x-nanoflags-stale"] = "true" }
                if signed {
                    headers["x-nanoflags-signature"] = signature(for: bundleText)
                    headers["x-nanoflags-key-id"] = kid
                }
                if request.value(forHTTPHeaderField: "If-None-Match") == etag { return HTTPResponse(status: 304, headers: headers, body: Data()) }
                // Byte-for-byte embedding of the stored text, with whitespace the client must not normalise.
                let body = "{\"revision\":\(revision),\"checksum\":\"\(checksum)\",\"bundle\":\(bundleText)}"
                return HTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
            }
        default:
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamPart, Error> {
        AsyncThrowingStream { c in
            let offline = locked { requests.append(request); streams.append(c); return self.offline }
            if offline { return c.finish(throwing: URLError(.notConnectedToInternet)) }
            c.yield(.status(200))
            c.yield(.bytes(Data(": hi\n\n".utf8)))
        }
    }

    func webSocket(_ request: URLRequest) -> WebSocketConnection {
        let s = FakeSocket(edge: self)
        let (supported, refused, offline) = locked { () -> (Bool, Bool, Bool) in
            requests.append(request)
            sockets.append(s)
            return (webSocketsSupported, refuseWebSocket, self.offline)
        }
        if !supported { s.fail(WebSocketUnsupported()) } else if refused || offline { s.fail(URLError(.badServerResponse)) } else {
            s.push(locked { liveMessage("hello") })
        }
        return s
    }

    var openSockets: [FakeSocket] { locked { sockets.filter { !$0.isClosed } } }
    var bundleRequests: Int { locked { requests.filter { $0.url?.path == "/v1/bundle" }.count } }
    var keysRequests: Int { locked { requests.filter { $0.url?.path == "/v1/keys" }.count } }
}

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    weak var edge: FakeEdge?
    private let lock = NSLock()
    private var queue: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var sent: [String] = []
    private var _closeCode = 0
    private var _closeReason: String?

    init(edge: FakeEdge) { self.edge = edge }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func push(_ text: String) { deliver(.success(text)) }
    func fail(_ e: Error) {
        deliver(.failure(e))
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// The edge closes the socket (e.g. 4004 "environment deleted").
    func serverClose(code: Int, reason: String) {
        lock.lock()
        _closeCode = code
        _closeReason = reason
        lock.unlock()
        fail(URLError(.networkConnectionLost))
    }

    private func deliver(_ r: Result<String, Error>) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(with: r)
        } else {
            queue.append(r)
            lock.unlock()
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            lock.lock()
            if !queue.isEmpty {
                let r = queue.removeFirst()
                lock.unlock()
                c.resume(with: r)
            } else if closed {
                lock.unlock()
                c.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func send(_ text: String) async throws { record(text) }

    private func record(_ text: String) {
        lock.lock()
        sent.append(text)
        lock.unlock()
        if text == "ping" { push("pong") }
    }

    func close(code: Int) {
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: URLError(.cancelled))
    }

    var closeCode: Int { lock.lock(); defer { lock.unlock() }; return _closeCode }
    var closeReason: String? { lock.lock(); defer { lock.unlock() }; return _closeReason }
    var upgradeStatus: Int { 0 }
}

enum TestKeys {
    /// Not a real key: the fake edge accepts it.
    static let client = "nf_pub_test0000000000000000"
}

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Polls `condition` until it holds or `timeout` passes.
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

func assertEventually(_ condition: () -> Bool, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async {
    let ok = await eventually(timeout, condition)
    XCTAssertTrue(ok, "condition not met within \(timeout) s", file: file, line: line)
}

/// Collects events delivered on other threads.
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    func add(_ x: T) { lock.lock(); _items.append(x); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
}

extension NanoFlagsClient {
    /// A client wired to a fake edge (no lifecycle observers).
    static func test(edge: FakeEdge, key: String = TestKeys.client, _ configure: (inout NanoFlagsOptions) -> Void = { _ in }) -> NanoFlagsClient {
        var o = NanoFlagsOptions(baseURL: URL(string: "https://edge.test")!, service: "swift-tests", storage: .none, events: .disabled)
        o.verify = .enabled(VerifyOptions(publicKeys: [edge.publicJWK], require: true))
        configure(&o)
        return NanoFlagsClient(key: key, options: o, network: edge, startPlatformObservers: false)
    }
}
