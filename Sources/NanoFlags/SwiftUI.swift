// SwiftUI and Combine helpers. Apple platforms only: this file compiles to nothing on Linux, so it is NOT
// compiled by the Linux build in this repository; the macOS / iOS-simulator CI jobs (ci/mobile-swift.yml)
// compile and test it (Tests/NanoFlagsTests/AppleTests.swift).
#if canImport(SwiftUI) && canImport(Combine)
import Combine
import SwiftUI

/// An `ObservableObject` view of a client (iOS 14+): views observing it re-render when the configuration,
/// the context or the status changes. `NanoFlagsObservable.shared` follows `NanoFlags.shared`.
///
///     @StateObject var flags = NanoFlagsObservable(client: NanoFlags.start(key: "nf_pub_…"))
public final class NanoFlagsObservable: ObservableObject, @unchecked Sendable {
    @Published public private(set) var revision: Int?
    @Published public private(set) var status: NanoFlagsStatus = .notReady
    /// Bumped (on the main thread) on every change.
    @Published public private(set) var version = 0

    public private(set) var client: NanoFlagsClient?
    private var subscriptions: [NanoFlagsSubscription] = []
    private let lock = NSLock()

    public init(client: NanoFlagsClient?) {
        if let client { attach(client) }
    }

    /// Follows `NanoFlags.shared`: before `NanoFlags.start` is called every flag reads its default.
    public static let shared: NanoFlagsObservable = {
        let o = NanoFlagsObservable(client: nil)
        NanoFlags.observeShared { [weak o] client in o?.attach(client) }
        return o
    }()

    func attach(_ client: NanoFlagsClient) {
        lock.lock()
        subscriptions.forEach { $0.cancel() }
        self.client = client
        subscriptions = [
            client.onChange { [weak self] _ in self?.refresh() },
            client.onStatusChange { [weak self] _ in self?.refresh() },
        ]
        lock.unlock()
        refresh()
    }

    deinit { subscriptions.forEach { $0.cancel() } }

    private func refresh() {
        onMain { [weak self] in
            guard let self else { return }
            self.revision = self.client?.revision
            self.status = self.client?.status ?? .notReady
            self.version += 1
        }
    }

    public func value<T: FlagValue>(_ key: String, default defaultValue: T) -> T {
        client?.variationDetail(key: key, default: defaultValue).value ?? defaultValue
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool { value(key, default: defaultValue) }
    public func string(_ key: String, default defaultValue: String) -> String { value(key, default: defaultValue) }
    public func number(_ key: String, default defaultValue: Double) -> Double { value(key, default: defaultValue) }
    public func json(_ key: String, default defaultValue: JSONValue) -> JSONValue { value(key, default: defaultValue) }
}

/// A flag as a view property; the view re-renders when its value can have changed.
///
///     struct CheckoutButton: View {
///         @FeatureFlag("new-checkout", default: false) var newCheckout
///         var body: some View { Text(newCheckout ? "Pay now" : "Checkout") }
///     }
///
/// Reads `NanoFlagsObservable.shared` (the client of the last `NanoFlags.start`) unless you pass one.
@propertyWrapper
public struct FeatureFlag<Value: FlagValue>: DynamicProperty {
    @ObservedObject private var flags: NanoFlagsObservable
    private let key: String
    private let defaultValue: Value

    public init(_ key: String, default defaultValue: Value, flags: NanoFlagsObservable = .shared) {
        self.key = key
        self.defaultValue = defaultValue
        _flags = ObservedObject(wrappedValue: flags)
    }

    public var wrappedValue: Value { flags.value(key, default: defaultValue) }
}

private struct FlagChangeModifier<Value: FlagValue & Equatable>: ViewModifier {
    @ObservedObject var flags: NanoFlagsObservable
    let key: String
    let defaultValue: Value
    let action: (Value) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: flags.value(key, default: defaultValue)) { action($0) }
    }
}

extension View {
    /// Puts `flags` into the environment (`@EnvironmentObject var flags: NanoFlagsObservable`).
    public func nanoFlags(_ flags: NanoFlagsObservable) -> some View {
        environmentObject(flags)
    }

    /// Calls `action` with the new value whenever the value of flag `key` changes.
    public func onFlagChange<Value: FlagValue & Equatable>(_ key: String, default defaultValue: Value, flags: NanoFlagsObservable = .shared,
                                                           perform action: @escaping (Value) -> Void) -> some View {
        modifier(FlagChangeModifier(flags: flags, key: key, defaultValue: defaultValue, action: action))
    }
}
#endif
