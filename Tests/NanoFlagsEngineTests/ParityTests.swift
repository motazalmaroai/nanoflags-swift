import Foundation
import XCTest
@testable import NanoFlagsEngine

/// The parity fixtures are generated from the TypeScript engine by
/// packages/engine/fixtures/generate-parity.mjs (shared by every port). The extra fixtures of the Go port
/// (packages/sdk-go/internal/testdata/extra.json) add JavaScript corner cases and V8's error messages.
enum Fixtures {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func locate(env: String, _ candidates: [String]) -> URL? {
        if let p = ProcessInfo.processInfo.environment[env], !p.isEmpty { return URL(fileURLWithPath: p) }
        for c in candidates {
            let u = packageRoot.appendingPathComponent(c).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static let parity = locate(env: "NANOFLAGS_PARITY_JSON", [
        "../engine/fixtures/parity.json",             // monorepo: packages/sdk-swift
        "../packages/engine/fixtures/parity.json",    // public mirror: swift/ next to packages/
        "Tests/Fixtures/parity.json",                 // standalone repository nanoflags-swift (vendored copy)
    ])
    static let extra = locate(env: "NANOFLAGS_EXTRA_JSON", [
        "../sdk-go/internal/testdata/extra.json",
        "../go/internal/testdata/extra.json",
        "Tests/Fixtures/extra.json",
    ])

    static func load(_ url: URL?) throws -> JSValue {
        // A missing fixture fails the suite (never a silent skip): the parity cases are the port's main guarantee.
        guard let url else {
            throw FixtureError.notFound("parity fixture not found under \(packageRoot.path); set NANOFLAGS_PARITY_JSON / NANOFLAGS_EXTRA_JSON")
        }
        return try JSValue.parse(Data(contentsOf: url))
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case notFound(String)
    var description: String { switch self { case .notFound(let m): return m } }
}

func js(_ v: JSValue) -> String { v.json ?? "undefined" }

/// Renders an evaluation the way the generator's expectedOf does, with a fixed key order, so results compare as text.
func canonical(_ r: EngineResult, withTrace: Bool, maskErrorDetail: Bool) -> String {
    var b = "{\"reason\":" + jsonQuote(r.reason.rawValue) + ",\"revision\":" + js(r.revision)
    if !r.value.isUndefined { b += ",\"value\":" + js(r.value) }
    if let i = r.ruleIndex { b += ",\"ruleIndex\":" + String(i) }
    if r.ruleIndex != nil && !r.ruleId.isUndefined { b += ",\"ruleId\":" + js(r.ruleId) }
    if let x = r.inRollout { b += ",\"inRollout\":" + (x ? "true" : "false") }
    if let x = r.bucket { b += ",\"bucket\":" + jsNumberToString(x) }
    if r.reason == .error { b += ",\"error\":true" }
    if withTrace {
        b += ",\"trace\":["
        for (i, s) in r.trace.enumerated() {
            if i > 0 { b += "," }
            let detail = maskErrorDetail && i == r.trace.count - 1 ? "<error>" : s.detail
            b += "{\"kind\":" + jsonQuote(s.kind) + ",\"title\":" + jsonQuote(s.title) + ",\"detail\":" + jsonQuote(detail)
            if let m = s.matched { b += ",\"matched\":" + (m ? "true" : "false") }
            b += "}"
        }
        b += "]"
    }
    return b + "}"
}

func canonicalExpected(_ e: JSValue, maskErrorDetail: Bool) -> String {
    var b = "{\"reason\":" + js(e.field("reason")) + ",\"revision\":" + js(e.field("revision"))
    for k in ["value", "ruleIndex", "ruleId", "inRollout", "bucket", "error"] {
        let v = e.field(k)
        if !v.isUndefined { b += ",\"\(k)\":" + js(v) }
    }
    if case .array(let tr) = e.field("trace") {
        b += ",\"trace\":["
        for (i, s) in tr.enumerated() {
            if i > 0 { b += "," }
            var detail = s.field("detail")
            if maskErrorDetail && i == tr.count - 1 { detail = .string("<error>") }
            b += "{\"kind\":" + js(s.field("kind")) + ",\"title\":" + js(s.field("title")) + ",\"detail\":" + js(detail)
            let m = s.field("matched")
            if !m.isUndefined { b += ",\"matched\":" + js(m) }
            b += "}"
        }
        b += "]"
    }
    return b + "}"
}

/// Evaluates every case of a fixture document; returns (checked, failures).
func runCases(_ doc: JSValue, compareErrorMessages: Bool, report: (String) -> Void) -> (Int, Int) {
    let bundles = doc.field("bundles").arrayValue ?? []
    let contexts = doc.field("contexts").arrayValue ?? []
    let cases = doc.field("cases").arrayValue ?? []
    var failures = 0
    for (i, c) in cases.enumerated() {
        let bi = Int(c.field("bundle").numberValue ?? -1)
        let ci = Int(c.field("context").numberValue ?? 0)
        let flag = c.field("flag").stringValue ?? ""
        let bundle = bi >= 0 ? bundles[bi] : .null
        let expected = c.field("expected")
        let withTrace = !expected.field("trace").isUndefined
        let mask = !expected.field("error").isUndefined && !compareErrorMessages
        let got = Engine.evaluate(bundle: bundle, flagKey: flag, context: contexts[ci], fallback: c.field("fallback"))
        var g = canonical(got, withTrace: withTrace, maskErrorDetail: mask)
        var w = canonicalExpected(expected, maskErrorDetail: mask)
        if compareErrorMessages, case .string(let m) = expected.field("errorMessage"), m != got.error {
            g += " err=" + jsonQuote(got.error ?? "")
            w += " err=" + jsonQuote(m)
        }
        if g != w {
            failures += 1
            if failures <= 20 { report("case \(i) \(js(c.field("name")))\n got: \(g)\nwant: \(w)") }
        }
    }
    return (cases.count, failures)
}

final class ParityTests: XCTestCase {
    static var doc: JSValue?
    func parity() throws -> JSValue {
        if let d = ParityTests.doc { return d }
        let d = try Fixtures.load(Fixtures.parity)
        ParityTests.doc = d
        return d
    }

    func testEvaluationCases() throws {
        let doc = try parity()
        XCTAssertEqual(doc.field("engineVersion").numberValue, Double(Engine.version))
        let (n, failures) = runCases(doc, compareErrorMessages: false) { XCTFail($0) }
        XCTAssertGreaterThan(n, 20000)
        XCTAssertEqual(failures, 0, "\(failures) of \(n) cases differ")
        print("parity: \(n - failures)/\(n) evaluation cases identical (\(Fixtures.parity!.path))")
    }

    func testHashing() throws {
        let doc = try parity()
        let m = doc.field("murmur3").arrayValue ?? []
        var ok = 0
        for c in m {
            let got = Engine.murmur3(c.field("input").stringValue!, seed: UInt32(c.field("seed").numberValue!))
            if Double(got) == c.field("hash").numberValue { ok += 1 } else { XCTFail("murmur3(\(js(c.field("input"))), \(js(c.field("seed")))) = \(got), want \(js(c.field("hash")))") }
        }
        let b = doc.field("buckets").arrayValue ?? []
        for c in b {
            let got = Engine.bucketOf(seed: c.field("seed").stringValue!, identity: c.field("identity").stringValue!)
            if got == c.field("bucket").numberValue { ok += 1 } else { XCTFail("bucketOf(\(js(c.field("seed"))), \(js(c.field("identity")))) = \(got), want \(js(c.field("bucket")))") }
        }
        XCTAssertEqual(ok, m.count + b.count)
        print("parity: \(m.count) murmur3 vectors and \(b.count) buckets identical")
    }

    func testSupportsEngine() throws {
        let cases = try parity().field("supportsEngine").arrayValue ?? []
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(Engine.supportsEngine(c.field("bundle").field("engine")), c.field("expected").boolValue, js(c.field("bundle")))
        }
        print("parity: \(cases.count) supportsEngine cases identical")
    }

    func testClientBundle() throws {
        let cases = try parity().field("clientBundle").arrayValue ?? []
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let got = JSValue.object(Engine.clientBundle(c.field("bundle").objectValue!))
            XCTAssertEqual(js(got), js(c.field("expected")))
        }
        print("parity: \(cases.count) clientBundle (browser view) cases identical")
    }

