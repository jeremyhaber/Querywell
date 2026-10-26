import Foundation

// MARK: - Statement scanner

/// Byte-at-a-time SQL lexer that only answers one question: "where does this statement end?"
/// It tracks quotes (`'`, `"`, `` ` `` with backslash escapes in the first two), `-- ` / `#` / `/* */`
/// comments and the active client delimiter. `/*! … */` and `/*M! … */` versioned comments are
/// treated as code (as the mysql client does), ordinary comments as opaque. State survives chunk
/// boundaries, so the scanner can stream arbitrarily long statements in constant memory.
///
/// Assumes backslash escapes are active in string literals (the app strips `NO_BACKSLASH_ESCAPES`
/// from its sessions — DECISIONS #29 — and mysqldump emits backslash-escaped literals).
struct StatementScanner {
    private enum State: UInt8 { case normal, sq, dq, bt, line, block, dash2 }

    private var state: State = .normal
    private var esc = false
    private var prev: UInt8 = 0
    private var dashPending = false
    private var blockStage = 0
    private var blockStar = false
    private var versioned = false
    private var dm = 0

    /// Consumes bytes from `start`. Returns the index just past the statement delimiter, or nil if the
    /// statement continues beyond the buffer.
    mutating func scan(_ p: UnsafeBufferPointer<UInt8>, from start: Int, delimiter: [UInt8]) -> Int? {
        var i = start
        let n = p.count
        let d0 = delimiter[0]
        let dcount = delimiter.count
        while i < n {
            let b = p[i]
            switch state {
            case .sq:
                if esc { esc = false } else if b == 0x5C { esc = true } else if b == 0x27 { state = .normal; prev = 0; dm = 0 }
                i += 1
            case .dq:
                if esc { esc = false } else if b == 0x5C { esc = true } else if b == 0x22 { state = .normal; prev = 0; dm = 0 }
                i += 1
            case .bt:
                if b == 0x60 { state = .normal; prev = 0; dm = 0 }
                i += 1
            case .line:
                if b == 0x0A { state = .normal; prev = 0; dm = 0 }
                i += 1
            case .dash2:
                if b <= 0x20 {
                    state = (b == 0x0A) ? .normal : .line
                    prev = 0
                    i += 1
                } else {
                    state = .normal  // not a comment after all; reprocess this byte
                    prev = 0x2D
                }
            case .block:
                if blockStage < 2 {
                    if b == 0x21 {  // '!' — versioned comment: contents are code
                        state = .normal
                        versioned = true
                        prev = 0
                        i += 1
                        continue
                    }
                    if blockStage == 0 && b == 0x4D {  // 'M' of "/*M!"
                        blockStage = 1
                        blockStar = false
                        i += 1
                        continue
                    }
                    blockStage = 2
                }
                if blockStar && b == 0x2F {
                    state = .normal
                    prev = 0
                    dm = 0
                    blockStar = false
                } else {
                    blockStar = (b == 0x2A)
                }
                i += 1
            case .normal:
                // delimiter detection
                if b == delimiter[dm] {
                    dm += 1
                    if dm == dcount {
                        dm = 0
                        prev = 0
                        dashPending = false
                        return i + 1
                    }
                } else {
                    dm = (b == d0) ? 1 : 0
                    if dm == dcount {  // single-byte delimiter handled above; defensive
                        dm = 0
                        return i + 1
                    }
                }
                switch b {
                case 0x27: state = .sq; dm = 0; dashPending = false
                case 0x22: state = .dq; dm = 0; dashPending = false
                case 0x60: state = .bt; dm = 0; dashPending = false
                case 0x23: state = .line; dm = 0; dashPending = false
                case 0x2D:
                    if dashPending {
                        dashPending = false
                        state = .dash2
                        dm = 0
                    } else {
                        dashPending = true
                    }
                case 0x2A:
                    dashPending = false
                    if prev == 0x2F {
                        state = .block
                        blockStage = 0
                        blockStar = false
                        dm = 0
                    }
                case 0x2F:
                    dashPending = false
                    if prev == 0x2A && versioned { versioned = false }
                default:
                    dashPending = false
                }
                prev = b
                i += 1
            }
        }
        return nil
    }
}

