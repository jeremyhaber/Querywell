import Foundation

public struct CompletionItem: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        case table, view, schema, column, function, routine, keyword, enumValue, alias
    }

    /// What the popup shows (`p.ID` when the column name is ambiguous in scope).
    public var label: String
    /// What replaces ``CompletionResult/range``: identifiers quoted only when needed, enum values as SQL literals.
    public var insertText: String
    public var kind: Kind
    /// Secondary text: a column's declared type, a table's kind, "enum value", …
    public var detail: String?
    /// Higher is better; already folded into the order of ``CompletionResult/items``.
    public var score: Int

    public init(label: String, insertText: String, kind: Kind, detail: String? = nil, score: Int = 0) {
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.detail = detail
        self.score = score
    }
}

/// Which situation the cursor is in, as detected from the tokens around it.
public enum CompletionContext: Hashable, Sendable {
    /// Inside a string, comment or a finished literal: nothing is offered.
    case suppressed
    case statementStart
    /// After FROM / JOIN / INTO / UPDATE / TABLE …
    case tableName
    /// `schema.` in a table position.
    case qualifiedTables
    /// After a table reference in FROM/JOIN/INTO: clause keywords.
    case afterTable
    /// SELECT list, WHERE, ON, GROUP/ORDER BY, SET, function arguments …
    case expression
    /// `alias.` or `table.`
    case qualifiedColumns
    /// `INSERT INTO t (|`
    case insertColumns
    case schemaName
    case routineName
    case other
}

public struct CompletionResult: Hashable, Sendable {
    /// The text to replace, as UTF-16 offsets into the input (NSRange-compatible): the word under the
    /// cursor extended to its end (or the whole quoted identifier); empty at the cursor without a prefix.
    public var range: Range<Int>
    /// Best first.
    public var items: [CompletionItem]
    public var context: CompletionContext
    /// Tables in scope whose columns the catalog doesn't have yet — load them and call again.
    public var missingColumns: [TableRef]
    /// Schemas whose table list the catalog doesn't have yet (after `other_db.`).
    public var missingTableLists: [String]

    public init(range: Range<Int>, items: [CompletionItem] = [], context: CompletionContext = .other,
                missingColumns: [TableRef] = [], missingTableLists: [String] = []) {
        self.range = range
        self.items = items
        self.context = context
        self.missingColumns = missingColumns
        self.missingTableLists = missingTableLists
    }
}

/// Schema-aware SQL autocomplete. Pure: text + cursor + a ``SchemaCatalog`` in, ranked suggestions out.
///
/// Context comes from the lexer, never from regexes, so nothing is offered inside strings or comments
/// and `;`, quotes and parentheses are handled exactly. Aliases (`wp_posts p`, `AS p`) are resolved from
/// the FROM / JOIN / UPDATE / INTO clauses of the statement the cursor is in (and its enclosing queries,
/// for correlated subqueries).
public enum SQLCompletion {
    public static func complete(
        text: String, cursor: Int, dialect: SQLDialect, catalog: SchemaCatalog,
        currentSchema: String?, limit: Int = 60
    ) -> CompletionResult {
        var engine = Engine(text: text, cursor: cursor, dialect: dialect, catalog: catalog,
                            currentSchema: currentSchema, limit: limit)
        return engine.run()
    }
}

// MARK: - Engine

private struct Tok {
    var kind: SQLToken.Kind
    var text: String
    var start: Int  // UTF-16
    var end: Int
    var terminated: Bool

    var keyword: String? { kind == .word ? text.uppercased() : nil }
    func isSym(_ s: String) -> Bool { kind == .symbol && text == s }
    func isKeyword(_ k: String) -> Bool { kind == .word && text.caseInsensitiveCompare(k) == .orderedSame }
    var isIdent: Bool { kind == .word || kind == .quotedIdentifier }
    var identifier: String {
        guard kind == .quotedIdentifier, let q = text.first else { return text }
        var body = String(text.dropFirst())
        if terminated, body.last == q { body.removeLast() }
        return body.replacingOccurrences(of: String(q) + String(q), with: String(q))
    }
}

private struct ScopeTable {
    enum Kind { case table, derived, cte }
    var kind: Kind
    var alias: String?
    var ref: TableReference?
    var name: String { alias ?? ref?.name ?? "" }
}

