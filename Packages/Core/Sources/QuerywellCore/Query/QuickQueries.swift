import Foundation

/// The common queries offered by the query tab's "Quick queries" menu.
public enum QuickQueryKind: String, CaseIterable, Sendable, Identifiable {
    case selectAll, selectColumns, count, newest, findByValue, duplicates
    case insert, update, delete
    case structure
    case tableSizes, processes

    public var id: String { rawValue }

    /// Menu title.
    public var title: String {
        switch self {
        case .selectAll: "SELECT * … LIMIT 100"
        case .selectColumns: "SELECT with all columns"
        case .count: "Count rows"
        case .newest: "Newest rows (by primary key)"
        case .findByValue: "Find by column value"
        case .duplicates: "Find duplicates in a column"
        case .insert: "INSERT template"
        case .update: "UPDATE by primary key"
        case .delete: "DELETE by primary key"
        case .structure: "Show structure"
        case .tableSizes: "Table sizes"
        case .processes: "Running processes"
        }
    }

    /// Needs a table; the others run against the database / server.
    public var needsTable: Bool {
        switch self {
        case .tableSizes, .processes: false
        default: true
        }
    }

    /// Kinds that read data without a table, in menu order.
    public static var databaseLevel: [QuickQueryKind] { [.tableSizes, .processes] }
    /// Kinds about one table, in menu order.
    public static var tableLevel: [QuickQueryKind] { allCases.filter(\.needsTable) }
}

/// What a quick query is generated for.
public struct QuickQueryContext: Sendable {
    public var dialect: SQLDialect
    /// The schema / database the session is in: tables of it are left unqualified on MySQL.
    public var currentSchema: String?
    public var table: TableRef?
    /// Columns and keys of `table`; templates degrade to placeholders when nil.
    public var structure: TableStructure?
    /// The column for "find by value" / "duplicates"; defaults to the first non-key column.
    public var column: String?

    public init(dialect: SQLDialect, currentSchema: String?, table: TableRef? = nil,
                structure: TableStructure? = nil, column: String? = nil) {
        self.dialect = dialect
        self.currentSchema = currentSchema
        self.table = table
        self.structure = structure
        self.column = column
    }
}

/// Generates the SQL behind the Quick queries menu. Pure: identifiers go through ``SQLDialect``,
/// names used as values are quoted as string literals, and nothing is run here: the result is inserted
/// into the editor and executes through the usual guarded path.
public enum QuickQueries {
    /// A snippet template (`${1:?}` stops, escaped literals; see ``SnippetTemplate``) for `kind`.
    /// Nil when the kind needs a table and the context has none (or a schema is missing for table sizes).
    public static func template(_ kind: QuickQueryKind, _ ctx: QuickQueryContext) -> String? {
        let d = ctx.dialect
        switch kind {
        case .tableSizes:
            guard let schema = ctx.currentSchema ?? ctx.table?.schema else { return nil }
            return tableSizes(d, schema: schema)
        case .processes:
            switch d.family {
            case .mysql: return "SHOW FULL PROCESSLIST;"
            case .postgres:
                return """
                    SELECT pid, usename, datname, state, wait_event_type, now() - query_start AS running_for, query
                    FROM pg_stat_activity
                    WHERE pid <> pg_backend_pid()
                    ORDER BY query_start;
                    """
            }
        default:
            guard let table = ctx.table else { return nil }
            return tableTemplate(kind, ctx, table)
        }
    }

    /// The SQL as it reads once inserted (stops replaced by their defaults).
    public static func plainText(_ template: String) -> String { SnippetTemplate.parse(template).text }