// MARK: - Streaming engine

/// Splits a SQL dump stream into statements and hands DDL statements (CREATE / ALTER / SET and
/// versioned-comment statements) to `transform`. Everything else — INSERT, REPLACE, UPDATE, LOCK,
/// COPY data, `LOAD DATA`, unknown statements, comments — streams through byte-for-byte without
/// being buffered. An allow-list (not a block-list) decides what is rewritable, so unrecognised
/// statements are never touched.
final class DumpStreamEngine {
    private enum Mode { case idle, ddl, passthrough, delimiterLine, copyData, lineComment, blockComment }

    private var mode: Mode = .idle
    private var scanner = StatementScanner()
    private var delimiter: [UInt8] = [0x3B]
    private var carry: [UInt8] = []
    private var stmt: [UInt8] = []
    private var delimArg: [UInt8] = []
    private var isCopy = false
    private var copyState = 0
    private var blockStar = false

    private(set) var out: [UInt8] = []
    private let emit: Bool
    private let transform: ([UInt8]) -> [UInt8]?
    let maxBuffered: Int
    private(set) var oversizedStatements = 0

    init(emitOutput: Bool, maxBufferedStatementBytes: Int, transform: @escaping ([UInt8]) -> [UInt8]?) {
        self.emit = emitOutput
        self.maxBuffered = maxBufferedStatementBytes
        self.transform = transform
    }

    func takeOutput() -> Data {
        let d = Data(out)
        out.removeAll(keepingCapacity: true)
        return d
    }