private enum Ctx {
    case statementStart
    case subqueryStart
    case tableName
    case afterTable(String)
    case expression
    case insertColumns(TableReference)
    case schemaName
    case routineName
    case other
}

private struct Engine {
    let text: String
    let cursor: Int
    let dialect: SQLDialect
    let catalog: SchemaCatalog
    let currentSchema: String?
    let limit: Int

    var missingColumns: [TableRef] = []
    var missingTableLists: [String] = []

    init(text: String, cursor: Int, dialect: SQLDialect, catalog: SchemaCatalog, currentSchema: String?, limit: Int) {
        self.text = text
        self.cursor = max(0, min(cursor, text.utf16.count))
        self.dialect = dialect
        self.catalog = catalog
        self.currentSchema = currentSchema
        self.limit = limit
    }

    // MARK: Entry

    mutating func run() -> CompletionResult {
        let empty = CompletionResult(range: cursor..<cursor, context: .suppressed)

        // Tokenise with UTF-16 offsets.
        let bytes = Array(text.utf8)
        let lexed = SQLLexer(dialect).tokenize(bytes)
        var cur = UTF16Cursor(bytes: bytes)
        let all: [Tok] = lexed.map {
            Tok(kind: $0.kind, text: $0.text, start: cur.offset(of: $0.range.lowerBound),
                end: cur.offset(of: $0.range.upperBound), terminated: $0.isTerminated)
        }

        // Inside a literal / comment (or directly after a finished one) -> nothing.
        var prefix = ""
        var range = cursor..<cursor
        var quotedPrefix = false
        var prefixStart = cursor
        for t in all {
            switch t.kind {
            case .string, .dollarString, .lineComment, .blockComment, .versionedComment:
                let inside = (t.start < cursor && cursor < t.end)
                    || (cursor == t.end && (!t.terminated || t.kind == .lineComment))
                if inside { return empty }
                if cursor == t.end && t.end > t.start { return empty }  // right after a literal / comment
            case .number:
                if t.start < cursor && cursor <= t.end { return empty }
            case .quotedIdentifier:
                if t.start < cursor && (cursor < t.end || (cursor == t.end && !t.terminated)) {
                    quotedPrefix = true
                    prefixStart = t.start
                    prefix = slice(t.start + 1, cursor)
                    range = t.start..<(t.terminated ? t.end : cursor)
                } else if cursor == t.end && t.terminated {
                    return empty
                }
            case .word:
                if t.start < cursor && cursor <= t.end {
                    prefixStart = t.start
                    prefix = slice(t.start, cursor)
                    range = t.start..<t.end
                }
            default: break
            }
        }

        // Significant tokens of the current statement.
        let sig = all.filter { $0.kind != .whitespace && $0.kind != .lineComment && $0.kind != .blockComment && $0.kind != .versionedComment }
        var stmtStart = 0
        var stmtEnd = sig.count
        for (i, t) in sig.enumerated() where t.isSym(";") {
            if t.end <= prefixStart { stmtStart = i + 1 }
            else if t.start >= max(cursor, range.upperBound) { stmtEnd = i; break }
        }
        let S = Array(sig[stmtStart..<max(stmtStart, stmtEnd)])
        // Tokens before the prefix word.
        let ci = S.firstIndex { $0.start >= prefixStart } ?? S.count

        // Parenthesis structure before the insertion point.
        var opens: [Int] = []
        for i in 0..<ci {
            if S[i].isSym("(") { opens.append(i) } else if S[i].isSym(")"), !opens.isEmpty { opens.removeLast() }
        }

        // Qualifier chain: `a.` or `a.b.` immediately before the prefix.
        var qualifier: [String] = []
        var k = ci - 1
        while k >= 1, S[k].isSym("."), S[k - 1].isIdent {
            qualifier.insert(S[k - 1].identifier, at: 0)
            k -= 2
        }
        let hasDotBefore = ci >= 1 && S[ci - 1].isSym(".")
        if hasDotBefore && qualifier.isEmpty { return CompletionResult(range: range, context: .other) }

        let scopes = scopeTables(S, ci: ci, opens: opens)
        let followedByParen = nextCharIsParen(after: range.upperBound)

        var items: [CompletionItem] = []
        var context: CompletionContext = .other

        if !qualifier.isEmpty {
            // Decide between "tables of a schema" and "columns of a table".
            let tableContext: Bool
            if case .tableName = detectContext(S, ci: max(0, k + 1)) { tableContext = true } else { tableContext = false }
            (items, context) = qualified(qualifier, scopes: scopes, tablePosition: tableContext)
        } else {
            switch detectContext(S, ci: ci) {
            case .statementStart:
                context = .statementStart
                items = keywordItems(SQLKeywords.statementStarters, prefix: prefix, boost: 100)
            case .subqueryStart:
                context = .statementStart
                items = keywordItems(["SELECT", "WITH", "VALUES"], prefix: prefix, boost: 100)
            case .tableName:
                context = .tableName
                items = tableItems(scopes: scopes, includeSchemas: true)
            case .afterTable(let clause):
                context = .afterTable
                items = keywordItems(Self.followKeywords(clause), prefix: prefix, boost: 100)
            case .schemaName:
                context = .schemaName
                items = catalog.schemas.map {
                    CompletionItem(label: $0, insertText: ident($0), kind: .schema, detail: "schema", score: 100)
                }
            case .routineName:
                context = .routineName
                items = routineItems(procedures: true)
            case .insertColumns(let ref):
                context = .insertColumns
                let t = ScopeTable(kind: .table, alias: nil, ref: ref)
                items = columnItems(for: [t], ambiguous: [])
            case .expression:
                context = .expression
                items = expressionItems(S, ci: ci, opens: opens, scopes: scopes, prefix: prefix,
                                        followedByParen: followedByParen)
            case .other:
                context = .other
                items = keywordItems(SQLKeywords.sortedKeywords(for: dialect.family), prefix: prefix, boost: 0)
            }
        }

        if quotedPrefix {
            // Inside backticks / double quotes only identifiers make sense, always quoted.
            items = items.filter { [.table, .view, .schema, .column, .alias].contains($0.kind) }
                .map { var i = $0; i.insertText = dialect.quoteIdentifier(identifierText(of: $0)); return i }
        }

        items = rank(items, prefix: prefix)
        if items.count > limit { items = Array(items.prefix(limit)) }
        return CompletionResult(range: range, items: items, context: context, missingColumns: dedupe(missingColumns),
                                missingTableLists: Array(Set(missingTableLists)).sorted())
    }

