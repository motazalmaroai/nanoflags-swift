import Foundation

/// An evaluation mapped onto OpenFeature's vocabulary. Used by the NanoFlagsOpenFeature provider; it lives here
/// (platform-independent) so the mapping is tested on every platform, while the provider itself only converts
/// types.
///
/// Mapping (same as the Go, Python and JS providers): the OpenFeature targeting key becomes the NanoFlags `key`
/// (the bucketing identity) and wins over an attribute called "key"; reason off → DISABLED, default → DEFAULT,
/// a fixed-value rule → TARGETING_MATCH, a percentage rollout → SPLIT; the variant is the matching rule's id;
/// flag metadata carries the revision (and the rule index). A missing flag is FLAG_NOT_FOUND
/// (PROVIDER_NOT_READY while nothing is loaded), a served value of another type TYPE_MISMATCH, an evaluation
/// error GENERAL.
public struct OpenFeatureResolution<Value: FlagValue>: Sendable {
    public enum ErrorKind: String, Sendable {
        case providerNotReady = "PROVIDER_NOT_READY"
        case flagNotFound = "FLAG_NOT_FOUND"
        case typeMismatch = "TYPE_MISMATCH"
        case general = "GENERAL"
    }

    public let value: Value
    /// "DISABLED", "DEFAULT", "TARGETING_MATCH", "SPLIT" or "ERROR".
    public let reason: String
    public let variant: String?
    public let error: ErrorKind?
    public let errorMessage: String?
    public let revision: Int
    public let ruleIndex: Int?
}

extension NanoFlagsContext {
    /// A context from an OpenFeature evaluation context: the targeting key becomes `key`.
    public static func openFeature(targetingKey: String?, attributes: [String: JSONValue]) -> NanoFlagsContext {
        var attrs = attributes
        let key = (targetingKey?.isEmpty == false) ? targetingKey : nil
        if key != nil { attrs["key"] = nil }
        return NanoFlagsContext(key: key, attributes: attrs)
    }
}

extension NanoFlagsClient {
    /// Evaluates `key` for OpenFeature (see `OpenFeatureResolution`). `context` nil: the client's context.
    public func openFeatureResolve<T: FlagValue>(key: String, default defaultValue: T, context: NanoFlagsContext? = nil) -> OpenFeatureResolution<T> {
        let loaded = locked { snapshot != nil }
        // Untyped evaluation (any served value), then the type check of the requested accessor.
        let d = evaluate(key, JSONValue.null, context)
        func fail(_ kind: OpenFeatureResolution<T>.ErrorKind, _ message: String) -> OpenFeatureResolution<T> {
            OpenFeatureResolution(value: defaultValue, reason: "ERROR", variant: nil, error: kind, errorMessage: message, revision: d.revision, ruleIndex: nil)
        }
        switch d.reason {
        case .flagNotFound:
            return loaded ? fail(.flagNotFound, "Flag \"\(key)\" is not in the loaded configuration (r\(d.revision)).")
                : fail(.providerNotReady, "NanoFlags has no configuration loaded yet.")
        case .error:
            return fail(.general, d.errorMessage ?? "evaluation error")
        default:
            break
        }
        guard let typed = T.fromFlag(d.value) else {
            return fail(.typeMismatch, "Flag \"\(key)\" has a \(d.value.typeName) value; a \(String(describing: T.self)) was requested.")
        }
        let reason: String
        switch d.reason {
        case .off: reason = "DISABLED"
        case .default: reason = "DEFAULT"
        default: reason = d.inRollout != nil ? "SPLIT" : "TARGETING_MATCH"
        }
        return OpenFeatureResolution(value: typed, reason: reason, variant: d.ruleId, error: nil, errorMessage: nil, revision: d.revision, ruleIndex: d.ruleIndex)
    }
}
