import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A public Ed25519 bundle-signing key as a JWK (`GET /v1/keys` serves these).
public struct SigningKey: Sendable, Hashable, Codable {
    public var kty: String
    public var crv: String
    /// The public key, base64url.
    public var x: String
    public var kid: String?
    /// A private member. A JWK that carries one is a private key and is refused: private keys never belong
    /// in an app.
    public var d: String?

    public init(kty: String = "OKP", crv: String = "Ed25519", x: String, kid: String? = nil) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.kid = kid
        self.d = nil
    }

    var isPublicEd25519: Bool { kty == "OKP" && crv == "Ed25519" && !x.isEmpty && (d ?? "").isEmpty }
}

extension NanoFlags {
    /// The hosted NanoFlags edge. With this base URL (the default) every bundle is verified against
    /// `officialSigningKeys` and unsigned bundles are refused.
    public static let officialEdgeURL = URL(string: "https://edge.nanoflags.io")!

    /// The public halves of the production bundle-signing keys (safe to embed). A bundle signed with a key
    /// id that is not listed here — a rotation after this release — makes the client load `GET /v1/keys`
    /// once (at most once a minute).
    public static let officialSigningKeys: [SigningKey] = [
        SigningKey(x: "wQu1EsaE-yTjqpUbibGyBrajy3IiRb7LyaiqeYRxG4U", kid: "k1"),
    ]
}

/// How bundle signatures are checked before a new bundle replaces the one in use.
public enum VerifyMode: Sendable {
    /// The default. On the official edge: the embedded production keys (plus `GET /v1/keys` once when a bundle
    /// names an unknown key id), and unsigned bundles are refused. On any other edge: nothing is verified.
    case automatic
    /// Verify with these settings.
    case enabled(VerifyOptions)
    /// Accept bundles without checking signatures. Only for local development against your own edge.
    case disabled
}

public struct VerifyOptions: Sendable {
    /// Keys to verify with. nil: the embedded production keys on the official edge, the keys of
    /// `GET /v1/keys` on any other edge. Pinning keys is stronger than fetching them: fetched keys are only
    /// as trustworthy as the connection they arrived over.
    public var publicKeys: [SigningKey]?
    /// Also load `GET /v1/keys` (once, and again at most once a minute when a bundle names an unknown key id).
    public var fetchKeys: Bool
    /// Refuse bundles that carry no signature (the edge's unsigned fallback). nil: true on the official
    /// edge, false elsewhere.
    public var require: Bool?

    public init(publicKeys: [SigningKey]? = nil, fetchKeys: Bool = false, require: Bool? = nil) {
        self.publicKeys = publicKeys
        self.fetchKeys = fetchKeys
        self.require = require
    }
}

/// What a bundle was signed with: enough to verify it again later (a persisted copy is re-verified).
struct SignatureInfo: Sendable, Equatable {
    var signature: String
    var kid: String?
    var environmentId: String
    var revision: Int
    var checksum: String

    func toJS() -> JSValue {
        var b = JSObjectBuilder()
        b.set("signature", .string(signature))
        if let kid { b.set("kid", .string(kid)) }
        b.set("environmentId", .string(environmentId))
        b.set("revision", .number(Double(revision)))
        b.set("checksum", .string(checksum))
        return .object(b.build())
    }

    init(signature: String, kid: String?, environmentId: String, revision: Int, checksum: String) {
        self.signature = signature
        self.kid = kid
        self.environmentId = environmentId
        self.revision = revision
        self.checksum = checksum
    }

    init?(_ v: JSValue) {
        guard case .string(let s) = v.field("signature"), case .string(let e) = v.field("environmentId"),
              case .string(let c) = v.field("checksum"), case .number(let r) = v.field("revision"), r == r.rounded()
        else { return nil }
        self.init(signature: s, kid: v.field("kid").stringValue, environmentId: e, revision: Int(r), checksum: c)
    }
}

struct ImportedKey: Sendable {
    let kid: String?
    let raw: Data
}

func base64URLDecode(_ input: String) -> Data? {
    var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.hasSuffix("=") { s.removeLast() }
    if s.count % 4 == 1 { return nil }
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    return Data(base64Encoded: s)
}

func importKeys(_ jwks: [SigningKey]) -> [ImportedKey] {
    jwks.compactMap { k in
        guard k.isPublicEd25519, let raw = base64URLDecode(k.x), CryptoShim.isValidEd25519PublicKey(raw) else { return nil }
        return ImportedKey(kid: k.kid, raw: raw)
    }
}

