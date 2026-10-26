import Foundation

/// One lexical token of a SQL script. Offsets are UTF-8 byte offsets into the source string.
public struct SQLToken: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case whitespace
        /// `-- …` (and `# …` on MySQL) up to, not including, the newline.
        case lineComment
        case blockComment
        /// MySQL/MariaDB executable comment: `/*! … */`, `/*!50100 … */`, `/*M! … */`.
        case versionedComment
        /// Bare word: keyword or unquoted identifier (`SELECT`, `my_table`, `schema$1`).
        case word
        /// Backtick identifier (MySQL) or `"identifier"` (Postgres).
        case quotedIdentifier
        /// `'text'`, or `"text"` on MySQL.
        case string
        /// Postgres `$tag$ … $tag$`.
        case dollarString
        case number
        /// Any single other byte: `(`, `,`, `;`, `.`, `=`, …
        case symbol
    }

    public var kind: Kind
    /// UTF-8 byte range in the source.
    public var range: Range<Int>
    public var text: String
    /// False for an unterminated string/identifier/comment (runs to end of input).
    public var isTerminated: Bool

    public init(kind: Kind, range: Range<Int>, text: String, isTerminated: Bool = true) {
        self.kind = kind
        self.range = range
        self.text = text
        self.isTerminated = isTerminated
    }

    /// Whitespace or any comment form other than a versioned (executable) comment.
    public var isTrivia: Bool {
        switch kind {
        case .whitespace, .lineComment, .blockComment: true
        default: false
        }
    }

    /// Uppercased text for `.word` tokens, nil otherwise.
    public var keyword: String? { kind == .word ? text.uppercased() : nil }

    /// The identifier a `.word` / `.quotedIdentifier` token names (quotes removed, doubled quotes collapsed).
    public var identifierValue: String? {
        switch kind {
        case .word: return text
        case .quotedIdentifier:
            guard let q = text.first else { return nil }
            var body = String(text.dropFirst())
            if isTerminated, body.last == q { body.removeLast() }
            return body.replacingOccurrences(of: String(q) + String(q), with: String(q))
        default: return nil
        }
    }

    public func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
}

/// A small SQL tokenizer that is exact about everything that can hide a `;` or a keyword:
/// quotes (with per-dialect escape rules), comments, and Postgres dollar quoting. Pure.
public struct SQLLexer: Sendable {
    public let family: SQLDialect.Family

    public init(_ dialect: SQLDialect) { family = dialect.family }
    public init(family: SQLDialect.Family) { self.family = family }

    public func tokenize(_ source: String) -> [SQLToken] {
        tokenize(Array(source.utf8))
    }

    func tokenize(_ bytes: [UInt8]) -> [SQLToken] {
        var out: [SQLToken] = []
        var i = 0
        while i < bytes.count {
            let t = nextToken(in: bytes, at: i)
            out.append(t)
            i = t.range.upperBound
        }
        return out
    }

    // MARK: Character classes

