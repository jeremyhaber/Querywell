import Foundation

// MARK: - Model

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONNode
    public init(key: String, value: JSONNode) {
        self.key = key
        self.value = value
    }
}

/// JSON tree that keeps object key order (and duplicate keys) and number text verbatim, so that big
/// integers and `1.0`/`1e5` spellings survive an edit untouched.
public indirect enum JSONNode: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONNode])
    case string(String)
    /// The number exactly as written (`12345678901234567890`, `1.0`, `-0`, `1E+3`).
    case number(raw: String)
    case bool(Bool)
    case null

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Errors

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    /// Byte offset into the UTF-8 text.
    public let offset: Int
    /// 1-based line.
    public let line: Int
    /// 1-based column, counted in Unicode scalars.
    public let column: Int

    public var description: String { "\(message) (line \(line), column \(column))" }
}

// MARK: - Formatting

public enum JSONIndent: Equatable, Sendable {
    case spaces(Int)
    case tab
}

public struct JSONFormatting: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// `{"a":1,"b":[1,2]}`
        case minified
        /// `{"a": 1, "b": [1, 2]}` — single line with spaces after `:` and `,`.
        case inline
        /// One element per line (PHP `JSON_PRETTY_PRINT` / `JSON.stringify(x, null, n)` style).
        case pretty(indent: JSONIndent)
    }

    public var layout: Layout
    /// Write `/` as `\/` (PHP `json_encode` default, which WordPress uses).
    public var escapeSlashes: Bool
    /// Write non-ASCII characters as `\uXXXX` (lowercase hex, surrogate pairs for astral planes).
    public var escapeNonASCII: Bool

    public init(layout: Layout, escapeSlashes: Bool = false, escapeNonASCII: Bool = false) {
        self.layout = layout
        self.escapeSlashes = escapeSlashes
        self.escapeNonASCII = escapeNonASCII
    }
}

// MARK: - Document

/// A parsed JSON text.
///
/// Formatting policy: `originalFormatting` returns the original text byte-for-byte while the tree is
/// unchanged; after an edit it re-emits the tree using the *detected* style (minified / inline /
/// pretty with the detected indent, plus whether `/` and non-ASCII were escaped). Whitespace oddities
/// of the original (aligned columns, trailing spaces, mixed indent) are normalised on edit.
/// `prettyPrinted` and `minified` change layout only and keep the detected escape style, so `\/`
/// (which PHP writes everywhere) is not silently dropped.
public struct JSONDocument: Sendable {
    public let originalText: String
    public var root: JSONNode
    public let detectedFormatting: JSONFormatting
    private let originalRoot: JSONNode

    public var isModified: Bool { root != originalRoot }

    init(originalText: String, root: JSONNode, detectedFormatting: JSONFormatting) {
        self.originalText = originalText
        self.root = root
        self.originalRoot = root
        self.detectedFormatting = detectedFormatting
    }

    public static func parse(_ text: String) throws -> JSONDocument {
        var p = JSONParser(text: text)
        let root = try p.parseDocument()
        return JSONDocument(originalText: text, root: root, detectedFormatting: JSONFormatDetector.detect(text))
    }

    /// Nil when valid; otherwise the first error with line/column.
    public static func validate(_ text: String) -> JSONParseError? {
        do {
            var p = JSONParser(text: text)
            _ = try p.parseDocument()
            return nil
        } catch let e as JSONParseError {
            return e
        } catch {
            return nil
        }
    }

