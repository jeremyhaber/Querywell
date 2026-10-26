import Foundation

/// A statement cut out of a dump stream.
public struct SplitStatement: Sendable, Equatable {
    /// 0-based position among the executable statements of the stream.
    public var index: Int
    /// Exactly as written (comments inside kept, trailing delimiter removed, surrounding whitespace trimmed).
    /// PostgreSQL `COPY … FROM stdin` data blocks arrive as generated multi-row `INSERT` statements.
    public var text: String
    /// 1-based line of the stream on which the statement starts.
    public var startLine: Int
    /// Byte offset in the (decompressed) stream where the statement starts.
    public var startOffset: Int64
}

public enum StreamingSplitterError: Error, Equatable, Sendable, LocalizedError {
    case statementTooLarge(limit: Int, line: Int)
    case unsupportedCopy(String)

    public var errorDescription: String? {
        switch self {
        case .statementTooLarge(let limit, let line):
            "The statement starting on line \(line) is larger than \(limit / 1_048_576) MB; the file may be damaged."
        case .unsupportedCopy(let m): m
        }
    }
}

/// Incremental SQL script splitter for multi-gigabyte dumps: feed chunks of any size, get complete
/// statements; memory is bounded by the largest single statement.
///
/// Understands (state survives chunk boundaries):
/// - quotes: `'…'`, `"…"`, `` `…` `` (MySQL); backslash escapes in MySQL strings and PostgreSQL `E'…'`; doubled quotes
/// - comments: `-- ` / `#` (MySQL), `--` (PostgreSQL), `/* … */` (nested on PostgreSQL); MySQL executable comments
///   `/*! … */` and `/*M! … */` are code, as in the mysql client
/// - the mysql client's `DELIMITER` command (any delimiter, e.g. `;;` or `$$`)
/// - PostgreSQL dollar quoting (`$tag$ … $tag$`) and `BEGIN ATOMIC … END` bodies
/// - psql meta-commands at statement start (`\restrict`, `\unrestrict`, `\connect`): skipped, never executed
/// - PostgreSQL `COPY … FROM stdin;` data blocks, converted to batched `INSERT` statements (text format only), because
///   the driver's query API can't stream COPY data
///
/// Comment-only chunks yield no statement.
public final class StreamingStatementSplitter {
    private enum State {
        case normal
        case singleQuote
        case doubleQuote
        case backtick
        case lineComment
        case blockComment
        case dash2                     // saw "--" (MySQL): next byte decides comment vs operator
        case slash                     // saw "/"
        case slashStar                 // saw "/*": '!' makes it code
        case slashStarM                // saw "/*M"
        case dollarTag                 // inside "$tag" while reading the tag
        case dollarQuote               // inside $tag$ … $tag$
        case delimiterLine             // collecting the argument of DELIMITER
        case metaLine                  // skipping a psql meta-command line
        case copyData                  // PostgreSQL COPY text rows
    }

    private let family: SQLDialect.Family
    private let maxStatementBytes: Int
    private var state: State = .normal
    private var buffer: [UInt8] = []
    private var delimiter: [UInt8] = [0x3B]
    private var contentSeen = false
    private var escape = false            // backslash seen inside a string
    private var backslashEscapes = false  // current string honours backslash (MySQL always, PG only for E'')
    private var blockDepth = 0
    private var blockStar = false         // previous byte in a block comment was '*'
    private var prev: UInt8 = 0
    private var prev2: UInt8 = 0
    private var dollarTag: [UInt8] = []
    private var tagScratch: [UInt8] = []
    private var delimiterArg: [UInt8] = []
    private var probeIndex = 0            // progress matching "DELIMITER " at statement start
    private var dashPending = false
    private var dashWasLeading = false
    private var copyHeaderLineDone = false
    private var atomicDepth = 0
    private var word: [UInt8] = []
    private var prevWord = ""

    // positions
    private var offset: Int64 = 0
    private var line = 1
    private var statementStartLine = 1
    private var statementStartOffset: Int64 = 0
    private var nextIndex = 0

