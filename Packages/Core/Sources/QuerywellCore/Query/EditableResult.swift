import Foundation

/// A query result the grid may edit inline, mapped back to its base table.
public struct EditableResultInfo: Sendable, Hashable {
    public var table: TableRef
    /// Indexes into the result's columns of the primary-key columns, in primary-key order.
    public var pkColumnIndexes: [Int]
    /// For each result column (by index) the table column it shows.
    public var columnMap: [String]
    /// The table's column definitions (for ``EditSession``).
    public var tableColumns: [ColumnDefinition]
    public var primaryKey: [String]

    /// The edit session for this result: edits are keyed by the PK values taken from the result row.
    public func makeEditSession() throws -> EditSession {
        try EditSession(table: table, primaryKey: primaryKey, columns: tableColumns)
    }

    /// The row key for a result row, nil if a PK cell is missing or NULL.
    public func rowKey(for row: [DatabaseValue]) -> RowKey? {
        var values: [DatabaseValue] = []
        for i in pkColumnIndexes {
            guard i < row.count, !row[i].isNull else { return nil }
            values.append(row[i])
        }
        return RowKey(values)
    }

    /// Table column behind result column `index`.
    public func columnName(at index: Int) -> String? {
        columnMap.indices.contains(index) ? columnMap[index] : nil
    }
}

public enum EditableResultVerdict: Sendable, Hashable {
    case editable(EditableResultInfo)
    /// User-facing reason, e.g. "Joins two tables", "Primary key `ID` not selected".
    case notEditable(String)

    public var info: EditableResultInfo? { if case .editable(let i) = self { i } else { nil } }
    public var reason: String? { if case .notEditable(let r) = self { r } else { nil } }
}

/// Decides whether a SELECT's result can be edited in place.
///
/// Editable means: a plain `SELECT` from exactly one base table (no JOIN / comma join, GROUP BY, HAVING,
/// DISTINCT, aggregates, UNION, CTE, subquery in FROM or in the select list), every select item is a
/// bare column of that table (or `*`, or `alias.*`), possibly renamed with `AS`, and all primary-key
/// columns are among them. Two steps because the second needs schema: ``analyze(sql:dialect:)`` is
/// purely syntactic and names the table; ``resolve(shape:table:resultColumns:structure:)`` checks the
/// result columns against the table's structure.
public enum EditableResultAnalyzer {
    /// What the SQL's text says about the query.
    public struct Shape: Sendable, Hashable {
        public var table: TableReference
        /// Alias given to the table in FROM (or nil).
        public var tableAlias: String?
        /// The select list as written.
        public var items: [SelectItem]
    }

    public enum SelectItem: Sendable, Hashable {
        /// `*` or `alias.*`
        case star
        /// A bare column; `output` is the name it appears under in the result.
        case column(name: String, output: String)
    }

    public enum SyntaxResult: Sendable, Hashable {
        case shape(Shape)
        case notEditable(String)
    }

