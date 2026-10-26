import Foundation

/// `SchemaInspector` for PostgreSQL, built on `pg_catalog`. Names reach SQL only as literals
/// produced by ``SQLDialect``.
///
/// - `ColumnDefinition.dataType` is the `pg_type.typname` (`int8`, `varchar`, `jsonb`, `_int4`), matching
///   `ColumnInfo.typeName` from query results; enum-typed columns report `enum` (the type name is `fullType`).
/// - `fullType` is `format_type()` output (`character varying(255)`, `numeric(10,2)`).
/// - `createStatement` is **reconstructed** from the catalog (Postgres has no `SHOW CREATE TABLE`): columns,
///   identity/generated clauses, primary key, foreign keys, then `CREATE INDEX` statements from
///   `pg_get_indexdef`. It is informative DDL, not a `pg_dump` replacement (no ownership, grants,
///   triggers, check constraints, partitioning clauses or storage parameters).
/// - `estimatedRows` is `reltuples` (nil when never analysed); sizes come from `pg_relation_size` and
///   `pg_indexes_size`.
public struct PostgresSchemaInspector: SchemaInspector {
    private let session: any DatabaseSession
    private let dialect = SQLDialect(.postgresql)

    public init(session: any DatabaseSession) {
        self.session = session
    }

    private func lit(_ s: String) -> String { dialect.quoteString(s) }

    // MARK: Lists

    public func listSchemas() async throws -> [String] {
        let result = try await session.execute(
            """
            SELECT nspname::text AS qw_name FROM pg_namespace \
            WHERE left(nspname, 3) <> 'pg_' AND nspname <> 'information_schema' ORDER BY nspname
            """
        )
        return result.records.compactMap { $0.string("qw_name") }
    }

    private static let tableColumns = """
        SELECT n.nspname::text AS qw_schema, c.relname::text AS qw_name, c.relkind::text AS qw_kind, \
        c.reltuples::int8 AS qw_tuples, pg_relation_size(c.oid)::int8 AS qw_size, \
        pg_indexes_size(c.oid)::int8 AS qw_isize, obj_description(c.oid, 'pg_class')::text AS qw_comment \
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
        WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
        """

    public func listTables(schema: String) async throws -> [TableInfo] {
        let result = try await session.execute(
            Self.tableColumns + " AND n.nspname = \(lit(schema)) ORDER BY c.relname"
        )
        return result.records.map(Self.tableInfo)
    }

    private static func tableInfo(_ r: Record) -> TableInfo {
        let relkind = r.string("qw_kind") ?? "r"
        let kind: TableKind = relkind == "v" ? .view : relkind == "m" ? .materializedView : .table
        let tuples = r.int("qw_tuples")
        return TableInfo(
            ref: TableRef(schema: r.string("qw_schema") ?? "", name: r.string("qw_name") ?? ""),
            kind: kind,
            engine: nil,
            estimatedRows: kind == .view ? nil : (tuples.flatMap { $0 < 0 ? nil : $0 }),
            dataBytes: kind == .view ? nil : r.int("qw_size"),
            indexBytes: kind == .view ? nil : r.int("qw_isize"),
            collation: nil,
            comment: r.string("qw_comment")?.nilIfEmpty
        )
    }

    public func listRoutines(schema: String) async throws -> [RoutineInfo] {
        let result = try await session.execute(
            """
            SELECT p.proname::text AS qw_name, p.prokind::text AS qw_kind FROM pg_proc p \
            JOIN pg_namespace n ON n.oid = p.pronamespace \
            WHERE n.nspname = \(lit(schema)) AND p.prokind IN ('f', 'p') \
            AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e') \
            ORDER BY p.proname, p.oid
            """
        )
        return result.records.compactMap { r in
            guard let name = r.string("qw_name") else { return nil }
            return RoutineInfo(schema: schema, name: name, kind: r.string("qw_kind") == "p" ? .procedure : .function)
        }
    }

    // MARK: Structure

    /// Subquery yielding the table's OID (NULL when it doesn't exist).
    private func relOID(_ table: TableRef) -> String {
        """
        (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
        WHERE n.nspname = \(lit(table.schema)) AND c.relname = \(lit(table.name)))
        """
    }

    private struct ColumnExtras {
        var identity: String = ""  // "a" ALWAYS, "d" BY DEFAULT
        var generatedExpression: String?
    }

