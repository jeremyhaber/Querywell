import Foundation

/// Reads the server facts the Health page and the Doctor need. Every query is independent: one the
/// account may not run (no `PROCESS`, no `pg_monitor`, …) is recorded in ``ServerFacts/unavailable``
/// and the rest of the page still works. Only SELECT / SHOW statements are issued.
public struct HealthCollector: Sendable {
    public init() {}

    public func collect(session: any DatabaseSession) async -> ServerFacts {
        let info = session.serverInfo
        var facts = ServerFacts(engine: info.engine, versionString: info.versionString,
                                major: info.major, minor: info.minor, patch: info.patch)
        switch info.engine {
        case .mysql, .mariadb: await collectMySQL(session, into: &facts)
        case .postgresql: await collectPostgres(session, into: &facts)
        }
        return facts
    }

    // MARK: MySQL / MariaDB

    private static let mysqlSystemSchemas = "('mysql','information_schema','performance_schema','sys')"

    private func collectMySQL(_ session: any DatabaseSession, into facts: inout ServerFacts) async {
        let variables = await attempt("variables", &facts) { try await Self.pairs(session, "SHOW GLOBAL VARIABLES") }
        facts.variables = variables ?? [:]
        let status = await attempt("status", &facts) { try await Self.pairs(session, "SHOW GLOBAL STATUS") }
        facts.status = status ?? [:]
        facts.uptimeSeconds = facts.statusInt("uptime")

        let system = Self.mysqlSystemSchemas
        if let row = await attempt("storage", &facts, {
            try await session.execute("""
                SELECT CAST(COALESCE(SUM(data_length), 0) AS SIGNED), CAST(COALESCE(SUM(index_length), 0) AS SIGNED),
                       CAST(COALESCE(SUM(CASE WHEN engine = 'InnoDB' THEN data_length + index_length ELSE 0 END), 0) AS SIGNED)
                FROM information_schema.tables
                WHERE table_type = 'BASE TABLE' AND table_schema NOT IN \(system)
                """).rows.first
        }), row.count >= 3 {
            facts.dataBytes = Cell.int(row[0])
            facts.indexBytes = Cell.int(row[1])
            facts.innodbBytes = Cell.int(row[2])
        }
        if let rows = await attempt("noPrimaryKey", &facts, {
            try await session.execute("""
                SELECT t.table_schema, t.table_name
                FROM information_schema.tables t
                LEFT JOIN information_schema.table_constraints c
                  ON c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY'
                WHERE t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL AND t.table_schema NOT IN \(system)
                ORDER BY t.table_schema, t.table_name LIMIT 100
                """).rows
        }) {
            facts.tablesWithoutPrimaryKey = rows.compactMap { Cell.pair($0) }
        }
        if let rows = await attempt("nonInnoDB", &facts, {
            try await session.execute("""
                SELECT table_schema, table_name, engine FROM information_schema.tables
                WHERE table_type = 'BASE TABLE' AND engine IS NOT NULL AND engine <> 'InnoDB' AND table_schema NOT IN \(system)
                ORDER BY table_schema, table_name LIMIT 100
                """).rows
        }) {
            facts.nonInnoDBTables = rows.compactMap { row in
                Cell.pair(row).map { name in "\(name) (\(row.count > 2 ? Cell.string(row[2]) : "?"))" }
            }
        }
        if let rows = await attempt("largestTables", &facts, {
            try await session.execute("""
                SELECT table_schema, table_name, CAST(COALESCE(data_length, 0) + COALESCE(index_length, 0) AS SIGNED),
                       CAST(table_rows AS SIGNED)
                FROM information_schema.tables
                WHERE table_type = 'BASE TABLE' AND table_schema NOT IN \(system)
                ORDER BY COALESCE(data_length, 0) + COALESCE(index_length, 0) DESC LIMIT 10
                """).rows
        }) {
            facts.largestTables = rows.compactMap { row in
                guard row.count >= 4 else { return nil }
                return TableSizeEntry(schema: Cell.string(row[0]), name: Cell.string(row[1]),
                                      totalBytes: Cell.int(row[2]) ?? 0, rows: Cell.int(row[3]))
            }
        }
    }

    // MARK: PostgreSQL

    private static let pgSystemSchemas = "('pg_catalog','information_schema')"

