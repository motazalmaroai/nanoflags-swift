import Foundation
import XCTest
@testable import NanoFlags

final class VerifyTests: XCTestCase {
    /// A real signed answer of the production edge (demo browser key, captured 2026-11-12) verifies with the
    /// embedded production key, hashing the raw bytes of the "bundle" member (never a re-serialisation).
    func testProductionSignatureVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "signed-demo-response", withExtension: "json", subdirectory: "Resources"))
        let doc = try JSONValue(jsonData: Data(contentsOf: url))
        let headers = try XCTUnwrap(doc["headers"]?.objectValue)
        let body = Data(try XCTUnwrap(doc["body"]?.stringValue).utf8)
        let res = HTTPResponse(status: 200, headers: headers.mapValues { $0.stringValue ?? "" }, body: body)
        let raw = try XCTUnwrap(rawMember(body, "bundle"))
        let parsed = try JSValue.parse(body)
        let info = SignatureInfo(signature: res.header("x-nanoflags-signature")!, kid: res.header("x-nanoflags-key-id"),
                                 environmentId: res.header("x-nanoflags-environment-id")!, revision: Int(parsed.field("revision").numberValue!),
                                 checksum: parsed.field("checksum").stringValue!)
        let keys = importKeys(NanoFlags.officialSigningKeys)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(verifyBundleText(keys: keys, info: info, bundleText: raw))
        // JSON.stringify of the parsed bundle reproduces the signed bytes as well.
        XCTAssertEqual(parsed.field("bundle").json.map { Data($0.utf8) }, raw)
        // One flipped byte fails; another key id fails; a truncated signature fails.
        var tampered = raw
        tampered[tampered.index(tampered.startIndex, offsetBy: 20)] ^= 0x01
        XCTAssertFalse(verifyBundleText(keys: keys, info: info, bundleText: tampered))
        var other = info
        other.kid = "k9"
        XCTAssertFalse(verifyBundleText(keys: keys, info: other, bundleText: raw))
        other = info
        other.signature = String(info.signature.dropLast(4))
        XCTAssertFalse(verifyBundleText(keys: keys, info: other, bundleText: raw))
        other = info
        other.revision += 1
        XCTAssertFalse(verifyBundleText(keys: keys, info: other, bundleText: raw))
    }

    func testRawMember() {
        let cases: [(String, String?)] = [
            (#"{"bundle":{"a":"}"}}"#, #"{"a":"}"}"#),
            (#"{ "x" : [1,{"bundle":2}], "bundle" : [ "\"" ] }"#, #"[ "\"" ]"#),
            (#"{"bundle":1,"bundle":true}"#, "true"),
            (#"{"bundle":"esc"}"#, #""esc""#),
            (#"{"other":1}"#, nil),
            (#"[{"bundle":1}]"#, nil),
            (#"{"bundle":"#, nil),
            (#"{"bundle":7}"#, "7"),
        ]
        for (input, want) in cases {
            XCTAssertEqual(rawMember(Data(input.utf8), "bundle").map { String(decoding: $0, as: UTF8.self) }, want, input)
        }
    }

    func testPrivateAndMalformedKeysAreIgnored() {
        var priv = SigningKey(x: "wQu1EsaE-yTjqpUbibGyBrajy3IiRb7LyaiqeYRxG4U", kid: "p")
        priv.d = "private"
        XCTAssertTrue(importKeys([priv]).isEmpty)
        XCTAssertTrue(importKeys([SigningKey(x: "not base64!", kid: "x")]).isEmpty)
        XCTAssertTrue(importKeys([SigningKey(kty: "EC", crv: "P-256", x: "AAAA")]).isEmpty)
        XCTAssertEqual(importKeys(NanoFlags.officialSigningKeys).first?.kid, "k1")
    }
}

final class ValueTests: XCTestCase {
    func testNumberFormattingMatchesJavaScript() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-1.5, "-1.5"), (100, "100"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
            (1e-7, "1e-7"), (1e-6, "0.000001"), (0.1 + 0.2, "0.30000000000000004"), (123456789012, "123456789012"),
            (9007199254740992, "9007199254740992"), (Double.leastNonzeroMagnitude, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
            (.infinity, "Infinity"), (.nan, "NaN"), (33.33, "33.33"), (1.5e300, "1.5e+300"), (2e-7, "2e-7"), (123e-20, "1.23e-18"),
        ]
        for (n, want) in cases { XCTAssertEqual(jsNumberToString(n), want, "\(n)") }
    }

    func testStringToNumberMatchesJavaScript() {
        let cases: [(String, Double?)] = [
            ("10", 10), (" 10 ", 10), ("1e1", 10), ("0x10", 16), ("0b11", 3), ("0o7", 7), (".5", 0.5), ("5.", 5), ("+5", 5),
            ("-0x10", nil), ("5_0", nil), ("Infinity", .infinity), ("-Infinity", -.infinity), ("NaN", nil), ("", 0), (" ", 0),
            ("\u{FEFF}7", 7), ("١٢", nil), ("abc", nil), ("1e400", .infinity), ("0x1fffffffffffff1", 144115188075855856),
            ("0xFFFFFFFFFFFFFFFFF", 295147905179352825856), ("\u{00A0}\u{2028}3\u{3000}", 3),
        ]
        for (s, want) in cases {
            let got = jsStringToNumber(s)
            if let want { XCTAssertEqual(got, want, s) } else { XCTAssertTrue(got.isNaN, s) }
        }
    }

    func testJSONValueRoundTrip() throws {
        let v = try JSONValue(jsonText: #"{"b":[1,2.5,"x",null,true],"a":{"z":-0}}"#)
        XCTAssertEqual(v["b"]?[2], "x")
        XCTAssertEqual(v.jsonString, #"{"a":{"z":0},"b":[1,2.5,"x",null,true]}"#)
        let encoded = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), v)
    }

    func testContextKeyWinsOverAnAttributeNamedKey() {
        var c: NanoFlagsContext = ["key": "u1", "plan": "pro"]
        XCTAssertEqual(c.key, "u1")
        c.attributes["key"] = "other"
        XCTAssertEqual(c.engineValue().field("key").stringValue, "u1")
        XCTAssertEqual(NanoFlagsContext(attributes: ["key": 5]).engineValue().field("key").numberValue, 5)
    }
}