    public func structure(of table: TableRef) async throws -> TableStructure {
        let infoResult = try await session.execute(
            Self.tableColumns + " AND n.nspname = \(lit(table.schema)) AND c.relname = \(lit(table.name))"
        )
        guard let infoRecord = infoResult.records.first else {
            throw DatabaseError.query(message: "relation \"\(table.schema).\(table.name)\" does not exist", code: "42P01")
        }
        let info = Self.tableInfo(infoRecord)
        let oid = relOID(table)

        let indexes = try await indexes(oid: oid)
        let primary = Set(indexes.first(where: \.isPrimary)?.columns ?? [])
        let (columns, extras) = try await columns(oid: oid, primary: primary)
        let outgoing = try await foreignKeys(where: "c.conrelid = \(oid)")
        let incoming = try await foreignKeys(where: "c.confrelid = \(oid)")

        let create = try await createStatement(
            table: table, info: info, oid: oid, columns: columns, extras: extras, indexes: indexes, foreignKeys: outgoing
        )
        return TableStructure(
            info: info, columns: columns, indexes: indexes, foreignKeys: outgoing,
            referencedBy: incoming, createStatement: create
        )
    }

    private func columns(oid: String, primary: Set<String>) async throws -> ([ColumnDefinition], [String: ColumnExtras]) {
        let result = try await session.execute(
            """
            SELECT a.attname::text AS qw_name, a.attnum::int4 AS qw_pos, t.typname::text AS qw_type, \
            t.typtype::text AS qw_typtype, a.atttypid::int8 AS qw_typid, \
            format_type(a.atttypid, a.atttypmod)::text AS qw_fulltype, a.attnotnull AS qw_notnull, \
            pg_get_expr(d.adbin, d.adrelid)::text AS qw_default, a.attidentity::text AS qw_identity, \
            a.attgenerated::text AS qw_generated, col_description(a.attrelid, a.attnum)::text AS qw_comment, \
            CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation THEN co.collname::text END AS qw_collation \
            FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid \
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum \
            LEFT JOIN pg_collation co ON co.oid = a.attcollation \
            WHERE a.attrelid = \(oid) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
            """
        )
        let records = result.records

        // Enum labels for every enum-typed column in one query.
        let enumTypeIDs = Set(records.filter { $0.string("qw_typtype") == "e" }.compactMap { $0.int("qw_typid") })
        var labels: [Int64: [String]] = [:]
        if !enumTypeIDs.isEmpty {
            let list = enumTypeIDs.sorted().map(String.init).joined(separator: ", ")
            let enums = try await session.execute(
                """
                SELECT enumtypid::int8 AS qw_type, enumlabel::text AS qw_label FROM pg_enum \
                WHERE enumtypid IN (\(list)) ORDER BY enumtypid, enumsortorder
                """
            )
            for r in enums.records {
                if let id = r.int("qw_type"), let label = r.string("qw_label") { labels[id, default: []].append(label) }
            }
        }

        var extras: [String: ColumnExtras] = [:]
        let columns: [ColumnDefinition] = records.map { r in
            let name = r.string("qw_name") ?? ""
            let generated = (r.string("qw_generated") ?? "") == "s"
            let identity = r.string("qw_identity") ?? ""
            let rawDefault = r.string("qw_default")
            extras[name] = ColumnExtras(identity: identity, generatedExpression: generated ? rawDefault : nil)
            let isEnum = r.string("qw_typtype") == "e"
            let isSerial = !generated && (rawDefault?.hasPrefix("nextval(") ?? false)
            return ColumnDefinition(
                name: name,
                ordinal: Int(r.int("qw_pos") ?? 0),
                dataType: isEnum ? "enum" : (r.string("qw_type") ?? "").lowercased(),
                fullType: r.string("qw_fulltype") ?? "",
                isNullable: !(r.bool("qw_notnull") ?? false),
                defaultExpression: generated ? nil : rawDefault,
                isPrimaryKey: primary.contains(name),
                isAutoIncrement: !identity.isEmpty || isSerial,
                characterSet: nil,
                collation: r.string("qw_collation"),
                comment: r.string("qw_comment")?.nilIfEmpty,
                enumValues: isEnum ? r.int("qw_typid").flatMap { labels[$0] } : nil
            )
        }
        return (columns, extras)
    }