    /// Cheap check used before attempting a parse: trimmed text starts with `{`/`[` and ends with the
    /// matching `}`/`]`. Bare scalars (`123`, `"x"`, `true`) are deliberately not "JSON-looking".
    public static func looksLikeJSON(_ text: String) -> Bool {
        let bytes = text.utf8
        var lo = bytes.startIndex
        var hi = bytes.endIndex
        func isWS(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        while lo < hi, isWS(bytes[lo]) { lo = bytes.index(after: lo) }
        while hi > lo, isWS(bytes[bytes.index(before: hi)]) { hi = bytes.index(before: hi) }
        guard lo < hi else { return false }
        let first = bytes[lo]
        let last = bytes[bytes.index(before: hi)]
        return (first == 0x7B && last == 0x7D) || (first == 0x5B && last == 0x5D)
    }

    public var minified: String {
        JSONEmitter.emit(root, JSONFormatting(layout: .minified,
                                              escapeSlashes: detectedFormatting.escapeSlashes,
                                              escapeNonASCII: detectedFormatting.escapeNonASCII))
    }

    public func prettyPrinted(indent: Int = 2) -> String {
        prettyPrinted(indent: .spaces(indent))
    }

    public func prettyPrinted(indent: JSONIndent) -> String {
        JSONEmitter.emit(root, JSONFormatting(layout: .pretty(indent: indent),
                                              escapeSlashes: detectedFormatting.escapeSlashes,
                                              escapeNonASCII: detectedFormatting.escapeNonASCII))
    }

    /// Original text when unmodified; otherwise the tree re-emitted in the detected original style.
    public var originalFormatting: String {
        isModified ? JSONEmitter.emit(root, detectedFormatting) : originalText
    }

    /// Emits with an explicit style.
    public func emit(_ formatting: JSONFormatting) -> String { JSONEmitter.emit(root, formatting) }
}

// MARK: - Emitter

enum JSONEmitter {
    static func emit(_ node: JSONNode, _ f: JSONFormatting) -> String {
        var out: [UInt8] = []
        write(node, f, level: 0, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    private static func put(_ s: String, _ out: inout [UInt8]) { out.append(contentsOf: s.utf8) }

    private static func newline(_ f: JSONFormatting, level: Int, into out: inout [UInt8]) {
        guard case .pretty(let indent) = f.layout else { return }
        out.append(0x0A)
        switch indent {
        case .tab: out.append(contentsOf: [UInt8](repeating: 0x09, count: level))
        case .spaces(let n): out.append(contentsOf: [UInt8](repeating: 0x20, count: n * level))
        }
    }

    private static func write(_ node: JSONNode, _ f: JSONFormatting, level: Int, into out: inout [UInt8]) {
        switch node {
        case .null: put("null", &out)
        case .bool(let b): put(b ? "true" : "false", &out)
        case .number(let raw): put(raw, &out)
        case .string(let s): writeString(s, f, into: &out)
        case .array(let items):
            if items.isEmpty {
                put("[]", &out)
                return
            }
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { writeComma(f, &out) }
                newline(f, level: level + 1, into: &out)
                write(item, f, level: level + 1, into: &out)
            }
            newline(f, level: level, into: &out)
            out.append(0x5D)
        case .object(let members):
            if members.isEmpty {
                put("{}", &out)
                return
            }
            out.append(0x7B)
            for (i, m) in members.enumerated() {
                if i > 0 { writeComma(f, &out) }
                newline(f, level: level + 1, into: &out)
                writeString(m.key, f, into: &out)
                switch f.layout {
                case .minified: out.append(0x3A)
                default: put(": ", &out)
                }
                write(m.value, f, level: level + 1, into: &out)
            }
            newline(f, level: level, into: &out)
            out.append(0x7D)
        }
    }

    private static func writeComma(_ f: JSONFormatting, _ out: inout [UInt8]) {
        out.append(0x2C)
        if case .inline = f.layout { out.append(0x20) }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private static func writeU(_ unit: UInt16, into out: inout [UInt8]) {
        out.append(contentsOf: [0x5C, 0x75, hex[Int(unit >> 12) & 15], hex[Int(unit >> 8) & 15],
                                hex[Int(unit >> 4) & 15], hex[Int(unit) & 15]])
    }

    static func writeString(_ s: String, _ f: JSONFormatting, into out: inout [UInt8]) {
        out.append(0x22)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x2F:
                if f.escapeSlashes { out.append(contentsOf: [0x5C, 0x2F]) } else { out.append(0x2F) }
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0..<0x20: writeU(UInt16(v), into: &out)
            case 0x20..<0x80: out.append(UInt8(v))
            default:
                if f.escapeNonASCII {
                    for unit in String(scalar).utf16 { writeU(unit, into: &out) }
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        out.append(0x22)
    }
}

// MARK: - Format detection

enum JSONFormatDetector {
    /// Looks at the original text once (outside string contents) to pick layout and escaping style.
    static func detect(_ text: String) -> JSONFormatting {
        let b = Array(text.utf8)
        var i = 0
        var escapeSlashes = false
        var escapeNonASCII = false
        var layout: JSONFormatting.Layout?
        var sawFirstContainer = false
        var inlineSpaced: Bool?

        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }
        func hexVal(_ c: UInt8) -> Int? {
            switch c {
            case 0x30...0x39: return Int(c - 0x30)
            case 0x41...0x46: return Int(c - 0x41 + 10)
            case 0x61...0x66: return Int(c - 0x61 + 10)
            default: return nil
            }
        }
        while i < b.count {
            let c = b[i]
            if c == 0x22 {
                i += 1
                while i < b.count, b[i] != 0x22 {
                    if b[i] == 0x5C, i + 1 < b.count {
                        if b[i + 1] == 0x2F { escapeSlashes = true }
                        if b[i + 1] == 0x75, i + 5 < b.count {
                            var v = 0
                            var ok = true
                            for k in 2...5 {
                                if let h = hexVal(b[i + k]) { v = v * 16 + h } else { ok = false }
                            }
                            if ok && v >= 0x80 { escapeNonASCII = true }
                        }
                        i += 2
                    } else {
                        i += 1
                    }
                }
                i += 1
                continue
            }
            if (c == 0x7B || c == 0x5B), !sawFirstContainer {
                sawFirstContainer = true
                var j = i + 1
                var sawNewline = false
                var indentStart = -1
                while j < b.count, isWS(b[j]) {
                    if b[j] == 0x0A { sawNewline = true; indentStart = j + 1 }
                    j += 1
                }
                if sawNewline, j < b.count, b[j] != 0x7D, b[j] != 0x5D {
                    let ind = Array(b[indentStart..<j])
                    if ind.first == 0x09 {
                        layout = .pretty(indent: .tab)
                    } else {
                        layout = .pretty(indent: .spaces(ind.isEmpty ? 2 : ind.count))
                    }
                }
            } else if layout == nil, inlineSpaced == nil, c == 0x3A || c == 0x2C {
                inlineSpaced = (i + 1 < b.count && b[i + 1] == 0x20)
            }
            i += 1
        }
        let resolved: JSONFormatting.Layout = layout ?? ((inlineSpaced ?? false) ? .inline : .minified)
        return JSONFormatting(layout: resolved, escapeSlashes: escapeSlashes, escapeNonASCII: escapeNonASCII)
    }
}

// MARK: - Parser

struct JSONParser {
    static let maxDepth = 128
    let bytes: [UInt8]
    var pos = 0

    init(text: String) { bytes = Array(text.utf8) }

    func error(_ message: String, at offset: Int? = nil) -> JSONParseError {
        let off = min(offset ?? pos, bytes.count)
        var line = 1
        var lineStart = 0
        for i in 0..<off where bytes[i] == 0x0A {
            line += 1
            lineStart = i + 1
        }
        var col = 1
        for i in lineStart..<off where (bytes[i] & 0xC0) != 0x80 { col += 1 }
        return JSONParseError(message: message, offset: off, line: line, column: col)
    }

    mutating func skipWS() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { pos += 1 } else { break }
        }
    }

