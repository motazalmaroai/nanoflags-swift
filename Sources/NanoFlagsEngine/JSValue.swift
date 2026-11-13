import Foundation

// The engine is specified by its TypeScript implementation, which evaluates configuration that is plain
// JSON data with JavaScript semantics (truthiness, loose property access, Number(), String(),
// JSON.stringify). JSValue models exactly that subset of JavaScript, so this port produces the same
// results as the TypeScript engine, the Go port and the Python port, malformed configurations included.
//
// Swift strings compare and hash by canonical equivalence ("é" == "e\u{301}" is true); JavaScript
// compares code units. Every comparison in this module therefore works on UTF-8 bytes, which for
// well-formed strings is equivalent to comparing UTF-16 code units.

/// A JSON value with JavaScript semantics. `.undefined` is an absent value; `.function` only ever
/// comes from reading a String.prototype / Array.prototype member by name.
public enum JSValue: Sendable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSValue])
    case object(JSObject)
    case function(String)
}

/// Byte-exact string key (Swift's String equality is canonical equivalence, JavaScript's is not).
public struct JSKey: Hashable, Sendable {
    public let string: String
    public init(_ s: String) { string = s }
    public static func == (a: JSKey, b: JSKey) -> Bool { bytesEqual(a.string, b.string) }
    public func hash(into hasher: inout Hasher) {
        var s = string
        s.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

@inline(__always)
func bytesEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
}

/// A JavaScript plain object: own properties in JavaScript order (canonical array-index keys in
/// ascending numeric order first, then the other keys in insertion order). Immutable.
public final class JSObject: Sendable {
    public let keys: [String]
    let map: [JSKey: JSValue]

    init(keys: [String], map: [JSKey: JSValue]) {
        self.keys = keys
        self.map = map
    }

    public static let empty = JSObject(keys: [], map: [:])

    public subscript(_ key: String) -> JSValue? { map[JSKey(key)] }
    public var count: Int { keys.count }

    /// Entries in JavaScript order.
    public var entries: [(String, JSValue)] { keys.map { ($0, map[JSKey($0)]!) } }
}

/// Builds a JSObject with JavaScript's own-property order and JSON.parse's duplicate-key rule
/// (first position, last value).
public struct JSObjectBuilder {
    private var index: [(UInt32, String)] = []
    private var names: [String] = []
    private var map: [JSKey: JSValue] = [:]

    public init() {}

    public mutating func set(_ key: String, _ value: JSValue) {
        let k = JSKey(key)
        if map.updateValue(value, forKey: k) == nil {
            if let n = arrayIndex(key) {
                var lo = 0, hi = index.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if index[mid].0 < n { lo = mid + 1 } else { hi = mid }
                }
                index.insert((n, key), at: lo)
            } else {
                names.append(key)
            }
        }
    }

    public func build() -> JSObject {
        JSObject(keys: index.map { $0.1 } + names, map: map)
    }
}

/// A canonical array index (0 … 2³² − 2), as an object key.
func arrayIndex(_ k: String) -> UInt32? {
    let u = k.utf8
    if u.isEmpty || u.count > 10 { return nil }
    if u.count > 1 && u.first == UInt8(ascii: "0") { return nil }
    var n: UInt64 = 0
    for c in u {
        guard c >= 48 && c <= 57 else { return nil }
        n = n * 10 + UInt64(c - 48)
    }
    return n < 4_294_967_295 ? UInt32(n) : nil
}

// MARK: - Kinds and basic accessors

extension JSValue {
    public var isUndefined: Bool { if case .undefined = self { return true } else { return false } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
    var isNullish: Bool {
        switch self {
        case .undefined, .null: return true
        default: return false
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: JSObject? { if case .object(let o) = self { return o } else { return nil } }

    public func isString(_ s: String) -> Bool {
        if case .string(let x) = self { return bytesEqual(x, s) }
        return false
    }

    /// `typeOf` of the SDKs: "null", "array", or the JavaScript typeof.
    public var typeName: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        case .function: return "function"
        }
    }

    /// An own property of an object value (`.undefined` for anything else).
    public func field(_ name: String) -> JSValue { own(self, name) }
}

// MARK: - Abstract operations

extension JSValue {
    /// ToBoolean.
    public var truthy: Bool {
        switch self {
        case .undefined, .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    /// String(v).
    public var jsString: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return jsNumberToString(n)
        case .string(let s): return s
        case .array(let a): return jsJoin(a, ",")
        case .object: return "[object Object]"
        case .function(let name): return "function \(name)() { [native code] }"
        }
    }

