import Foundation

// Observable wrappers around a client. `NanoFlagsModel` (Observation, iOS 17+) also compiles on Linux and is
// tested there; the SwiftUI / Combine helpers in SwiftUI.swift are Apple-only.

/// Runs `body` on the main thread (immediately when already there).
func onMain(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
}

#if canImport(Observation)
import Observation

/// An `@Observable` view of a client (iOS 17, macOS 14, tvOS 17, watchOS 10): views that read a flag through
/// it re-render when the configuration, the context or the status changes.
///
///     @State var flags = NanoFlagsModel(client: NanoFlags.start(key: "nf_pub_…"))
///     var body: some View { if flags.bool("new-checkout", default: false) { NewCheckout() } }
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@Observable
public final class NanoFlagsModel: @unchecked Sendable {
    public private(set) var revision: Int?
    public private(set) var status: NanoFlagsStatus
    /// Bumped on every change; reading a flag reads it, which is what makes views depend on changes.
    public private(set) var version = 0

    @ObservationIgnored public let client: NanoFlagsClient
    @ObservationIgnored private var subscriptions: [NanoFlagsSubscription] = []

    public init(client: NanoFlagsClient) {
        self.client = client
        revision = client.revision
        status = client.status
        subscriptions = [
            client.onChange { [weak self] _ in self?.refresh() },
            client.onStatusChange { [weak self] _ in self?.refresh() },
        ]
    }

    deinit { subscriptions.forEach { $0.cancel() } }

    private func refresh() {
        onMain { [weak self] in
            guard let self else { return }
            self.revision = self.client.revision
            self.status = self.client.status
            self.version += 1
        }
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        _ = version
        return client.boolVariation(key: key, default: defaultValue)
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        _ = version
        return client.stringVariation(key: key, default: defaultValue)
    }

    public func number(_ key: String, default defaultValue: Double) -> Double {
        _ = version
        return client.numberVariation(key: key, default: defaultValue)
    }

    public func json(_ key: String, default defaultValue: JSONValue) -> JSONValue {
        _ = version
        return client.jsonVariation(key: key, default: defaultValue)
    }

    public func value<T: FlagValue>(_ key: String, default defaultValue: T) -> T {
        _ = version
        return client.variationDetail(key: key, default: defaultValue).value
    }

    /// Changes the context (see `NanoFlagsClient.identify(context:)`).
    public func identify(context: NanoFlagsContext) { client.identify(context: context) }
}
#endif
