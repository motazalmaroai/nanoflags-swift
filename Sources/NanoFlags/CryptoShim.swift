import Foundation

// The single place that touches a crypto library: CryptoKit on Apple platforms, swift-crypto
// (`import Crypto`, the same API backed by BoringSSL) everywhere else.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum CryptoShim {
    #if canImport(CryptoKit)
    static let backend = "CryptoKit"
    #else
    static let backend = "swift-crypto"
    #endif

    /// Lower-case hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var out = ""
        out.reserveCapacity(64)
        for b in digest {
            let s = String(b, radix: 16)
            if s.count == 1 { out += "0" }
            out += s
        }
        return out
    }

    /// True when `signature` is a valid Ed25519 signature by the raw 32-byte `publicKey` over `message`.
    static func verifyEd25519(publicKey: Data, signature: Data, message: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Whether `publicKey` is a usable Ed25519 public key.
    static func isValidEd25519PublicKey(_ publicKey: Data) -> Bool {
        publicKey.count == 32 && (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil
    }
}