    /// ToNumber(ToPrimitive(v, number)).
    public var jsNumber: Double {
        switch self {
        case .undefined: return .nan
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s): return jsStringToNumber(s)
        default: return jsStringToNumber(jsString)
        }
    }
}

/// Array.prototype.join.
func jsJoin(_ a: [JSValue], _ sep: String) -> String {
    var out = ""
    for (i, e) in a.enumerated() {
        if i > 0 { out += sep }
        if !e.isNullish { out += e.jsString }
    }
    return out
}

/// ECMAScript Number::toString(x) for radix 10.
public func jsNumberToString(_ f: Double) -> String {
    if f.isNaN { return "NaN" }
    if f == 0 { return "0" }
    if f.isInfinite { return f > 0 ? "Infinity" : "-Infinity" }
    let negative = f < 0
    // Swift's description is the shortest representation that round-trips (like ECMAScript's).
    let d = (negative ? -f : f).description
    var mantissa = Substring(d)
    var exp = 0
    if let e = d.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = d[..<e]
        exp = Int(d[d.index(after: e)...]) ?? 0
    }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = parts[0]
    let frac = parts.count > 1 ? parts[1] : ""
    var digits = Array(intPart.utf8) + Array(frac.utf8)
    var n = intPart.utf8.count + exp // position of the decimal point
    while digits.count > 1 && digits.first == UInt8(ascii: "0") {
        digits.removeFirst()
        n -= 1
    }
    while digits.count > 1 && digits.last == UInt8(ascii: "0") { digits.removeLast() }
    let k = digits.count
    let ds = String(decoding: digits, as: UTF8.self)
    var out: String
    if k <= n && n <= 21 {
        out = ds + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        out = String(ds.prefix(n)) + "." + String(ds.dropFirst(n))
    } else if -6 < n && n <= 0 {
        out = "0." + String(repeating: "0", count: -n) + ds
    } else {
        let e = n - 1
        let es = e < 0 ? "-" : "+"
        out = k == 1 ? ds + "e" + es + String(abs(e)) : String(ds.prefix(1)) + "." + String(ds.dropFirst()) + "e" + es + String(abs(e))
    }
    return negative ? "-" + out : out
}

func isJSWhitespace(_ v: UInt32) -> Bool {
    switch v {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return v >= 0x2000 && v <= 0x200A
    }
}

/// String.prototype.trim.
public func jsTrim(_ s: String) -> String {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isJSWhitespace($0.value) }) else { return "" }
    let last = scalars.lastIndex(where: { !isJSWhitespace($0.value) })!
    return String(scalars[first...last])
}

