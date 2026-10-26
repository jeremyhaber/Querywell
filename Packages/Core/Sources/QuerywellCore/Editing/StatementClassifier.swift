import Foundation

/// What a statement does, for the write guard. Deliberately coarse and conservative:
/// anything not positively recognised as harmless is `.write` or `.unknown` (treated as a write).
public enum StatementKind: String, Sendable, Hashable, Codable {
    /// SELECT / SHOW / DESCRIBE / EXPLAIN (without ANALYZE) / VALUES / TABLE / WITH … SELECT.
    case read
    /// INSERT/UPDATE/DELETE/REPLACE/MERGE/COPY FROM/LOAD DATA/CALL/DO, locking or INTO selects,
    /// data-modifying CTEs, EXPLAIN ANALYZE of a write, maintenance and server-admin commands.
    case write
    /// CREATE / ALTER / DROP / TRUNCATE / RENAME / GRANT / REVOKE / COMMENT ON.
    case ddl
    /// BEGIN / START TRANSACTION / COMMIT / ROLLBACK / SAVEPOINT …
    case transaction
    /// SET (session scope) / USE / PREPARE / DEALLOCATE …
    case session
    /// Not recognised. Callers must treat it like a write.
    case unknown

    /// Whether the guard must treat it as changing data or schema (`write`, `ddl`, `unknown`).
    public var isWriteLike: Bool {
        switch self {
        case .write, .ddl, .unknown: true
        case .read, .transaction, .session: false
        }
    }
}

/// A table named in a statement. `schema` is nil when the statement didn't qualify it.
public struct TableReference: Sendable, Hashable {
    public var schema: String?
    public var name: String

    public init(schema: String? = nil, name: String) {
        self.schema = schema
        self.name = name
    }

    public func resolved(defaultSchema: String) -> TableRef {
        TableRef(schema: schema ?? defaultSchema, name: name)
    }
}

public struct ClassifiedStatement: Sendable, Hashable {
    public var text: String
    /// Where the statement came from when it was split out of a script; nil for ad-hoc text.
    public var source: ScriptStatement?
    public var kind: StatementKind
    /// Uppercased leading verb ("SELECT", "DELETE", "WITH", "EXPLAIN", …); empty if none.
    public var verb: String
    /// DELETE/UPDATE (also inside CTEs and EXPLAIN ANALYZE), REPLACE, MERGE, DROP, TRUNCATE, RENAME,
    /// ALTER … DROP/RENAME/TRUNCATE, and anything `.unknown`.
    public var isDestructive: Bool
    /// A (non-trivial) top-level WHERE exists. `WHERE 1`, `WHERE TRUE`, `WHERE 1=1` count as none.
    public var hasWhereClause: Bool
    /// Some DELETE/UPDATE in the statement has no effective WHERE (always confirmed, any connection).
    public var isUnfilteredMutation: Bool
    /// Best-effort tables the statement reads/changes, in order of appearance.
    public var targetTables: [TableReference]
    /// For CREATE/ALTER/DROP: the object type ("TABLE", "DATABASE", "INDEX", …), uppercased.
    public var objectType: String?

    public var range: Range<String.Index>? { source?.range }

    public init(text: String, source: ScriptStatement? = nil, kind: StatementKind, verb: String,
                isDestructive: Bool, hasWhereClause: Bool, isUnfilteredMutation: Bool,
                targetTables: [TableReference], objectType: String? = nil) {
        self.text = text
        self.source = source
        self.kind = kind
        self.verb = verb
        self.isDestructive = isDestructive
        self.hasWhereClause = hasWhereClause
        self.isUnfilteredMutation = isUnfilteredMutation
        self.targetTables = targetTables
        self.objectType = objectType
    }
}

/// Classifies SQL statements for the write guard. Pure.
public struct StatementClassifier: Sendable {
    public let dialect: SQLDialect

    public init(dialect: SQLDialect) { self.dialect = dialect }

    /// Splits `script` and classifies every statement.
    public func classify(script: String) -> [ClassifiedStatement] {
        StatementSplitter.split(script, dialect: dialect).map { classify($0) }
    }

