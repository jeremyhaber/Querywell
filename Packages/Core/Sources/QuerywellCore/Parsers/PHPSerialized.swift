import Foundation

// MARK: - Model

/// Key of a PHP array / object property. PHP strings are byte strings, so string keys keep raw bytes.
public enum PHPArrayKey: Hashable, Sendable {
    case int(Int64)
    case string(Data)

    public static func key(_ s: String) -> PHPArrayKey { .string(Data(s.utf8)) }

    /// The key as text when it is a string key holding valid UTF-8; nil for int keys / binary keys.
    public var stringValue: String? {
        if case .string(let d) = self { return phpUTF8String(d) }
        return nil
    }

    /// Lossy, human-readable form (ints in decimal, invalid UTF-8 replaced).
    public var displayName: String {
        switch self {
        case .int(let i): return String(i)
        case .string(let d): return String(decoding: d, as: UTF8.self)
        }
    }
}

/// One ordered key/value pair of an array or object.
/// (A struct rather than a tuple so that `PHPValue` can be `Equatable`.)
public struct PHPEntry: Equatable, Sendable {
    public var key: PHPArrayKey
    public var value: PHPValue
    public init(key: PHPArrayKey, value: PHPValue) {
        self.key = key
        self.value = value
    }
}

public enum PHPReferenceKind: UInt8, Sendable {
    /// `r:N;` — object back-reference.
    case object = 0x72
    /// `R:N;` — PHP reference (`&`).
    case reference = 0x52
}

public enum PHPValueType: String, CaseIterable, Sendable {
    case null, bool, int, double, string, array, object
}

/// A parsed `serialize()` value. Decoding is lossless: strings keep their bytes, doubles keep their
/// original text.
public indirect enum PHPValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Original text of the double (`0.1`, `1.0E+25`, `-0`, `INF`, `-INF`, `NAN`).
    case double(raw: String)
    case string(Data)
    case array([PHPEntry])
    /// `O:` object. Property keys keep PHP's mangling (`\0*\0prop`, `\0Class\0prop`).
    case object(className: String, properties: [PHPEntry])
    /// `C:` Serializable payload — opaque and read-only.
    case customObject(className: String, payload: Data)
    /// `r:N;` / `R:N;` — read-only; indices are 1-based slots in PHP's numbering.
    case reference(kind: PHPReferenceKind, index: Int)
    /// `E:` PHP 8.1 enum case (`Class:Case`) — read-only.
    case enumCase(className: String, caseName: String)

    // MARK: Convenience

    public static func makeString(_ s: String) -> PHPValue { .string(Data(s.utf8)) }

    /// A double formatted the way PHP's `serialize()` does with `serialize_precision = -1`.
    public static func makeDouble(_ x: Double) -> PHPValue { .double(raw: PHPDoubleFormat.format(x)) }

    public static func makeArray(_ pairs: [(PHPArrayKey, PHPValue)]) -> PHPValue {
        .array(pairs.map { PHPEntry(key: $0.0, value: $0.1) })
    }

    /// Text of a string value when it is valid UTF-8.
    public var stringValue: String? {
        if case .string(let d) = self { return phpUTF8String(d) }
        return nil
    }

    /// Numeric value of a `.double`, parsed lazily from the raw text.
    public var doubleValue: Double? {
        guard case .double(let raw) = self else { return nil }
        return PHPDoubleFormat.parse(raw)
    }

    public var isReadOnly: Bool {
        switch self {
        case .customObject, .reference, .enumCase: return true
        default: return false
        }
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    public var type: PHPValueType? {
        switch self {
        case .null: return .null
        case .bool: return .bool
        case .int: return .int
        case .double: return .double
        case .string: return .string
        case .array: return .array
        case .object: return .object
        default: return nil
        }
    }

    /// Children of an array / object (empty otherwise).
    public var entries: [PHPEntry] {
        switch self {
        case .array(let e): return e
        case .object(_, let p): return p
        default: return []
        }
    }

    /// True when this value or any descendant is an `r:`/`R:` reference.
    public var containsReferences: Bool {
        switch self {
        case .reference: return true
        case .array(let e), .object(_, let e): return e.contains { $0.value.containsReferences }
        default: return false
        }
    }
}

