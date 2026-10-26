import Foundation

// Batch table operations (PROGRESS.md "Scope additions" B, DECISIONS #18): change storage engine and
// convert charset/collation for many tables at once. MySQL/MariaDB only.

public enum MaintenanceChange: Sendable, Hashable {
    /// `ALTER TABLE … ENGINE=<name>`
    case engine(String)
    /// `ALTER TABLE … CONVERT TO CHARACTER SET <charset> COLLATE <collation>`
    case convert(charset: String, collation: String)
}

public enum MaintenanceError: Error, Sendable, Equatable {
    /// Postgres has no storage engines / table-level charsets.
    case unsupported(String)
    /// An engine, charset or collation name that isn't a plain identifier (never interpolated into SQL).
    case invalidName(String)
    case collationDoesNotBelongToCharset(charset: String, collation: String)
}

public struct MaintenanceStep: Sendable, Hashable, Identifiable {
    public enum Target: Sendable, Hashable {
        case table(TableRef)
        case database(String)
    }

    /// Position in the plan (stable id for progress rows).
    public var id: Int
    public var target: Target
    public var sql: String
    /// Non-nil when the step won't run, with the reason ("Already InnoDB", "View").
    public var skipped: String?

    public init(id: Int, target: Target, sql: String, skipped: String? = nil) {
        self.id = id
        self.target = target
        self.sql = sql
        self.skipped = skipped
    }

    /// The table this step alters; nil for the database-default step.
    public var table: TableRef? {
        if case .table(let t) = target { return t }
        return nil
    }

    /// Short label for progress rows.
    public var title: String {
        switch target {
        case .table(let t): t.name
        case .database(let d): "Database \(d)"
        }
    }
}

public struct MaintenancePlan: Sendable, Hashable {
    public var steps: [MaintenanceStep]
    public var warnings: [String]

    public init(steps: [MaintenanceStep], warnings: [String]) {
        self.steps = steps
        self.warnings = warnings
    }

    public var runnableSteps: [MaintenanceStep] { steps.filter { $0.skipped == nil } }
    public var skippedSteps: [MaintenanceStep] { steps.filter { $0.skipped != nil } }

    /// The exact statements that will run, in order (for the preview / Copy).
    public var statements: [String] { runnableSteps.map(\.sql) }

    /// Nothing to do.
    public var isEmpty: Bool { runnableSteps.isEmpty }
}

/// Pure planner: current table metadata + requested change → ordered `ALTER` statements and warnings.
public enum TableMaintenancePlanner {
    /// - Parameters:
    ///   - tables: the user's selection (tables and views; views are skipped).
    ///   - structures: optional per-table structure; enables FK / FULLTEXT / index-length warnings and
    ///     column-level collation checks.
    ///   - alsoSetDatabaseDefault: for `.convert`, also `ALTER DATABASE … CHARACTER SET … COLLATE …`
    ///     for each schema involved (runs after the tables).
    ///   - server: version drives the old-server warnings.
    public static func plan(
        tables: [TableInfo],
        structures: [TableRef: TableStructure] = [:],
        change: MaintenanceChange,
        alsoSetDatabaseDefault: Bool = false,
        server: ServerInfo
    ) throws -> MaintenancePlan {
        guard server.engine != .postgresql else {
            throw MaintenanceError.unsupported(
                "Storage engines and table character sets are MySQL/MariaDB features; PostgreSQL tables can't be changed this way.")
        }
        let dialect = SQLDialect(server.engine)

        switch change {
        case .engine(let name):
            try validate(name)
        case .convert(let charset, let collation):
            try validate(charset)
            try validate(collation)
            let prefixes = charsetAliases(charset).map { $0 + "_" }
            guard collation.lowercased() == charset.lowercased() || prefixes.contains(where: { collation.lowercased().hasPrefix($0) }) else {
                throw MaintenanceError.collationDoesNotBelongToCharset(charset: charset, collation: collation)
            }
        }

        var steps: [MaintenanceStep] = []
        var warnings: [String] = []
        let selected = Set(tables.map(\.ref))

        for info in tables {
            let ref = info.ref
            let target = MaintenanceStep.Target.table(ref)
            func add(_ sql: String, skipped: String? = nil) {
                steps.append(MaintenanceStep(id: steps.count, target: target, sql: sql, skipped: skipped))
            }

            switch change {
            case .engine(let engine):
                let sql = "ALTER TABLE \(dialect.qualified(ref)) ENGINE=\(engine)"
                if info.kind != .table { add(sql, skipped: "Views have no storage engine"); continue }
                if let current = info.engine, current.caseInsensitiveCompare(engine) == .orderedSame {
                    add(sql, skipped: "Already \(current)")
                    continue
                }
                add(sql)
                warnings += engineWarnings(info, to: engine, structure: structures[ref], server: server)

            case .convert(let charset, let collation):
                let sql = "ALTER TABLE \(dialect.qualified(ref)) CONVERT TO CHARACTER SET \(charset) COLLATE \(collation)"
                if info.kind != .table { add(sql, skipped: "Views have no character set"); continue }
                if let current = info.collation, current.caseInsensitiveCompare(collation) == .orderedSame,
                   columnsAlreadyMatch(structures[ref], collation: collation) {
                    add(sql, skipped: "Already \(current)")
                    continue
                }
                add(sql)
                warnings += convertWarnings(info, charset: charset, structure: structures[ref], selected: selected, server: server)
            }
        }

        if case .convert(let charset, let collation) = change, alsoSetDatabaseDefault {
            var seen = Set<String>()
            for info in tables where seen.insert(info.ref.schema).inserted {
                let db = info.ref.schema
                steps.append(MaintenanceStep(
                    id: steps.count, target: .database(db),
                    sql: "ALTER DATABASE \(dialect.quoteIdentifier(db)) CHARACTER SET \(charset) COLLATE \(collation)"))
            }
        }

        let runnable = steps.filter { $0.skipped == nil }
        if !runnable.isEmpty {
            warnings.insert(
                "ALTER TABLE is not transactional: each table is changed on its own and a failure part-way leaves earlier tables converted.",
                at: 0)
        }
        // Large tables (once per table, regardless of change type).
        for info in tables where info.kind == .table && runnable.contains(where: { $0.table == info.ref }) {
            if let big = largeTableWarning(info) { warnings.append(big) }
        }

        // De-duplicate while keeping order.
        var seenWarnings = Set<String>()
        warnings = warnings.filter { seenWarnings.insert($0).inserted }
        return MaintenancePlan(steps: steps, warnings: warnings)
    }