    /// The Go port's extra fixtures, V8 error messages included. Swift strings cannot hold lone UTF-16
    /// surrogates (JSON.parse keeps them; this port's parser turns them into U+FFFD), so cases whose input
    /// contains one are counted separately: they can only differ in how such a string is rendered.
    func testExtraCases() throws {
        let doc = try Fixtures.load(Fixtures.extra)
        let bundles = doc.field("bundles").arrayValue ?? []
        let contexts = doc.field("contexts").arrayValue ?? []
        let cases = doc.field("cases").arrayValue ?? []
        func lossy(_ v: JSValue) -> Bool { (v.json ?? "").unicodeScalars.contains("\u{FFFD}") }
        var regular: [JSValue] = [], surrogate: [JSValue] = []
        for c in cases {
            let bi = Int(c.field("bundle").numberValue ?? -1)
            let ci = Int(c.field("context").numberValue ?? 0)
            let hit = (bi >= 0 && lossy(bundles[bi])) || lossy(contexts[ci]) || lossy(c.field("fallback")) || lossy(c.field("flag"))
            if hit { surrogate.append(c) } else { regular.append(c) }
        }
        func makeDoc(with list: [JSValue]) -> JSValue {
            var b = JSObjectBuilder()
            b.set("bundles", .array(bundles))
            b.set("contexts", .array(contexts))
            b.set("cases", .array(list))
            return .object(b.build())
        }
        let (n, failures) = runCases(makeDoc(with: regular), compareErrorMessages: true) { XCTFail($0) }
        let (sn, sfailures) = runCases(makeDoc(with: surrogate), compareErrorMessages: true) { _ in }
        XCTAssertEqual(failures, 0, "\(failures) of \(n) extra cases differ")
        print("extra: \(n - failures)/\(n) cases identical, error messages included; \(sn) cases with lone surrogates (not representable in Swift strings): \(sn - sfailures) identical anyway")
    }
}