    public func classify(_ statement: ScriptStatement) -> ClassifiedStatement {
        var c = classify(text: statement.text)
        c.source = statement
        return c
    }

    /// Classifies one statement's text (no splitting; a trailing `;` is tolerated).
    public func classify(text: String) -> ClassifiedStatement {
        let lexer = SQLLexer(dialect)
        let tokens = Self.significantTokens(lexer.tokenize(text), lexer: lexer)
        let analysis = Analysis(tokens: tokens, family: dialect.family)
        let r = analysis.classify()
        return ClassifiedStatement(
            text: text, kind: r.kind, verb: r.verb, isDestructive: r.destructive,
            hasWhereClause: r.hasWhere, isUnfilteredMutation: r.unfiltered,
            targetTables: r.tables, objectType: r.objectType)
    }

    /// Non-trivia tokens, with MySQL executable comments (`/*!50100 … */`) replaced by their content.
    static func significantTokens(_ tokens: [SQLToken], lexer: SQLLexer, level: Int = 0) -> [SQLToken] {
        var out: [SQLToken] = []
        for t in tokens {
            switch t.kind {
            case .whitespace, .lineComment, .blockComment: continue
            case .versionedComment where level < 4:
                var inner = Substring(t.text)
                inner = inner.dropFirst(inner.hasPrefix("/*M!") ? 4 : 3)
                if t.isTerminated, inner.hasSuffix("*/") { inner = inner.dropLast(2) }
                inner = inner.drop(while: { $0.isASCII && $0.isNumber })
                out += significantTokens(lexer.tokenize(String(inner)), lexer: lexer, level: level + 1)
            default:
                if t.kind == .symbol, t.text == ";" { continue }
                out.append(t)
            }
        }
        return out
    }
}

// MARK: - Analysis

private struct ClassResult {
    var kind: StatementKind
    var verb: String
    var destructive = false
    var hasWhere = false
    var unfiltered = false
    var tables: [TableReference] = []
    var objectType: String?
}

private struct Analysis {
    let t: [SQLToken]
    let family: SQLDialect.Family
    let kws: [String]
    let depth: [Int]

    init(tokens: [SQLToken], family: SQLDialect.Family) {
        t = tokens
        self.family = family
        kws = tokens.map { $0.kind == .word ? $0.text.uppercased() : "" }
        var d: [Int] = []
        var cur = 0
        for tok in tokens {
            if tok.isSymbol("(") { d.append(cur); cur += 1 }
            else if tok.isSymbol(")") { cur = max(0, cur - 1); d.append(cur) }
            else { d.append(cur) }
        }
        depth = d
    }

    func kw(_ i: Int) -> String { i >= 0 && i < t.count ? kws[i] : "" }
    func sym(_ i: Int, _ s: String) -> Bool { i >= 0 && i < t.count && t[i].isSymbol(s) }

