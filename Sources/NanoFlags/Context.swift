import Foundation

/// Who flags are evaluated for: a stable `key` (the bucketing identity of percentage rollouts) and any
/// attributes your rules use (`plan`, `country`, `appVersion`, …).
///
/// The context lives on the device. It is never sent to the edge: evaluation is local, and telemetry only
/// carries the names and JSON types of the attributes a flag's rules use — never their values.
public struct NanoFlagsContext: Sendable, Hashable {
    /// The bucketing identity. A rollout bucketing by `key` treats a context without one as outside the
    /// allocation. See `NanoFlags.anonymousKey` for a stable per-install identity.
    public var key: String?
    public var attributes: [String: JSONValue]

    public init(key: String? = nil, attributes: [String: JSONValue] = [:]) {
        self.key = key
        self.attributes = attributes
    }

    /// An empty context (no key, no attributes).
    public static let empty = NanoFlagsContext(key: nil, attributes: [:])

    public subscript(attribute: String) -> JSONValue? {
        get { attribute == "key" ? key.map { JSONValue.string($0) } ?? attributes["key"] : attributes[attribute] }
        set {
            if attribute == "key" {
                key = newValue?.stringValue
                if key == nil { attributes["key"] = newValue }
            } else {
                attributes[attribute] = newValue
            }
        }
    }

    /// A copy with `attributes` added (they replace attributes of the same name).
    public func with(_ more: [String: JSONValue]) -> NanoFlagsContext {
        var c = self
        for (k, v) in more { c[k] = v }
        return c
    }

    /// The engine's view: an object with the attributes, and `key` (which wins over an attribute named
    /// "key").
    func engineValue() -> JSValue {
        var b = JSObjectBuilder()
        for k in attributes.keys.sorted() where !(k == "key" && key != nil) { b.set(k, attributes[k]!.toJS()) }
        if let key { b.set("key", .string(key)) }
        return .object(b.build())
    }
}

extension NanoFlagsContext: ExpressibleByDictionaryLiteral {
    /// `["key": "user-42", "plan": "pro"]`.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(key: nil, attributes: [:])
        for (k, v) in elements { self[k] = v }
    }
}
