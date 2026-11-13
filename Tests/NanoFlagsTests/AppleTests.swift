import Foundation
import XCTest
@testable import NanoFlags
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(SwiftUI) && canImport(Combine)
import Combine
import SwiftUI
#endif
#if canImport(Observation)
import Observation
#endif

/// Platform pieces. The Observation test runs everywhere (Linux included); the lifecycle, SwiftUI and
/// CryptoKit tests only on Apple platforms (macOS `swift test`, iOS simulator `xcodebuild test`: see
/// ci/mobile-swift.yml). They are not compiled on Linux.
final class PlatformTests: XCTestCase {
    func testCryptoBackend() throws {
        #if canImport(CryptoKit)
        XCTAssertEqual(CryptoShim.backend, "CryptoKit")
        #else
        XCTAssertEqual(CryptoShim.backend, "swift-crypto")
        #endif
        // The production vector through the shim (CryptoKit on Apple platforms).
        let url = try XCTUnwrap(Bundle.module.url(forResource: "signed-demo-response", withExtension: "json", subdirectory: "Resources"))
        let doc = try JSONValue(jsonData: Data(contentsOf: url))
        let body = Data(try XCTUnwrap(doc["body"]?.stringValue).utf8)
        let headers = try XCTUnwrap(doc["headers"]?.objectValue)
        let parsed = try JSValue.parse(body)
        let info = SignatureInfo(signature: headers["x-nanoflags-signature"]!.stringValue!, kid: "k1", environmentId: headers["x-nanoflags-environment-id"]!.stringValue!,
                                 revision: Int(parsed.field("revision").numberValue!), checksum: parsed.field("checksum").stringValue!)
        XCTAssertTrue(verifyBundleText(keys: importKeys(NanoFlags.officialSigningKeys), info: info, bundleText: rawMember(body, "bundle")!))
    }

    #if canImport(Observation)
    func testObservableModelTracksChanges() throws {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) else { throw XCTSkip("Observation needs iOS 17 / macOS 14") }
        let edge = FakeEdge()
        edge.offline = true
        let boot = Data("{\"schema\":1,\"project\":\"p\",\"environment\":\"e\",\"revision\":0,\"flags\":\(checkoutFlags),\"segments\":{}}".utf8)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.bootstrap = boot }
        defer { c.close() }
        let model = NanoFlagsModel(client: c)
        XCTAssertFalse(model.bool("new-checkout", default: true))
        let changed = expectation(description: "observation fired")
        withObservationTracking {
            _ = model.bool("new-checkout", default: false)
        } onChange: {
            changed.fulfill()
        }
        c.identify(context: ["plan": "pro"])
        wait(for: [changed], timeout: 5) // spins the main run loop, where the model is updated
        XCTAssertTrue(model.bool("new-checkout", default: false))
    }
    #endif

    #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
    /// Background → the live socket closes; foreground → it reconnects and catches up. Simulated with the
    /// notifications the client observes.
    func testLifecycleNotificationsPauseAndResume() async throws {
        let edge = FakeEdge()
        edge.publish(flags: checkoutFlags)
        var o = NanoFlagsOptions(baseURL: URL(string: "https://edge.test")!, service: "swift-tests", storage: .none, events: .disabled)
        o.verify = .enabled(VerifyOptions(publicKeys: [edge.publicJWK], require: true))
        let c = NanoFlagsClient(key: TestKeys.client, options: o, network: edge, startPlatformObservers: true)
        defer { c.close() }
        await c.ready(timeout: 5)
        await assertEventually({ c.transport == .live })
        #if canImport(UIKit) && !os(watchOS)
        let background = UIApplication.didEnterBackgroundNotification
        let foreground = UIApplication.willEnterForegroundNotification
        #else
        let background = NSApplication.didHideNotification
        let foreground = NSApplication.didUnhideNotification
        #endif
        NotificationCenter.default.post(name: background, object: nil)
        await assertEventually({ edge.openSockets.isEmpty && c.locked { c.paused } })
        edge.publish(flags: checkoutFlags.replacingOccurrences(of: "\"default\":3", with: "\"default\":8"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(c.revision, 1)
        NotificationCenter.default.post(name: foreground, object: nil)
        await assertEventually({ c.revision == 2 && c.transport == .live })
        XCTAssertEqual(c.numberVariation(key: "limit", default: 0), 8)
    }
    #endif

    #if canImport(SwiftUI) && canImport(Combine)
    func testObservableObjectAndPropertyWrapper() throws {
        let edge = FakeEdge()
        edge.offline = true
        let boot = Data("{\"schema\":1,\"project\":\"p\",\"environment\":\"e\",\"revision\":0,\"flags\":\(checkoutFlags),\"segments\":{}}".utf8)
        let c = NanoFlagsClient.test(edge: edge) { $0.transport = .polling; $0.bootstrap = boot }
        defer { c.close() }
        let flags = NanoFlagsObservable(client: c)
        let wrapper = FeatureFlag("new-checkout", default: false, flags: flags)
        XCTAssertFalse(wrapper.wrappedValue)
        var bag = Set<AnyCancellable>()
        let bumped = expectation(description: "objectWillChange")
        bumped.assertForOverFulfill = false
        flags.objectWillChange.sink { bumped.fulfill() }.store(in: &bag)
        c.identify(context: ["plan": "pro"])
        wait(for: [bumped], timeout: 5)
        XCTAssertTrue(wrapper.wrappedValue)
        XCTAssertTrue(flags.bool("new-checkout", default: false))
        XCTAssertEqual(flags.string("accent", default: "x"), "green") // no key: outside the rollout
        // The modifiers build.
        _ = Text("x").nanoFlags(flags).onFlagChange("new-checkout", default: false, flags: flags) { _ in }
    }

    func testSharedObservableFollowsStart() throws {
        let shared = NanoFlagsObservable.shared
        let c = NanoFlags.start(key: TestKeys.client, options: NanoFlagsOptions(baseURL: URL(string: "http://127.0.0.1:9")!, transport: .polling, storage: .none, events: .disabled))
        defer { c.close() }
        XCTAssertTrue(shared.client === c)
        XCTAssertTrue(NanoFlags.shared === c)
    }
    #endif
}