    // Statement-start keywords used to find the real statement after WITH / EXPLAIN.
    private static let dmlStarts: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE"]
    private static let readStarts: Set<String> = ["SELECT", "VALUES", "TABLE"]
    private static let explainInner: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "WITH", "VALUES", "TABLE", "MERGE",
        "CREATE", "EXECUTE", "DECLARE",
    ]

    private static let writeVerbs: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "CALL", "DO", "LOAD", "IMPORT", "EXECUTE", "UPSERT",
        "LOCK", "UNLOCK", "FLUSH", "KILL", "OPTIMIZE", "ANALYZE", "REPAIR", "VACUUM", "REINDEX", "CLUSTER",
        "REFRESH", "NOTIFY", "INSTALL", "UNINSTALL", "CHECK", "SHUTDOWN", "PURGE", "CHANGE", "STOP", "BINLOG",
        "SIGNAL", "RESIGNAL", "HANDLER", "CACHE", "RESTART",
    ]
    /// Writes whose effect isn't visible in the statement text.
    private static let opaqueWriteVerbs: Set<String> = ["CALL", "DO", "EXECUTE"]
    private static let ddlVerbs: Set<String> = [
        "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "SECURITY",
    ]
    private static let readVerbs: Set<String> = ["SELECT", "SHOW", "DESCRIBE", "DESC", "HELP", "VALUES", "TABLE", "CHECKSUM", "FETCH"]
    private static let sessionVerbs: Set<String> = [
        "USE", "DISCARD", "DEALLOCATE", "LISTEN", "UNLISTEN", "DECLARE", "CLOSE", "MOVE",
    ]

    /// Functions that change state even when called from a plain SELECT.
    private static let sideEffectFunctions: Set<String> = [
        "NEXTVAL", "SETVAL", "SET_CONFIG", "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF",
        "PG_ROTATE_LOGFILE", "PG_SWITCH_WAL", "DBLINK_EXEC", "PG_NOTIFY", "PG_ADVISORY_LOCK",
        "PG_ADVISORY_XACT_LOCK", "PG_TRY_ADVISORY_LOCK", "PG_ADVISORY_UNLOCK", "PG_ADVISORY_UNLOCK_ALL",
    ]
    private static let sideEffectPrefixes = ["LO_", "PG_CREATE_", "PG_DROP_", "PG_REPLICATION_", "PG_WAL_REPLAY_"]

    func classify() -> ClassResult {
        var i = 0
        while sym(i, "(") { i += 1 }
        guard i < t.count, !kws[i].isEmpty else {
            return ClassResult(kind: .unknown, verb: "", destructive: true)
        }
        return classify(from: i)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func classify(from i: Int) -> ClassResult {
        let verb = kws[i]
        var r = ClassResult(kind: .unknown, verb: verb)

        switch verb {
        case "SELECT", "VALUES", "TABLE":
            r = readOrWrite(from: i, verb: verb)
            r.tables = fromTables(after: i)
            r.hasWhere = hasEffectiveWhere(from: i, depth: depth[i])
            return r

        case "SHOW", "DESCRIBE", "DESC", "HELP", "CHECKSUM", "FETCH":
            r.kind = .read
            if verb == "DESCRIBE" || verb == "DESC" { r.tables = names(at: i + 1, limit: 1) }
            return r

        case "WITH":
            return classifyWith(i)

        case "EXPLAIN":
            return classifyExplain(i)

        case "INSERT", "REPLACE":
            guard !sym(i + 1, "(") else { return unknownResult(verb) }
            r.kind = .write
            r.destructive = verb == "REPLACE"
            r.tables = names(at: i + 1, skipping: ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE", "INTO", "ONLY"], limit: 1)
            r.hasWhere = false
            // INSERT … SELECT … FOR UPDATE etc. are still writes; nothing more to learn.
            return r

        case "UPDATE":
            r.kind = .write
            r.destructive = true
            r.tables = updateTables(i)
            r.hasWhere = hasEffectiveWhere(from: i, depth: depth[i])
            r.unfiltered = !r.hasWhere
            return r

        case "DELETE":
            r.kind = .write
            r.destructive = true
            r.tables = deleteTables(i)
            r.hasWhere = hasEffectiveWhere(from: i, depth: depth[i])
            r.unfiltered = !r.hasWhere
            return r

        case "MERGE":
            r.kind = .write
            r.destructive = true
            r.hasWhere = true // MERGE is gated by its ON condition; destructive handling still applies
            r.tables = names(at: i + 1, skipping: ["INTO", "ONLY"], limit: 1)
            return r

        case "COPY":
            r.kind = .write
            r.tables = sym(i + 1, "(") ? [] : names(at: i + 1, limit: 1)
            // COPY … TO STDOUT only reads.
            if let to = firstDepth0(["TO", "FROM"], from: i + 1), kws[to] == "TO", kw(to + 1) == "STDOUT" {
                r.kind = .read
            }
            return r

        case "LOAD":
            r.kind = .write
            if let into = firstDepth0(["INTO"], from: i + 1) {
                r.tables = names(at: into + 1, skipping: ["TABLE"], limit: 1)
            }
            return r

        case "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "END", "ABORT", "XA":
            r.kind = .transaction
            return readWriteTransactionGuard(r, from: i)

        case "START":
            if kw(i + 1) == "TRANSACTION" {
                r.kind = .transaction
                return readWriteTransactionGuard(r, from: i)
            }
            r.kind = .write // START REPLICA/SLAVE …
            return r

        case "RELEASE":
            r.kind = kw(i + 1) == "SAVEPOINT" ? .transaction : .write
            return r

        case "PREPARE":
            r.kind = kw(i + 1) == "TRANSACTION" ? .transaction : .session
            return r

        case "SET":
            r.kind = .session
            let words = (i + 1..<t.count).map { kws[$0] }
            if words.contains(where: { ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD"].contains($0) })
                || (kw(i + 1) == "DEFAULT" && kw(i + 2) == "ROLE")
                || (kw(i + 1) == "RESOURCE") {
                r.kind = .write
            }
            // `SET @@global.x` lexes as symbols + word `global`; covered by the words check above.
            return readWriteTransactionGuard(r, from: i)

        case "RESET":
            r.kind = family == .postgres ? .session : .write
            return r

        case "COMMENT":
            r.kind = kw(i + 1) == "ON" ? .ddl : .unknown
            r.destructive = r.kind == .unknown
            if r.kind == .ddl { r.objectType = kw(i + 2) }
            return r

        case "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "SECURITY":
            return classifyDDL(i)

        default:
            break
        }

        if Self.sessionVerbs.contains(verb) { r.kind = .session; return r }
        if Self.writeVerbs.contains(verb) {
            r.kind = .write
            // Procedures and dynamic SQL can do anything (DELETE, DROP…) and can't be dry-run, so
            // treat them as destructive: on PROD that means typing the database name.
            r.destructive = Self.opaqueWriteVerbs.contains(verb)
            return r
        }
        if Self.readVerbs.contains(verb) { r.kind = .read; return r }
        return unknownResult(verb)
    }

    private func unknownResult(_ verb: String) -> ClassResult {
        ClassResult(kind: .unknown, verb: verb, destructive: true)
    }

    /// `START TRANSACTION READ WRITE` / `SET TRANSACTION READ WRITE` re-enable writes on a read-only
    /// connection, so they are treated as writes.
    private func readWriteTransactionGuard(_ r: ClassResult, from i: Int) -> ClassResult {
        var r = r
        for j in i..<max(i, t.count - 1) where kws[j] == "READ" && kws[j + 1] == "WRITE" {
            r.kind = .write
        }
        return r
    }

    // MARK: DDL

    private func classifyDDL(_ i: Int) -> ClassResult {
        let verb = kws[i]
        var r = ClassResult(kind: .ddl, verb: verb)
        switch verb {
        case "DROP", "TRUNCATE", "RENAME":
            r.destructive = true
        case "ALTER":
            r.destructive = (i..<t.count).contains { ["DROP", "RENAME", "TRUNCATE"].contains(kws[$0]) }
        default: break
        }

        // Object type: skip modifiers.
        var j = i + 1
        let modifiers: Set<String> = [
            "OR", "REPLACE", "TEMPORARY", "TEMP", "UNIQUE", "FULLTEXT", "SPATIAL", "UNLOGGED", "GLOBAL", "LOCAL",
            "MATERIALIZED", "RECURSIVE", "DEFINER", "ALGORITHM", "SQL", "SECURITY", "EVENT", "AGGREGATE",
        ]
        if verb == "TRUNCATE" {
            r.objectType = "TABLE"
        } else if verb == "RENAME" {
            r.objectType = kw(j) == "USER" ? "USER" : "TABLE"
        } else if verb == "CREATE" || verb == "ALTER" || verb == "DROP" {
            while j < t.count, modifiers.contains(kws[j]) || sym(j, "=") { j += 1 }
            r.objectType = kw(j).isEmpty ? nil : kw(j)
        }

        let skip: Set<String> = ["IF", "NOT", "EXISTS", "ONLY", "TEMPORARY", "TEMP", "UNLOGGED", "TABLE", "VIEW"]
        switch (verb, r.objectType ?? "") {
        case ("TRUNCATE", _):
            r.tables = nameList(at: i + 1, skipping: skip.union(["TABLE"]))
        case ("DROP", "TABLE"), ("DROP", "VIEW"):
            r.tables = nameList(at: j + 1, skipping: skip)
        case ("ALTER", "TABLE"), ("CREATE", "TABLE"):
            r.tables = names(at: j + 1, skipping: skip, limit: 1)
        case ("RENAME", "TABLE"):
            var k = i + 2
            while k < t.count {
                let (n, next) = parseName(at: k)
                if let n { r.tables.append(n) }
                k = max(next, k + 1)
            }
        default: break
        }
        return r
    }

    // MARK: SELECT & friends

    /// SELECT/VALUES/TABLE: read unless it locks, selects INTO, embeds DML or calls a side-effect function.
    private func readOrWrite(from start: Int, verb: String) -> ClassResult {
        var r = ClassResult(kind: .read, verb: verb)
        if writeIndicator(from: start) != nil { r.kind = .write }
        return r
    }

    /// Returns a description if the tokens from `start` contain something that makes a read statement write.
    private func writeIndicator(from start: Int) -> String? {
        guard start < t.count else { return nil }
        for j in start..<t.count {
            let k = kws[j]
            if k.isEmpty { continue }
            switch k {
            case "INTO": return "INTO"
            case "FOR":
                let n = kw(j + 1)
                if n == "UPDATE" || n == "SHARE" || n == "NO" || n == "KEY" { return "FOR UPDATE/SHARE" }
            case "LOCK":
                if kw(j + 1) == "IN", kw(j + 2) == "SHARE" { return "LOCK IN SHARE MODE" }
            case "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE":
                if sym(j - 1, "("), !sym(j + 1, "(") { return "embedded DML" }
            default:
                if sym(j + 1, "(") {
                    if Self.sideEffectFunctions.contains(k) { return k }
                    if Self.sideEffectPrefixes.contains(where: { k.hasPrefix($0) }) { return k }
                }
            }
        }
        return nil
    }

    private func classifyWith(_ i: Int) -> ClassResult {
        var r = ClassResult(kind: .read, verb: "WITH")
        // Main statement: first depth-0 SELECT/VALUES/TABLE/DML after the CTE list.
        var main: Int?
        let base = depth[i]
        for j in (i + 1)..<max(i + 1, t.count) where depth[j] == base {
            let k = kws[j]
            if Self.readStarts.contains(k) || Self.dmlStarts.contains(k) { main = j; break }
        }
        guard let main else { return unknownResult("WITH") }

        let mainVerb = kws[main]
        if Self.dmlStarts.contains(mainVerb) {
            var m = classify(from: main)
            m.verb = "WITH"
            let embedded = embeddedMutations(in: i..<main)
            m.destructive = m.destructive || embedded.destructive
            m.unfiltered = m.unfiltered || embedded.unfiltered
            return m
        }

        r.tables = fromTables(after: main)
        r.hasWhere = hasEffectiveWhere(from: main, depth: base)
        // Data-modifying CTEs make the whole statement a write.
        let embedded = embeddedMutations(in: i..<t.count)
        if embedded.found || writeIndicator(from: i) != nil {
            r.kind = .write
            r.destructive = embedded.destructive
            r.unfiltered = embedded.unfiltered
            r.tables = embedded.tables + r.tables
        }
        return r
    }

    /// DML statements that start a parenthesised CTE body within `range`.
    private func embeddedMutations(in range: Range<Int>) -> (found: Bool, destructive: Bool, unfiltered: Bool, tables: [TableReference]) {
        var found = false, destructive = false, unfiltered = false
        var tables: [TableReference] = []
        for j in range {
            let k = kws[j]
            guard Self.dmlStarts.contains(k), sym(j - 1, "("), !sym(j + 1, "(") else { continue }
            found = true
            let d = depth[j]
            switch k {
            case "UPDATE":
                destructive = true
                tables += updateTables(j)
                if !hasEffectiveWhere(from: j, depth: d) { unfiltered = true }
            case "DELETE":
                destructive = true
                tables += deleteTables(j)
                if !hasEffectiveWhere(from: j, depth: d) { unfiltered = true }
            case "MERGE", "REPLACE":
                destructive = true
            default: break
            }
        }
        return (found, destructive, unfiltered, tables)
    }

    private func classifyExplain(_ i: Int) -> ClassResult {
        var r = ClassResult(kind: .read, verb: "EXPLAIN")
        var analyze = false
        var j = i + 1
        if sym(j, "(") {
            var close = j
            while close < t.count, !(sym(close, ")") && depth[close] == depth[j]) { close += 1 }
            for k in j..<min(close, t.count) where kws[k] == "ANALYZE" || kws[k] == "ANALYSE" {
                let v = kw(k + 1)
                if !(v == "FALSE" || v == "OFF" || (k + 1 < t.count && t[k + 1].text == "0")) { analyze = true }
            }
            j = close + 1
        }
        var inner: Int?
        while j < t.count {
            let k = kws[j]
            if k == "ANALYZE" || k == "ANALYSE" { analyze = true }
            if Self.explainInner.contains(k) { inner = j; break }
            j += 1
        }
        guard let inner else { return r } // EXPLAIN tbl / EXPLAIN FOR CONNECTION n
        let innerResult = classify(from: inner)
        r.tables = innerResult.tables
        r.hasWhere = innerResult.hasWhere
        if analyze {
            var a = innerResult
            a.verb = "EXPLAIN"
            if a.kind == .unknown { a.kind = .write }
            return a
        }
        return r
    }

    // MARK: WHERE

    /// Whether a non-trivial WHERE at `depth` occurs from `start` to the end of that parenthesis level.
    private func hasEffectiveWhere(from start: Int, depth d: Int) -> Bool {
        var j = start
        while j < t.count, depth[j] >= d {
            if depth[j] == d, kws[j] == "WHERE" {
                var body: [String] = []
                var k = j + 1
                while k < t.count, depth[k] >= d {
                    if depth[k] == d, ["ORDER", "LIMIT", "RETURNING", "GROUP", "HAVING"].contains(kws[k]) { break }
                    body.append(t[k].text.uppercased())
                    k += 1
                }
                var b = body
                while b.count > 2, b.first == "(", b.last == ")" { b = Array(b.dropFirst().dropLast()) }
                let trivial: [[String]] = [["1"], ["TRUE"], ["1", "=", "1"], ["TRUE", "=", "TRUE"], []]
                return !trivial.contains(b)
            }
            j += 1
        }
        return false
    }

    // MARK: Names

    private static let notAnAlias: Set<String> = [
        "SET", "WHERE", "JOIN", "USING", "ON", "INNER", "LEFT", "RIGHT", "CROSS", "NATURAL", "FULL", "OUTER",
        "STRAIGHT_JOIN", "WINDOW", "GROUP", "ORDER", "LIMIT", "HAVING", "UNION", "INTERSECT", "EXCEPT", "FOR",
        "LOCK", "PARTITION", "USE", "FORCE", "IGNORE", "RETURNING", "VALUES", "SELECT", "FROM", "INTO", "OFFSET",
        "FETCH", "TABLESAMPLE", "LATERAL", "AS", "WITH", "TO", "TABLE",
    ]

    /// `a`, `a.b`, `` `a`.`b` `` at `i`. Returns the reference and the index after it.
    private func parseName(at i: Int) -> (TableReference?, Int) {
        func ident(_ k: Int) -> String? {
            guard k < t.count else { return nil }
            switch t[k].kind {
            case .word:
                return Self.notAnAlias.contains(kws[k]) ? nil : t[k].text
            case .quotedIdentifier: return t[k].identifierValue
            default: return nil
            }
        }
        guard let first = ident(i) else { return (nil, i) }
        var parts = [first]
        var j = i + 1
        while sym(j, "."), let next = ident(j + 1) {
            parts.append(next)
            j += 2
        }
        let name = parts[parts.count - 1]
        let schema = parts.count >= 2 ? parts[parts.count - 2] : nil
        return (TableReference(schema: schema, name: name), j)
    }

    /// Names starting at `i`, skipping leading modifier keywords, up to `limit`.
    private func names(at i: Int, skipping: Set<String> = [], limit: Int) -> [TableReference] {
        var j = i
        while j < t.count, skipping.contains(kws[j]) { j += 1 }
        var out: [TableReference] = []
        while out.count < limit {
            let (n, next) = parseName(at: j)
            guard let n else { break }
            out.append(n)
            j = next
        }
        return out
    }

    /// `a, b, c` after optional modifiers (TRUNCATE / DROP TABLE).
    private func nameList(at i: Int, skipping: Set<String>) -> [TableReference] {
        var j = i
        while j < t.count, skipping.contains(kws[j]) { j += 1 }
        var out: [TableReference] = []
        while true {
            let (n, next) = parseName(at: j)
            guard let n else { break }
            out.append(n)
            j = next
            if sym(j, ",") { j += 1 } else { break }
        }
        return out
    }

    private func firstDepth0(_ words: Set<String>, from start: Int) -> Int? {
        guard start < t.count else { return nil }
        let base = depth[min(start, t.count - 1)]
        for j in start..<t.count where depth[j] == base && words.contains(kws[j]) { return j }
        return nil
    }

    /// Table list that follows FROM at the statement's own depth (comma lists and JOINs).
    private func fromTables(after i: Int) -> [TableReference] {
        guard let from = firstDepth0(["FROM"], from: i) else { return [] }
        return tableList(at: from + 1)
    }

    /// `t1 [AS] a, t2 JOIN t3 ON … JOIN t4 …`
    private func tableList(at start: Int) -> [TableReference] {
        var out: [TableReference] = []
        var j = start
        let base = j < t.count ? depth[j] : 0
        while j < t.count {
            let (n, next) = parseName(at: j)
            guard let n else { break }
            out.append(n)
            j = next
            // optional alias
            if kw(j) == "AS" { j += 1; if j < t.count, t[j].kind == .word || t[j].kind == .quotedIdentifier { j += 1 } }
            else if j < t.count, depth[j] == base, t[j].kind == .word, !Self.notAnAlias.contains(kws[j]) { j += 1 }
            else if j < t.count, t[j].kind == .quotedIdentifier { j += 1 }
            if sym(j, ",") { j += 1; continue }
            // advance to next JOIN at this depth, stop at clause end
            var k = j
            var foundJoin = false
            while k < t.count, depth[k] >= base {
                if depth[k] == base {
                    let w = kws[k]
                    if sym(k, ",") { foundJoin = true; break }
                    if w == "JOIN" || w == "STRAIGHT_JOIN" { foundJoin = true; break }
                    if ["WHERE", "GROUP", "ORDER", "LIMIT", "HAVING", "UNION", "WINDOW", "FOR", "SET", "RETURNING"].contains(w) { break }
                }
                k += 1
            }
            guard foundJoin else { break }
            j = k + 1
        }
        return out
    }

    private func updateTables(_ i: Int) -> [TableReference] {
        // UPDATE [LOW_PRIORITY] [IGNORE] [ONLY] t [, t2 …] SET …
        var j = i + 1
        while j < t.count, ["LOW_PRIORITY", "IGNORE", "ONLY"].contains(kws[j]) { j += 1 }
        return tableList(at: j)
    }

    private func deleteTables(_ i: Int) -> [TableReference] {
        // DELETE [mods] FROM [ONLY] t …   |   DELETE t1[,t2] FROM t1 JOIN …   |   DELETE FROM t USING …
        guard let from = firstDepth0(["FROM"], from: i + 1) else { return [] }
        var j = from + 1
        while j < t.count, kws[j] == "ONLY" { j += 1 }
        var out = tableList(at: j)
        if let using = firstDepth0(["USING"], from: j) { out += tableList(at: using + 1) }
        return out
    }
}
