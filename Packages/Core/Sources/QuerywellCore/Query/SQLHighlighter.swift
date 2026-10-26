import Foundation

/// Semantic style of a highlighted span; the editor maps these to colours.
public enum SQLHighlightStyle: String, Sendable, Hashable, CaseIterable {
    case keyword
    case function
    case string
    case number
    case comment
    /// A bare identifier (table, column, alias).
    case identifier
    /// `` `name` `` (MySQL) or `"name"` (Postgres).
    case quotedIdentifier
    case `operator`
    /// `@user_var`, `@@sys_var`, `:named`, `?`, `$1`.
    case variable
}

public struct SQLHighlightSpan: Sendable, Hashable {
    /// UTF-16 range in the highlighted text (NSRange-compatible).
    public var range: Range<Int>
    public var style: SQLHighlightStyle

    public init(range: Range<Int>, style: SQLHighlightStyle) {
        self.range = range
        self.style = style
    }

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Maps lexer tokens to semantic styles. Pure; whitespace and punctuation produce no span.
public struct SQLHighlighter: Sendable {
    public let dialect: SQLDialect
    private let keywords: Set<String>
    private let functions: Set<String>

    public init(dialect: SQLDialect) {
        self.dialect = dialect
        keywords = SQLKeywords.keywords(for: dialect.family)
        functions = SQLKeywords.functions(for: dialect.family)
    }

    /// All styled spans of `text`, ascending and non-overlapping. UTF-16 ranges.
    public func highlight(_ text: String) -> [SQLHighlightSpan] {
        spans(for: text, shiftedBy: 0)
    }

    /// Spans of the part of `text` inside `range` (UTF-16). The slice is lexed on its own, so `range`
    /// must start at a statement boundary — use ``rehighlightRange(in:edited:removed:)`` to obtain one.
    public func highlight(_ text: String, in range: Range<Int>) -> [SQLHighlightSpan] {
        let ns = text as NSString
        let r = Self.clamp(range, to: ns.length)
        guard !r.isEmpty else { return [] }
        return spans(for: ns.substring(with: NSRange(location: r.lowerBound, length: r.count)), shiftedBy: r.lowerBound)
    }

    /// Characters whose insertion/removal can change how *later* text is tokenised (quotes, comment
    /// openers, dollar quoting, the `;` statement boundary).
    private static let lexicalDelimiters: Set<Character> = ["'", "\"", "`", "*", "/", "-", "#", "$", ";"]

    /// The minimal range (UTF-16, in the *edited* text) that must be re-highlighted after an edit.
    ///
    /// The range is bounded by statements: from just after the last top-level `;` before the edit to
    /// the next top-level `;` after it. When the edit inserted or removed a lexical delimiter (quote,
    /// comment marker, `$`, `;`) the range runs to the end of the text, because an unbalanced quote
    /// re-colours everything after it. A line comment that is joined to the next line by deleting a
    /// newline stays inside the statement range (a `;` in a comment is not a boundary).
    ///
    /// - Parameters:
    ///   - edited: range the edit now occupies in `text` (empty for a pure deletion).
    ///   - removed: text the edit replaced, when the caller knows it. `nil` is treated as "unknown",
    ///     which for a deletion means "may have contained delimiters".
    public func rehighlightRange(in text: String, edited: Range<Int>, removed: String? = nil) -> Range<Int> {
        let ns = text as NSString
        let total = ns.length
        let edit = Self.clamp(edited, to: total)
        let tokens = SQLLexer(dialect).tokenize(text)
        var offsets = UTF16Cursor(bytes: Array(text.utf8))

        var start = 0
        var end = total
        for t in tokens where t.kind == .symbol && t.text == ";" {
            let u16Start = offsets.offset(of: t.range.lowerBound)
            let u16End = offsets.offset(of: t.range.upperBound)
            if u16End <= edit.lowerBound {
                start = u16End
            } else if u16Start >= edit.upperBound {
                end = u16End
                break
            }
        }

        let inserted = edit.isEmpty ? "" : ns.substring(with: NSRange(location: edit.lowerBound, length: edit.count))
        var touches = inserted.contains(where: { Self.lexicalDelimiters.contains($0) })
        if let removed {
            touches = touches || removed.contains(where: { Self.lexicalDelimiters.contains($0) })
        } else if edit.isEmpty {
            touches = true
        }
        if touches { end = total }
        return start..<max(end, start)
    }

    // MARK: Implementation

