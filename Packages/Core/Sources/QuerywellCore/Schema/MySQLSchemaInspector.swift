import Foundation

/// `SchemaInspector` for MySQL and MariaDB, built on `information_schema` plus `SHOW CREATE`.
///
/// Every name that reaches SQL is a literal produced by ``SQLDialect``; nothing is interpolated raw.
///
/// Engine differences handled here:
/// - `COLUMN_DEFAULT`: MySQL 8 reports string defaults *unquoted* (and flags expression defaults with
///   `EXTRA = DEFAULT_GENERATED`); MariaDB reports ready-to-use SQL (`'publish'`, `current_timestamp()`)
///   and the text `NULL` for nullable columns without a default. Both are normalised to SQL text / nil.
/// - `COLUMN_TYPE`: MySQL 8.4 has no display widths (`bigint unsigned`), MariaDB does (`bigint(20) unsigned`).
/// - `STATISTICS.EXPRESSION` (functional indexes) only exists on MySQL 8.
public struct MySQLSchemaInspector: SchemaInspector {
    private let session: any DatabaseSession
    private let dialect = SQLDialect(.mysql)

    public init(session: any DatabaseSession) {
        self.session = session
    }

    private func lit(_ s: String) -> String { dialect.quoteString(s) }

    // MARK: Lists

    public func listSchemas() async throws -> [String] {
        try await session.listDatabases()
    }

    public func listTables(schema: String) async throws -> [TableInfo] {
        let result = try await session.execute(
            Self.tablesSQL(where: "TABLE_SCHEMA = \(lit(schema))", dialect: dialect) + " ORDER BY TABLE_NAME"
        )
        return result.records.map(Self.tableInfo)
    }

    private static func tablesSQL(where condition: String, dialect: SQLDialect) -> String {
        """
        SELECT TABLE_SCHEMA AS qw_schema, TABLE_NAME AS qw_name, TABLE_TYPE AS qw_type, ENGINE AS qw_engine, \
        TABLE_ROWS AS qw_rows, DATA_LENGTH AS qw_data, INDEX_LENGTH AS qw_index, \
        TABLE_COLLATION AS qw_collation, TABLE_COMMENT AS qw_comment \
        FROM information_schema.TABLES WHERE \(condition)
        """
    }

    private static func tableInfo(_ r: Record) -> TableInfo {
        let type = (r.string("qw_type") ?? "BASE TABLE").uppercased()
        let isView = type == "VIEW" || type == "SYSTEM VIEW"
        var comment = r.string("qw_comment")?.nilIfEmpty
        if isView && comment == "VIEW" { comment = nil }  // both servers put the literal "VIEW" here
        return TableInfo(
            ref: TableRef(schema: r.string("qw_schema") ?? "", name: r.string("qw_name") ?? ""),
            kind: isView ? .view : .table,
            engine: isView ? nil : r.string("qw_engine"),
            estimatedRows: isView ? nil : r.int("qw_rows"),
            dataBytes: isView ? nil : r.int("qw_data"),
            indexBytes: isView ? nil : r.int("qw_index"),
            collation: isView ? nil : r.string("qw_collation"),
            comment: comment
        )
    }

    public func listRoutines(schema: String) async throws -> [RoutineInfo] {
        let result = try await session.execute(
            """
            SELECT ROUTINE_NAME AS qw_name, ROUTINE_TYPE AS qw_type FROM information_schema.ROUTINES \
            WHERE ROUTINE_SCHEMA = \(lit(schema)) ORDER BY ROUTINE_NAME, ROUTINE_TYPE
            """
        )
        return result.records.compactMap { r in
            guard let name = r.string("qw_name") else { return nil }
            let kind: RoutineKind = (r.string("qw_type") ?? "").uppercased() == "PROCEDURE" ? .procedure : .function
            return RoutineInfo(schema: schema, name: name, kind: kind)
        }
    }

    // MARK: Structure