    private func indexes(oid: String) async throws -> [IndexDefinition] {
        let heads = try await session.execute(
            """
            SELECT ix.indexrelid::int8 AS qw_id, i.relname::text AS qw_name, ix.indisunique AS qw_unique, \
            ix.indisprimary AS qw_primary, am.amname::text AS qw_method, \
            pg_get_expr(ix.indpred, ix.indrelid)::text AS qw_predicate, \
            pg_get_indexdef(ix.indexrelid)::text AS qw_def \
            FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_am am ON am.oid = i.relam \
            WHERE ix.indrelid = \(oid) ORDER BY ix.indisprimary DESC, i.relname
            """
        )
        // Key parts in order: plain columns by attname (unquoted), expressions via pg_get_indexdef.
        let parts = try await session.execute(
            """
            SELECT ix.indexrelid::int8 AS qw_id, k.n::int4 AS qw_n, \
            CASE WHEN ix.indkey[k.n - 1] = 0 THEN '(' || pg_get_indexdef(ix.indexrelid, k.n, true) || ')' \
            ELSE (SELECT a.attname::text FROM pg_attribute a WHERE a.attrelid = ix.indrelid AND a.attnum = ix.indkey[k.n - 1]) END AS qw_part \
            FROM pg_index ix CROSS JOIN LATERAL generate_series(1, ix.indnkeyatts::int4) AS k(n) \
            WHERE ix.indrelid = \(oid) ORDER BY ix.indexrelid, k.n
            """
        )
        var columnsByIndex: [Int64: [String]] = [:]
        for r in parts.records {
            if let id = r.int("qw_id"), let part = r.string("qw_part") { columnsByIndex[id, default: []].append(part) }
        }
        return heads.records.compactMap { r in
            guard let id = r.int("qw_id"), let name = r.string("qw_name") else { return nil }
            return IndexDefinition(
                name: name, columns: columnsByIndex[id] ?? [],
                isUnique: r.bool("qw_unique") ?? false, isPrimary: r.bool("qw_primary") ?? false,
                method: r.string("qw_method"), predicate: r.string("qw_predicate")
            )
        }
    }

    private func foreignKeys(where condition: String) async throws -> [ForeignKeyDefinition] {
        let result = try await session.execute(
            """
            SELECT c.oid::int8 AS qw_id, c.conname::text AS qw_name, \
            sn.nspname::text AS qw_schema, sc.relname::text AS qw_table, \
            tn.nspname::text AS qw_rschema, tc.relname::text AS qw_rtable, \
            c.confupdtype::text AS qw_update, c.confdeltype::text AS qw_delete, k.ord::int4 AS qw_ord, \
            sa.attname::text AS qw_column, ta.attname::text AS qw_rcolumn \
            FROM pg_constraint c \
            JOIN pg_class sc ON sc.oid = c.conrelid JOIN pg_namespace sn ON sn.oid = sc.relnamespace \
            JOIN pg_class tc ON tc.oid = c.confrelid JOIN pg_namespace tn ON tn.oid = tc.relnamespace \
            CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(sattnum, tattnum, ord) \
            JOIN pg_attribute sa ON sa.attrelid = c.conrelid AND sa.attnum = k.sattnum \
            JOIN pg_attribute ta ON ta.attrelid = c.confrelid AND ta.attnum = k.tattnum \
            WHERE c.contype = 'f' AND \(condition) ORDER BY sn.nspname, sc.relname, c.conname, c.oid, k.ord
            """
        )
        var order: [Int64] = []
        var byID: [Int64: ForeignKeyDefinition] = [:]
        for r in result.records {
            guard let id = r.int("qw_id") else { continue }
            let column = r.string("qw_column") ?? "", refColumn = r.string("qw_rcolumn") ?? ""
            if var existing = byID[id] {
                existing.columns.append(column)
                existing.referencedColumns.append(refColumn)
                byID[id] = existing
            } else {
                order.append(id)
                byID[id] = ForeignKeyDefinition(
                    name: r.string("qw_name") ?? "", columns: [column],
                    referenced: TableRef(schema: r.string("qw_rschema") ?? "", name: r.string("qw_rtable") ?? ""),
                    referencedColumns: [refColumn],
                    onUpdate: Self.action(r.string("qw_update")), onDelete: Self.action(r.string("qw_delete")),
                    table: TableRef(schema: r.string("qw_schema") ?? "", name: r.string("qw_table") ?? "")
                )
            }
        }
        return order.compactMap { byID[$0] }
    }

    static func action(_ code: String?) -> String {
        switch code {
        case "r": "RESTRICT"
        case "c": "CASCADE"
        case "n": "SET NULL"
        case "d": "SET DEFAULT"
        default: "NO ACTION"
        }
    }