    /// `template` to insert at `caret` (UTF-16 offset), set apart from SQL before and after it by a blank line
    /// so statements never run together. Nothing is added in an empty (or whitespace-only) neighbourhood.
    public static func separated(_ template: String, editorText: String, caret: Int, selectionLength: Int = 0) -> String {
        let ns = editorText as NSString
        let start = min(max(0, caret), ns.length)
        let end = min(ns.length, start + max(0, selectionLength))
        let before = ns.substring(to: start)
        let after = ns.substring(from: end)
        var out = template
        if !before.allSatisfy(\.isWhitespace) {
            out = (before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n") + out
        }
        if !after.allSatisfy(\.isWhitespace) {
            out += after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        }
        return out
    }

    // MARK: Table templates

    private static func tableTemplate(_ kind: QuickQueryKind, _ ctx: QuickQueryContext, _ table: TableRef) -> String {
        let d = ctx.dialect
        let name = tableName(table, ctx)
        let cols = ctx.structure?.columns ?? []
        let keys = ctx.structure?.primaryKey ?? []
        var t = TemplateBuilder()

        switch kind {
        case .selectAll:
            t.text("SELECT * FROM \(name) LIMIT 100;")
        case .selectColumns:
            if cols.isEmpty {
                t.text("SELECT "); t.stop("*"); t.text(" FROM \(name) LIMIT 100;")
            } else {
                t.text("SELECT \(cols.map { d.quoteIdentifier($0.name) }.joined(separator: ", "))\nFROM \(name)\nLIMIT 100;")
            }
        case .count:
            t.text("SELECT COUNT(*) FROM \(name);")
        case .newest:
            let order = newestOrder(ctx.structure)
            if order.isEmpty {
                t.text("SELECT * FROM \(name)\nORDER BY "); t.stop("column"); t.text(" DESC\nLIMIT 100;")
            } else {
                t.text("SELECT * FROM \(name)\nORDER BY \(order.map { d.quoteIdentifier($0) + " DESC" }.joined(separator: ", "))\nLIMIT 100;")
            }
        case .findByValue:
            t.text("SELECT * FROM \(name)\nWHERE ")
            t.stop(columnForValue(ctx).map(d.quoteIdentifier) ?? "column")
            t.text(" = "); t.stop("?"); t.text("\nLIMIT 100;")
        case .duplicates:
            t.text("SELECT ")
            t.stop(columnForValue(ctx).map(d.quoteIdentifier) ?? "column")
            t.text(", COUNT(*) AS duplicates\nFROM \(name)\nGROUP BY ")
            t.mirror(1)
            t.text("\nHAVING COUNT(*) > 1\nORDER BY duplicates DESC;")
        case .insert:
            if cols.isEmpty {
                t.text("INSERT INTO \(name) ("); t.stop("columns"); t.text(")\nVALUES ("); t.stop("values"); t.text(");")
            } else {
                t.text("INSERT INTO \(name)\n  (\(cols.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")))\nVALUES\n  (")
                for (i, c) in cols.enumerated() {
                    if i > 0 { t.text(", ") }
                    if c.isAutoIncrement { t.text("DEFAULT") } else { t.stop("?") }
                }
                t.text(");")
            }
        case .update:
            let settable = cols.filter { !keys.contains($0.name) }
            let assigned = settable.isEmpty ? cols : settable
            t.text("UPDATE \(name)\nSET ")
            if assigned.isEmpty { t.stop("column"); t.text(" = "); t.stop("?") }
            for (i, c) in assigned.enumerated() {
                if i > 0 { t.text(",\n    ") }
                t.text("\(d.quoteIdentifier(c.name)) = "); t.stop("?")
            }
            t.text("\n"); whereClause(&t, keys, d); t.text(";")
        case .delete:
            t.text("DELETE FROM \(name)\n"); whereClause(&t, keys, d); t.text(";")
        case .structure:
            switch d.family {
            case .mysql:
                t.text("SHOW CREATE TABLE \(name);\nDESCRIBE \(name);")
            case .postgres:
                t.text("""
                    SELECT column_name, data_type, character_maximum_length, is_nullable, column_default
                    FROM information_schema.columns
                    WHERE table_schema = \(d.quoteString(table.schema)) AND table_name = \(d.quoteString(table.name))
                    ORDER BY ordinal_position;
                    """)
            }
        case .tableSizes, .processes:
            break
        }
        return t.result
    }

    private static func whereClause(_ t: inout TemplateBuilder, _ keys: [String], _ d: SQLDialect) {
        t.text("WHERE ")
        if keys.isEmpty { t.stop("condition"); return }
        for (i, k) in keys.enumerated() {
            if i > 0 { t.text("\n  AND ") }
            t.text("\(d.quoteIdentifier(k)) = "); t.stop("?")
        }
    }

    private static func tableSizes(_ d: SQLDialect, schema: String) -> String {
        switch d.family {
        case .mysql:
            return """
                SELECT table_name, table_rows AS estimated_rows,
                       ROUND(data_length / 1024 / 1024, 2) AS data_mb,
                       ROUND(index_length / 1024 / 1024, 2) AS index_mb,
                       ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb
                FROM information_schema.tables
                WHERE table_schema = \(d.quoteString(schema))
                ORDER BY (data_length + index_length) DESC;
                """
        case .postgres:
            return """
                SELECT c.relname AS table_name, c.reltuples::bigint AS estimated_rows,
                       pg_size_pretty(pg_table_size(c.oid)) AS table_size,
                       pg_size_pretty(pg_indexes_size(c.oid)) AS index_size,
                       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(d.quoteString(schema)) AND c.relkind IN ('r', 'p', 'm')
                ORDER BY pg_total_relation_size(c.oid) DESC;
                """
        }
    }

    // MARK: Helpers

    /// `db`.`table` unless MySQL is already in that database. Postgres always qualifies (search_path is not assumed).
    private static func tableName(_ table: TableRef, _ ctx: QuickQueryContext) -> String {
        let d = ctx.dialect
        if d.family == .mysql, let current = ctx.currentSchema, current == table.schema { return d.quoteIdentifier(table.name) }
        return d.qualified(table)
    }