    public func structure(of table: TableRef) async throws -> TableStructure {
        let schemaLit = lit(table.schema), nameLit = lit(table.name)

        let infoResult = try await session.execute(
            Self.tablesSQL(where: "TABLE_SCHEMA = \(schemaLit) AND TABLE_NAME = \(nameLit)", dialect: dialect)
        )
        guard let infoRecord = infoResult.records.first else {
            throw DatabaseError.query(message: "Table \(table) doesn't exist.", code: "1146")
        }
        let info = Self.tableInfo(infoRecord)

        let columnsResult = try await session.execute(
            """
            SELECT COLUMN_NAME AS qw_name, ORDINAL_POSITION AS qw_pos, DATA_TYPE AS qw_type, COLUMN_TYPE AS qw_ctype, \
            IS_NULLABLE AS qw_null, COLUMN_DEFAULT AS qw_default, COLUMN_KEY AS qw_key, EXTRA AS qw_extra, \
            CHARACTER_SET_NAME AS qw_charset, COLLATION_NAME AS qw_collation, COLUMN_COMMENT AS qw_comment \
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(schemaLit) AND TABLE_NAME = \(nameLit) \
            ORDER BY ORDINAL_POSITION
            """
        )
        var columns = columnsResult.records.map(column)

        let indexes = try await indexes(schema: table.schema, name: table.name)
        let outgoing = try await foreignKeys(where: "k.TABLE_SCHEMA = \(schemaLit) AND k.TABLE_NAME = \(nameLit)")
        let incoming = try await foreignKeys(
            where: "k.REFERENCED_TABLE_SCHEMA = \(schemaLit) AND k.REFERENCED_TABLE_NAME = \(nameLit)"
        )

        // Views have no PRI keys; SHOW CREATE VIEW keeps the original definition text.
        let create = try? await session.execute(
            "SHOW CREATE \(info.kind == .view ? "VIEW" : "TABLE") \(dialect.qualified(table))"
        )
        let createStatement = create?.rows.first.flatMap { $0.count > 1 ? Record.string(from: $0[1]) : nil }

        // MariaDB has no JSON type: `JSON` is LONGTEXT plus `CHECK (json_valid(col))`, so information_schema
        // reports longtext. Recognise those columns so they get the JSON editor, filters and pill.
        if session.serverInfo.engine == .mariadb, let ddl = createStatement?.lowercased() {
            for i in columns.indices where columns[i].dataType == "longtext" && ddl.contains("json_valid(`\(columns[i].name.lowercased())`)") {
                columns[i].dataType = "json"
                columns[i].fullType = "json"
            }
        }

        return TableStructure(
            info: info, columns: columns, indexes: indexes, foreignKeys: outgoing,
            referencedBy: incoming, createStatement: createStatement
        )
    }

    private func column(_ r: Record) -> ColumnDefinition {
        let dataType = (r.string("qw_type") ?? "").lowercased()
        let fullType = r.string("qw_ctype") ?? dataType
        let extra = (r.string("qw_extra") ?? "").lowercased()
        let enumValues = (dataType == "enum" || dataType == "set") ? Self.parseEnumValues(fullType) : nil
        return ColumnDefinition(
            name: r.string("qw_name") ?? "",
            ordinal: Int(r.int("qw_pos") ?? 0),
            dataType: dataType,
            fullType: fullType,
            isNullable: (r.string("qw_null") ?? "YES").uppercased() == "YES",
            defaultExpression: normalizedDefault(
                raw: r.value("qw_default"), dataType: dataType, extra: extra
            ),
            isPrimaryKey: (r.string("qw_key") ?? "").uppercased() == "PRI",
            isAutoIncrement: extra.contains("auto_increment"),
            characterSet: r.string("qw_charset")?.nilIfEmpty,
            collation: r.string("qw_collation")?.nilIfEmpty,
            comment: r.string("qw_comment")?.nilIfEmpty,
            enumValues: enumValues
        )
    }

    /// Default as SQL text. See the type-level notes for the MySQL/MariaDB differences.
    func normalizedDefault(raw: DatabaseValue, dataType: String, extra: String) -> String? {
        guard let text = Record.string(from: raw) else { return nil }
        if session.engine == .mariadb {
            // Already SQL text; a nullable column without default is reported as the word NULL.
            return text == "NULL" ? nil : text
        }
        if extra.contains("default_generated") { return text }  // expression / CURRENT_TIMESTAMP
        if dataType == "bit" { return text }  // b'0'
        if Self.isNumericLiteral(text), Self.numericTypes.contains(dataType) { return text }
        return lit(text)
    }

    private static let numericTypes: Set<String> = [
        "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "year",
    ]

    private static func isNumericLiteral(_ s: String) -> Bool {
        !s.isEmpty && Double(s) != nil && !s.contains(where: { $0 == "x" || $0 == "X" || $0 == "n" || $0 == "N" || $0 == "i" || $0 == "I" })
    }

