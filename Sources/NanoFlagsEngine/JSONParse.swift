import Foundation

/// JSON text that JSON.parse would reject.
public struct InvalidJSON: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "invalid JSON: \(message) at offset \(offset)" }
}

extension JSValue {
    /// Parses JSON text like JavaScript's JSON.parse: numbers become IEEE-754 doubles (overflow becomes
    /// ±Infinity, "-0" is negative zero), duplicate keys keep their first position and last value, and
    /// object key order follows JavaScript's own-property order.
    ///
    /// Lone UTF-16 surrogates (only expressible as `\u` escapes) become U+FFFD: Swift strings cannot hold
    /// them. Invalid UTF-8 in the text is replaced by U+FFFD, as a TextDecoder would.
    public static func parse(_ data: Data) throws -> JSValue {
        try [UInt8](data).withUnsafeBufferPointer { try parse(bytes: $0) }
    }

    public static func parse(_ text: String) throws -> JSValue {
        var t = text
        return try t.withUTF8 { try parse(bytes: $0) }
    }

    public static func parse(bytes: UnsafeBufferPointer<UInt8>) throws -> JSValue {
        var p = JSONParser(d: bytes)
        p.ws()
        let v = try p.value(depth: 0)
        p.ws()
        if p.i != bytes.count { throw p.fail("unexpected trailing data") }
        return v
    }
}

struct JSONParser {
    let d: UnsafeBufferPointer<UInt8>
    var i = 0
    static let maxDepth = 5000

    init(d: UnsafeBufferPointer<UInt8>) { self.d = d }

    func fail(_ msg: String) -> InvalidJSON { InvalidJSON(message: msg, offset: i) }

    mutating func ws() {
        while i < d.count {
            switch d[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func value(depth: Int) throws -> JSValue {
        if depth > JSONParser.maxDepth { throw fail("nesting too deep") }
        guard i < d.count else { throw fail("unexpected end") }
        let c = d[i]
        switch c {
        case UInt8(ascii: "{"):
            i += 1
            var o = JSObjectBuilder()
            ws()
            if i < d.count && d[i] == UInt8(ascii: "}") {
                i += 1
                return .object(o.build())
            }
            while true {
                ws()
                guard i < d.count, d[i] == UInt8(ascii: "\"") else { throw fail("expected a string key") }
                let k = try str()
                ws()
                guard i < d.count, d[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                ws()
                let v = try value(depth: depth + 1)
                o.set(k, v)
                ws()
                if i < d.count && d[i] == UInt8(ascii: ",") { i += 1; continue }
                if i < d.count && d[i] == UInt8(ascii: "}") { i += 1; return .object(o.build()) }
                throw fail("expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1
            var arr: [JSValue] = []
            ws()
            if i < d.count && d[i] == UInt8(ascii: "]") {
                i += 1
                return .array(arr)
            }
            while true {
                ws()
                arr.append(try value(depth: depth + 1))
                ws()
                if i < d.count && d[i] == UInt8(ascii: ",") { i += 1; continue }
                if i < d.count && d[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                throw fail("expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            return .string(try str())
        case UInt8(ascii: "t"): return try lit("true", .bool(true))
        case UInt8(ascii: "f"): return try lit("false", .bool(false))
        case UInt8(ascii: "n"): return try lit("null", .null)
        case UInt8(ascii: "-"), 48...57: return try number()
        default: throw fail("unexpected character")
        }
    }

    mutating func lit(_ word: StaticString, _ v: JSValue) throws -> JSValue {
        let n = word.utf8CodeUnitCount
        guard d.count - i >= n else { throw fail("invalid literal") }
        let w = word.utf8Start
        for j in 0..<n where d[i + j] != w[j] { throw fail("invalid literal") }
        i += n
        return v
    }

    mutating func digits() -> Int {
        var n = 0
        while i < d.count && d[i] >= 48 && d[i] <= 57 { i += 1; n += 1 }
        return n
    }

    mutating func number() throws -> JSValue {
        let start = i
        if d[i] == UInt8(ascii: "-") { i += 1 }
        if i < d.count && d[i] == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            throw fail("invalid number")
        }
        if i < d.count && d[i] == UInt8(ascii: ".") {
            i += 1
            if digits() == 0 { throw fail("invalid number") }
        }
        if i < d.count && (d[i] == UInt8(ascii: "e") || d[i] == UInt8(ascii: "E")) {
            i += 1
            if i < d.count && (d[i] == UInt8(ascii: "+") || d[i] == UInt8(ascii: "-")) { i += 1 }
            if digits() == 0 { throw fail("invalid number") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: d[start..<i]), as: UTF8.self)
        guard let f = Double(text) else { throw fail("invalid number") }
        return .number(f)
    }

    mutating func hex4() -> UInt32? {
        guard d.count - i >= 4 else { return nil }
        var r: UInt32 = 0
        for j in 0..<4 {
            guard let h = hexValue(d[i + j]) else { return nil }
            r = r << 4 | UInt32(h)
        }
        i += 4
        return r
    }

    mutating func str() throws -> String {
        i += 1 // opening quote
        var buf: [UInt8] = []
        while true {
            let start = i
            while i < d.count {
                let c = d[i]
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") || c < 0x20 { break }
                i += 1
            }
            if i > start {
                if buf.isEmpty && i < d.count && d[i] == UInt8(ascii: "\"") {
                    // Fast path: no escapes.
                    let s = String(decoding: UnsafeBufferPointer(rebasing: d[start..<i]), as: UTF8.self)
                    i += 1
                    return s
                }
                buf.append(contentsOf: UnsafeBufferPointer(rebasing: d[start..<i]))
            }
            guard i < d.count else { throw fail("unterminated string") }
            let c = d[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: buf, as: UTF8.self)
            }
            if c < 0x20 { throw fail("control character in string") }
            // backslash
            i += 1
            guard i < d.count else { throw fail("unterminated escape") }
            let e = d[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buf.append(e)
            case UInt8(ascii: "b"): buf.append(0x08)
            case UInt8(ascii: "f"): buf.append(0x0C)
            case UInt8(ascii: "n"): buf.append(0x0A)
            case UInt8(ascii: "r"): buf.append(0x0D)
            case UInt8(ascii: "t"): buf.append(0x09)
            case UInt8(ascii: "u"):
                guard let u = hex4() else { throw fail("invalid unicode escape") }
                var scalar: UInt32 = u
                if u >= 0xD800 && u <= 0xDBFF {
                    scalar = 0xFFFD
                    if i + 1 < d.count && d[i] == UInt8(ascii: "\\") && d[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        if let lo = hex4(), lo >= 0xDC00 && lo <= 0xDFFF {
                            scalar = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                } else if u >= 0xDC00 && u <= 0xDFFF {
                    scalar = 0xFFFD
                }
                buf.append(contentsOf: Array(String(Unicode.Scalar(scalar)!).utf8))
            default:
                throw fail("invalid escape")
            }
        }
    }
}
