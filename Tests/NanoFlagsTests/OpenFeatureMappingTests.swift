import Foundation
import XCTest
@testable import NanoFlags

final class OpenFeatureMappingTests: XCTestCase {
    func testResolutionMapping() async throws {
        let edge = FakeEdge()
        let flags = checkoutFlags.dropLast() + #","off-flag":{"type":"string","enabled":false,"clientExposed":true,"default":"a","off":"o","rules":[]}}"#
        edge.publish(flags: String(flags))
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling }
        defer { c.close() }
        let early = c.openFeatureResolve(key: "new-checkout", default: false)
        if c.revision == nil { XCTAssertEqual(early.error, .providerNotReady) }
        await c.ready(timeout: 5)
        let pro = NanoFlagsContext.openFeature(targetingKey: "user-1", attributes: ["plan": "pro", "key": "ignored"])
        XCTAssertEqual(pro.key, "user-1")
        let r1 = c.openFeatureResolve(key: "new-checkout", default: false, context: pro)
        XCTAssertEqual(r1.value, true)
        XCTAssertEqual(r1.reason, "TARGETING_MATCH")
        XCTAssertEqual(r1.variant, "pro")
        XCTAssertEqual(r1.revision, 1)
        let r2 = c.openFeatureResolve(key: "accent", default: "", context: pro)
        XCTAssertEqual(r2.reason, "SPLIT")
        XCTAssertEqual(r2.variant, "half")
        XCTAssertEqual(c.openFeatureResolve(key: "limit", default: 0.0).reason, "DEFAULT")
        XCTAssertEqual(c.openFeatureResolve(key: "limit", default: 0).value, 3)
        XCTAssertEqual(c.openFeatureResolve(key: "off-flag", default: "").reason, "DISABLED")
        let mismatch = c.openFeatureResolve(key: "limit", default: false)
        XCTAssertEqual(mismatch.error, .typeMismatch)
        XCTAssertEqual(mismatch.value, false)
        XCTAssertEqual(c.openFeatureResolve(key: "nope", default: false).error, .flagNotFound)
        XCTAssertEqual(c.openFeatureResolve(key: "theme", default: JSONValue.null).value, ["dark": true, "sizes": [1, 2]])
    }
}