    /// Parses the quoted list of `enum('a','b')` / `set('a','b')` as printed by the server:
    /// `''` for a quote, backslash escapes (`\\`, `\n`, …) for the rest.
    static func parseEnumValues(_ columnType: String) -> [String]? {
        guard let open = columnType.firstIndex(of: "(") else { return nil }
        var values: [String] = []
        var current = ""
        var inString = false
        let chars = Array(columnType[columnType.index(after: open)...])
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" {
                        current.append("'")
                        i += 2
                        continue
                    }
                    inString = false
                    values.append(current)
                    current = ""
                } else if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    switch n {
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "t": current.append("\t")
                    case "0": current.append("\0")
                    case "Z": current.append("\u{1A}")
                    default: current.append(n)  // \\ \' \" \%…
                    }
                    i += 2
                    continue
                } else {
                    current.append(c)
                }
            } else if c == "'" {
                inString = true
            } else if c == ")" {
                break
            }
            i += 1
        }
        return values
    }

    // MARK: Indexes

    private func indexes(schema: String, name: String) async throws -> [IndexDefinition] {
        // STATISTICS.EXPRESSION only exists on MySQL 8+ (functional key parts).
        let hasExpression = session.engine == .mysql && session.serverInfo.major >= 8
        let result = try await session.execute(
            """
            SELECT INDEX_NAME AS qw_index, SEQ_IN_INDEX AS qw_seq, COLUMN_NAME AS qw_column, \
            NON_UNIQUE AS qw_nonunique, INDEX_TYPE AS qw_method\(hasExpression ? ", EXPRESSION AS qw_expr" : "") \
            FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(lit(schema)) AND TABLE_NAME = \(lit(name)) \
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
            """
        )
        var order: [String] = []
        var groups: [String: IndexDefinition] = [:]
        for r in result.records {
            guard let indexName = r.string("qw_index") else { continue }
            let part = r.string("qw_column") ?? r.string("qw_expr").map { "(\($0))" } ?? ""
            if var existing = groups[indexName] {
                existing.columns.append(part)
                groups[indexName] = existing
            } else {
                order.append(indexName)
                groups[indexName] = IndexDefinition(
                    name: indexName, columns: [part],
                    isUnique: (r.int("qw_nonunique") ?? 1) == 0,
                    isPrimary: indexName == "PRIMARY",
                    method: r.string("qw_method")?.uppercased()
                )
            }
        }
        // PRIMARY first, then by name (information_schema doesn't expose definition order).
        let primary = order.filter { $0 == "PRIMARY" }
        let rest = order.filter { $0 != "PRIMARY" }
        return (primary + rest).compactMap { groups[$0] }
    }

    // MARK: Foreign keys

    private func foreignKeys(where condition: String) async throws -> [ForeignKeyDefinition] {
        let result = try await session.execute(
            """
            SELECT k.CONSTRAINT_NAME AS qw_name, k.TABLE_SCHEMA AS qw_schema, k.TABLE_NAME AS qw_table, \
            k.COLUMN_NAME AS qw_column, k.ORDINAL_POSITION AS qw_pos, \
            k.REFERENCED_TABLE_SCHEMA AS qw_rschema, k.REFERENCED_TABLE_NAME AS qw_rtable, \
            k.REFERENCED_COLUMN_NAME AS qw_rcolumn, r.UPDATE_RULE AS qw_update, r.DELETE_RULE AS qw_delete \
            FROM information_schema.KEY_COLUMN_USAGE k \
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA \
            AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME \
            WHERE k.REFERENCED_TABLE_NAME IS NOT NULL AND \(condition) \
            ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """
        )
        var order: [String] = []
        var byKey: [String: ForeignKeyDefinition] = [:]
        for r in result.records {
            guard let name = r.string("qw_name") else { continue }
            let owner = TableRef(schema: r.string("qw_schema") ?? "", name: r.string("qw_table") ?? "")
            let key = "\(owner.schema)\u{0}\(owner.name)\u{0}\(name)"
            let column = r.string("qw_column") ?? ""
            let refColumn = r.string("qw_rcolumn") ?? ""
            if var existing = byKey[key] {
                existing.columns.append(column)
                existing.referencedColumns.append(refColumn)
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = ForeignKeyDefinition(
                    name: name, columns: [column],
                    referenced: TableRef(schema: r.string("qw_rschema") ?? "", name: r.string("qw_rtable") ?? ""),
                    referencedColumns: [refColumn],
                    onUpdate: r.string("qw_update"), onDelete: r.string("qw_delete"), table: owner
                )
            }
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: Collations & engines

    /// `SHOW COLLATION`, with each character set's real default taken from
    /// `information_schema.CHARACTER_SETS`: MariaDB 11.4 doesn't flag its `utf8mb4_uca1400_ai_ci` default
    /// in `SHOW COLLATION` (and lists charset-less `uca1400_*` pseudo-collations, which are skipped here).
    public func availableCollations() async throws -> [CollationInfo] {
        let result = try await session.execute("SHOW COLLATION")
        var byName: [String: CollationInfo] = [:]
        for r in result.records {
            guard let name = r.string("Collation"), let charset = r.string("Charset") else { continue }
            byName[name] = CollationInfo(
                name: name, characterSet: charset, isDefault: (r.string("Default") ?? "").lowercased() == "yes"
            )
        }
        let defaults = try await session.execute(
            "SELECT CHARACTER_SET_NAME AS qw_charset, DEFAULT_COLLATE_NAME AS qw_collation FROM information_schema.CHARACTER_SETS"
        )
        for r in defaults.records {
            guard let charset = r.string("qw_charset"), let name = r.string("qw_collation") else { continue }
            if byName[name] != nil {
                byName[name]?.isDefault = true
            } else {
                byName[name] = CollationInfo(name: name, characterSet: charset, isDefault: true)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public func availableEngines() async throws -> [String] {
        let result = try await session.execute("SHOW ENGINES")
        return result.records.compactMap { r in
            guard let engine = r.string("Engine"),
                  ["YES", "DEFAULT"].contains((r.string("Support") ?? "").uppercased())
            else { return nil }
            return engine
        }
    }

    // MARK: Table options and triggers

    public func tableOptions(of table: TableRef) async throws -> TableOptions {
        let result = try await session.execute(
            """
            SELECT ENGINE AS qw_engine, TABLE_COLLATION AS qw_collation, TABLE_COMMENT AS qw_comment, \
            AUTO_INCREMENT AS qw_auto, ROW_FORMAT AS qw_format, TABLE_TYPE AS qw_type \
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(lit(table.schema)) AND TABLE_NAME = \(lit(table.name))
            """
        )
        guard let r = result.records.first else {
            throw DatabaseError.query(message: "Table \(table) doesn't exist.", code: "1146")
        }
        // MySQL 8 serves information_schema.TABLES.AUTO_INCREMENT from a cache (up to 24 h stale);
        // SHOW CREATE TABLE is always current.
        var auto = r.int("qw_auto")
        if let create = try? await session.execute("SHOW CREATE TABLE \(dialect.qualified(table))"),
           let text = create.rows.first.flatMap({ $0.count > 1 ? Record.string(from: $0[1]) : nil }) {
            auto = Self.parseAutoIncrement(createStatement: text) ?? auto
        }
        let isView = (r.string("qw_type") ?? "").uppercased().contains("VIEW")
        return TableOptions(
            engine: isView ? nil : r.string("qw_engine"), collation: r.string("qw_collation"),
            comment: isView ? "" : (r.string("qw_comment") ?? ""), autoIncrement: auto, rowFormat: r.string("qw_format"))
    }

    /// The `AUTO_INCREMENT=n` table option of a `SHOW CREATE TABLE` text (nil when there is none).
    static func parseAutoIncrement(createStatement: String) -> Int64? {
        guard let close = createStatement.lastIndex(of: ")") else { return nil }
        var tail = String(createStatement[close...])
        if let comment = tail.range(of: "COMMENT='") { tail = String(tail[..<comment.lowerBound]) }  // never read inside the comment
        guard let range = tail.range(of: "AUTO_INCREMENT=") else { return nil }
        let digits = tail[range.upperBound...].prefix { $0.isNumber }
        return Int64(digits)
    }

    public func triggers(on table: TableRef) async throws -> [TriggerInfo] {
        let result = try await session.execute(
            """
            SELECT TRIGGER_NAME AS qw_name, ACTION_TIMING AS qw_timing, EVENT_MANIPULATION AS qw_event, \
            ACTION_STATEMENT AS qw_stmt, ACTION_ORIENTATION AS qw_orient, DEFINER AS qw_definer \
            FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA = \(lit(table.schema)) \
            AND EVENT_OBJECT_TABLE = \(lit(table.name)) ORDER BY ACTION_TIMING, EVENT_MANIPULATION, ACTION_ORDER, TRIGGER_NAME
            """
        )
        return result.records.compactMap { r in
            guard let name = r.string("qw_name"),
                  let timing = TriggerTiming(rawValue: (r.string("qw_timing") ?? "").uppercased()),
                  let event = TriggerEvent(rawValue: (r.string("qw_event") ?? "").uppercased())
            else { return nil }
            return TriggerInfo(
                name: name, table: table, timing: timing, events: [event], forEachRow: true,
                statement: r.string("qw_stmt") ?? "", definer: r.string("qw_definer")?.nilIfEmpty)
        }
    }

    public func triggerDefinition(_ trigger: TriggerInfo) async throws -> String {
        let result = try await session.execute(
            "SHOW CREATE TRIGGER \(dialect.qualified(TableRef(schema: trigger.table.schema, name: trigger.name)))")
        // Columns: Trigger, sql_mode, SQL Original Statement, …
        if let r = result.records.first, let text = r.string("SQL Original Statement") { return text }
        return result.rows.first.flatMap { $0.count > 2 ? Record.string(from: $0[2]) : nil } ?? ""
    }

    public func triggerFunctions(schema: String) async throws -> [TableRef] { [] }
    public func functionDefinition(_ function: TableRef) async throws -> String? { nil }
}