/// The signed text: "nanoflags-bundle-v1\n<environment>\n<revision>\n<checksum>\n<sha256 hex of the bundle text>".
func canonicalString(environmentId: String, revision: Int, checksum: String, bundleText: Data) -> Data {
    Data("nanoflags-bundle-v1\n\(environmentId)\n\(revision)\n\(checksum)\n\(CryptoShim.sha256Hex(bundleText))".utf8)
}

/// Whether `info.signature` is a valid signature by one of `keys` over the canonical string for
/// `bundleText`. A key id narrows the candidates; an unknown key id matches no key.
func verifyBundleText(keys: [ImportedKey], info: SignatureInfo, bundleText: Data) -> Bool {
    guard let sig = base64URLDecode(info.signature), sig.count == 64 else { return false }
    let msg = canonicalString(environmentId: info.environmentId, revision: info.revision, checksum: info.checksum, bundleText: bundleText)
    for k in keys {
        if let want = info.kid, let have = k.kid, want != have { continue }
        if CryptoShim.verifyEd25519(publicKey: k.raw, signature: sig, message: msg) { return true }
    }
    return false
}

/// The exact source bytes of the top-level member `name` of a JSON object (the last one when it repeats,
/// like JSON.parse), or nil. The edge embeds the stored, signed bundle text byte-for-byte; hashing that span
/// avoids any re-serialisation.
func rawMember(_ text: Data, _ name: String) -> Data? {
    let t = [UInt8](text)
    let n = t.count
    var i = 0
    func ws() {
        while i < n && (t[i] == 0x20 || t[i] == 0x0A || t[i] == 0x0D || t[i] == 0x09) { i += 1 }
    }
    func str() -> (Int, Int)? {
        guard i < n, t[i] == UInt8(ascii: "\"") else { return nil }
        let start = i
        i += 1
        while i < n {
            switch t[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""):
                i += 1
                return (start, i)
            default: i += 1
            }
        }
        return nil
    }
    func value() -> Bool {
        ws()
        guard i < n else { return false }
        switch t[i] {
        case UInt8(ascii: "\""): return str() != nil
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while i < n {
                switch t[i] {
                case UInt8(ascii: "\""):
                    if str() == nil { return false }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                i += 1
                if depth == 0 { return true }
            }
            return false
        default:
            let start = i
            while i < n && ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09].contains(t[i]) { i += 1 }
            return i > start
        }
    }
    ws()
    guard i < n, t[i] == UInt8(ascii: "{") else { return nil }
    i += 1
    var found: Data?
    while true {
        ws()
        if i < n && t[i] == UInt8(ascii: "}") { return found }
        guard let (ks, ke) = str() else { return nil }
        ws()
        guard i < n, t[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        ws()
        let start = i
        guard value() else { return nil }
        if let key = try? JSValue.parse(Data(t[ks..<ke])), key.isString(name) { found = Data(t[start..<i]) }
        ws()
        if i < n && t[i] == UInt8(ascii: ",") {
            i += 1
        } else if i < n && t[i] == UInt8(ascii: "}") {
            return found
        } else {
            return nil
        }
    }
}

/// The effective verification settings and the key cache (pinned/embedded keys + `/v1/keys`).
actor KeyRing {
    let base: [ImportedKey]
    let require: Bool
    let refetch: Bool
    private var fetched: [ImportedKey] = []
    private var fetchedAt: Date?
    private var fetching: Task<[ImportedKey], Error>?
    private let fetchKeys: @Sendable () async throws -> [ImportedKey]
    static let refetchInterval: TimeInterval = 60

    init(base: [ImportedKey], require: Bool, refetch: Bool, fetchKeys: @escaping @Sendable () async throws -> [ImportedKey]) {
        self.base = base
        self.require = require
        self.refetch = refetch
        self.fetchKeys = fetchKeys
    }

    /// Keys to verify a signature by `kid` with. With `refetch`, a key id none of the known keys has
    /// (rotation) loads `/v1/keys` once — again at most once a minute.
    func keys(for kid: String?) async throws -> [ImportedKey] {
        if !refetch { return base }
        let known = base + fetched
        if !known.isEmpty && (kid == nil || known.contains { $0.kid == kid }) { return known }
        if let at = fetchedAt, Date().timeIntervalSince(at) < KeyRing.refetchInterval { return known }
        let task: Task<[ImportedKey], Error>
        if let f = fetching {
            task = f
        } else {
            let load = fetchKeys
            task = Task { try await load() }
            fetching = task
        }
        do {
            let keys = try await task.value
            fetching = nil
            fetched = keys
            fetchedAt = Date()
        } catch {
            fetching = nil
            // Without any key the bundle cannot be checked (the next bundle tries again). With the embedded
            // keys the failed reload counts as this minute's reload, so a bad key id cannot make every poll
            // ask for keys.
            if base.isEmpty { throw error }
            fetchedAt = Date()
        }
        return base + fetched
    }
}