func phpUTF8String(_ d: Data) -> String? {
    let s = String(decoding: d, as: UTF8.self)
    return s.utf8.elementsEqual(d) ? s : nil
}

// MARK: - Double formatting

enum PHPDoubleFormat {
    static func parse(_ raw: String) -> Double? {
        switch raw {
        case "INF": return .infinity
        case "-INF": return -.infinity
        case "NAN": return .nan
        default: return Double(raw)
        }
    }

    static func isValidRaw(_ raw: String) -> Bool {
        if raw == "INF" || raw == "-INF" || raw == "NAN" { return true }
        guard !raw.isEmpty else { return false }
        for b in raw.utf8 {
            switch b {
            case 0x30...0x39, 0x2E, 0x45, 0x65, 0x2B, 0x2D: continue
            default: return false
            }
        }
        return Double(raw) != nil
    }

    /// Shortest round-trip representation, PHP style (`0.1`, `1.0E+25`, `-0`, `100000`).
    /// Exponent form is used below 1e-4 and from 1e17 upward — thresholds verified against PHP 8.3
    /// (see `PHPDoubleOracle` in the tests).
    static func format(_ x: Double) -> String {
        if x.isNaN { return "NAN" }
        if x.isInfinite { return x < 0 ? "-INF" : "INF" }
        if x == 0 { return x.sign == .minus ? "-0" : "0" }
        var desc = x.magnitude.description
        var exp = 0
        if let eIdx = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let expText = desc[desc.index(after: eIdx)...].replacingOccurrences(of: "+", with: "")
            exp = Int(expText) ?? 0
            desc = String(desc[..<eIdx])
        }
        var intPart = desc
        var frac = ""
        if let dot = desc.firstIndex(of: ".") {
            intPart = String(desc[..<dot])
            frac = String(desc[desc.index(after: dot)...])
        }
        var digits = Array((intPart + frac).utf8)
        var decpt = intPart.count + exp
        var lead = 0
        while lead < digits.count && digits[lead] == 0x30 { lead += 1 }
        digits.removeFirst(lead)
        decpt -= lead
        while let l = digits.last, l == 0x30 { digits.removeLast() }
        if digits.isEmpty { return "0" }
        let sciExp = decpt - 1
        let sign = x < 0 ? "-" : ""
        let ds = String(decoding: digits, as: UTF8.self)
        if sciExp < -4 || sciExp >= 17 {
            let first = String(ds.prefix(1))
            let rest = String(ds.dropFirst())
            return sign + first + "." + (rest.isEmpty ? "0" : rest) + "E" + (sciExp < 0 ? "-" : "+") + String(abs(sciExp))
        }
        if decpt <= 0 {
            return sign + "0." + String(repeating: "0", count: -decpt) + ds
        }
        if ds.count <= decpt {
            return sign + ds + String(repeating: "0", count: decpt - ds.count)
        }
        let idx = ds.index(ds.startIndex, offsetBy: decpt)
        return sign + String(ds[..<idx]) + "." + String(ds[idx...])
    }
}

// MARK: - Errors

public struct PHPSerializedError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case unexpectedEnd
        case unexpectedByte(UInt8)
        case invalidNumber
        case invalidLength
        /// `s:N:"` where the bytes at `contentStart + N` are not `";` — the classic corrupted-length error.
        case stringLengthMismatch(declared: Int, contentStart: Int)
        case unsupportedType(UInt8)
        case invalidClassName
        case trailingData
        case tooDeeplyNested
    }

    public let kind: Kind
    /// Byte offset in the input where the problem was detected.
    public let offset: Int

    public init(kind: Kind, offset: Int) {
        self.kind = kind
        self.offset = offset
    }

    public var description: String {
        let what: String
        switch kind {
        case .unexpectedEnd: what = "unexpected end of data"
        case .unexpectedByte(let b): what = "unexpected byte 0x\(String(b, radix: 16))"
        case .invalidNumber: what = "invalid number"
        case .invalidLength: what = "invalid length or count"
        case .stringLengthMismatch(let n, _): what = "string length \(n) does not match the data (string not terminated by \";)"
        case .unsupportedType(let b): what = "unsupported type tag 0x\(String(b, radix: 16))"
        case .invalidClassName: what = "invalid class name"
        case .trailingData: what = "unexpected data after the serialized value"
        case .tooDeeplyNested: what = "nesting too deep"
        }
        return "PHP serialized data malformed at byte \(offset): \(what)"
    }
}

