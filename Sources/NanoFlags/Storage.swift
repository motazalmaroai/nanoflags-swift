import Foundation

/// Where the last verified bundle is kept between launches (offline-first start). The stored copy is
/// outside the trust boundary: it is verified again when it is loaded.
public protocol BundleStorage: Sendable {
    func load(id: String) -> Data?
    func save(_ data: Data, id: String) throws
    func remove(id: String)
}

/// The built-in storage choices.
public enum StorageOption: Sendable {
    /// A file in Application Support/NanoFlags (excluded from iCloud/iTunes backups on Apple platforms).
    /// The default.
    case applicationSupport
    /// A file in this directory.
    case directory(URL)
    /// `UserDefaults` (the standard defaults, or the suite with this name). Fine for small bundles.
    case userDefaults(suiteName: String?)
    /// Your own storage.
    case custom(BundleStorage)
    /// Nothing is persisted: every launch starts without a configuration until the edge answers.
    case none

    func make() -> BundleStorage? {
        switch self {
        case .applicationSupport: return FileBundleStorage(directory: nil)
        case .directory(let url): return FileBundleStorage(directory: url)
        case .userDefaults(let suite): return UserDefaultsBundleStorage(suiteName: suite)
        case .custom(let s): return s
        case .none: return nil
        }
    }
}

/// One JSON file per SDK key + edge, written atomically.
public struct FileBundleStorage: BundleStorage {
    let directory: URL?

    public init(directory: URL?) { self.directory = directory }

    func dir() throws -> URL {
        if let directory { return directory }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("NanoFlags", isDirectory: true)
    }

    func file(_ id: String) throws -> URL { try dir().appendingPathComponent("bundle-\(id).json") }

    public func load(id: String) -> Data? {
        guard let url = try? file(id) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func save(_ data: Data, id: String) throws {
        let d = try dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var url = try file(id)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        #if canImport(Darwin)
        // A cache of the edge's configuration: never worth backing up.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
        _ = url
    }

    public func remove(id: String) {
        if let url = try? file(id) { try? FileManager.default.removeItem(at: url) }
    }
}

public struct UserDefaultsBundleStorage: BundleStorage, @unchecked Sendable {
    let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    var defaults: UserDefaults { suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func load(id: String) -> Data? { defaults.data(forKey: "nanoflags.bundle.\(id)") }
    public func save(_ data: Data, id: String) throws { defaults.set(data, forKey: "nanoflags.bundle.\(id)") }
    public func remove(id: String) { defaults.removeObject(forKey: "nanoflags.bundle.\(id)") }
}

/// In-memory storage (tests, previews).
public final class MemoryBundleStorage: BundleStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func load(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    public func save(_ data: Data, id: String) throws {
        lock.lock()
        items[id] = data
        lock.unlock()
    }

    public func remove(id: String) {
        lock.lock()
        items[id] = nil
        lock.unlock()
    }
}
