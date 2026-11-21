// Version (`semver_*`) and date (`before` / `after`) operators: the engine's parseSemver, compareSemver and
// parseInstant. Values are compared as ASCII bytes; any non-ASCII character makes a value invalid, exactly as the
// TypeScript engine's character checks do.

private let maxVersionLength = 256

struct SemVer {
    let core: [[UInt8]]
    let pre: [[UInt8]]
}

@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
@inline(__always) private func isIdent(_ c: UInt8) -> Bool {
    isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45
}

private func stripZeros(_ d: ArraySlice<UInt8>) -> [UInt8] {
    var i = d.startIndex
    while i < d.endIndex - 1 && d[i] == 48 { i += 1 }
    return Array(d[i...])
}

private func allDigits(_ s: [UInt8]) -> Bool { !s.isEmpty && s.allSatisfy(isDigit) }

/// Lexicographic byte comparison: -1, 0 or 1.
private func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
    var i = 0
    while i < a.count && i < b.count {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        i += 1
    }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
}

private func compareDigits(_ a: [UInt8], _ b: [UInt8]) -> Int {
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    return compareBytes(a, b)
}

private func asciiBytes(_ v: JSValue) -> [UInt8]? {
    guard case .string(let str) = v else { return nil }
    let s = Array(str.utf8)
    if s.contains(where: { $0 >= 0x80 }) || s.count > maxVersionLength { return nil }
    return s
}

func parseSemver(_ v: JSValue) -> SemVer? {
    guard let s = asciiBytes(v), !s.isEmpty else { return nil }
    let n = s.count
    var i = (s[0] == 118 || s[0] == 86) ? 1 : 0
    var core: [[UInt8]] = []
    while true {
        let start = i
        while i < n && isDigit(s[i]) { i += 1 }
        if i == start { return nil }
        core.append(stripZeros(s[start..<i]))
        if core.count < 3 && i < n && s[i] == 46 { i += 1; continue }
        break
    }
    while core.count < 3 { core.append([48]) }
    func idents(_ from: Int, _ stopAtPlus: Bool) -> ([[UInt8]], Int)? {
        var out: [[UInt8]] = []
        var j = from
        var start = j
        while true {
            while j < n && isIdent(s[j]) { j += 1 }
            if j == start { return nil }
            out.append(Array(s[start..<j]))
            if j < n && s[j] == 46 { j += 1; start = j; continue }
            if j == n || (stopAtPlus && s[j] == 43) { return (out, j) }
            return nil
        }
    }
    var pre: [[UInt8]] = []
    if i < n && s[i] == 45 {
        guard let r = idents(i + 1, true) else { return nil }
        pre = r.0
        i = r.1
    }
    if i < n && s[i] == 43 {
        guard let r = idents(i + 1, false) else { return nil }
        i = r.1
    }
    if i != n { return nil }
    return SemVer(core: core, pre: pre)
}

func compareSemver(_ a: SemVer, _ b: SemVer) -> Int {
    for k in 0..<3 {
        let c = compareDigits(a.core[k], b.core[k])
        if c != 0 { return c }
    }
    let pa = a.pre, pb = b.pre
    if pa.isEmpty || pb.isEmpty { return pa.count == pb.count ? 0 : (pa.isEmpty ? 1 : -1) }
    var k = 0
    while k < pa.count && k < pb.count {
        let x = pa[k], y = pb[k]
        let xn = allDigits(x), yn = allDigits(y)
        let c: Int
        if xn && yn { c = compareDigits(stripZeros(x[...]), stripZeros(y[...])) }
        else if xn { c = -1 }
        else if yn { c = 1 }
        else { c = compareBytes(x, y) }
        if c != 0 { return c }
        k += 1
    }
    return pa.count == pb.count ? 0 : (pa.count < pb.count ? -1 : 1)
}

func matchSemver(_ op: String, _ actual: JSValue, _ expected: JSValue) -> Bool {
    guard let a = parseSemver(actual), let b = parseSemver(expected) else { return false }
    let c = compareSemver(a, b)
    switch op {
    case "semver_eq": return c == 0
    case "semver_neq": return c != 0
    case "semver_gt": return c > 0
    case "semver_gte": return c >= 0
    case "semver_lt": return c < 0
    default: return c <= 0
    }
}

private func daysFromCivil(_ year: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = m <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

private func digitsAt(_ s: [UInt8], _ i: Int, _ n: Int) -> Int64? {
    if i + n > s.count { return nil }
    var v: Int64 = 0
    for j in i..<(i + n) {
        if !isDigit(s[j]) { return nil }
        v = v * 10 + Int64(s[j] - 48)
    }
    return v
}

func parseInstant(_ v: JSValue) -> Double? {
    if case .number(let x) = v {
        if !x.isFinite { return nil }
        return abs(x) >= 1e12 ? x : x * 1000
    }
    guard let s = asciiBytes(v) else { return nil }
    let n = s.count
    if n < 10 { return nil }
    guard let y = digitsAt(s, 0, 4), let mo = digitsAt(s, 5, 2), let d = digitsAt(s, 8, 2), s[4] == 45, s[7] == 45 else { return nil }
    if mo < 1 || mo > 12 || d < 1 { return nil }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    let dim: Int64 = mo == 2 ? (leap ? 29 : 28) : (mo == 4 || mo == 6 || mo == 9 || mo == 11) ? 30 : 31
    if d > dim { return nil }
    var ms = daysFromCivil(y, mo, d) * 86_400_000
    if n == 10 { return Double(ms) }
    if s[10] != 84 && s[10] != 116 && s[10] != 32 { return nil }
    guard let h = digitsAt(s, 11, 2), let mi = digitsAt(s, 14, 2), s[13] == 58 else { return nil }
    var i = 16
    var sec: Int64 = 0
    var frac: Int64 = 0
    if i < n && s[i] == 58 {
        guard let x = digitsAt(s, i + 1, 2) else { return nil }
        sec = x
        i += 3
        if i < n && s[i] == 46 {
            var j = i + 1
            while j < n && isDigit(s[j]) { j += 1 }
            if j == i + 1 || j - i - 1 > 9 { return nil }
            let digits = Array(s[(i + 1)..<j]) + [48, 48]
            frac = digitsAt(digits, 0, 3) ?? 0
            i = j
        }
    }
    if h > 23 || mi > 59 || sec > 59 || i >= n { return nil }
    ms += h * 3_600_000 + mi * 60_000 + sec * 1000 + frac
    let z = s[i]
    if (z == 90 || z == 122) && i + 1 == n { return Double(ms) }
    if (z == 43 || z == 45) && i + 6 == n && s[i + 3] == 58 {
        guard let oh = digitsAt(s, i + 1, 2), let om = digitsAt(s, i + 4, 2), oh <= 23, om <= 59 else { return nil }
        let off = (oh * 60 + om) * 60_000
        return Double(z == 45 ? ms + off : ms - off)
    }
    return nil
}

func matchDate(_ op: String, _ actual: JSValue, _ expected: JSValue) -> Bool {
    guard let a = parseInstant(actual), let b = parseInstant(expected) else { return false }
    return op == "before" ? a < b : a > b
}