    // MARK: Validation

    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }) else {
            throw MaintenanceError.invalidName(name)
        }
    }

    private static func charsetAliases(_ charset: String) -> [String] {
        let c = charset.lowercased()
        return (c == "utf8" || c == "utf8mb3") ? ["utf8", "utf8mb3"] : [c]
    }

    private static func columnsAlreadyMatch(_ s: TableStructure?, collation: String) -> Bool {
        guard let s else { return true } // table default is all we know
        return s.columns.allSatisfy { c in
            guard let cc = c.collation else { return true }
            return cc.caseInsensitiveCompare(collation) == .orderedSame
        }
    }

    // MARK: Engine warnings

    private static func engineWarnings(_ info: TableInfo, to engine: String, structure: TableStructure?, server: ServerInfo) -> [String] {
        var out: [String] = []
        let name = info.ref.name
        let from = info.engine?.uppercased() ?? ""
        let to = engine.uppercased()

        if from == "INNODB", to != "INNODB" {
            if let s = structure {
                if !s.foreignKeys.isEmpty || !s.referencedBy.isEmpty {
                    let related = (s.foreignKeys.map(\.referenced.name) + s.referencedBy.map(\.referenced.name)).joined(separator: ", ")
                    out.append("`\(name)` has foreign keys (\(related.isEmpty ? "see Relations" : related)); \(engine) doesn't support them, so they are dropped or the change fails.")
                }
            } else {
                out.append("Leaving InnoDB drops foreign key support: tables that have or are referenced by foreign keys can't be changed to \(engine).")
            }
        }

        if from == "MYISAM", to == "INNODB", isOldForInnoDBFulltext(server) {
            let hasFulltext = structure?.indexes.contains { ($0.method ?? "").uppercased() == "FULLTEXT" } ?? false
            if hasFulltext {
                out.append("`\(name)` has FULLTEXT indexes, which InnoDB doesn't support before MySQL 5.6 / MariaDB 10.0 (this is \(server.shortDescription)).")
            } else if structure == nil {
                out.append("FULLTEXT indexes are not supported by InnoDB before MySQL 5.6 / MariaDB 10.0 (this is \(server.shortDescription)); check tables that use them.")
            }
        }

        switch to {
        case "MEMORY", "HEAP":
            out.append("MEMORY tables lose all rows when the server restarts and can't hold BLOB/TEXT columns.")
            if let s = structure, s.columns.contains(where: { $0.dataType.contains("blob") || $0.dataType.contains("text") || $0.dataType == "json" }) {
                out.append("`\(name)` has BLOB/TEXT/JSON columns, so converting it to MEMORY will fail.")
            }
        case "ARCHIVE":
            out.append("ARCHIVE tables allow only INSERT and SELECT (no UPDATE or DELETE) and no indexes except on an AUTO_INCREMENT column.")
        case "CSV":
            out.append("CSV tables have no indexes and all columns must be NOT NULL.")
        case "BLACKHOLE":
            out.append("BLACKHOLE tables discard every row written to them: converting a table to BLACKHOLE destroys its data.")
        case "MYISAM", "ARIA":
            if from == "INNODB" || from.isEmpty {
                out.append("\(engine) has no transactions and is not crash-safe; foreign keys are not enforced.")
            }
        default: break
        }
        return out
    }

    private static func isOldForInnoDBFulltext(_ server: ServerInfo) -> Bool {
        switch server.engine {
        case .mysql: server.major < 5 || (server.major == 5 && server.minor < 6)
        case .mariadb: server.major < 10
        case .postgresql: false
        }
    }

    // MARK: Charset warnings

    private static func convertWarnings(
        _ info: TableInfo, charset: String, structure: TableStructure?, selected: Set<TableRef>, server: ServerInfo
    ) -> [String] {
        var out: [String] = []
        let name = info.ref.name

        if let s = structure {
            // Foreign keys to tables outside the selection.
            let outside = Set((s.foreignKeys.map(\.referenced) + s.referencedBy.map(\.referenced)).filter { !selected.contains($0) })
            if !outside.isEmpty, !(s.foreignKeys.isEmpty && s.referencedBy.isEmpty) {
                let names = outside.map(\.name).sorted().joined(separator: ", ")
                out.append("`\(name)` is linked by foreign keys to \(names), which isn't part of this change; converting only one side of a foreign key can fail with incompatible column types.")
            }

            // Index key length after conversion.
            let engine = (info.engine ?? "InnoDB").uppercased()
            let limit = indexKeyLimit(engine: engine, server: server)
            let perChar = bytesPerCharacter(charset)
            for idx in s.indexes where !(idx.method ?? "").uppercased().contains("FULLTEXT") {
                var total = 0
                for colName in idx.columns {
                    guard let col = s.columns.first(where: { $0.name == colName }),
                          let n = charLength(col.fullType) else { continue }
                    total += n * perChar
                }
                if total > limit.bytes {
                    out.append("Index `\(idx.name)` on `\(name)` may exceed the \(limit.bytes)-byte key limit after converting to \(charset) (about \(total) bytes at \(perChar) bytes per character, \(limit.basis)).")
                }
            }
        } else {
            let perChar = bytesPerCharacter(charset)
            if perChar >= 4 {
                out.append("Converting to \(charset) uses up to \(perChar) bytes per character; indexes on long VARCHAR columns may exceed the server's index key length limit (767 bytes on older row formats, 3072 on InnoDB DYNAMIC).")
            }
        }
        return out
    }

    private static func indexKeyLimit(engine: String, server: ServerInfo) -> (bytes: Int, basis: String) {
        if engine == "MYISAM" || engine == "ARIA" { return (1000, "MyISAM limit") }
        let dynamicDefault: Bool
        switch server.engine {
        case .mysql: dynamicDefault = server.major > 5 || (server.major == 5 && (server.minor > 7 || (server.minor == 7 && server.patch >= 7)))
        case .mariadb: dynamicDefault = server.major > 10 || (server.major == 10 && (server.minor > 2 || (server.minor == 2 && server.patch >= 2)))
        case .postgresql: dynamicDefault = true
        }
        return dynamicDefault ? (3072, "InnoDB DYNAMIC row format assumed") : (767, "older server defaults to COMPACT rows")
    }

    static func bytesPerCharacter(_ charset: String) -> Int {
        switch charset.lowercased() {
        case "latin1", "ascii", "binary", "cp1250", "cp1251", "cp1252", "cp850", "koi8r", "koi8u", "armscii8", "greek", "hebrew", "latin2", "latin5", "latin7": 1
        case "utf8", "utf8mb3": 3
        case "ucs2", "gbk", "big5", "sjis", "euckr", "gb2312", "cp932": 2
        case "ujis", "eucjpms": 3
        default: 4 // utf8mb4, utf16, utf32, gb18030, unknown → worst case
        }
    }

    /// `varchar(255)` / `char(10)` → 255 / 10; nil for other types.
    static func charLength(_ fullType: String) -> Int? {
        let t = fullType.lowercased()
        guard t.hasPrefix("varchar(") || t.hasPrefix("char(") else { return nil }
        guard let open = t.firstIndex(of: "("), let close = t.firstIndex(of: ")"), open < close else { return nil }
        return Int(t[t.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    private static func largeTableWarning(_ info: TableInfo) -> String? {
        let rows = info.estimatedRows ?? 0
        let bytes = (info.dataBytes ?? 0) + (info.indexBytes ?? 0)
        guard rows > 1_000_000 || bytes > 1 << 30 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "`\(info.ref.name)` is large (about \(rows.formatted()) rows, \(size)); rebuilding it can take a long time and block writes."
    }
}