// MARK: - Parser

public enum PHPSerializedParser {
    /// Maximum nesting depth accepted (guards the recursive parser against stack exhaustion).
    public static let maxDepth = 128

    /// Parses a complete `serialize()` payload. Trailing ASCII whitespace is tolerated (and preserved);
    /// any other trailing data is an error.
    public static func parse(_ data: Data) throws -> PHPDocument {
        var p = Parser(bytes: [UInt8](data))
        let root = try p.parseValue(depth: 0)
        var trailing: [UInt8] = []
        while p.pos < p.bytes.count {
            let b = p.bytes[p.pos]
            guard b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 else {
                throw PHPSerializedError(kind: .trailingData, offset: p.pos)
            }
            trailing.append(b)
            p.pos += 1
        }
        return PHPDocument(original: data, root: root, trailing: Data(trailing))
    }

    public static func parse(_ string: String) throws -> PHPDocument { try parse(Data(string.utf8)) }

    struct Parser {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func err(_ k: PHPSerializedError.Kind, _ at: Int? = nil) -> PHPSerializedError {
            PHPSerializedError(kind: k, offset: at ?? pos)
        }

        mutating func expect(_ b: UInt8) throws {
            guard pos < bytes.count else { throw err(.unexpectedEnd) }
            guard bytes[pos] == b else { throw err(.unexpectedByte(bytes[pos])) }
            pos += 1
        }

        /// Reads an optionally signed decimal integer; `pos` stops on `terminator` (not consumed).
        mutating func readInt64(until terminator: UInt8) throws -> Int64 {
            let start = pos
            var neg = false
            if pos < bytes.count, bytes[pos] == 0x2D || bytes[pos] == 0x2B {
                neg = bytes[pos] == 0x2D
                pos += 1
            }
            let digitsStart = pos
            var value: Int64 = 0
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 {
                let d = Int64(bytes[pos] - 0x30)
                let (m, o1) = value.multipliedReportingOverflow(by: 10)
                let (s, o2) = neg ? m.subtractingReportingOverflow(d) : m.addingReportingOverflow(d)
                if o1 || o2 { throw err(.invalidNumber, start) }
                value = s
                pos += 1
            }
            guard pos > digitsStart else {
                if pos >= bytes.count { throw err(.unexpectedEnd) }
                throw err(.invalidNumber, start)
            }
            guard pos < bytes.count else { throw err(.unexpectedEnd) }
            guard bytes[pos] == terminator else { throw err(.unexpectedByte(bytes[pos])) }
            return value
        }

        mutating func readLength(until terminator: UInt8) throws -> Int {
            let start = pos
            let v = try readInt64(until: terminator)
            guard v >= 0, v <= Int64(Int32.max) else { throw err(.invalidLength, start) }
            return Int(v)
        }

        /// `<len>:"<bytes>"` — returns the bytes; leaves `pos` after the closing quote.
        mutating func readQuoted() throws -> Data {
            let n = try readLength(until: 0x3A)
            pos += 1  // ':'
            try expect(0x22)
            let contentStart = pos
            guard contentStart + n + 1 <= bytes.count, bytes[contentStart + n] == 0x22 else {
                throw err(.stringLengthMismatch(declared: n, contentStart: contentStart),
                          min(contentStart + n, bytes.count))
            }
            pos = contentStart + n + 1
            return Data(bytes[contentStart..<(contentStart + n)])
        }