    private func spans(for text: String, shiftedBy base: Int) -> [SQLHighlightSpan] {
        let bytes = Array(text.utf8)
        let tokens = SQLLexer(dialect).tokenize(bytes)
        var offsets = UTF16Cursor(bytes: bytes)
        var out: [SQLHighlightSpan] = []
        out.reserveCapacity(tokens.count)

        func emit(_ lower: Int, _ upper: Int, _ style: SQLHighlightStyle) {
            let a = offsets.offset(of: lower) + base
            let b = offsets.offset(of: upper) + base
            if b > a { out.append(SQLHighlightSpan(range: a..<b, style: style)) }
        }

        var i = 0
        let n = tokens.count
        while i < n {
            let t = tokens[i]
            switch t.kind {
            case .whitespace:
                break
            case .lineComment, .blockComment, .versionedComment:
                emit(t.range.lowerBound, t.range.upperBound, .comment)
            case .string, .dollarString:
                emit(t.range.lowerBound, t.range.upperBound, .string)
            case .number:
                emit(t.range.lowerBound, t.range.upperBound, .number)
            case .quotedIdentifier:
                emit(t.range.lowerBound, t.range.upperBound, .quotedIdentifier)
            case .word:
                emit(t.range.lowerBound, t.range.upperBound, wordStyle(tokens, i))
            case .symbol:
                if let (upper, style) = symbolRun(tokens, i) {
                    emit(t.range.lowerBound, upper, style)
                    // Skip the tokens swallowed by a `@name` / `:name` / `$1` run.
                    while i + 1 < n, tokens[i + 1].range.upperBound <= upper { i += 1 }
                } else if Self.operatorSymbols.contains(t.text) {
                    emit(t.range.lowerBound, t.range.upperBound, .operator)
                }
            }
            i += 1
        }
        return out
    }

    private static let operatorSymbols: Set<String> = ["+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~"]

    private func wordStyle(_ tokens: [SQLToken], _ i: Int) -> SQLHighlightStyle {
        let token = tokens[i]
        // Part of a dotted name (`t.select`) is an identifier, not a keyword.
        if i > 0, tokens[i - 1].isSymbol(".") { return .identifier }
        let upper = token.text.uppercased()
        let callLike = nextSignificant(tokens, after: i)?.isSymbol("(") ?? false
        if callLike, functions.contains(upper) { return .function }
        if keywords.contains(upper) { return .keyword }
        return .identifier
    }

    private func nextSignificant(_ tokens: [SQLToken], after i: Int) -> SQLToken? {
        var j = i + 1
        while j < tokens.count {
            if tokens[j].kind != .whitespace { return tokens[j] }
            j += 1
        }
        return nil
    }

    /// `@var`, `@@var`, `:name`, `?`, `$1` — returns the byte end of the run.
    private func symbolRun(_ tokens: [SQLToken], _ i: Int) -> (Int, SQLHighlightStyle)? {
        let t = tokens[i]
        let next: SQLToken? = i + 1 < tokens.count ? tokens[i + 1] : nil
        switch t.text {
        case "?":
            return (t.range.upperBound, .variable)
        case "@":
            var j = i + 1
            var upper = t.range.upperBound
            if j < tokens.count, tokens[j].isSymbol("@"), tokens[j].range.lowerBound == upper {
                upper = tokens[j].range.upperBound
                j += 1
            }
            if j < tokens.count, tokens[j].range.lowerBound == upper,
               [.word, .quotedIdentifier, .string, .number].contains(tokens[j].kind) {
                upper = tokens[j].range.upperBound
                // `@@global.max_connections`
                if j + 2 < tokens.count, tokens[j + 1].isSymbol("."), tokens[j + 1].range.lowerBound == upper,
                   tokens[j + 2].kind == .word, tokens[j + 2].range.lowerBound == tokens[j + 1].range.upperBound {
                    upper = tokens[j + 2].range.upperBound
                }
            }
            return (upper, .variable)
        case ":":
            // `::` casts are operators; `:name` is a named parameter.
            if i > 0, tokens[i - 1].isSymbol(":"), tokens[i - 1].range.upperBound == t.range.lowerBound { return nil }
            guard let next, next.kind == .word, next.range.lowerBound == t.range.upperBound else { return nil }
            return (next.range.upperBound, .variable)
        case "$":
            guard let next, next.kind == .number, next.range.lowerBound == t.range.upperBound else { return nil }
            return (next.range.upperBound, .variable)
        default:
            return nil
        }
    }

    private static func clamp(_ r: Range<Int>, to length: Int) -> Range<Int> {
        let lo = max(0, min(r.lowerBound, length))
        let hi = max(lo, min(r.upperBound, length))
        return lo..<hi
    }
}

/// Incremental UTF-8 byte offset → UTF-16 offset conversion. Offsets are normally requested in
/// non-decreasing order (a token walk); going backwards rewinds and rescans.
struct UTF16Cursor {
    let bytes: [UInt8]
    private var utf8 = 0
    private var utf16 = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func offset(of target: Int) -> Int {
        if target < utf8 {
            utf8 = 0
            utf16 = 0
        }
        let limit = min(target, bytes.count)
        while utf8 < limit {
            let b = bytes[utf8]
            if b & 0xC0 != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 }
            utf8 += 1
        }
        return utf16
    }
}