    func feed(_ chunk: Data) {
        chunk.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            if carry.isEmpty {
                let used = run(p, final: false)
                if used < p.count { carry = Array(p[used...]) }
            } else {
                var combined = carry
                combined.append(contentsOf: p)
                carry = []
                let used = combined.withUnsafeBufferPointer { run($0, final: false) }
                if used < combined.count { carry = Array(combined[used...]) }
            }
        }
    }

    func finish() {
        if !carry.isEmpty {
            let c = carry
            carry = []
            _ = c.withUnsafeBufferPointer { run($0, final: true) }
        }
        if mode == .ddl, !stmt.isEmpty {
            flushDDL()
        }
        if mode == .delimiterLine { applyDelimiter() }
    }

    // MARK: helpers

    @inline(__always) private func put(_ b: UInt8) { if emit { out.append(b) } }

    private func putRange(_ p: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int) {
        if emit && b > a { out.append(contentsOf: UnsafeBufferPointer(rebasing: p[a..<b])) }
    }

    private func putBytes(_ bytes: [UInt8]) { if emit { out.append(contentsOf: bytes) } }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C }
    private static func isWordStart(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
    private static func isWordChar(_ b: UInt8) -> Bool { isWordStart(b) || (b >= 0x30 && b <= 0x39) || b == 0x5F }

    private func startStatement(_ m: Mode, copy: Bool = false) {
        scanner = StatementScanner()
        mode = m
        isCopy = copy
        stmt.removeAll(keepingCapacity: true)
    }

    private func applyDelimiter() {
        var a = delimArg[...]
        while let f = a.first, Self.isSpace(f) { a = a.dropFirst() }
        while let l = a.last, Self.isSpace(l) { a = a.dropLast() }
        if !a.isEmpty { delimiter = Array(a) }
        delimArg.removeAll()
        mode = .idle
    }

    private func flushDDL() {
        let statement = stmt
        stmt.removeAll(keepingCapacity: true)
        mode = .idle
        if isCopy {
            putBytes(statement)
            if Self.containsStdin(statement) {
                mode = .copyData
                copyState = 0
            }
            return
        }
        if let rewritten = transform(statement) { putBytes(rewritten) } else { putBytes(statement) }
    }

    private static func containsStdin(_ s: [UInt8]) -> Bool {
        let needle = Array("stdin".utf8)
        guard s.count >= needle.count else { return false }
        for i in 0...(s.count - needle.count) {
            var ok = true
            for k in 0..<needle.count where (s[i + k] | 0x20) != needle[k] {
                ok = false
                break
            }
            if ok { return true }
        }
        return false
    }

    // MARK: main loop

    /// Processes `p`; returns how many bytes were consumed (the rest needs more look-ahead and is carried).
    private func run(_ p: UnsafeBufferPointer<UInt8>, final: Bool) -> Int {
        var i = 0
        let n = p.count
        while i < n {
            switch mode {
            case .idle:
                let b = p[i]
                if Self.isSpace(b) {
                    put(b)
                    i += 1
                    continue
                }
                switch b {
                case 0x23:  // '#'
                    mode = .lineComment
                case 0x2D:  // '-'
                    if n - i < 3 && !final { return i }
                    if i + 1 < n, p[i + 1] == 0x2D, i + 2 >= n || p[i + 2] <= 0x20 {
                        mode = .lineComment
                        putRange(p, i, i + 2)
                        i += 2
                    } else {
                        startStatement(.passthrough)
                    }
                case 0x2F:  // '/'
                    if n - i < 2 && !final { return i }
                    if i + 1 < n, p[i + 1] == 0x2A {
                        if n - i < 4 && !final { return i }
                        let c2: UInt8 = i + 2 < n ? p[i + 2] : 0
                        let c3: UInt8 = i + 3 < n ? p[i + 3] : 0
                        if c2 == 0x21 || (c2 == 0x4D && c3 == 0x21) {
                            startStatement(.ddl)
                        } else {
                            mode = .blockComment
                            blockStar = false
                            putRange(p, i, i + 2)
                            i += 2
                        }
                    } else {
                        startStatement(.passthrough)
                    }
                default:
                    if Self.isWordStart(b) {
                        var j = i
                        while j < n, j - i <= 16, Self.isWordChar(p[j]) { j += 1 }
                        if j == n && !final && j - i <= 16 { return i }
                        let len = j - i
                        var upper = [UInt8]()
                        if len <= 16 { for k in i..<j { upper.append(p[k] & 0xDF) } }
                        switch String(decoding: upper, as: UTF8.self) {
                        case "CREATE", "ALTER", "SET":
                            startStatement(.ddl)
                        case "COPY":
                            startStatement(.ddl, copy: true)
                        case "DELIMITER":
                            if j < n, p[j] == 0x20 || p[j] == 0x09 {
                                putRange(p, i, j)
                                i = j
                                delimArg.removeAll()
                                mode = .delimiterLine
                            } else if j == n {
                                // "DELIMITER" at the very end of input
                                putRange(p, i, j)
                                i = j
                            } else {
                                startStatement(.passthrough)
                            }
                        default:
                            startStatement(.passthrough)
                        }
                    } else {
                        startStatement(.passthrough)
                    }
                }
            case .lineComment:
                let start = i
                while i < n && p[i] != 0x0A { i += 1 }
                if i < n {
                    i += 1
                    mode = .idle
                }
                putRange(p, start, i)
            case .blockComment:
                let b = p[i]
                put(b)
                i += 1
                if blockStar && b == 0x2F {
                    mode = .idle
                    blockStar = false
                } else {
                    blockStar = (b == 0x2A)
                }
            case .delimiterLine:
                let b = p[i]
                put(b)
                i += 1
                if b == 0x0A {
                    applyDelimiter()
                } else if delimArg.count < 64 {
                    delimArg.append(b)
                }
            case .ddl:
                let start = i
                if let end = scanner.scan(p, from: i, delimiter: delimiter) {
                    stmt.append(contentsOf: UnsafeBufferPointer(rebasing: p[start..<end]))
                    i = end
                    flushDDL()
                } else {
                    stmt.append(contentsOf: UnsafeBufferPointer(rebasing: p[start..<n]))
                    i = n
                    if stmt.count > maxBuffered {
                        // Too big to rewrite safely in bounded memory: pass the rest through untouched.
                        putBytes(stmt)
                        stmt.removeAll(keepingCapacity: true)
                        oversizedStatements += 1
                        mode = .passthrough
                    }
                }
            case .passthrough:
                let start = i
                if let end = scanner.scan(p, from: i, delimiter: delimiter) {
                    putRange(p, start, end)
                    i = end
                    mode = .idle
                } else {
                    putRange(p, start, n)
                    i = n
                }
            case .copyData:
                let b = p[i]
                put(b)
                i += 1
                switch copyState {
                case 0: if b == 0x0A { copyState = 1 }
                case 1: copyState = (b == 0x5C) ? 2 : (b == 0x0A ? 1 : 0)
                case 2: copyState = (b == 0x2E) ? 3 : (b == 0x0A ? 1 : 0)
                default:
                    if b == 0x0A || b == 0x0D { mode = .idle } else { copyState = 0 }
                }
            }
        }
        return n
    }
}