        mutating func readClassName() throws -> String {
            let start = pos
            let raw = try readQuoted()
            guard let s = phpUTF8String(raw) else { throw err(.invalidClassName, start) }
            return s
        }

        mutating func parseKey() throws -> PHPArrayKey {
            guard pos < bytes.count else { throw err(.unexpectedEnd) }
            switch bytes[pos] {
            case 0x69:  // i
                pos += 1
                try expect(0x3A)
                let v = try readInt64(until: 0x3B)
                pos += 1
                return .int(v)
            case 0x73:  // s
                pos += 1
                try expect(0x3A)
                let d = try readQuoted()
                try expect(0x3B)
                return .string(d)
            default:
                throw err(.unexpectedByte(bytes[pos]))
            }
        }

        mutating func parseBody(count: Int, depth: Int) throws -> [PHPEntry] {
            try expect(0x7B)  // {
            var entries: [PHPEntry] = []
            entries.reserveCapacity(min(count, max(0, bytes.count - pos) / 4))
            for _ in 0..<count {
                let k = try parseKey()
                let v = try parseValue(depth: depth + 1)
                entries.append(PHPEntry(key: k, value: v))
            }
            try expect(0x7D)  // }
            return entries
        }

        mutating func parseValue(depth: Int) throws -> PHPValue {
            guard depth <= PHPSerializedParser.maxDepth else { throw err(.tooDeeplyNested) }
            guard pos < bytes.count else { throw err(.unexpectedEnd) }
            let tag = bytes[pos]
            switch tag {
            case 0x4E:  // N;
                pos += 1
                try expect(0x3B)
                return .null
            case 0x62:  // b:0;
                pos += 1
                try expect(0x3A)
                guard pos < bytes.count else { throw err(.unexpectedEnd) }
                let c = bytes[pos]
                guard c == 0x30 || c == 0x31 else { throw err(.unexpectedByte(c)) }
                pos += 1
                try expect(0x3B)
                return .bool(c == 0x31)
            case 0x69:  // i:
                pos += 1
                try expect(0x3A)
                let v = try readInt64(until: 0x3B)
                pos += 1
                return .int(v)
            case 0x64:  // d:
                pos += 1
                try expect(0x3A)
                let start = pos
                while pos < bytes.count, bytes[pos] != 0x3B { pos += 1 }
                guard pos < bytes.count else { throw err(.unexpectedEnd) }
                let raw = String(decoding: bytes[start..<pos], as: UTF8.self)
                guard PHPDoubleFormat.isValidRaw(raw) else { throw err(.invalidNumber, start) }
                pos += 1
                return .double(raw: raw)
            case 0x73:  // s:
                pos += 1
                try expect(0x3A)
                let d = try readQuoted()
                try expect(0x3B)
                return .string(d)
            case 0x61:  // a:
                pos += 1
                try expect(0x3A)
                let n = try readLength(until: 0x3A)
                pos += 1
                return .array(try parseBody(count: n, depth: depth))
            case 0x4F:  // O:
                pos += 1
                try expect(0x3A)
                let cls = try readClassName()
                try expect(0x3A)
                let n = try readLength(until: 0x3A)
                pos += 1
                return .object(className: cls, properties: try parseBody(count: n, depth: depth))
            case 0x43:  // C:
                pos += 1
                try expect(0x3A)
                let cls = try readClassName()
                try expect(0x3A)
                let n = try readLength(until: 0x3A)
                pos += 1
                try expect(0x7B)
                guard pos + n + 1 <= bytes.count else { throw err(.unexpectedEnd, bytes.count) }
                let payload = Data(bytes[pos..<(pos + n)])
                pos += n
                try expect(0x7D)
                return .customObject(className: cls, payload: payload)
            case 0x72, 0x52:  // r: R:
                pos += 1
                try expect(0x3A)
                let v = try readLength(until: 0x3B)
                pos += 1
                return .reference(kind: tag == 0x72 ? .object : .reference, index: v)
            case 0x45:  // E:
                pos += 1
                try expect(0x3A)
                let startQ = pos
                let raw = try readQuoted()
                try expect(0x3B)
                guard let s = phpUTF8String(raw), let colon = s.firstIndex(of: ":") else {
                    throw err(.invalidClassName, startQ)
                }
                return .enumCase(className: String(s[..<colon]), caseName: String(s[s.index(after: colon)...]))
            default:
                throw err(.unsupportedType(tag))
            }
        }
    }
}