    /// Primary key, else the first date/time column, else the first column.
    private static func newestOrder(_ s: TableStructure?) -> [String] {
        guard let s else { return [] }
        if !s.primaryKey.isEmpty { return s.primaryKey }
        if let c = s.columns.first(where: { $0.dataType.contains("timestamp") || $0.dataType.contains("date") }) { return [c.name] }
        return s.columns.first.map { [$0.name] } ?? []
    }

    private static func columnForValue(_ ctx: QuickQueryContext) -> String? {
        if let c = ctx.column { return c }
        guard let s = ctx.structure else { return nil }
        let keys = Set(s.primaryKey)
        return (s.columns.first { !keys.contains($0.name) } ?? s.columns.first)?.name
    }

    /// Builds a snippet template: literals are escaped, stops numbered in order.
    private struct TemplateBuilder {
        var result = ""
        var next = 1

        static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "}", with: "\\}")
        }

        mutating func text(_ s: String) { result += Self.escape(s) }

        mutating func stop(_ placeholder: String) {
            result += placeholder.isEmpty ? "${\(next)}" : "${\(next):\(Self.escape(placeholder))}"
            next += 1
        }

        /// Another occurrence of stop `index` (edited together with the first).
        mutating func mirror(_ index: Int) { result += "$\(index)" }
    }
}

/// Finds the table an editor is "about".
public enum QuickQueryTableFinder {
    /// The known table named at the caret, else the nearest one named before it, else the nearest after it.
    /// `caret` is a UTF-16 offset. Names compare case-insensitively; strings and comments are ignored.
    public static func table(in text: String, caret: Int, tables: [TableInfo], dialect: SQLDialect) -> TableRef? {
        guard !tables.isEmpty, !text.isEmpty else { return nil }
        var byName: [String: TableRef] = [:]
        for t in tables { byName[t.ref.name.lowercased()] = byName[t.ref.name.lowercased()] ?? t.ref }

        let utf16 = text.utf16
        let clamped = min(max(0, caret), utf16.count)
        let index = utf16.index(utf16.startIndex, offsetBy: clamped)
        let caretByte = text.utf8.distance(from: text.utf8.startIndex, to: index.samePosition(in: text.utf8) ?? text.utf8.startIndex)

        var before: TableRef?
        var after: TableRef?
        for token in SQLLexer(dialect).tokenize(text) {
            guard let value = token.identifierValue, let ref = byName[value.lowercased()] else { continue }
            if token.range.lowerBound <= caretByte && caretByte <= token.range.upperBound { return ref }
            if token.range.upperBound < caretByte { before = ref } else if after == nil { after = ref }
        }
        return before ?? after
    }
}

/// One column of a table as the schema sidebar shows it.
public struct SchemaOutlineColumn: Sendable, Equatable, Identifiable {
    public var name: String
    public var type: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    /// Alone in a unique index.
    public var isUnique: Bool
    /// Part of any secondary index.
    public var isIndexed: Bool
    /// `table.column` this column references.
    public var foreignKey: String?
    public var id: String { name }

    /// For VoiceOver and tooltips: "id, bigint, primary key, not null".
    public var summary: String {
        var parts = [name, type]
        if isPrimaryKey { parts.append("primary key") } else if isUnique { parts.append("unique") } else if isIndexed { parts.append("indexed") }
        if let foreignKey { parts.append("references \(foreignKey)") }
        parts.append(isNullable ? "nullable" : "not null")
        return parts.joined(separator: ", ")
    }
}

public enum SchemaOutline {
    public static func columns(of structure: TableStructure) -> [SchemaOutlineColumn] {
        let secondary = structure.indexes.filter { !$0.isPrimary }
        let primary = Set(structure.primaryKey)
        return structure.columns.map { c in
            let fk = structure.foreignKeys.first { $0.columns.contains(c.name) }.map { key -> String in
                let i = key.columns.firstIndex(of: c.name) ?? 0
                let target = key.referencedColumns.indices.contains(i) ? ".\(key.referencedColumns[i])" : ""
                return key.referenced.name + target
            }
            return SchemaOutlineColumn(
                name: c.name, type: c.fullType, isNullable: c.isNullable,
                isPrimaryKey: c.isPrimaryKey || primary.contains(c.name),
                isUnique: secondary.contains { $0.isUnique && $0.columns == [c.name] },
                isIndexed: secondary.contains { $0.columns.contains(c.name) }, foreignKey: fk)
        }
    }

    /// Tables matching `query` (fuzzy, best first); everything in the original order when it is empty.
    public static func filter(_ tables: [TableInfo], query: String) -> [TableInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tables }
        return FuzzyMatcher.rank(tables, query: q, key: { $0.ref.name }, limit: tables.count).map(\.0)
    }
}