// MARK: - DDL name rewriting

/// Finds charset / collation names in one buffered DDL statement and lets `visit` replace them.
enum DDLNameRewriter {
    private struct Token {
        enum Kind { case word, string, quotedIdent, punct }
        var kind: Kind
        var start: Int
        var end: Int
    }

    private static let charsetVariables: Set<String> = [
        "character_set_client", "character_set_connection", "character_set_results",
        "character_set_database", "character_set_server", "character_set_filesystem",
    ]
    private static let collationVariables: Set<String> = [
        "collation_connection", "collation_database", "collation_server",
    ]

    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x5F || b == 0x24 || b == 0x40 || b >= 0x80
    }

    private static func tokenize(_ s: [UInt8]) -> [Token] {
        var toks: [Token] = []
        var i = 0
        let n = s.count
        var versioned = false
        while i < n {
            let b = s[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C {
                i += 1
            } else if b == 0x23 || (b == 0x2D && i + 1 < n && s[i + 1] == 0x2D && (i + 2 >= n || s[i + 2] <= 0x20)) {
                while i < n && s[i] != 0x0A { i += 1 }
            } else if b == 0x2F && i + 1 < n && s[i + 1] == 0x2A {
                if i + 2 < n && s[i + 2] == 0x21 {
                    versioned = true
                    i += 3
                    while i < n && s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
                } else if i + 3 < n && s[i + 2] == 0x4D && s[i + 3] == 0x21 {
                    versioned = true
                    i += 4
                    while i < n && s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
                } else {
                    i += 2
                    while i + 1 < n && !(s[i] == 0x2A && s[i + 1] == 0x2F) { i += 1 }
                    i = min(n, i + 2)
                }
            } else if b == 0x2A && versioned && i + 1 < n && s[i + 1] == 0x2F {
                versioned = false
                i += 2
            } else if b == 0x27 || b == 0x22 || b == 0x60 {
                let q = b
                let start = i
                i += 1
                while i < n {
                    if s[i] == 0x5C && q != 0x60 { i += 2; continue }
                    if s[i] == q {
                        if i + 1 < n && s[i + 1] == q { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                i = min(i, n)
                toks.append(Token(kind: q == 0x60 ? .quotedIdent : .string, start: start, end: i))
            } else if isWordByte(b) {
                let start = i
                while i < n && isWordByte(s[i]) { i += 1 }
                toks.append(Token(kind: .word, start: start, end: i))
            } else {
                toks.append(Token(kind: .punct, start: i, end: i + 1))
                i += 1
            }
        }
        return toks
    }

    /// Returns the rewritten statement, or nil when nothing changed.
    static func rewrite(_ s: [UInt8], visit: (CollationNameKind, String) -> String?) -> [UInt8]? {
        let toks = tokenize(s)
        guard !toks.isEmpty else { return nil }
        var edits: [Int: [UInt8]] = [:]

        func text(_ i: Int) -> String { String(decoding: s[toks[i].start..<toks[i].end], as: UTF8.self) }
        func isWord(_ i: Int, _ w: String) -> Bool {
            i >= 0 && i < toks.count && toks[i].kind == .word && text(i).uppercased() == w
        }
        func isPunct(_ i: Int, _ c: UInt8) -> Bool {
            i >= 0 && i < toks.count && toks[i].kind == .punct && s[toks[i].start] == c
        }
        func skipEquals(_ i: Int) -> Int { isPunct(i, 0x3D) ? i + 1 : i }

        func plainName(_ t: String) -> Bool {
            !t.isEmpty && t.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
        }

        func apply(_ kind: CollationNameKind, at i: Int, prefixLength: Int = 0) {
            guard i >= 0, i < toks.count else { return }
            let t = toks[i]
            var q: UInt8?
            var name: String
            switch t.kind {
            case .word:
                name = text(i)
            case .string:
                guard t.end - t.start >= 2, s[t.start] == s[t.end - 1] else { return }
                q = s[t.start]
                name = String(decoding: s[(t.start + 1)..<(t.end - 1)], as: UTF8.self)
            default:
                return
            }
            if prefixLength > 0 { name = String(name.dropFirst(prefixLength)) }
            guard plainName(name), name.first.map({ !$0.isNumber }) ?? false,
                  !MappingGuard.reserved.contains(name.lowercased()) else { return }
            guard let replacement = visit(kind, name) else { return }
            var bytes: [UInt8] = []
            if let q { bytes.append(q) }
            if prefixLength > 0 { bytes.append(contentsOf: s[t.start..<(t.start + prefixLength)]) }
            bytes.append(contentsOf: replacement.utf8)
            if let q { bytes.append(q) }
            edits[i] = bytes
        }

        for i in toks.indices where toks[i].kind == .word {
            let up = text(i).uppercased()
            switch up {
            case "COLLATE":
                apply(.collation, at: skipEquals(i + 1))
            case "CHARSET":
                apply(.charset, at: skipEquals(i + 1))
            case "CHARACTER":
                if isWord(i + 1, "SET") { apply(.charset, at: skipEquals(i + 2)) }
            case "NAMES":
                if isWord(i - 1, "SET") { apply(.charset, at: i + 1) }
            default:
                var low = up.lowercased()
                if low.hasPrefix("@@") { low.removeFirst(2) } else if low.hasPrefix("@") { low.removeFirst() }
                if charsetVariables.contains(low), isPunct(i + 1, 0x3D) {
                    apply(.charset, at: i + 2)
                } else if charsetVariables.contains(low), isPunct(i + 1, 0x3A), isPunct(i + 2, 0x3D) {
                    apply(.charset, at: i + 3)
                } else if collationVariables.contains(low), isPunct(i + 1, 0x3D) {
                    apply(.collation, at: i + 2)
                } else if collationVariables.contains(low), isPunct(i + 1, 0x3A), isPunct(i + 2, 0x3D) {
                    apply(.collation, at: i + 3)
                } else if up.hasPrefix("_"), up.count > 1, i + 1 < toks.count, toks[i + 1].kind == .string {
                    // character-set introducer: _utf8mb3'text'
                    apply(.charset, at: i, prefixLength: 1)
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(s.count + 16)
        var cursor = 0
        for i in edits.keys.sorted() {
            out.append(contentsOf: s[cursor..<toks[i].start])
            out.append(contentsOf: edits[i]!)
            cursor = toks[i].end
        }
        out.append(contentsOf: s[cursor...])
        return out
    }

    private enum MappingGuard {
        static let reserved: Set<String> = ["default", "binary", "null"]
    }
}