// MARK: - Serializer

public enum PHPSerializer {
    /// Serializes with correct UTF-8 byte lengths and element counts.
    public static func serialize(_ value: PHPValue) -> Data {
        var out: [UInt8] = []
        write(value, into: &out)
        return Data(out)
    }

    private static func put(_ s: String, _ out: inout [UInt8]) { out.append(contentsOf: s.utf8) }

    private static func writeString(_ d: Data, into out: inout [UInt8]) {
        put("s:\(d.count):\"", &out)
        out.append(contentsOf: d)
        put("\";", &out)
    }

    private static func writeKey(_ k: PHPArrayKey, into out: inout [UInt8]) {
        switch k {
        case .int(let i): put("i:\(i);", &out)
        case .string(let d): writeString(d, into: &out)
        }
    }

    private static func writeBody(_ entries: [PHPEntry], into out: inout [UInt8]) {
        put("\(entries.count):{", &out)
        for e in entries {
            writeKey(e.key, into: &out)
            write(e.value, into: &out)
        }
        out.append(0x7D)
    }

    static func write(_ v: PHPValue, into out: inout [UInt8]) {
        switch v {
        case .null: put("N;", &out)
        case .bool(let b): put(b ? "b:1;" : "b:0;", &out)
        case .int(let i): put("i:\(i);", &out)
        case .double(let raw): put("d:\(raw);", &out)
        case .string(let d): writeString(d, into: &out)
        case .array(let e):
            put("a:", &out)
            writeBody(e, into: &out)
        case .object(let cls, let props):
            put("O:\(cls.utf8.count):\"\(cls)\":", &out)
            writeBody(props, into: &out)
        case .customObject(let cls, let payload):
            put("C:\(cls.utf8.count):\"\(cls)\":\(payload.count):{", &out)
            out.append(contentsOf: payload)
            out.append(0x7D)
        case .reference(let kind, let idx):
            out.append(kind.rawValue)
            put(":\(idx);", &out)
        case .enumCase(let cls, let name):
            let body = cls + ":" + name
            put("E:\(body.utf8.count):\"\(body)\";", &out)
        }
    }
}

// MARK: - Detection

public enum PHPSerialized {
    /// Cheap structural check modelled on WordPress `is_serialized()`. Does not parse the value;
    /// a `true` result may still fail `PHPSerializedParser.parse`.
    public static func looksSerialized(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var lo = 0
        var hi = bytes.count
        func isWS(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        while lo < hi, isWS(bytes[lo]) { lo += 1 }
        while hi > lo, isWS(bytes[hi - 1]) { hi -= 1 }
        let len = hi - lo
        guard len >= 2 else { return false }
        if len == 2 { return bytes[lo] == 0x4E && bytes[lo + 1] == 0x3B }  // N;
        guard len >= 4, bytes[lo + 1] == 0x3A else { return false }
        let last = bytes[hi - 1]
        func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        switch bytes[lo] {
        case 0x73:  // s:N:"…";
            return last == 0x3B && bytes[hi - 2] == 0x22 && digit(bytes[lo + 2])
        case 0x61, 0x4F, 0x43:  // a O C
            return last == 0x7D && digit(bytes[lo + 2])
        case 0x45:  // E
            return last == 0x3B && bytes[hi - 2] == 0x22
        case 0x62, 0x69, 0x64, 0x72, 0x52:  // b i d r R
            guard last == 0x3B else { return false }
            let c = bytes[lo + 2]
            return digit(c) || c == 0x2D || c == 0x2B || c == 0x49 || c == 0x4E || c == 0x2E
        default:
            return false
        }
    }

    public static func looksSerialized(_ string: String) -> Bool {
        looksSerialized(Data(string.utf8))
    }
}