    private static let aggregates: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG", "JSON_ARRAYAGG", "JSON_OBJECTAGG",
        "BIT_AND", "BIT_OR", "BIT_XOR", "STD", "STDDEV", "VARIANCE", "BOOL_AND", "BOOL_OR", "JSON_AGG", "JSONB_AGG",
    ]
    private static let tailKeywords: Set<String> = [
        "WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR", "LOCK", "WINDOW", "PROCEDURE", "INTO",
    ]

    // MARK: Step 1: syntax

    public static func analyze(sql: String, dialect: SQLDialect) -> SyntaxResult {
        let lexer = SQLLexer(dialect)
        let toks = StatementClassifier.significantTokens(lexer.tokenize(sql), lexer: lexer)
        guard let first = toks.first, let verb = first.keyword else { return .notEditable("Not a SELECT statement") }
        switch verb {
        case "SELECT": break
        case "WITH": return .notEditable("Uses a WITH (CTE) clause")
        case "TABLE", "VALUES", "SHOW", "DESCRIBE", "DESC", "EXPLAIN": return .notEditable("Not a plain SELECT")
        default: return .notEditable("Not a SELECT statement")
        }

        // Top-level scan for disqualifying constructs and the clause boundaries.
        var depth = 0
        var fromIndex: Int?
        var selectEnd = toks.count
        var fromEnd = toks.count
        var i = 1
        while i < toks.count {
            let t = toks[i]
            if t.isSymbol("(") { depth += 1 }
            else if t.isSymbol(")") { depth -= 1 }
            else if depth == 0, let kw = t.keyword {
                switch kw {
                case "FROM" where fromIndex == nil:
                    fromIndex = i
                    selectEnd = i
                case "JOIN", "STRAIGHT_JOIN", "NATURAL", "CROSS", "INNER", "OUTER":
                    return .notEditable("Joins two tables")
                case "UNION", "INTERSECT", "EXCEPT", "MINUS":
                    return .notEditable("Combines queries with \(kw)")
                case "GROUP": return .notEditable("Uses GROUP BY")
                case "HAVING": return .notEditable("Uses HAVING")
                case "DISTINCT" where i == 1 || toks[i - 1].keyword == "SELECT" || toks[i - 1].keyword == "ALL":
                    return .notEditable("Uses DISTINCT")
                case "DISTINCTROW" where i == 1: return .notEditable("Uses DISTINCT")
                case "INTO" where fromIndex == nil: return .notEditable("Uses SELECT … INTO")
                default:
                    if fromIndex != nil, fromEnd == toks.count, tailKeywords.contains(kw) { fromEnd = i }
                }
            }
            i += 1
        }
        guard let fromIdx = fromIndex else { return .notEditable("No table in the query") }

        // FROM ref [AS] [alias]
        var j = fromIdx + 1
        guard j < fromEnd else { return .notEditable("No table in the query") }
        if toks[j].isSymbol("(") { return .notEditable("Selects from a subquery") }
        guard toks[j].kind == .word || toks[j].kind == .quotedIdentifier else {
            return .notEditable("Not a plain table reference")
        }
        var table = TableReference(name: toks[j].identifierValue ?? toks[j].text)
        j += 1
        if j + 1 < fromEnd, toks[j].isSymbol("."), toks[j + 1].kind == .word || toks[j + 1].kind == .quotedIdentifier {
            table = TableReference(schema: table.name, name: toks[j + 1].identifierValue ?? toks[j + 1].text)
            j += 2
        }
        var alias: String?
        if j < fromEnd {
            if toks[j].isSymbol(",") { return .notEditable("Joins two tables") }
            if toks[j].keyword == "AS" { j += 1 }
            if j < fromEnd, toks[j].kind == .word || toks[j].kind == .quotedIdentifier,
               !["USE", "FORCE", "IGNORE", "PARTITION", "TABLESAMPLE"].contains(toks[j].keyword ?? "") {
                alias = toks[j].identifierValue ?? toks[j].text
                j += 1
            }
            if j < fromEnd {
                if toks[j].isSymbol(",") { return .notEditable("Joins two tables") }
                if toks[j].isSymbol("(") { return .notEditable("Not a plain table reference") }
                if let kw = toks[j].keyword, ["USE", "FORCE", "IGNORE", "PARTITION", "TABLESAMPLE"].contains(kw) {
                    // index hints / partition selection do not change which rows are shown as table rows
                } else {
                    return .notEditable("Not a plain table reference")
                }
            }
        }

        // Select list: split on top-level commas between SELECT and FROM.
        var items: [SelectItem] = []
        var itemTokens: [SQLToken] = []
        var d = 0
        var start = 1
        // Skip leading ALL / modifiers.
        while start < selectEnd, let kw = toks[start].keyword, ["ALL", "HIGH_PRIORITY", "SQL_NO_CACHE", "SQL_CACHE", "SQL_CALC_FOUND_ROWS", "SQL_SMALL_RESULT", "SQL_BIG_RESULT", "SQL_BUFFER_RESULT"].contains(kw) {
            start += 1
        }
        var position = 0
        func flush() -> String? {
            position += 1
            if let reason = classify(itemTokens, position: position, tableName: table.name, alias: alias, into: &items) { return reason }
            itemTokens = []
            return nil
        }
        for k in start..<selectEnd {
            let t = toks[k]
            if t.isSymbol("(") { d += 1 } else if t.isSymbol(")") { d -= 1 }
            if d == 0, t.isSymbol(",") {
                if let r = flush() { return .notEditable(r) }
            } else {
                itemTokens.append(t)
            }
        }
        if let r = flush() { return .notEditable(r) }
        return .shape(Shape(table: table, tableAlias: alias, items: items))
    }

    /// Classifies one select-list item; returns a reason when it is not a bare column.
    private static func classify(
        _ t: [SQLToken], position: Int, tableName: String, alias: String?, into items: inout [SelectItem]
    ) -> String? {
        func isIdent(_ k: SQLToken) -> Bool { k.kind == .word || k.kind == .quotedIdentifier }
        func name(_ k: SQLToken) -> String { k.identifierValue ?? k.text }
        func qualifierOK(_ q: String) -> Bool {
            let target = alias ?? tableName
            return q.caseInsensitiveCompare(target) == .orderedSame || q.caseInsensitiveCompare(tableName) == .orderedSame
        }
        guard !t.isEmpty else { return "Empty select item" }

        if t.contains(where: { $0.isSymbol("(") }) {
            for (n, tok) in t.enumerated() where tok.isSymbol("(") && n > 0 && t[n - 1].kind == .word
                && aggregates.contains(t[n - 1].text.uppercased()) {
                return "Uses aggregate functions"
            }
            if t.contains(where: { $0.keyword == "SELECT" }) { return "Column \(position) is a subquery" }
            return "Column \(position) is an expression"
        }
        // star forms
        if t.count == 1, t[0].isSymbol("*") { items.append(.star); return nil }
        if t.count == 3, isIdent(t[0]), t[1].isSymbol("."), t[2].isSymbol("*") {
            return qualifierOK(name(t[0])) ? { items.append(.star); return nil }() : "Selects from another table"
        }
        // [q.]col [AS] [alias]
        var k = 0
        var q: String?
        if t.count >= 3, isIdent(t[0]), t[1].isSymbol("."), isIdent(t[2]) {
            q = name(t[0])
            k = 2
        } else if isIdent(t[0]) {
            k = 0
        } else {
            return "Column \(position) is an expression"
        }
        if let q, !qualifierOK(q) { return "Selects from another table" }
        let col = name(t[k])
        var rest = Array(t[(k + 1)...])
        if rest.first?.keyword == "AS" { rest.removeFirst() }
        var output = col
        if rest.count == 1, isIdent(rest[0]) || rest[0].kind == .string {
            output = name(rest[0])
            if rest[0].kind == .string { output = String(rest[0].text.dropFirst().dropLast()) }
        } else if !rest.isEmpty {
            return "Column \(position) is an expression"
        }
        if q == nil, col.uppercased() == "NULL" || col.uppercased() == "TRUE" || col.uppercased() == "FALSE" {
            return "Column \(position) is a constant"
        }
        items.append(.column(name: col, output: output))
        return nil
    }

    // MARK: Step 2: against the schema

    /// - Parameters:
    ///   - resultColumns: the executed result's columns (their names must line up with the select list).
    ///   - structure: structure of ``Shape/table``, resolved against the session's current schema by the caller.
    public static func resolve(
        shape: Shape, resultColumns: [ColumnInfo], structure: TableStructure
    ) -> EditableResultVerdict {
        let info = structure.info
        let table = info.ref
        if info.kind != .table { return .notEditable("`\(table.name)` is a \(info.kind == .view ? "view" : "materialized view")") }

        // Expand the select list to table column names, in result order.
        var mapped: [String] = []
        for item in shape.items {
            switch item {
            case .star:
                mapped += structure.columns.map(\.name)
            case .column(let name, _):
                guard let def = structure.columns.first(where: { $0.name == name })
                    ?? structure.columns.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    return .notEditable("Column `\(name)` isn't in table `\(table.name)`")
                }
                mapped.append(def.name)
            }
        }
        guard mapped.count == resultColumns.count else { return .notEditable("Columns don't match the query") }

        // Result names must be what the select list promises (guards against unusual server behaviour).
        var outputs: [String] = []
        for item in shape.items {
            switch item {
            case .star: outputs += structure.columns.map(\.name)
            case .column(_, let out): outputs.append(out)
            }
        }
        for (i, c) in resultColumns.enumerated() {
            if c.name.caseInsensitiveCompare(outputs[i]) != .orderedSame { return .notEditable("Columns don't match the query") }
            if let origin = c.table, !origin.isEmpty, origin.caseInsensitiveCompare(shape.tableAlias ?? table.name) != .orderedSame,
               origin.caseInsensitiveCompare(table.name) != .orderedSame {
                return .notEditable("Column `\(c.name)` comes from another table")
            }
        }

        let pk = structure.primaryKey
        if pk.isEmpty { return .notEditable("Table `\(table.name)` has no primary key") }
        var pkIndexes: [Int] = []
        var missing: [String] = []
        for key in pk {
            if let idx = mapped.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { pkIndexes.append(idx) }
            else { missing.append(key) }
        }
        if !missing.isEmpty {
            let list = missing.map { "`\($0)`" }.joined(separator: ", ")
            return .notEditable(missing.count == 1 ? "Primary key \(list) not selected" : "Primary key columns \(list) not selected")
        }
        // A column selected twice (`id, id AS other`) makes edits ambiguous.
        if Set(mapped.map { $0.lowercased() }).count != mapped.count {
            return .notEditable("A column is selected more than once")
        }
        return .editable(EditableResultInfo(table: table, pkColumnIndexes: pkIndexes, columnMap: mapped,
                                            tableColumns: structure.columns, primaryKey: pk))
    }

    // MARK: Both steps

    /// Parses `sql`, loads the table's structure through `inspector` and checks the result.
    public static func analyze(
        sql: String, dialect: SQLDialect, currentSchema: String, resultColumns: [ColumnInfo], inspector: any SchemaInspector
    ) async -> EditableResultVerdict {
        switch analyze(sql: sql, dialect: dialect) {
        case .notEditable(let reason):
            return .notEditable(reason)
        case .shape(let shape):
            let ref = shape.table.resolved(defaultSchema: currentSchema)
            do {
                let structure = try await inspector.structure(of: ref)
                return resolve(shape: shape, resultColumns: resultColumns, structure: structure)
            } catch {
                return .notEditable("Couldn't read the structure of `\(ref.name)`")
            }
        }
    }
}