    private func collectPostgres(_ session: any DatabaseSession, into facts: inout ServerFacts) async {
        if let rows = await attempt("variables", &facts, {
            try await session.execute("SELECT name, setting, unit, context, source FROM pg_settings").rows
        }) {
            for row in rows where row.count >= 5 {
                let name = Cell.string(row[0]).lowercased()
                facts.variables[name] = Self.postgresDisplayValue(setting: Cell.string(row[1]), unit: Cell.optionalString(row[2]))
                facts.contexts[name] = Cell.string(row[3])
                facts.sources[name] = Cell.string(row[4])
            }
        }
        if let row = await attempt("uptime", &facts, {
            try await session.execute("SELECT extract(epoch FROM now() - pg_postmaster_start_time())::bigint").rows.first
        }) {
            facts.uptimeSeconds = row.first.flatMap(Cell.int)
        }
        if let row = await attempt("connections", &facts, {
            try await session.execute("""
                SELECT count(*)::bigint,
                       (count(*) FILTER (WHERE state = 'active' AND pid <> pg_backend_pid()))::bigint
                FROM pg_stat_activity WHERE backend_type = 'client backend'
                """).rows.first
        }), row.count >= 2 {
            facts.activeConnections = Cell.int(row[0])
            facts.runningBackends = Cell.int(row[1])
        }
        if let row = await attempt("databaseStats", &facts, {
            try await session.execute("""
                SELECT blks_hit::bigint, blks_read::bigint, xact_commit::bigint, xact_rollback::bigint,
                       deadlocks::bigint, temp_files::bigint, temp_bytes::bigint, pg_database_size(datname)::bigint
                FROM pg_stat_database WHERE datname = current_database()
                """).rows.first
        }), row.count >= 8 {
            let v = row.map { Cell.int($0) ?? 0 }
            facts.postgresStats = PostgresDatabaseStats(
                blocksHit: v[0], blocksRead: v[1], commits: v[2], rollbacks: v[3],
                deadlocks: v[4], tempFiles: v[5], tempBytes: v[6], databaseBytes: v[7])
        }
        if let rows = await attempt("largestTables", &facts, {
            try await session.execute("""
                SELECT n.nspname::text, c.relname::text, pg_total_relation_size(c.oid)::bigint, c.reltuples::bigint
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN \(Self.pgSystemSchemas) AND n.nspname NOT LIKE 'pg_toast%'
                ORDER BY 3 DESC LIMIT 10
                """).rows
        }) {
            facts.largestTables = rows.compactMap { row in
                guard row.count >= 4 else { return nil }
                return TableSizeEntry(schema: Cell.string(row[0]), name: Cell.string(row[1]),
                                      totalBytes: Cell.int(row[2]) ?? 0, rows: Cell.int(row[3]).map { max($0, 0) })
            }
            facts.dataBytes = facts.largestTables.map { $0.reduce(0) { $0 + $1.totalBytes } }
        }
        if let rows = await attempt("deadTuples", &facts, {
            try await session.execute("""
                SELECT schemaname::text, relname::text, n_live_tup::bigint, n_dead_tup::bigint,
                       last_autovacuum::text, last_vacuum::text
                FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY n_dead_tup DESC LIMIT 20
                """).rows
        }) {
            facts.deadTupleTables = rows.compactMap { row in
                guard row.count >= 6 else { return nil }
                return DeadTupleEntry(
                    schema: Cell.string(row[0]), name: Cell.string(row[1]),
                    liveTuples: Cell.int(row[2]) ?? 0, deadTuples: Cell.int(row[3]) ?? 0,
                    lastAutovacuum: Cell.optionalString(row[4]), lastVacuum: Cell.optionalString(row[5]))
            }
        }
        if let rows = await attempt("unusedIndexes", &facts, {
            try await session.execute("""
                SELECT s.schemaname::text, s.relname::text, s.indexrelname::text, pg_relation_size(s.indexrelid)::bigint
                FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
                WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
                ORDER BY 4 DESC LIMIT 20
                """).rows
        }) {
            facts.unusedIndexes = rows.compactMap { row in
                guard row.count >= 4 else { return nil }
                return UnusedIndexEntry(schema: Cell.string(row[0]), table: Cell.string(row[1]),
                                        index: Cell.string(row[2]), bytes: Cell.int(row[3]) ?? 0)
            }
        }
        if let rows = await attempt("noPrimaryKey", &facts, {
            try await session.execute("""
                SELECT n.nspname::text, c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind = 'r' AND n.nspname NOT IN \(Self.pgSystemSchemas) AND n.nspname NOT LIKE 'pg_toast%'
                  AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')
                ORDER BY 1, 2 LIMIT 100
                """).rows
        }) {
            facts.tablesWithoutPrimaryKey = rows.compactMap { Cell.pair($0) }
        }
    }

    /// `pg_settings` → the text `ALTER SYSTEM SET` accepts back ("4GB", "5min", "1000ms", "on").
    static func postgresDisplayValue(setting: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty, let number = Int64(setting), number >= 0 else { return setting }
        switch unit {
        case "8kB": return ByteSize.postgresValue(number * 8192)
        case "kB": return ByteSize.postgresValue(number * 1024)
        case "MB": return ByteSize.postgresValue(number * 1024 * 1024)
        case "ms", "s", "min", "h", "d": return "\(number)\(unit)"
        default: return setting
        }
    }

    // MARK: Helpers

    private func attempt<T>(_ section: String, _ facts: inout ServerFacts, _ body: () async throws -> T?) async -> T? {
        do {
            return try await body()
        } catch {
            facts.unavailable[section] = Self.reason(error)
            return nil
        }
    }

    static func reason(_ error: any Error) -> String {
        if let db = error as? DatabaseError { return QueryRunner.describe(db) }
        return String(describing: error)
    }

    private static func pairs(_ session: any DatabaseSession, _ sql: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try await session.execute(sql).rows where row.count >= 2 {
            out[Cell.string(row[0]).lowercased()] = Cell.string(row[1])
        }
        return out
    }
}

/// Tolerant conversions from driver values (drivers differ on integer / decimal / text typing).
enum Cell {
    static func string(_ value: DatabaseValue) -> String {
        if case .bytes(let data) = value { return String(decoding: data, as: UTF8.self) }
        return value.displayString
    }

    static func optionalString(_ value: DatabaseValue) -> String? {
        value.isNull ? nil : string(value)
    }

    static func int(_ value: DatabaseValue) -> Int64? {
        switch value {
        case .integer(let v): return v
        case .unsignedInteger(let v): return Int64(clamping: v)
        case .double(let v): return v.isFinite ? Int64(v) : nil
        case .bool(let v): return v ? 1 : 0
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return Int64(t) ?? Double(t).map { Int64($0) }
        case .bytes(let d):
            let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return Int64(t) ?? Double(t).map { Int64($0) }
        case .null: return nil
        }
    }

    /// "schema.table" from the first two columns.
    static func pair(_ row: [DatabaseValue]) -> String? {
        guard row.count >= 2 else { return nil }
        return "\(string(row[0])).\(string(row[1]))"
    }
}
