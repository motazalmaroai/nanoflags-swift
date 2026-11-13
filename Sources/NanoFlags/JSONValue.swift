import Foundation

/// A JSON value: what a flag serves and what a context attribute holds.
///
/// Numbers are `Double`, as in JavaScript (every NanoFlags SDK evaluates numbers as IEEE-754 doubles).
/// Object members keep their order when they come from a bundle; equality ignores member order.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// Member `key` of an object value.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    /// Element `index` of an array value.
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// The JSON text, as JSON.stringify writes it (object members sorted by key, since Swift dictionaries
    /// have no order).
    public var jsonString: String { toJS().json ?? "null" }

    /// Parses JSON text (JSON.parse semantics).
    public init(jsonText: String) throws {
        self = JSONValue(try JSValue.parse(jsonText))
    }

    /// Parses JSON data (JSON.parse semantics).
    public init(jsonData: Data) throws {
        self = JSONValue(try JSValue.parse(jsonData))
    }

    /// The JavaScript type name used in telemetry: "null", "boolean", "number", "string", "array", "object".
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

extension JSONValue {
    /// From an engine value; `.undefined` and functions become `nil`.
    init?(engine v: JSValue) {
        switch v {
        case .undefined, .function: return nil
        default: self.init(v)
        }
    }

    /// From an engine value (`.undefined` → null).
    init(_ v: JSValue) {
        switch v {
        case .undefined, .null, .function: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = .number(n)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map { JSONValue($0) })
        case .object(let o):
            var d: [String: JSONValue] = [:]
            d.reserveCapacity(o.count)
            for (k, e) in o.entries {
                if case .undefined = e { continue }
                d[k] = JSONValue(e)
            }
            self = .object(d)
        }
    }

    /// To an engine value. Object members are added in sorted key order (deterministic JSON text).
    func toJS() -> JSValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map { $0.toJS() })
        case .object(let o):
            var b = JSObjectBuilder()
            for k in o.keys.sorted() { b.set(k, o[k]!.toJS()) }
            return .object(b.build())
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var d: [String: JSONValue] = [:]
        for (k, v) in elements { d[k] = v }
        self = .object(d)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString }
}

// MARK: - Typed flag values

/// A Swift type a flag can be read as. `Bool`, `String`, `Double`, `Int` and `JSONValue` conform.
public protocol FlagValue: Sendable {
    /// The served value as this type, or nil when it has another type (the default is returned then,
    /// with reason `error`).
    static func fromFlag(_ value: JSONValue) -> Self?
    var jsonValue: JSONValue { get }
}

extension Bool: FlagValue {
    public static func fromFlag(_ value: JSONValue) -> Bool? { value.boolValue }
    public var jsonValue: JSONValue { .bool(self) }
}

extension String: FlagValue {
    public static func fromFlag(_ value: JSONValue) -> String? { value.stringValue }
    public var jsonValue: JSONValue { .string(self) }
}

extension Double: FlagValue {
    public static func fromFlag(_ value: JSONValue) -> Double? {
        guard let n = value.numberValue, n.isFinite else { return nil }
        return n
    }
    public var jsonValue: JSONValue { .number(self) }
}

extension Int: FlagValue {
    /// A number flag read as an integer: only whole numbers that fit are accepted.
    public static func fromFlag(_ value: JSONValue) -> Int? {
        guard let n = value.numberValue, n.isFinite, n == n.rounded(), abs(n) < 9.007_199_254_740_992e15 else { return nil }
        return Int(n)
    }
    public var jsonValue: JSONValue { .number(Double(self)) }
}

extension JSONValue: FlagValue {
    public static func fromFlag(_ value: JSONValue) -> JSONValue? { value }
    public var jsonValue: JSONValue { self }
}