    static func isIdentStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }
    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    static func isIdentPart(_ b: UInt8) -> Bool { isIdentStart(b) || isDigit(b) || b == 0x24 }
    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C }

    // MARK: Tokenizer

    /// Scans exactly one token starting at `i` (`i < bytes.count`).
    func nextToken(in bytes: [UInt8], at i: Int) -> SQLToken {
        let b = bytes[i]
        let n = bytes.count

        func make(_ kind: SQLToken.Kind, _ end: Int, terminated: Bool = true) -> SQLToken {
            SQLToken(kind: kind, range: i..<end, text: String(decoding: bytes[i..<end], as: UTF8.self), isTerminated: terminated)
        }

        if Self.isSpace(b) {
            var j = i + 1
            while j < n, Self.isSpace(bytes[j]) { j += 1 }
            return make(.whitespace, j)
        }

        // -- comment (MySQL needs whitespace/control/end after the dashes)
        if b == 0x2D, i + 1 < n, bytes[i + 1] == 0x2D {
            let isComment: Bool
            switch family {
            case .postgres: isComment = true
            case .mysql: isComment = i + 2 >= n || bytes[i + 2] <= 0x20
            }
            if isComment { return make(.lineComment, lineEnd(bytes, from: i + 2)) }
        }
        // # comment (MySQL only)
        if b == 0x23, family == .mysql { return make(.lineComment, lineEnd(bytes, from: i + 1)) }

        // /* … */
        if b == 0x2F, i + 1 < n, bytes[i + 1] == 0x2A {
            return blockComment(bytes, at: i)
        }

        switch b {
        case 0x27: // '
            return quoted(bytes, at: i, quote: 0x27, kind: .string, backslash: family == .mysql)
        case 0x22: // "
            switch family {
            case .mysql: return quoted(bytes, at: i, quote: 0x22, kind: .string, backslash: true)
            case .postgres: return quoted(bytes, at: i, quote: 0x22, kind: .quotedIdentifier, backslash: false)
            }
        case 0x60 where family == .mysql: // `
            return quoted(bytes, at: i, quote: 0x60, kind: .quotedIdentifier, backslash: false)
        case 0x24 where family == .postgres: // $
            if let end = dollarQuoteEnd(bytes, at: i) {
                return make(.dollarString, end.end, terminated: end.terminated)
            }
        default: break
        }

        if Self.isIdentStart(b) {
            var j = i + 1
            while j < n, Self.isIdentPart(bytes[j]) { j += 1 }
            // Postgres E'…' strings honour backslash escapes.
            if family == .postgres, j == i + 1, b == 0x45 || b == 0x65, j < n, bytes[j] == 0x27 {
                let s = quoted(bytes, at: j, quote: 0x27, kind: .string, backslash: true)
                return SQLToken(kind: .string, range: i..<s.range.upperBound,
                                text: String(decoding: bytes[i..<s.range.upperBound], as: UTF8.self),
                                isTerminated: s.isTerminated)
            }
            return make(.word, j)
        }

        if Self.isDigit(b) || (b == 0x2E && i + 1 < n && Self.isDigit(bytes[i + 1])) {
            var j = i + 1
            while j < n {
                let c = bytes[j]
                if Self.isDigit(c) || c == 0x2E || Self.isIdentStart(c) { j += 1 }
                else if (c == 0x2B || c == 0x2D), bytes[j - 1] == 0x65 || bytes[j - 1] == 0x45 { j += 1 }
                else { break }
            }
            return make(.number, j)
        }

        // Any other single byte (ASCII). Non-ASCII bytes were consumed as identifier characters above.
        return make(.symbol, i + 1)
    }

    private func lineEnd(_ bytes: [UInt8], from: Int) -> Int {
        var j = from
        while j < bytes.count, bytes[j] != 0x0A { j += 1 }
        return j
    }

    private func blockComment(_ bytes: [UInt8], at i: Int) -> SQLToken {
        let n = bytes.count
        var versioned = false
        if family == .mysql, i + 2 < n {
            if bytes[i + 2] == 0x21 { versioned = true }                                       // /*!
            else if bytes[i + 2] == 0x4D, i + 3 < n, bytes[i + 3] == 0x21 { versioned = true } // /*M!
        }
        var j = i + 2
        var depth = 1
        while j < n {
            if bytes[j] == 0x2A, j + 1 < n, bytes[j + 1] == 0x2F {
                depth -= 1
                j += 2
                if depth == 0 { break }
            } else if family == .postgres, bytes[j] == 0x2F, j + 1 < n, bytes[j + 1] == 0x2A {
                depth += 1
                j += 2
            } else {
                j += 1
            }
        }
        let end = min(j, n)
        return SQLToken(kind: versioned ? .versionedComment : .blockComment, range: i..<end,
                        text: String(decoding: bytes[i..<end], as: UTF8.self), isTerminated: depth == 0)
    }

    private func quoted(_ bytes: [UInt8], at i: Int, quote: UInt8, kind: SQLToken.Kind, backslash: Bool) -> SQLToken {
        let n = bytes.count
        var j = i + 1
        var terminated = false
        while j < n {
            let c = bytes[j]
            if backslash, c == 0x5C {
                j += 2
                continue
            }
            if c == quote {
                if j + 1 < n, bytes[j + 1] == quote { j += 2; continue }
                j += 1
                terminated = true
                break
            }
            j += 1
        }
        let end = min(j, n)
        return SQLToken(kind: kind, range: i..<end, text: String(decoding: bytes[i..<end], as: UTF8.self), isTerminated: terminated)
    }

    /// `$tag$ … $tag$` starting at `i`; nil when `$` here is not a dollar-quote opener (`$1`).
    private func dollarQuoteEnd(_ bytes: [UInt8], at i: Int) -> (end: Int, terminated: Bool)? {
        let n = bytes.count
        var j = i + 1
        if j < n, Self.isIdentStart(bytes[j]) {
            j += 1
            while j < n, Self.isIdentStart(bytes[j]) || Self.isDigit(bytes[j]) { j += 1 }
        }
        guard j < n, bytes[j] == 0x24 else { return nil }
        let tag = Array(bytes[i...j]) // includes both '$'
        var k = j + 1
        while k + tag.count <= n {
            if bytes[k] == 0x24, Array(bytes[k..<(k + tag.count)]) == tag { return (k + tag.count, true) }
            k += 1
        }
        return (n, false)
    }
}
