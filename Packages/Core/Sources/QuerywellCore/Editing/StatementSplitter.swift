import Foundation

/// One statement cut out of a script, with where it came from.
public struct ScriptStatement: Sendable, Hashable {
    /// 0-based position among the statements of the script.
    public var index: Int
    /// The statement text exactly as written (comments inside kept, trailing delimiter removed,
    /// surrounding whitespace trimmed).
    public var text: String
    /// Range in the original script string.
    public var range: Range<String.Index>
    /// UTF-8 byte offsets in the script.
    public var utf8Range: Range<Int>
    /// UTF-16 offsets (what NSTextView / NSRange use) — for "run selection" and error highlighting.
    public var utf16Range: Range<Int>
    /// 1-based line on which the statement text starts.
    public var startLine: Int

    public init(index: Int, text: String, range: Range<String.Index>, utf8Range: Range<Int>,
                utf16Range: Range<Int>, startLine: Int) {
        self.index = index
        self.text = text
        self.range = range
        self.utf8Range = utf8Range
        self.utf16Range = utf16Range
        self.startLine = startLine
    }
}

/// Splits a script into statements.
///
/// Respects quotes (single/double/backtick, backslash and doubled-quote escapes per dialect),
/// `--` / `#` (MySQL) / `/* */` comments, MySQL executable comments (`/*! … */` is part of the
/// statement and counts as content), Postgres dollar quoting and `BEGIN ATOMIC … END` bodies, and
/// the MySQL client's `DELIMITER` command. Comment-only chunks yield no statement.
public enum StatementSplitter {
    public static func split(_ script: String, dialect: SQLDialect) -> [ScriptStatement] {
        let lexer = SQLLexer(dialect)
        let bytes = Array(script.utf8)
        let n = bytes.count
        let isMySQL = dialect.family == .mysql

        var statements: [ScriptStatement] = []
        var delimiter: [UInt8] = [0x3B]

        var chunkStart: Int?          // first non-whitespace byte of the current chunk
        var lastEnd = 0               // end of the last non-whitespace token of the chunk
        var hasContent = false        // any token other than whitespace/plain comments
        var prevKeyword = ""
        var atomicDepth = 0           // Postgres BEGIN ATOMIC … END nesting

        var cursor = OffsetCursor(bytes: bytes)

        func emit() {
            defer {
                chunkStart = nil
                hasContent = false
                prevKeyword = ""
                atomicDepth = 0
            }
            guard hasContent, let start = chunkStart, lastEnd > start else { return }
            let (u16Start, line) = cursor.advance(to: start)
            let (u16End, _) = cursor.advance(to: lastEnd)
            let startIdx = script.utf8.index(script.utf8.startIndex, offsetBy: start)
            let endIdx = script.utf8.index(script.utf8.startIndex, offsetBy: lastEnd)
            statements.append(ScriptStatement(
                index: statements.count,
                text: String(decoding: bytes[start..<lastEnd], as: UTF8.self),
                range: startIdx..<endIdx,
                utf8Range: start..<lastEnd,
                utf16Range: u16Start..<u16End,
                startLine: line))
        }

        func matchesDelimiter(at i: Int) -> Bool {
            i + delimiter.count <= n && bytes[i..<(i + delimiter.count)].elementsEqual(delimiter)
        }

        var i = 0
        while i < n {
            if atomicDepth == 0, matchesDelimiter(at: i) {
                emit()
                i += delimiter.count
                i = skipSameLineComment(bytes, lexer: lexer, from: i)
                continue
            }

            var tok = lexer.nextToken(in: bytes, at: i)

            // A custom delimiter can sit glued to a word (`END$$`): cut the token at it.
            if delimiter != [0x3B], tok.kind == .word || tok.kind == .number || tok.kind == .symbol {
                if let p = indexOf(delimiter, in: bytes, from: tok.range.lowerBound + 1, to: tok.range.upperBound) {
                    tok = SQLToken(kind: tok.kind, range: tok.range.lowerBound..<p,
                                   text: String(decoding: bytes[tok.range.lowerBound..<p], as: UTF8.self))
                }
            }

            if tok.kind == .whitespace {
                i = tok.range.upperBound
                continue
            }

            // MySQL client command: DELIMITER <word>
            if isMySQL, !hasContent, tok.kind == .word, tok.text.uppercased() == "DELIMITER",
               tok.range.upperBound < n, bytes[tok.range.upperBound] == 0x20 || bytes[tok.range.upperBound] == 0x09 {
                var j = tok.range.upperBound
                while j < n, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                var k = j
                while k < n, bytes[k] != 0x0A, bytes[k] != 0x0D, bytes[k] != 0x20, bytes[k] != 0x09 { k += 1 }
                if k > j { delimiter = Array(bytes[j..<k]) }
                while k < n, bytes[k] != 0x0A { k += 1 }
                chunkStart = nil
                lastEnd = 0
                i = k
                continue
            }

            if chunkStart == nil { chunkStart = tok.range.lowerBound }
            lastEnd = tok.range.upperBound

            switch tok.kind {
            case .lineComment, .blockComment:
                break
            default:
                hasContent = true
            }

            if dialect.family == .postgres, tok.kind == .word {
                let kw = tok.text.uppercased()
                if kw == "ATOMIC", prevKeyword == "BEGIN" {
                    atomicDepth = 1
                } else if atomicDepth > 0 {
                    if kw == "CASE" { atomicDepth += 1 }
                    else if kw == "END" { atomicDepth -= 1 }
                }
                prevKeyword = kw
            } else if tok.kind != .whitespace, !tok.isTrivia {
                prevKeyword = ""
            }

            i = tok.range.upperBound
        }
        emit()
        return statements
    }

    /// The statement containing UTF-16 `offset` (cursor position), or the nearest preceding one —
    /// what "run current statement" needs. Nil for an empty script.
    public static func statement(at utf16Offset: Int, in statements: [ScriptStatement]) -> ScriptStatement? {
        if let hit = statements.first(where: { $0.utf16Range.contains(utf16Offset) || $0.utf16Range.upperBound == utf16Offset }) {
            return hit
        }
        return statements.last(where: { $0.utf16Range.upperBound <= utf16Offset }) ?? statements.first
    }

    // MARK: Helpers

    private static func indexOf(_ needle: [UInt8], in bytes: [UInt8], from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, from < to else { return nil }
        var p = from
        while p + needle.count <= to {
            if bytes[p..<(p + needle.count)].elementsEqual(needle) { return p }
            p += 1
        }
        return nil
    }

    /// After a delimiter, a comment on the same line belongs to the statement that just ended.
    private static func skipSameLineComment(_ bytes: [UInt8], lexer: SQLLexer, from: Int) -> Int {
        var j = from
        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
        guard j < bytes.count else { return from }
        let t = lexer.nextToken(in: bytes, at: j)
        switch t.kind {
        case .lineComment:
            return t.range.upperBound
        case .blockComment where !bytes[t.range].contains(0x0A):
            return t.range.upperBound
        default:
            return from
        }
    }

    /// Incremental UTF-8 → (UTF-16 offset, line) conversion; offsets must be requested in order.
    private struct OffsetCursor {
        let bytes: [UInt8]
        var utf8 = 0
        var utf16 = 0
        var line = 1

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func advance(to target: Int) -> (utf16: Int, line: Int) {
            while utf8 < target {
                let b = bytes[utf8]
                if b == 0x0A { line += 1 }
                if b & 0xC0 != 0x80 { utf16 += b >= 0xF0 ? 2 : 1 }
                utf8 += 1
            }
            return (utf16, line)
        }
    }
}