    // MARK: Utilities

    private func slice(_ a: Int, _ b: Int) -> String {
        let u = Array(text.utf16)
        let lo = max(0, min(a, u.count)), hi = max(lo, min(b, u.count))
        return String(decoding: u[lo..<hi], as: UTF16.self)
    }

    private func nextCharIsParen(after offset: Int) -> Bool {
        let u = Array(text.utf16)
        var i = offset
        while i < u.count, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        return i < u.count && u[i] == 0x28
    }

    private func ident(_ name: String) -> String {
        WhereCompletion.insertableIdentifier(name, dialect: dialect)
    }

    private func identifierText(of item: CompletionItem) -> String {
        // Items carry the bare name in `label` except ambiguous columns (`p.ID`), where it is the last part.
        item.label.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? item.label
    }

    private func dedupe(_ refs: [TableRef]) -> [TableRef] {
        var seen = Set<TableRef>()
        return refs.filter { seen.insert($0).inserted }
    }

    private func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        var scored: [(offset: Int, item: CompletionItem)] = []
        var seen = Set<String>()
        for (offset, var item) in items.enumerated() {
            let key = "\(item.kind.rawValue)|\(item.insertText)"
            guard seen.insert(key).inserted else { continue }
            if prefix.isEmpty {
                scored.append((offset, item))
            } else {
                let candidate = identifierText(of: item)
                guard let m = FuzzyMatcher.score(query: prefix, candidate: item.kind == .enumValue ? item.label : candidate) else { continue }
                item.score += m.score
                scored.append((offset, item))
            }
        }
        scored.sort { a, b in a.item.score != b.item.score ? a.item.score > b.item.score : a.offset < b.offset }
        return scored.map(\.item)
    }

    // MARK: Item builders

    private func keywordCase(_ prefix: String) -> (String) -> String {
        let lower = !prefix.isEmpty && prefix == prefix.lowercased()
        return { lower ? $0.lowercased() : $0 }
    }

    private func keywordItems(_ words: [String], prefix: String, boost: Int) -> [CompletionItem] {
        let c = keywordCase(prefix)
        return words.map { CompletionItem(label: $0, insertText: c($0), kind: .keyword, score: boost) }
    }

    private func tableItems(scopes: [ScopeTable], includeSchemas: Bool) -> [CompletionItem] {
        var out: [CompletionItem] = []
        let schema = currentSchema ?? catalog.schemas.first ?? ""
        for t in catalog.tables(in: schema) {
            let kind: CompletionItem.Kind = t.kind == .table ? .table : .view
            out.append(CompletionItem(label: t.ref.name, insertText: ident(t.ref.name), kind: kind,
                                      detail: t.kind == .table ? "table" : "view", score: 300))
        }
        for s in scopes where s.kind == .cte {
            out.append(CompletionItem(label: s.name, insertText: ident(s.name), kind: .table, detail: "CTE", score: 320))
        }
        if includeSchemas {
            for s in catalog.schemas {
                out.append(CompletionItem(label: s, insertText: ident(s), kind: .schema, detail: "schema", score: 100))
            }
        }
        return out
    }

    private func routineItems(procedures: Bool) -> [CompletionItem] {
        let schema = currentSchema ?? ""
        return catalog.routines(in: schema)
            .filter { procedures ? $0.kind == .procedure : true }
            .map { CompletionItem(label: $0.name, insertText: ident($0.name), kind: .routine, detail: $0.kind.rawValue, score: 200) }
    }

    /// Columns of `tables`; names present in more than one of them are prefixed with the alias / table name.
    private mutating func columnItems(for tables: [ScopeTable], ambiguous: Set<String>) -> [CompletionItem] {
        var out: [CompletionItem] = []
        for t in tables {
            guard let cols = columns(of: t) else { continue }
            for c in cols {
                let bare = ident(c.name)
                let isAmbiguous = ambiguous.contains(c.name.lowercased())
                let q = ident(t.name)
                var detail = c.fullType
                if c.isPrimaryKey { detail += " · PK" }
                out.append(CompletionItem(
                    label: isAmbiguous ? "\(t.name).\(c.name)" : c.name,
                    insertText: isAmbiguous ? "\(q).\(bare)" : bare,
                    kind: .column, detail: detail, score: 300 - min(c.ordinal, 100) / 10))
            }
        }
        return out
    }

    /// Resolved columns for a scope table, recording what's missing from the catalog.
    private mutating func columns(of t: ScopeTable) -> [ColumnDefinition]? {
        guard t.kind == .table, let ref = t.ref else { return nil }
        let schema = ref.schema.flatMap { catalog.schema(named: $0) ?? $0 } ?? currentSchema ?? ""
        let tableRef = TableRef(schema: schema, name: ref.name)
        if let cols = catalog.columns(of: tableRef) { return cols }
        if !catalog.hasLoadedTables(in: schema) || catalog.table(ref.name, in: schema) != nil {
            let canonical = catalog.canonical(tableRef) ?? tableRef
            missingColumns.append(canonical)
        }
        return nil
    }

    // MARK: Qualified (`a.` / `a.b.`)

    private mutating func qualified(
        _ q: [String], scopes: [ScopeTable], tablePosition: Bool
    ) -> ([CompletionItem], CompletionContext) {
        func tablesOfSchema(_ s: String) -> [CompletionItem] {
            if !catalog.hasLoadedTables(in: s) { missingTableLists.append(s) }
            return catalog.tables(in: s).map {
                CompletionItem(label: $0.ref.name, insertText: ident($0.ref.name),
                               kind: $0.kind == .table ? .table : .view,
                               detail: $0.kind == .table ? "table" : "view", score: 300)
            }
        }
        func columnsOf(_ t: ScopeTable) -> [CompletionItem] { columnItems(for: [t], ambiguous: []) }

        if q.count == 1 {
            let name = q[0]
            if tablePosition, let s = catalog.schema(named: name) {
                return (tablesOfSchema(s), .qualifiedTables)
            }
            // alias / table name in scope
            if let t = scopes.first(where: { $0.alias?.caseInsensitiveCompare(name) == .orderedSame })
                ?? scopes.first(where: { $0.ref?.name.caseInsensitiveCompare(name) == .orderedSame && $0.alias == nil })
                ?? scopes.first(where: { $0.ref?.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return (columnsOf(t), .qualifiedColumns)
            }
            if let s = catalog.schema(named: name) { return (tablesOfSchema(s), .qualifiedTables) }
            // A table of the current schema that isn't in a FROM clause (ALTER TABLE x.|, ON x.|)
            if let schema = currentSchema, catalog.table(name, in: schema) != nil {
                return (columnsOf(ScopeTable(kind: .table, alias: nil, ref: TableReference(schema: schema, name: name))), .qualifiedColumns)
            }
            return ([], .other)
        }
        // schema.table.
        let schemaName = catalog.schema(named: q[q.count - 2]) ?? q[q.count - 2]
        let t = ScopeTable(kind: .table, alias: nil, ref: TableReference(schema: schemaName, name: q[q.count - 1]))
        return (columnsOf(t), .qualifiedColumns)
    }

    // MARK: Expression context

    private mutating func expressionItems(
        _ S: [Tok], ci: Int, opens: [Int], scopes: [ScopeTable], prefix: String, followedByParen: Bool
    ) -> [CompletionItem] {
        var out: [CompletionItem] = []

        // Enum values after `col =` / `col IN (`.
        if let col = enumColumn(S, ci: ci, opens: opens, scopes: scopes), let values = col.enumValues {
            for v in values {
                out.append(CompletionItem(label: v, insertText: dialect.quoteString(v), kind: .enumValue,
                                          detail: "enum value", score: 1000))
            }
        }

        // Columns of the tables in scope, prefixed when a name occurs in several.
        let tables = scopes.filter { $0.kind == .table }
        var counts: [String: Int] = [:]
        var resolved: [(ScopeTable, [ColumnDefinition])] = []
        for t in tables {
            if let cols = columns(of: t) {
                resolved.append((t, cols))
                for n in Set(cols.map { $0.name.lowercased() }) { counts[n, default: 0] += 1 }
            }
        }
        let ambiguous = Set(counts.filter { $0.value > 1 }.keys)
        out += columnItems(for: resolved.map(\.0), ambiguous: ambiguous)

        // Aliases / table names, to start a qualified reference.
        for t in tables + scopes.filter({ $0.kind != .table }) {
            let n = t.name
            if !n.isEmpty {
                out.append(CompletionItem(label: n, insertText: ident(n), kind: .alias,
                                          detail: t.alias != nil ? (t.ref?.name ?? "alias") : "table", score: 150))
            }
        }

        // Functions and routines.
        let upperFirst = keywordCase(prefix)
        for f in SQLKeywords.sortedFunctions(for: dialect.family) {
            out.append(CompletionItem(label: f, insertText: upperFirst(f) + (followedByParen ? "" : "("),
                                      kind: .function, detail: "function", score: 40))
        }
        for r in routineItems(procedures: false) {
            var i = r
            i.kind = .function
            i.insertText += followedByParen ? "" : "("
            out.append(i)
        }

        // Keywords.
        var words = Self.expressionKeywords
        if ci > 0, S[ci - 1].isSym("(") { words.insert("SELECT", at: 0) }
        out += keywordItems(words, prefix: prefix, boost: 50)
        return out
    }

    private static let expressionKeywords = [
        "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS", "NULL", "TRUE", "FALSE", "CASE", "WHEN", "THEN", "ELSE",
        "END", "DISTINCT", "AS", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "ASC", "DESC", "EXISTS",
        "ALL", "ANY", "UNION", "ON", "JOIN", "LEFT JOIN", "INNER JOIN", "OVER", "PARTITION BY",
    ]

    private static func followKeywords(_ clause: String) -> [String] {
        let joins = ["WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "CROSS JOIN", "LEFT OUTER JOIN",
                     "GROUP BY", "ORDER BY", "LIMIT", "HAVING", "UNION", "AS"]
        switch clause {
        case "JOIN": return ["ON", "USING", "AS"] + joins.filter { $0 != "AS" }
        case "INTO": return ["VALUES", "SELECT", "SET", "DEFAULT VALUES"]
        case "TABLE": return ["ADD", "DROP", "MODIFY", "CHANGE", "RENAME", "ENGINE", "CONVERT TO", "ALTER COLUMN", "ADD COLUMN"]
        case "UPDATE": return ["SET", "AS", "INNER JOIN", "LEFT JOIN"]
        default: return joins
        }
    }

    // MARK: Context detection

    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "JOIN", "INTO", "UPDATE", "WHERE", "ON", "HAVING", "SET", "BY", "VALUES", "USING",
        "TABLE", "TRUNCATE", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "DESCRIBE", "CALL", "USE", "RETURNING",
        "STRAIGHT_JOIN", "WITH",
    ]

    private func detectContext(_ S: [Tok], ci: Int) -> Ctx {
        if ci == 0 { return .statementStart }
        var depth = 0
        var after: [Tok] = []
        var clause: String?
        var openParen: Int?
        var i = ci - 1
        while i >= 0 {
            let t = S[i]
            if t.isSym(")") {
                if depth == 0 { after.append(t) }
                depth += 1
            } else if t.isSym("(") {
                if depth == 0 { openParen = i; break }
                depth -= 1
            } else if depth == 0, let kw = t.keyword, Self.clauseKeywords.contains(kw) {
                let prev = i > 0 ? S[i - 1].keyword : nil
                if kw == "UPDATE", prev == "FOR" {
                    after.append(t)
                } else if kw == "UPDATE", prev == "KEY" {
                    clause = "SET"; break
                } else if kw == "WITH", prev != nil {
                    after.append(t)  // `... WITH ROLLUP`, `WITH CHECK OPTION`
                } else if kw == "TABLE", let p = prev, !["ALTER", "TRUNCATE", "DROP", "LOCK"].contains(p) {
                    after.append(t)
                } else {
                    clause = kw; break
                }
            } else if depth == 0 {
                after.append(t)
            }
            i -= 1
        }
        let forward = Array(after.reversed())

        if let p = openParen {
            let before = p > 0 ? S[p - 1] : nil
            if let b = before, b.keyword == "FROM" || b.keyword == "JOIN", p == ci - 1 { return .subqueryStart }
            // INSERT INTO t (|  /  INSERT INTO s.t (|
            if let b = before, b.isIdent {
                var j = p - 1
                var schema: String?
                if j >= 2, S[j - 1].isSym("."), S[j - 2].isIdent {
                    schema = S[j - 2].identifier
                    j -= 2
                }
                if j >= 1, S[j - 1].keyword == "INTO" {
                    return .insertColumns(TableReference(schema: schema, name: b.identifier))
                }
            }
            return .expression
        }

        guard let clause else {
            if forward.isEmpty { return .statementStart }
            if let first = S.first?.keyword, ["EXPLAIN", "ANALYZE"].contains(first), forward.count == 1 { return .statementStart }
            return .other
        }

        let last = forward.last
        switch clause {
        case "FROM", "UPDATE":
            if forward.isEmpty || last?.isSym(",") == true { return .tableName }
            if last?.keyword == "AS" { return .other }
            if forward.allSatisfy({ ["ONLY", "LATERAL"].contains($0.keyword ?? "") }) { return .tableName }
            return .afterTable(clause)
        case "JOIN", "STRAIGHT_JOIN":
            if forward.isEmpty || forward.allSatisfy({ ["ONLY", "LATERAL"].contains($0.keyword ?? "") }) { return .tableName }
            if last?.keyword == "AS" { return .other }
            return .afterTable("JOIN")
        case "INTO":
            if forward.isEmpty { return .tableName }
            if forward.contains(where: { $0.kind == .symbol && $0.text != "." }) { return .other }
            return .afterTable("INTO")
        case "TABLE", "TRUNCATE", "DESCRIBE":
            if forward.isEmpty || forward.allSatisfy({ ["IF", "NOT", "EXISTS", "ONLY", "TABLE"].contains($0.keyword ?? "") }) {
                return .tableName
            }
            return clause == "TABLE" ? .afterTable("TABLE") : .other
        case "USE":
            return forward.isEmpty ? .schemaName : .other
        case "CALL":
            return forward.isEmpty ? .routineName : .other
        case "UNION", "INTERSECT", "EXCEPT":
            if forward.isEmpty || forward.allSatisfy({ ["ALL", "DISTINCT"].contains($0.keyword ?? "") }) { return .subqueryStart }
            return .other
        case "VALUES", "LIMIT", "OFFSET":
            return .other
        default:
            return .expression
        }
    }

    // MARK: Enum values

    private mutating func enumColumn(_ S: [Tok], ci: Int, opens: [Int], scopes: [ScopeTable]) -> ColumnDefinition? {
        // `col =`, `col <>`, `col !=`, `col <=>`
        func operatorStart() -> Int? {
            guard ci >= 2 else { return nil }
            let last = S[ci - 1]
            guard last.kind == .symbol else { return nil }
            if last.text == "=" {
                if ci >= 3, S[ci - 2].kind == .symbol, ["<", ">", "!"].contains(S[ci - 2].text), S[ci - 2].end == last.start {
                    return ci - 2
                }
                return ci - 1
            }
            if last.text == ">" , S[ci - 2].isSym("<"), S[ci - 2].end == last.start { return ci - 2 }
            return nil
        }
        var colEnd: Int?  // index of the last token of the column expression
        if let op = operatorStart() {
            colEnd = op - 1
        } else if let p = opens.last, p >= 1, S[p - 1].keyword == "IN" {
            // inside `IN (` list, at an item boundary
            if S[ci - 1].isSym("(") || S[ci - 1].isSym(",") {
                var j = p - 2
                if j >= 0, S[j].keyword == "NOT" { j -= 1 }
                colEnd = j
            }
        }
        guard let e = colEnd, e >= 0, S[e].isIdent else { return nil }
        let name = S[e].identifier
        var qualifier: String?
        if e >= 2, S[e - 1].isSym("."), S[e - 2].isIdent { qualifier = S[e - 2].identifier }

        for t in scopes where t.kind == .table {
            if let q = qualifier {
                let matches = t.alias?.caseInsensitiveCompare(q) == .orderedSame
                    || (t.alias == nil && t.ref?.name.caseInsensitiveCompare(q) == .orderedSame)
                guard matches else { continue }
            }
            if let cols = columns(of: t),
               let c = cols.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return c
            }
        }
        return nil
    }

    // MARK: Scope (tables in FROM / JOIN / UPDATE / INTO)

    /// Tables visible at the insertion point: the innermost query first, then enclosing ones.
    private func scopeTables(_ S: [Tok], ci: Int, opens: [Int]) -> [ScopeTable] {
        var ranges: [Range<Int>] = []
        for p in opens.reversed() where p + 1 < S.count {
            if let kw = S[p + 1].keyword, ["SELECT", "WITH", "VALUES", "TABLE"].contains(kw) {
                ranges.append((p + 1)..<(matchingClose(S, open: p) ?? S.count))
            }
        }
        ranges.append(0..<S.count)
        var out: [ScopeTable] = []
        for r in ranges { out += collectTables(S, in: r) }
        return out
    }

    private func matchingClose(_ S: [Tok], open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < S.count {
            if S[i].isSym("(") { depth += 1 }
            else if S[i].isSym(")") { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    private static let aliasStoppers: Set<String> = [
        "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "ON", "USING", "GROUP", "ORDER",
        "LIMIT", "HAVING", "UNION", "INTERSECT", "EXCEPT", "SET", "VALUES", "WINDOW", "FOR", "LOCK", "STRAIGHT_JOIN",
        "OUTER", "SELECT", "RETURNING", "PARTITION", "USE", "IGNORE", "FORCE", "OFFSET", "FETCH", "TABLESAMPLE",
        "LATERAL", "AS", "DEFAULT", "WITH", "INTO", "FROM", "CONFLICT", "ADD", "DROP", "MODIFY", "CHANGE", "RENAME",
    ]

    private func collectTables(_ S: [Tok], in range: Range<Int>) -> [ScopeTable] {
        var out: [ScopeTable] = []
        var i = range.lowerBound
        var depth = 0

        func parseRef(_ j: Int) -> (TableReference, Int)? {
            var j = j
            while j < range.upperBound, ["ONLY", "LATERAL"].contains(S[j].keyword ?? "") { j += 1 }
            guard j < range.upperBound, S[j].isIdent else { return nil }
            if S[j].kind == .word, ["OUTFILE", "DUMPFILE", "SELECT", "VALUES", "TEMPORARY", "TEMP", "IF"].contains(S[j].text.uppercased()) { return nil }
            if j + 2 < range.upperBound, S[j + 1].isSym("."), S[j + 2].isIdent {
                return (TableReference(schema: S[j].identifier, name: S[j + 2].identifier), j + 3)
            }
            return (TableReference(name: S[j].identifier), j + 1)
        }
        func parseAlias(_ j: Int) -> (String?, Int) {
            var j = j
            if j < range.upperBound, S[j].isKeyword("AS") { j += 1 }
            else if j < range.upperBound, S[j].kind == .word, Self.aliasStoppers.contains(S[j].text.uppercased()) { return (nil, j) }
            if j < range.upperBound, S[j].isIdent {
                if S[j].kind == .word, Self.aliasStoppers.contains(S[j].text.uppercased()) { return (nil, j) }
                return (S[j].identifier, j + 1)
            }
            return (nil, j)
        }
        func parseSource(_ j: Int) -> Int {
            // derived table: ( ... ) [AS] alias
            if j < range.upperBound, S[j].isSym("("), let close = matchingClose(S, open: j) {
                let (alias, next) = parseAlias(close + 1)
                if let alias { out.append(ScopeTable(kind: .derived, alias: alias, ref: nil)) }
                return next
            }
            guard let (ref, afterRef) = parseRef(j) else { return j }
            let (alias, next) = parseAlias(afterRef)
            out.append(ScopeTable(kind: .table, alias: alias, ref: ref))
            return next
        }

        // CTE names: WITH [RECURSIVE] name [(cols)] AS ( ... ) [, ...]
        if i < range.upperBound, S[i].isKeyword("WITH") {
            var j = i + 1
            if j < range.upperBound, S[j].isKeyword("RECURSIVE") { j += 1 }
            while j < range.upperBound, S[j].isIdent {
                let name = S[j].identifier
                j += 1
                if j < range.upperBound, S[j].isSym("("), let c = matchingClose(S, open: j) { j = c + 1 }
                guard j < range.upperBound, S[j].isKeyword("AS") else { break }
                j += 1
                if j < range.upperBound, S[j].isKeyword("NOT") { j += 1 }
                if j < range.upperBound, S[j].isKeyword("MATERIALIZED") { j += 1 }
                guard j < range.upperBound, S[j].isSym("("), let c = matchingClose(S, open: j) else { break }
                out.append(ScopeTable(kind: .cte, alias: name, ref: nil))
                j = c + 1
                if j < range.upperBound, S[j].isSym(",") { j += 1 } else { break }
            }
        }

        while i < range.upperBound {
            let t = S[i]
            if t.isSym("(") { depth += 1; i += 1; continue }
            if t.isSym(")") { depth = max(0, depth - 1); i += 1; continue }
            guard depth == 0, let kw = t.keyword else { i += 1; continue }
            let prev = i > range.lowerBound ? S[i - 1].keyword : nil
            switch kw {
            case "FROM", "UPDATE":
                if kw == "UPDATE", prev == "FOR" || prev == "KEY" { i += 1; continue }
                var j = parseSource(i + 1)
                while j < range.upperBound, S[j].isSym(",") { j = parseSource(j + 1) }
                i = max(j, i + 1)
            case "JOIN", "STRAIGHT_JOIN":
                i = max(parseSource(i + 1), i + 1)
            case "INTO":
                if let (ref, next) = parseRef(i + 1) {
                    out.append(ScopeTable(kind: .table, alias: nil, ref: ref))
                    i = next
                } else { i += 1 }
            case "TABLE":
                if let p = prev, ["ALTER", "TRUNCATE", "DROP"].contains(p) {
                    var j = i + 1
                    while j < range.upperBound, ["IF", "EXISTS", "ONLY"].contains(S[j].keyword ?? "") { j += 1 }
                    if let (ref, next) = parseRef(j) {
                        out.append(ScopeTable(kind: .table, alias: nil, ref: ref))
                        i = next
                        continue
                    }
                }
                i += 1
            case "DESCRIBE", "TRUNCATE":
                if i == range.lowerBound, let (ref, next) = parseRef(i + 1), S[i + 1].keyword != "TABLE" {
                    out.append(ScopeTable(kind: .table, alias: nil, ref: ref))
                    i = next
                } else { i += 1 }
            default:
                i += 1
            }
        }
        return out
    }
}