    mutating func parseDocument() throws -> JSONNode {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
        skipWS()
        guard pos < bytes.count else { throw error("Empty input; expected a JSON value") }
        let v = try parseValue(depth: 0)
        skipWS()
        if pos < bytes.count { throw error("Unexpected data after the JSON value") }
        return v
    }

    func describe(_ at: Int) -> String {
        guard at < bytes.count else { return "end of input" }
        let c = bytes[at]
        if c >= 0x20 && c < 0x7F { return "'\(Character(UnicodeScalar(c)))'" }
        return "byte 0x\(String(c, radix: 16))"
    }

    mutating func parseValue(depth: Int) throws -> JSONNode {
        guard depth <= JSONParser.maxDepth else { throw error("Nesting too deep") }
        guard pos < bytes.count else { throw error("Unexpected end of input; expected a value") }
        switch bytes[pos] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw error("Unexpected \(describe(pos)); expected a value")
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        for (k, c) in w.enumerated() {
            guard pos + k < bytes.count, bytes[pos + k] == c else {
                throw error("Invalid literal; expected '\(word)'", at: pos + k)
            }
        }
        pos += w.count
        if pos < bytes.count {
            let n = bytes[pos]
            if (n >= 0x30 && n <= 0x39) || (n >= 0x41 && n <= 0x5A) || (n >= 0x61 && n <= 0x7A) || n == 0x5F {
                throw error("Invalid literal; expected '\(word)'", at: pos - w.count)
            }
        }
    }

