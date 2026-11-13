import Foundation

// Platform lifecycle and network-path observers. Everything here is behind `#if`: this file compiles to
// nothing on Linux (where it is built and tested), so the Apple branches are NOT compiled in this
// repository's CI. They only call `pause()`, `resume()` and `networkChanged(constrained:available:)`,
// which are platform-independent and covered by the Linux tests.

#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(Network)
import Network
#endif

#if canImport(Network)
final class PathObserver: @unchecked Sendable {
    let monitor = NWPathMonitor()

    init(_ onChange: @escaping @Sendable (_ constrained: Bool, _ available: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onChange(path.isConstrained, path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "io.nanoflags.path"))
    }

    func cancel() { monitor.cancel() }
}
#endif

/// A NotificationCenter registration (removed on close).
struct NotificationObservation {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

extension NanoFlagsClient {
    func startLifecycleObservers() {
        var observers: [Any] = []
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @Sendable (NanoFlagsClient) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if let self { body(self) }
            }
            observers.append(NotificationObservation(center: center, token: token))
        }
        if options.pauseInBackground {
            #if canImport(UIKit) && !os(watchOS)
            observe(.default, UIApplication.didEnterBackgroundNotification) { $0.pause() }
            observe(.default, UIApplication.willEnterForegroundNotification) { $0.resume() }
            #elseif os(watchOS)
            observe(.default, WKExtension.applicationDidEnterBackgroundNotification) { $0.pause() }
            observe(.default, WKExtension.applicationWillEnterForegroundNotification) { $0.resume() }
            #elseif canImport(AppKit)
            observe(.default, NSApplication.didHideNotification) { $0.pause() }
            observe(.default, NSApplication.didUnhideNotification) { $0.resume() }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.pause() }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.resume() }
            #endif
        }
        #if canImport(Network)
        observers.append(PathObserver { [weak self] constrained, available in
            self?.networkChanged(constrained: constrained, available: available)
        })
        #endif
        locked { platformObservers = observers }
    }

    func stopLifecycleObservers(_ observers: [Any]) {
        for o in observers {
            if let n = o as? NotificationObservation { n.center.removeObserver(n.token) }
            #if canImport(Network)
            if let p = o as? PathObserver { p.cancel() }
            #endif
        }
    }
}
