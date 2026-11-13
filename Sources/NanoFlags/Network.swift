import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An HTTP answer with lower-cased header names.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// One piece of a streamed response (SSE): the status line first, then body bytes as they arrive.
enum StreamPart: Sendable {
    case status(Int)
    case bytes(Data)
}

/// A WebSocket connection carrying text messages.
protocol WebSocketConnection: AnyObject, Sendable {
    /// The next text message. Throws when the socket closed or failed.
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close(code: Int)
    /// Close code sent by the server (0 when unknown).
    var closeCode: Int { get }
    /// Close reason sent by the server.
    var closeReason: String? { get }
    /// HTTP status of a refused upgrade (0 when unknown).
    var upgradeStatus: Int { get }
}

/// The network the client uses. The default is URLSession; tests inject a fake edge.
protocol NetworkTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamPart, Error>
    func webSocket(_ request: URLRequest) -> WebSocketConnection
}

/// Thrown when the platform's URLSession cannot open WebSockets (swift-corelibs-foundation on Linux uses
/// libcurl, which is usually built without WebSocket support).
struct WebSocketUnsupported: Error {}

final class URLSessionTransport: NetworkTransport, @unchecked Sendable {
    let session: URLSession
    let requestTimeout: TimeInterval

    init(configuration: URLSessionConfiguration?, requestTimeout: TimeInterval) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        // The client handles ETags itself; a URL cache would turn the edge's 304 into a 200.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = requestTimeout
        session = URLSession(configuration: config)
        self.requestTimeout = requestTimeout
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { return cont.resume(throwing: error) }
                    guard let http = response as? HTTPURLResponse else { return cont.resume(throwing: URLError(.badServerResponse)) }
                    cont.resume(returning: HTTPResponse(status: http.statusCode, headers: lowercasedHeaders(http), body: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamPart, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamDelegate(continuation: continuation)
            let config = session.configuration.copy() as! URLSessionConfiguration
            // A stream is idle between events: only the connection itself may time out.
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 24 * 3600
            let streamSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = streamSession.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                streamSession.invalidateAndCancel()
            }
            task.resume()
        }
    }

    func webSocket(_ request: URLRequest) -> WebSocketConnection {
        URLSessionWebSocket(task: session.webSocketTask(with: request))
    }
}

func lowercasedHeaders(_ r: HTTPURLResponse) -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in r.allHeaderFields {
        if let k = k as? String, let v = v as? String { out[k.lowercased()] = v }
    }
    return out
}

/// Holds a URLSessionTask for cancellation from another thread.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) {
        lock.lock()
        task = t
        let c = cancelled
        lock.unlock()
        if c { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<StreamPart, Error>.Continuation

    init(continuation: AsyncThrowingStream<StreamPart, Error>.Continuation) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        continuation.yield(.status((response as? HTTPURLResponse)?.statusCode ?? 0))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.bytes(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}

final class URLSessionWebSocket: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        #if !canImport(FoundationNetworking)
        // A pushed bundle can be up to ~1.9 MB (the edge's limit); the default limit is 1 MB.
        task.maximumMessageSize = 4 * 1024 * 1024
        #endif
        task.resume()
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            task.receive { result in
                switch result {
                case .success(.string(let s)): cont.resume(returning: s)
                case .success(.data(let d)): cont.resume(returning: String(decoding: d, as: UTF8.self))
                case .success: cont.resume(returning: "")
                case .failure(let e):
                    let ns = e as NSError
                    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorUnsupportedURL {
                        cont.resume(throwing: WebSocketUnsupported())
                    } else {
                        cont.resume(throwing: e)
                    }
                }
            }
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }

    var closeCode: Int { task.closeCode.rawValue }
    var closeReason: String? { task.closeReason.map { String(decoding: $0, as: UTF8.self) } }
    var upgradeStatus: Int { (task.response as? HTTPURLResponse)?.statusCode ?? 0 }
}

/// Splits a Server-Sent Events byte stream into (event, data) pairs.
struct SSEParser {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []

    mutating func feed(_ chunk: Data) -> [(String, String)] {
        buffer.append(chunk)
        var out: [(String, String)] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            if line.last == 0x0D { line = line.dropLast() }
            let text = String(decoding: line, as: UTF8.self)
            if text.isEmpty {
                if !data.isEmpty || !event.isEmpty { out.append((event.isEmpty ? "message" : event, data.joined(separator: "\n"))) }
                event = ""
                data = []
                continue
            }
            if text.hasPrefix(":") { continue }
            let field: Substring, value: Substring
            if let colon = text.firstIndex(of: ":") {
                field = text[..<colon]
                var v = text[text.index(after: colon)...]
                if v.hasPrefix(" ") { v = v.dropFirst() }
                value = v
            } else {
                field = Substring(text)
                value = ""
            }
            if field == "event" { event = String(value) } else if field == "data" { data.append(String(value)) }
        }
        return out
    }
}