    // COPY
    private var copyHeader = ""
    private var copyLine: [UInt8] = []
    private var copyRows: [String] = []
    private var pendingCopy = false      // the COPY statement was emitted; data follows
    private var copyBatch = 500

    public init(family: SQLDialect.Family, maxStatementBytes: Int = 512 * 1024 * 1024) {
        self.family = family
        self.maxStatementBytes = maxStatementBytes
    }

    // MARK: API

    public func feed(_ chunk: Data) throws -> [SplitStatement] {
        var out: [SplitStatement] = []
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = p.count
            while i < n {
                // Fast path: inside a single-quoted string, copy up to the next interesting byte.
                if state == .singleQuote, !escape {
                    var j = i
                    let special: UInt8 = 0x27
                    while j < n, p[j] != special, p[j] != 0x0A, !(backslashEscapes && p[j] == 0x5C) { j += 1 }
                    if j > i {
                        buffer.append(contentsOf: UnsafeBufferPointer(rebasing: p[i..<j]))
                        offset += Int64(j - i)
                        prev2 = j - i >= 2 ? p[j - 2] : prev
                        prev = p[j - 1]
                        i = j
                        if buffer.count > maxStatementBytes { throw StreamingSplitterError.statementTooLarge(limit: maxStatementBytes, line: statementStartLine) }
                        continue
                    }
                }
                try step(p[i], &out)
                i += 1
            }
        }
        return out
    }

    /// Flushes a trailing statement that has no final delimiter, and any pending COPY rows.
    public func finish() throws -> [SplitStatement] {
        var out: [SplitStatement] = []
        if state == .copyData {
            if !copyLine.isEmpty { try consumeCopyLine(&out) }
            flushCopyRows(&out)
            state = .normal
        }
        if state == .delimiterLine { applyDelimiter() }
        if probeIndex > 0 || state == .slash || state == .dash2 || (dashPending && dashWasLeading) { contentSeen = true }
        if contentSeen { emit(dropping: 0, &out) }
        return out
    }

    // MARK: Byte machine

    private func step(_ b: UInt8, _ out: inout [SplitStatement]) throws {
        offset += 1
        if b == 0x0A { line += 1 }
        defer { prev2 = prev; prev = b }

        switch state {
        case .copyData:
            if b == 0x0A {
                if copyHeaderLineDone {
                    try consumeCopyLine(&out)
                } else {
                    copyHeaderLineDone = true  // the newline that ends the COPY header line
                }
                copyLine.removeAll(keepingCapacity: true)
            } else {
                copyLine.append(b)
            }
            return
        case .delimiterLine:
            if b == 0x0A || b == 0x0D {
                if b == 0x0A { applyDelimiter() }
            } else {
                delimiterArg.append(b)
            }
            return
        case .metaLine:
            if b == 0x0A { state = .normal }
            return
        default:
            break
        }

        if buffer.isEmpty, state == .normal {
            if b <= 0x20 { return }  // leading whitespace is never part of a statement
            statementStartLine = line
            statementStartOffset = offset - 1
        }
        buffer.append(b)
        if buffer.count > maxStatementBytes { throw StreamingSplitterError.statementTooLarge(limit: maxStatementBytes, line: statementStartLine) }

        switch state {
        case .singleQuote:
            if escape { escape = false } else if backslashEscapes && b == 0x5C { escape = true } else if b == 0x27 { state = .normal }
        case .doubleQuote:
            if escape { escape = false } else if family == .mysql && b == 0x5C { escape = true } else if b == 0x22 { state = .normal }
        case .backtick:
            if b == 0x60 { state = .normal }
        case .lineComment:
            if b == 0x0A { state = .normal }
        case .blockComment:
            if family == .postgres {
                if blockStar && b == 0x2F {
                    blockDepth -= 1
                    blockStar = false
                    if blockDepth == 0 { state = .normal }
                } else if prev == 0x2F && b == 0x2A {
                    blockDepth += 1
                    blockStar = false
                } else {
                    blockStar = (b == 0x2A)
                }
            } else {
                if blockStar && b == 0x2F { state = .normal; blockStar = false } else { blockStar = (b == 0x2A) }
            }
        case .dash2:
            if b <= 0x20 {
                state = (b == 0x0A) ? .normal : .lineComment
            } else {
                state = .normal
                if dashWasLeading { markContent() }
                normal(b, &out)
            }
        case .slash:
            if b == 0x2A {
                state = .slashStar
            } else {
                state = .normal
                contentSeen = true
                normal(b, &out)
            }
        case .slashStar:
            if b == 0x21 && family == .mysql {
                state = .normal
                contentSeen = true
            } else if b == 0x4D && family == .mysql {
                state = .slashStarM
            } else {
                state = .blockComment
                blockDepth = 1
                blockStar = (b == 0x2A)
            }
        case .slashStarM:
            if b == 0x21 {
                state = .normal
                contentSeen = true
            } else {
                state = .blockComment
                blockDepth = 1
                blockStar = (b == 0x2A)
            }
        case .dollarTag:
            if b == 0x24 {
                dollarTag = tagScratch
                state = .dollarQuote
            } else if Self.isIdentifierByte(b), !(tagScratch.isEmpty && b >= 0x30 && b <= 0x39) {
                tagScratch.append(b)
            } else {
                state = .normal
                normal(b, &out)
            }
        case .dollarQuote:
            if b == 0x24, buffer.count >= dollarTag.count + 2 {
                let n = buffer.count
                let tagStart = n - dollarTag.count - 1
                if buffer[n - dollarTag.count - 2] == 0x24, buffer[tagStart..<(n - 1)].elementsEqual(dollarTag) {
                    state = .normal
                }
            }
        case .normal:
            normal(b, &out)
        case .copyData, .delimiterLine, .metaLine:
            break
        }
    }

    private static let delimiterWord = Array("DELIMITER".utf8)

    /// Handles one byte in the normal (code) state. `buffer` already contains `b`.
    private func normal(_ b: UInt8, _ out: inout [SplitStatement]) {
        // A '-' seen last time is only now known to be a comment start, an operator, or a minus sign.
        if dashPending {
            dashPending = false
            if b == 0x2D {
                if family == .postgres { state = .lineComment } else { state = .dash2 }
                return
            }
            if dashWasLeading { markContent() }
        }

        // MySQL client command `DELIMITER x`, recognised at the very start of a statement.
        if family == .mysql, probeIndex > 0 || !contentSeen {
            if probeIndex < 9 {
                if b >= 0x41, (b & 0xDF) == Self.delimiterWord[probeIndex] {
                    probeIndex += 1
                    return
                }
                if probeIndex > 0 { probeIndex = 0; markContent() }  // not DELIMITER after all; those letters were content
            } else {
                if b == 0x20 || b == 0x09 {
                    buffer.removeLast(10)
                    probeIndex = 0
                    contentSeen = false
                    delimiterArg.removeAll()
                    state = .delimiterLine
                    return
                }
                probeIndex = 0
                markContent()
            }
        }

        switch b {
        case 0x27:
            markContent()
            state = .singleQuote
            backslashEscapes = family == .mysql || ((prev == 0x45 || prev == 0x65) && !Self.isIdentifierByte(prev2))
            escape = false
        case 0x22:
            markContent()
            state = .doubleQuote
            escape = false
        case 0x60 where family == .mysql:
            markContent()
            state = .backtick
        case 0x23 where family == .mysql:
            state = .lineComment
        case 0x2D:
            dashPending = true
            dashWasLeading = !contentSeen
        case 0x2F:
            state = .slash
        case 0x24 where family == .postgres:
            markContent()
            if !Self.isIdentifierByte(prev) {
                state = .dollarTag
                tagScratch.removeAll(keepingCapacity: true)
            }
        case 0x5C where family == .postgres && !contentSeen:
            // psql meta-command (\restrict, \connect …): the whole line is dropped
            buffer.removeLast()
            state = .metaLine
        default:
            if b > 0x20 { markContent() }
            if family == .postgres { trackPostgresWord(b) }
        }

        if state == .normal || (state == .slash && delimiter.last == 0x2F) { checkDelimiter(&out) }
    }

    @inline(__always) private func markContent() { contentSeen = true }

    private static func isIdentifierByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    private func trackPostgresWord(_ b: UInt8) {
        if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
            word.append(b & 0xDF)
            return
        }
        guard !word.isEmpty else { return }
        let w = String(decoding: word, as: UTF8.self)
        word.removeAll(keepingCapacity: true)
        if w == "ATOMIC" && prevWord == "BEGIN" { atomicDepth = 1 } else if atomicDepth > 0 {
            if w == "CASE" { atomicDepth += 1 } else if w == "END" { atomicDepth -= 1 }
        }
        prevWord = w
    }

    private func checkDelimiter(_ out: inout [SplitStatement]) {
        guard atomicDepth == 0 else { return }
        let d = delimiter.count
        guard buffer.count >= d, state == .normal || state == .slash else { return }
        if d == 1 {
            if buffer[buffer.count - 1] == delimiter[0] { emit(dropping: 1, &out) }
        } else if buffer[(buffer.count - d)...].elementsEqual(delimiter) {
            emit(dropping: d, &out)
        }
    }

    private func applyDelimiter() {
        var a = delimiterArg[...]
        while let f = a.first, f == 0x20 || f == 0x09 { a = a.dropFirst() }
        while let l = a.last, l == 0x20 || l == 0x09 || l == 0x0D { a = a.dropLast() }
        // The argument ends at the first whitespace, like the mysql client.
        if let sp = a.firstIndex(where: { $0 == 0x20 || $0 == 0x09 }) { a = a[a.startIndex..<sp] }
        if !a.isEmpty { delimiter = Array(a) }
        delimiterArg.removeAll()
        state = .normal
        contentSeen = false
        buffer.removeAll(keepingCapacity: true)
    }

    private func emit(dropping delimiterLength: Int, _ out: inout [SplitStatement]) {
        let hadContent = contentSeen
        var bytes = buffer
        // reset for the next statement (before a COPY header may switch the state)
        buffer.removeAll(keepingCapacity: true)
        contentSeen = false
        probeIndex = 0
        dashPending = false
        atomicDepth = 0
        word.removeAll(keepingCapacity: true)
        prevWord = ""
        state = .normal
        guard hadContent else { return }

        bytes.removeLast(min(delimiterLength, bytes.count))
        var start = 0
        var end = bytes.count
        while start < end, bytes[start] <= 0x20 { start += 1 }
        while end > start, bytes[end - 1] <= 0x20 { end -= 1 }
        guard end > start else { return }
        let text = String(decoding: bytes[start..<end], as: UTF8.self)
        if family == .postgres, Self.isCopyFromStdin(text) {
            // The statement itself is not executed; its rows arrive next as INSERTs.
            copyHeader = text
            copyRows.removeAll()
            copyLine.removeAll()
            copyHeaderLineDone = false
            state = .copyData
            return
        }
        out.append(SplitStatement(index: nextIndex, text: text, startLine: statementStartLine, startOffset: statementStartOffset))
        nextIndex += 1
    }

    // MARK: COPY → INSERT

    /// The statement without leading whitespace and comments (the splitter keeps those in the text).
    static func withoutLeadingTrivia(_ text: String) -> String {
        var rest = Substring(text)
        while true {
            let trimmed = rest.drop(while: { $0.isWhitespace })
            if trimmed.hasPrefix("--") {
                rest = trimmed.drop(while: { $0 != "\n" })
            } else if trimmed.hasPrefix("/*"), let end = trimmed.range(of: "*/") {
                rest = trimmed[end.upperBound...]
            } else {
                return String(trimmed)
            }
        }
    }

    private static func isCopyFromStdin(_ raw: String) -> Bool {
        let text = withoutLeadingTrivia(raw)
        let head = text.prefix(512)
        guard head.range(of: #"^\s*COPY\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        return head.range(of: #"\bFROM\s+stdin\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func consumeCopyLine(_ out: inout [SplitStatement]) throws {
        var bytes = copyLine
        if bytes.last == 0x0D { bytes.removeLast() }
        if bytes == [0x5C, 0x2E] {  // "\."
            flushCopyRows(&out)
            state = .normal
            buffer.removeAll(keepingCapacity: true)
            contentSeen = false
            return
        }
        copyRows.append(try Self.copyRowLiteral(bytes))
        if copyRows.count >= copyBatch { flushCopyRows(&out) }
    }

    private func flushCopyRows(_ out: inout [SplitStatement]) {
        guard !copyRows.isEmpty else { return }
        guard let target = Self.copyTarget(copyHeader) else { copyRows.removeAll(); return }
        let text = "INSERT INTO \(target) VALUES " + copyRows.joined(separator: ", ")
        out.append(SplitStatement(index: nextIndex, text: text, startLine: line, startOffset: offset))
        nextIndex += 1
        copyRows.removeAll(keepingCapacity: true)
    }

    /// `COPY public.t (a, b) FROM stdin;` → `public.t (a, b)`
    static func copyTarget(_ rawHeader: String) -> String? {
        let header = withoutLeadingTrivia(rawHeader)
        guard let re = try? NSRegularExpression(pattern: #"^\s*COPY\s+(.+?)\s+FROM\s+stdin\b(.*)$"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let r = Range(m.range(at: 1), in: header) else { return nil }
        return String(header[r])
    }

    /// One COPY text-format row → `('a', NULL, 'c')`.
    static func copyRowLiteral(_ line: [UInt8]) throws -> String {
        let dialect = SQLDialect(.postgresql)
        var fields: [[UInt8]] = [[]]
        for b in line {
            if b == 0x09 { fields.append([]) } else { fields[fields.count - 1].append(b) }
        }
        let parts = fields.map { field -> String in
            if field == [0x5C, 0x4E] { return "NULL" }  // \N
            return dialect.quoteString(String(decoding: unescapeCopy(field), as: UTF8.self))
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    /// COPY text escapes: `\\ \b \f \n \r \t \v`, octal `\NNN`, hex `\xHH`; any other `\c` is `c`.
    static func unescapeCopy(_ f: [UInt8]) -> [UInt8] {
        guard f.contains(0x5C) else { return f }
        var out: [UInt8] = []
        var i = 0
        func isOct(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: b - 0x30
            case 0x41...0x46: b - 0x41 + 10
            case 0x61...0x66: b - 0x61 + 10
            default: nil
            }
        }
        while i < f.count {
            let b = f[i]
            guard b == 0x5C, i + 1 < f.count else { out.append(b); i += 1; continue }
            let c = f[i + 1]
            switch c {
            case 0x62: out.append(0x08); i += 2
            case 0x66: out.append(0x0C); i += 2
            case 0x6E: out.append(0x0A); i += 2
            case 0x72: out.append(0x0D); i += 2
            case 0x74: out.append(0x09); i += 2
            case 0x76: out.append(0x0B); i += 2
            case 0x78 where i + 2 < f.count && hex(f[i + 2]) != nil:
                var v = hex(f[i + 2])!
                var used = 3
                if i + 3 < f.count, let h2 = hex(f[i + 3]) { v = v * 16 + h2; used = 4 }
                out.append(v); i += used
            case _ where isOct(c):
                var v = Int(c - 0x30)
                var used = 2
                while used < 4, i + used < f.count, isOct(f[i + used]) { v = v * 8 + Int(f[i + used] - 0x30); used += 1 }
                out.append(UInt8(truncatingIfNeeded: v)); i += used
            default: out.append(c); i += 2
            }
        }
        return out
    }
}