    mutating func parseNumber() throws -> JSONNode {
        let start = pos
        if bytes[pos] == 0x2D { pos += 1 }
        guard pos < bytes.count else { throw error("Invalid number", at: start) }
        if bytes[pos] == 0x30 {
            pos += 1
        } else if bytes[pos] >= 0x31 && bytes[pos] <= 0x39 {
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
        } else {
            throw error("Invalid number; expected a digit", at: pos)
        }
        if pos < bytes.count, bytes[pos] == 0x2E {
            pos += 1
            let s = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            if pos == s { throw error("Invalid number; expected digits after '.'", at: pos) }
        }
        if pos < bytes.count, bytes[pos] == 0x65 || bytes[pos] == 0x45 {
            pos += 1
            if pos < bytes.count, bytes[pos] == 0x2B || bytes[pos] == 0x2D { pos += 1 }
            let s = pos
            while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
            if pos == s { throw error("Invalid number; expected exponent digits", at: pos) }
        }
        return .number(raw: String(decoding: bytes[start..<pos], as: UTF8.self))
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw error("Incomplete \\u escape", at: pos) }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c = bytes[pos + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw error("Invalid hex digit in \\u escape", at: pos + k)
            }
            v = v * 16 + d
        }
        pos += 4
        return v
    }

    mutating func parseString() throws -> String {
        let start = pos
        pos += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard pos < bytes.count else { throw error("Unterminated string", at: start) }
            let c = bytes[pos]
            switch c {
            case 0x22:
                pos += 1
                return String(decoding: out, as: UTF8.self)
            case 0x5C:
                guard pos + 1 < bytes.count else { throw error("Unterminated string", at: start) }
                let e = bytes[pos + 1]
                let escPos = pos
                pos += 2
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    var cp = try parseHex4()
                    if cp >= 0xD800 && cp <= 0xDBFF {
                        guard pos + 1 < bytes.count, bytes[pos] == 0x5C, bytes[pos + 1] == 0x75 else {
                            throw error("Unpaired high surrogate in \\u escape", at: escPos)
                        }
                        pos += 2
                        let low = try parseHex4()
                        guard low >= 0xDC00 && low <= 0xDFFF else {
                            throw error("Invalid low surrogate in \\u escape", at: escPos)
                        }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                    } else if cp >= 0xDC00 && cp <= 0xDFFF {
                        throw error("Unpaired low surrogate in \\u escape", at: escPos)
                    }
                    out.append(contentsOf: String(UnicodeScalar(cp)!).utf8)
                default:
                    throw error("Invalid escape sequence '\\\(describe(pos - 1))'", at: escPos)
                }
            case 0..<0x20:
                throw error("Unescaped control character in string", at: pos)
            default:
                out.append(c)
                pos += 1
            }
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONNode {
        pos += 1
        skipWS()
        var items: [JSONNode] = []
        if pos < bytes.count, bytes[pos] == 0x5D {
            pos += 1
            return .array(items)
        }
        while true {
            skipWS()
            items.append(try parseValue(depth: depth + 1))
            skipWS()
            guard pos < bytes.count else { throw error("Unexpected end of input in array") }
            if bytes[pos] == 0x2C { pos += 1; continue }
            if bytes[pos] == 0x5D { pos += 1; return .array(items) }
            throw error("Unexpected \(describe(pos)); expected ',' or ']' in array")
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONNode {
        pos += 1
        skipWS()
        var members: [JSONMember] = []
        if pos < bytes.count, bytes[pos] == 0x7D {
            pos += 1
            return .object(members)
        }
        while true {
            skipWS()
            guard pos < bytes.count else { throw error("Unexpected end of input in object") }
            guard bytes[pos] == 0x22 else { throw error("Unexpected \(describe(pos)); expected a string key") }
            let key = try parseString()
            skipWS()
            guard pos < bytes.count, bytes[pos] == 0x3A else {
                throw error("Unexpected \(describe(pos)); expected ':' after key")
            }
            pos += 1
            skipWS()
            let v = try parseValue(depth: depth + 1)
            members.append(JSONMember(key: key, value: v))
            skipWS()
            guard pos < bytes.count else { throw error("Unexpected end of input in object") }
            if bytes[pos] == 0x2C { pos += 1; continue }
            if bytes[pos] == 0x7D { pos += 1; return .object(members) }
            throw error("Unexpected \(describe(pos)); expected ',' or '}' in object")
        }
    }
}