/// ECMAScript StringToNumber.
public func jsStringToNumber(_ input: String) -> Double {
    let s = Array(jsTrim(input).utf8)
    if s.isEmpty { return 0 }
    switch String(decoding: s, as: UTF8.self) {
    case "Infinity", "+Infinity": return .infinity
    case "-Infinity": return -.infinity
    default: break
    }
    if s.count > 2 && s[0] == UInt8(ascii: "0") {
        var bitsPerDigit = 0
        switch s[1] {
        case UInt8(ascii: "x"), UInt8(ascii: "X"): bitsPerDigit = 4
        case UInt8(ascii: "o"), UInt8(ascii: "O"): bitsPerDigit = 3
        case UInt8(ascii: "b"), UInt8(ascii: "B"): bitsPerDigit = 1
        default: break
        }
        if bitsPerDigit > 0 {
            var bits: [Bool] = []
            for c in s[2...] {
                guard let d = hexValue(c), d < (1 << bitsPerDigit) else { return .nan }
                for b in stride(from: bitsPerDigit - 1, through: 0, by: -1) { bits.append((d >> b) & 1 == 1) }
            }
            return bitsToDouble(bits)
        }
    }
    // StrDecimalLiteral: [+-] (digits [. digits] | . digits) [e [+-] digits]
    var i = 0
    if s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
    var intDigits = 0
    while i < s.count && s[i] >= 48 && s[i] <= 57 { i += 1; intDigits += 1 }
    var fracDigits = 0
    if i < s.count && s[i] == UInt8(ascii: ".") {
        i += 1
        while i < s.count && s[i] >= 48 && s[i] <= 57 { i += 1; fracDigits += 1 }
    }
    if intDigits + fracDigits == 0 { return .nan }
    if i < s.count && (s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E")) {
        i += 1
        if i < s.count && (s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-")) { i += 1 }
        var expDigits = 0
        while i < s.count && s[i] >= 48 && s[i] <= 57 { i += 1; expDigits += 1 }
        if expDigits == 0 { return .nan }
    }
    if i != s.count { return .nan }
    return parseDecimal(s[...]) ?? .nan
}

/// Correctly rounded decimal → double for text already validated as a decimal literal.
func parseDecimal(_ bytes: ArraySlice<UInt8>) -> Double? {
    var text = String(decoding: bytes, as: UTF8.self)
    // strtod accepts "5." and ".5"; normalise anyway for portability.
    if text.hasSuffix(".") { text += "0" }
    if text.hasPrefix(".") { text = "0" + text }
    if text.hasPrefix("-.") { text = "-0" + text.dropFirst() }
    if text.hasPrefix("+.") { text = "0" + text.dropFirst() }
    if text.hasPrefix("+") { text.removeFirst() }
    text = text.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
    return Double(text)
}

func hexValue(_ c: UInt8) -> Int? {
    switch c {
    case 48...57: return Int(c - 48)
    case 97...102: return Int(c - 97 + 10)
    case 65...70: return Int(c - 65 + 10)
    default: return nil
    }
}

/// An exact binary integer rounded to the nearest double (ties to even).
func bitsToDouble(_ bits: [Bool]) -> Double {
    guard let first = bits.firstIndex(of: true) else { return 0 }
    let b = Array(bits[first...])
    if b.count <= 53 {
        var v: UInt64 = 0
        for x in b { v = v << 1 | (x ? 1 : 0) }
        return Double(v)
    }
    var mant: UInt64 = 0
    for x in b[0..<53] { mant = mant << 1 | (x ? 1 : 0) }
    let roundBit = b[53]
    let sticky = b[54...].contains(true)
    var shift = b.count - 53
    if roundBit && (sticky || mant & 1 == 1) {
        mant += 1
        if mant == 1 << 53 {
            mant >>= 1
            shift += 1
        }
    }
    if shift > 1100 { return .infinity }
    return Double(sign: .plus, exponent: shift, significand: Double(mant))
}

// MARK: - JSON.stringify

extension JSValue {
    /// JSON.stringify(v), or nil when JSON.stringify returns undefined.
    public var json: String? {
        switch self {
        case .undefined, .function: return nil
        default:
            var out = ""
            writeJSON(&out)
            return out
        }
    }

    func writeJSON(_ out: inout String) {
        switch self {
        case .null, .undefined, .function: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += (n.isNaN || n.isInfinite) ? "null" : jsNumberToString(n)
        case .string(let s): quoteJSON(&out, s)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," }
                e.writeJSON(&out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            for k in o.keys {
                let e = o.map[JSKey(k)]!
                if case .undefined = e { continue }
                if case .function = e { continue }
                if !first { out += "," }
                first = false
                quoteJSON(&out, k)
                out += ":"
                e.writeJSON(&out)
            }
            out += "}"
        }
    }
}

private let hexDigits = Array("0123456789abcdef".unicodeScalars)

func quoteJSON(_ out: inout String, _ s: String) {
    out.unicodeScalars.append("\"")
    for u in s.unicodeScalars {
        switch u.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0..<0x20:
            out += "\\u00"
            out.unicodeScalars.append(hexDigits[Int(u.value >> 4)])
            out.unicodeScalars.append(hexDigits[Int(u.value & 0xF)])
        default: out.unicodeScalars.append(u)
        }
    }
    out.unicodeScalars.append("\"")
}

/// JSON.stringify of a string.
public func jsonQuote(_ s: String) -> String {
    var out = ""
    quoteJSON(&out, s)
    return out
}

// MARK: - Property access

struct EngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private let stringMethods: Set<String> = [
    "anchor", "at", "big", "blink", "bold", "charAt", "charCodeAt", "codePointAt", "concat", "constructor", "endsWith",
    "fixed", "fontcolor", "fontsize", "includes", "indexOf", "isWellFormed", "italics", "lastIndexOf", "link",
    "localeCompare", "match", "matchAll", "normalize", "padEnd", "padStart", "repeat", "replace", "replaceAll", "search",
    "slice", "small", "split", "strike", "sub", "substr", "substring", "sup", "toLocaleLowerCase", "toLocaleUpperCase",
    "toLowerCase", "toString", "toUpperCase", "toWellFormed", "trim", "trimEnd", "trimLeft", "trimRight", "trimStart", "valueOf",
]

private let arrayMethods: Set<String> = [
    "at", "concat", "constructor", "copyWithin", "entries", "every", "fill", "filter", "find", "findIndex", "findLast",
    "findLastIndex", "flat", "flatMap", "forEach", "includes", "indexOf", "join", "keys", "lastIndexOf", "map", "pop", "push",
    "reduce", "reduceRight", "reverse", "shift", "slice", "some", "sort", "splice", "toLocaleString", "toReversed", "toSorted",
    "toSpliced", "toString", "unshift", "values", "with",
]

/// Object.prototype members, as `${words[name]}` renders them in describeCondition.
let objectProtoStrings: [String: String] = [
    "constructor": "function Object() { [native code] }",
    "__defineGetter__": "function __defineGetter__() { [native code] }",
    "__defineSetter__": "function __defineSetter__() { [native code] }",
    "hasOwnProperty": "function hasOwnProperty() { [native code] }",
    "__lookupGetter__": "function __lookupGetter__() { [native code] }",
    "__lookupSetter__": "function __lookupSetter__() { [native code] }",
    "isPrototypeOf": "function isPrototypeOf() { [native code] }",
    "propertyIsEnumerable": "function propertyIsEnumerable() { [native code] }",
    "toString": "function toString() { [native code] }",
    "valueOf": "function valueOf() { [native code] }",
    "__proto__": "[object Object]",
    "toLocaleString": "function toLocaleString() { [native code] }",
]

/// UTF-16 code unit `i` of `s` as a one-unit string (a lone surrogate half becomes U+FFFD:
/// Swift strings cannot hold one).
func utf16At(_ s: String, _ i: Int) -> JSValue {
    let u = s.utf16
    let unit = u[u.index(u.startIndex, offsetBy: i)]
    return .string(String(decoding: [unit], as: UTF16.self))
}

extension JSValue {
    /// The property read `v[name]` for the fixed property names the engine reads. Plain objects only
    /// expose own properties here: none of those names exist on Object.prototype.
    func get(_ name: String) throws -> JSValue {
        switch self {
        case .undefined, .null:
            throw EngineError(message: "Cannot read properties of \(jsString) (reading '\(name)')")
        case .string(let s):
            if name == "length" { return .number(Double(s.utf16.count)) }
            if let n = arrayIndex(name) {
                return Int(n) < s.utf16.count ? utf16At(s, Int(n)) : .undefined
            }
            if stringMethods.contains(name) { return .function(name) }
        case .array(let a):
            if name == "length" { return .number(Double(a.count)) }
            if let n = arrayIndex(name) { return Int(n) < a.count ? a[Int(n)] : .undefined }
            if arrayMethods.contains(name) { return .function(name) }
        case .object(let o):
            if let e = o[name] { return e }
        default:
            break
        }
        return .undefined
    }

    /// `get` for reads that cannot throw (the receiver is known not to be nullish), or where JavaScript's
    /// optional chaining applies.
    func getOrUndefined(_ name: String) -> JSValue { (try? get(name)) ?? .undefined }
}

/// The engine's `own(obj, key)`: an own-property lookup that never reads inherited members.
func own(_ obj: JSValue, _ key: String) -> JSValue {
    switch obj {
    case .object(let o):
        return o[key] ?? .undefined
    case .array, .string:
        if arrayIndex(key) != nil || key == "length" { return obj.getOrUndefined(key) }
        return .undefined
    default:
        return .undefined
    }
}