    // MARK: DDL reconstruction

    private func createStatement(
        table: TableRef, info: TableInfo, oid: String, columns: [ColumnDefinition],
        extras: [String: ColumnExtras], indexes: [IndexDefinition], foreignKeys: [ForeignKeyDefinition]
    ) async throws -> String {
        let header = "-- Reconstructed from the Postgres catalog by Querywell; not pg_dump output.\n"
        let qualified = dialect.qualified(table)

        if info.kind == .view || info.kind == .materializedView {
            let result = try await session.execute("SELECT pg_get_viewdef(\(oid), true)::text AS qw_def")
            let body = (result.records.first?.string("qw_def") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let keyword = info.kind == .view ? "CREATE OR REPLACE VIEW" : "CREATE MATERIALIZED VIEW"
            let terminator = body.hasSuffix(";") ? "" : ";"
            return header + "\(keyword) \(qualified) AS\n\(body)\(terminator)"
        }

        var lines: [String] = []
        for column in columns {
            var line = "  " + dialect.quoteIdentifier(column.name) + " " + column.fullType
            let extra = extras[column.name] ?? ColumnExtras()
            if let generated = extra.generatedExpression {
                line += " GENERATED ALWAYS AS (\(generated)) STORED"
            } else if extra.identity == "a" {
                line += " GENERATED ALWAYS AS IDENTITY"
            } else if extra.identity == "d" {
                line += " GENERATED BY DEFAULT AS IDENTITY"
            } else if let def = column.defaultExpression {
                line += " DEFAULT \(def)"
            }
            if let collation = column.collation { line += " COLLATE \(dialect.quoteIdentifier(collation))" }
            if !column.isNullable { line += " NOT NULL" }
            lines.append(line)
        }
        if let pk = indexes.first(where: \.isPrimary) {
            lines.append(
                "  CONSTRAINT \(dialect.quoteIdentifier(pk.name)) PRIMARY KEY (\(pk.columns.map(dialect.quoteIdentifier).joined(separator: ", ")))"
            )
        }
        for fk in foreignKeys {
            var line = "  CONSTRAINT \(dialect.quoteIdentifier(fk.name)) FOREIGN KEY "
            line += "(\(fk.columns.map(dialect.quoteIdentifier).joined(separator: ", "))) "
            line += "REFERENCES \(dialect.qualified(fk.referenced)) "
            line += "(\(fk.referencedColumns.map(dialect.quoteIdentifier).joined(separator: ", ")))"
            if let u = fk.onUpdate, u != "NO ACTION" { line += " ON UPDATE \(u)" }
            if let d = fk.onDelete, d != "NO ACTION" { line += " ON DELETE \(d)" }
            lines.append(line)
        }
        var out = header + "CREATE TABLE \(qualified) (\n" + lines.joined(separator: ",\n") + "\n);"

        let defs = try await session.execute(
            """
            SELECT pg_get_indexdef(ix.indexrelid)::text AS qw_def FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid \
            WHERE ix.indrelid = \(oid) AND NOT ix.indisprimary ORDER BY i.relname
            """
        )
        for def in defs.records.compactMap({ $0.string("qw_def") }) {
            out += "\n\(def);"
        }
        return out
    }

    // MARK: Collations & engines

    public func availableCollations() async throws -> [CollationInfo] { [] }
    public func availableEngines() async throws -> [String] { [] }

    // MARK: Table options and triggers

    public func tableOptions(of table: TableRef) async throws -> TableOptions {
        let oid = relOID(table)
        let info = try await session.execute(
            """
            SELECT obj_description(c.oid, 'pg_class')::text AS qw_comment, ts.spcname::text AS qw_space \
            FROM pg_class c LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace AND c.reltablespace <> 0 \
            WHERE c.oid = \(oid)
            """
        )
        guard let r = info.records.first else {
            throw DatabaseError.query(message: "relation \"\(table.schema).\(table.name)\" does not exist", code: "42P01")
        }
        // The first identity / serial column's sequence, and where it will continue.
        let seqResult = try await session.execute(
            """
            SELECT sn.nspname::text AS qw_schema, s.relname::text AS qw_name FROM pg_depend d \
            JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S' JOIN pg_namespace sn ON sn.oid = s.relnamespace \
            WHERE d.refobjid = \(oid) AND d.deptype IN ('a', 'i') AND d.classid = 'pg_class'::regclass \
            AND d.refclassid = 'pg_class'::regclass ORDER BY d.refobjsubid LIMIT 1
            """
        )
        var sequence: TableRef?
        var next: Int64?
        if let s = seqResult.records.first, let schema = s.string("qw_schema"), let name = s.string("qw_name") {
            let ref = TableRef(schema: schema, name: name)
            sequence = ref
            if let state = try? await session.execute("SELECT last_value::int8 AS qw_last, is_called AS qw_called FROM \(dialect.qualified(ref))"),
               let row = state.records.first, let last = row.int("qw_last") {
                next = (row.bool("qw_called") ?? true) ? last + 1 : last
            }
        }
        return TableOptions(
            comment: r.string("qw_comment") ?? "", autoIncrement: next, sequence: sequence, tablespace: r.string("qw_space"))
    }

    /// `tgtype` bit field → timing, events, row / statement level.
    static func decodeTriggerType(_ type: Int) -> (timing: TriggerTiming, events: [TriggerEvent], forEachRow: Bool) {
        var events: [TriggerEvent] = []
        if type & 4 != 0 { events.append(.insert) }
        if type & 16 != 0 { events.append(.update) }
        if type & 8 != 0 { events.append(.delete) }
        if type & 32 != 0 { events.append(.truncate) }
        let timing: TriggerTiming = type & 64 != 0 ? .insteadOf : (type & 2 != 0 ? .before : .after)
        return (timing, events, type & 1 != 0)
    }

    public func triggers(on table: TableRef) async throws -> [TriggerInfo] {
        let result = try await session.execute(
            """
            SELECT t.tgname::text AS qw_name, t.tgtype::int4 AS qw_type, t.tgenabled::text AS qw_enabled, \
            fn.nspname::text AS qw_fn_schema, p.proname::text AS qw_fn_name, \
            pg_get_expr(t.tgqual, t.tgrelid)::text AS qw_when \
            FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace fn ON fn.oid = p.pronamespace \
            WHERE t.tgrelid = \(relOID(table)) AND NOT t.tgisinternal ORDER BY t.tgname
            """
        )
        return result.records.compactMap { r in
            guard let name = r.string("qw_name"), let type = r.int("qw_type") else { return nil }
            let decoded = Self.decodeTriggerType(Int(type))
            let function = TableRef(schema: r.string("qw_fn_schema") ?? "", name: r.string("qw_fn_name") ?? "")
            return TriggerInfo(
                name: name, table: table, timing: decoded.timing, events: decoded.events, forEachRow: decoded.forEachRow,
                statement: "EXECUTE FUNCTION \(dialect.qualified(function))()", function: function,
                whenCondition: r.string("qw_when")?.nilIfEmpty, isEnabled: r.string("qw_enabled") != "D")
        }
    }

    public func triggerDefinition(_ trigger: TriggerInfo) async throws -> String {
        let result = try await session.execute(
            """
            SELECT pg_get_triggerdef(t.oid, true)::text AS qw_def FROM pg_trigger t \
            WHERE t.tgrelid = \(relOID(trigger.table)) AND t.tgname = \(lit(trigger.name)) AND NOT t.tgisinternal
            """
        )
        return result.records.first?.string("qw_def") ?? ""
    }

    public func triggerFunctions(schema: String) async throws -> [TableRef] {
        let result = try await session.execute(
            """
            SELECT p.proname::text AS qw_name FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
            WHERE n.nspname = \(lit(schema)) AND p.prorettype = 'trigger'::regtype AND p.pronargs = 0 AND p.prokind = 'f' \
            ORDER BY p.proname
            """
        )
        return result.records.compactMap { $0.string("qw_name").map { TableRef(schema: schema, name: $0) } }
    }

    public func functionDefinition(_ function: TableRef) async throws -> String? {
        let result = try await session.execute(
            """
            SELECT pg_get_functiondef(p.oid)::text AS qw_def FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
            WHERE n.nspname = \(lit(function.schema)) AND p.proname = \(lit(function.name)) AND p.pronargs = 0 AND p.prokind = 'f' LIMIT 1
            """
        )
        return result.records.first?.string("qw_def")
    }
}

/// Picks the inspector for an open session's engine.
public enum SchemaInspectorFactory {
    public static func inspector(for session: any DatabaseSession) -> any SchemaInspector {
        switch session.engine {
        case .mysql, .mariadb: MySQLSchemaInspector(session: session)
        case .postgresql: PostgresSchemaInspector(session: session)
        }
    }
}
