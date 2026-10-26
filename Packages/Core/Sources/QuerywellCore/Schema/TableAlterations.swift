import Foundation

// SQL for the table tab's Operations mode (phpMyAdmin-style): table options, rename / move, copy,
// maintenance commands and emptying. Pure: current metadata + requested change → statements.
// Everything is quoted through `SQLDialect`; engine / collation / row-format names are validated
// as plain identifiers because they are keywords in the statement, not literals.

public enum TableAlterationError: Error, Sendable, Equatable {
    /// The option doesn't exist on this engine (e.g. storage engine on PostgreSQL).
    case unsupported(String)
    /// A keyword-position value that isn't a plain identifier.
    case invalidName(String)
    /// Nothing differs from the current state.
    case noChange
    case invalidValue(String)

    /// Wording for the sections' inline error line.
    public var message: String {
        switch self {
        case .unsupported(let m), .invalidValue(let m): m
        case .invalidName(let n): "“\(n)” isn't a valid name."
        case .noChange: "Nothing to change."
        }
    }
}

/// The table-level settings Operations prefills, read by the inspectors.
public struct TableOptions: Sendable, Hashable {
    /// MySQL storage engine.
    public var engine: String?
    /// MySQL table default collation.
    public var collation: String?
    public var comment: String
    /// MySQL: the next AUTO_INCREMENT value; PostgreSQL: the next value of the table's identity / serial sequence.
    public var autoIncrement: Int64?
    /// MySQL `ROW_FORMAT` as the server reports it ("Dynamic"), nil for PostgreSQL.
    public var rowFormat: String?
    /// PostgreSQL: the sequence behind the first identity / serial column.
    public var sequence: TableRef?
    /// PostgreSQL: non-default tablespace.
    public var tablespace: String?

    public init(engine: String? = nil, collation: String? = nil, comment: String = "", autoIncrement: Int64? = nil,
                rowFormat: String? = nil, sequence: TableRef? = nil, tablespace: String? = nil) {
        self.engine = engine
        self.collation = collation
        self.comment = comment
        self.autoIncrement = autoIncrement
        self.rowFormat = rowFormat
        self.sequence = sequence
        self.tablespace = tablespace
    }
}

/// Requested values for the "Table options" section; nil / unchanged fields produce no SQL.
public struct TableOptionChanges: Sendable, Hashable {
    public var engine: String?
    public var collation: String?
    /// Also convert every text column to `collation` (`CONVERT TO CHARACTER SET … COLLATE …`).
    public var convertColumns = false
    public var comment: String?
    public var autoIncrement: Int64?
    public var rowFormat: String?
    public var tablespace: String?

    public init(engine: String? = nil, collation: String? = nil, convertColumns: Bool = false, comment: String? = nil,
                autoIncrement: Int64? = nil, rowFormat: String? = nil, tablespace: String? = nil) {
        self.engine = engine
        self.collation = collation
        self.convertColumns = convertColumns
        self.comment = comment
        self.autoIncrement = autoIncrement
        self.rowFormat = rowFormat
        self.tablespace = tablespace
    }
}

public struct AlterationPlan: Sendable, Hashable {
    public var statements: [String]
    public var warnings: [String]

    public init(statements: [String], warnings: [String] = []) {
        self.statements = statements
        self.warnings = warnings
    }

    /// The statements as shown in the preview box.
    public var script: String { statements.map { $0 + ";" }.joined(separator: "\n") }
}

public enum CopyMode: String, Sendable, CaseIterable, Hashable {
    case structureOnly, structureAndData, dataOnly
}

public struct CopyOptions: Sendable, Hashable {
    public var mode: CopyMode
    /// `DROP TABLE IF EXISTS <target>` first.
    public var dropTargetFirst: Bool
    /// MySQL: carry over the source's AUTO_INCREMENT counter.
    public var keepAutoIncrement: Bool
    /// Re-create the source's foreign keys on the copy.
    public var addConstraints: Bool

    public init(mode: CopyMode = .structureAndData, dropTargetFirst: Bool = false, keepAutoIncrement: Bool = false,
                addConstraints: Bool = false) {
        self.mode = mode
        self.dropTargetFirst = dropTargetFirst
        self.keepAutoIncrement = keepAutoIncrement
        self.addConstraints = addConstraints
    }
}

public enum TableMaintenanceCommand: String, Sendable, CaseIterable, Hashable, Identifiable {
    case analyze, check, checksum, optimize, repair, flush
    case vacuum, vacuumFull, reindex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .analyze: "Analyze"
        case .check: "Check"
        case .checksum: "Checksum"
        case .optimize: "Optimize"
        case .repair: "Repair"
        case .flush: "Flush"
        case .vacuum: "Vacuum"
        case .vacuumFull: "Vacuum full"
        case .reindex: "Reindex"
        }
    }

    /// One-line explanation shown beside the button.
    public var summary: String {
        switch self {
        case .analyze: "Refresh the key distribution statistics the optimizer uses."
        case .check: "Look for errors in the table."
        case .checksum: "Compute a checksum of the table contents."
        case .optimize: "Defragment and reclaim unused space."
        case .repair: "Repair a corrupted MyISAM / Aria / ARCHIVE / CSV table."
        case .flush: "Close the table and flush it to disk."
        case .vacuum: "Reclaim dead rows without blocking reads and writes."
        case .vacuumFull: "Rewrite the table to return space to the OS. Locks the table."
        case .reindex: "Rebuild every index on the table. Locks writes."
        }
    }
}

public enum TableAlterations {
    // MARK: Rename / move

    /// MySQL: `RENAME TABLE`. PostgreSQL: `ALTER TABLE … RENAME TO`.
    public static func rename(_ table: TableRef, to newName: String, dialect: SQLDialect) throws -> AlterationPlan {
        guard !newName.isEmpty, !newName.allSatisfy(\.isWhitespace) else { throw TableAlterationError.invalidValue("The new name is empty.") }
        guard newName != table.name else { throw TableAlterationError.noChange }
        switch dialect.family {
        case .mysql:
            let target = TableRef(schema: table.schema, name: newName)
            return AlterationPlan(statements: ["RENAME TABLE \(dialect.qualified(table)) TO \(dialect.qualified(target))"])
        case .postgres:
            return AlterationPlan(statements: ["ALTER TABLE \(dialect.qualified(table)) RENAME TO \(dialect.quoteIdentifier(newName))"])
        }
    }

    /// Moves a table to another database / schema (optionally under a new name).
    /// MySQL: one `RENAME TABLE`. PostgreSQL: `SET SCHEMA`, then `RENAME TO` when the name changes.
    public static func move(_ table: TableRef, to target: TableRef, dialect: SQLDialect) throws -> AlterationPlan {
        guard !target.name.isEmpty, !target.schema.isEmpty else { throw TableAlterationError.invalidValue("Choose a target and a table name.") }
        guard target != table else { throw TableAlterationError.noChange }
        switch dialect.family {
        case .mysql:
            return AlterationPlan(statements: ["RENAME TABLE \(dialect.qualified(table)) TO \(dialect.qualified(target))"])
        case .postgres:
            var statements: [String] = []
            var current = table
            if target.schema != table.schema {
                statements.append("ALTER TABLE \(dialect.qualified(table)) SET SCHEMA \(dialect.quoteIdentifier(target.schema))")
                current = TableRef(schema: target.schema, name: table.name)
            }
            if target.name != table.name {
                statements.append("ALTER TABLE \(dialect.qualified(current)) RENAME TO \(dialect.quoteIdentifier(target.name))")
            }
            return AlterationPlan(statements: statements)
        }
    }

    // MARK: Options

    /// Statements for the options that differ from `current`.
    public static func options(
        _ table: TableRef, current: TableOptions, changes: TableOptionChanges, dialect: SQLDialect
    ) throws -> AlterationPlan {
        switch dialect.family {
        case .mysql: try mysqlOptions(table, current: current, changes: changes, dialect: dialect)
        case .postgres: try postgresOptions(table, current: current, changes: changes, dialect: dialect)
        }
    }

    private static func mysqlOptions(
        _ table: TableRef, current: TableOptions, changes: TableOptionChanges, dialect: SQLDialect
    ) throws -> AlterationPlan {
        if changes.tablespace != nil { throw TableAlterationError.unsupported("Tablespaces are a PostgreSQL option here.") }
        var options: [String] = []
        var warnings: [String] = []
        var statements: [String] = []
        let alter = "ALTER TABLE \(dialect.qualified(table))"

        if let engine = changes.engine, !same(engine, current.engine) {
            try validateKeyword(engine)
            options.append("ENGINE=\(engine)")
        }
        var convert: String?
        if let collation = changes.collation, !collation.isEmpty {
            try validateKeyword(collation)
            if changes.convertColumns {
                convert = "\(alter) CONVERT TO CHARACTER SET \(charset(of: collation)) COLLATE \(collation)"
                warnings.append("Converting columns rewrites the table and can change how indexed text compares; try it on a copy first if unsure.")
            } else if !same(collation, current.collation) {
                options.append("COLLATE=\(collation)")
                warnings.append("Only the table default changes; existing columns keep their collation. Tick “change all column collations” to convert them too.")
            }
        }
        if let comment = changes.comment, comment != current.comment {
            options.append("COMMENT=\(dialect.quoteString(comment))")
        }
        if let value = changes.autoIncrement, value != current.autoIncrement {
            guard value >= 1 else { throw TableAlterationError.invalidValue("AUTO_INCREMENT must be at least 1.") }
            options.append("AUTO_INCREMENT=\(value)")
            warnings.append("The server ignores a value at or below the highest existing id.")
        }
        if let format = changes.rowFormat, !format.isEmpty, !same(format, current.rowFormat) {
            try validateKeyword(format)
            options.append("ROW_FORMAT=\(format.uppercased())")
        }
        if !options.isEmpty { statements.append(alter + " " + options.joined(separator: ", ")) }
        if let convert { statements.append(convert) }
        guard !statements.isEmpty else { throw TableAlterationError.noChange }
        return AlterationPlan(statements: statements, warnings: warnings)
    }

    private static func postgresOptions(
        _ table: TableRef, current: TableOptions, changes: TableOptionChanges, dialect: SQLDialect
    ) throws -> AlterationPlan {
        if changes.engine != nil { throw TableAlterationError.unsupported("PostgreSQL has no storage engines.") }
        if changes.collation != nil || changes.convertColumns {
            throw TableAlterationError.unsupported("PostgreSQL collations are set per column, not per table.")
        }
        if changes.rowFormat != nil { throw TableAlterationError.unsupported("ROW_FORMAT is a MySQL option.") }
        var statements: [String] = []
        var warnings: [String] = []
        if let comment = changes.comment, comment != current.comment {
            let literal = comment.isEmpty ? "NULL" : dialect.quoteString(comment)
            statements.append("COMMENT ON TABLE \(dialect.qualified(table)) IS \(literal)")
        }
        if let space = changes.tablespace, !space.isEmpty, space != current.tablespace {
            statements.append("ALTER TABLE \(dialect.qualified(table)) SET TABLESPACE \(dialect.quoteIdentifier(space))")
            warnings.append("Moving a table to another tablespace copies its files and locks the table meanwhile.")
        }
        if let value = changes.autoIncrement, value != current.autoIncrement {
            guard let sequence = current.sequence else {
                throw TableAlterationError.unsupported("This table has no identity or serial column to restart.")
            }
            guard value >= 1 else { throw TableAlterationError.invalidValue("The sequence value must be at least 1.") }
            statements.append("ALTER SEQUENCE \(dialect.qualified(sequence)) RESTART WITH \(value)")
        }
        guard !statements.isEmpty else { throw TableAlterationError.noChange }
        return AlterationPlan(statements: statements, warnings: warnings)
    }

    // MARK: Copy

    /// Copies `source` to `target` (which may be in another database / schema).
    /// - Parameters:
    ///   - source: the source's structure; supplies the foreign keys.
    ///   - autoIncrement: the source's current AUTO_INCREMENT counter, used with `keepAutoIncrement` (MySQL).
    public static func copy(
        _ source: TableStructure, to target: TableRef, options: CopyOptions, autoIncrement: Int64? = nil, dialect: SQLDialect
    ) throws -> AlterationPlan {
        let from = source.info.ref
        guard source.info.kind == .table else { throw TableAlterationError.unsupported("Only tables can be copied.") }
        guard !target.name.isEmpty, !target.schema.isEmpty else { throw TableAlterationError.invalidValue("Choose a target and a table name.") }
        guard target != from else { throw TableAlterationError.invalidValue("The copy needs a different name or database.") }
        let src = dialect.qualified(from), dst = dialect.qualified(target)
        var statements: [String] = []
        var warnings: [String] = []
        let withStructure = options.mode != .dataOnly
        let withData = options.mode != .structureOnly

        if withStructure {
            if options.dropTargetFirst { statements.append("DROP TABLE IF EXISTS \(dst)") }
            switch dialect.family {
            case .mysql:
                statements.append("CREATE TABLE \(dst) LIKE \(src)")
            case .postgres:
                statements.append("CREATE TABLE \(dst) (LIKE \(src) INCLUDING ALL)")
                if source.columns.contains(where: { $0.defaultExpression?.lowercased().contains("nextval(") == true }) {
                    warnings.append("Serial columns keep sharing the source's sequence; give the copy its own if both tables will insert.")
                }
            }
        }
        if withData {
            statements.append("INSERT INTO \(dst) SELECT * FROM \(src)")
        }
        if withStructure {
            if options.addConstraints {
                for fk in source.foreignKeys { statements.append(foreignKeyStatement(fk, on: target, copyOf: from, dialect: dialect)) }
                if source.foreignKeys.isEmpty { warnings.append("The source has no foreign keys to add.") }
            } else if dialect.family == .mysql, !source.foreignKeys.isEmpty {
                warnings.append("Foreign keys are not copied unless “add constraints” is ticked (MySQL's LIKE leaves them out).")
            }
            if options.keepAutoIncrement, dialect.family == .mysql, let value = autoIncrement, value > 1 {
                statements.append("ALTER TABLE \(dst) AUTO_INCREMENT = \(value)")
            }
        }
        return AlterationPlan(statements: statements, warnings: warnings)
    }

    private static func foreignKeyStatement(
        _ fk: ForeignKeyDefinition, on target: TableRef, copyOf source: TableRef, dialect: SQLDialect
    ) -> String {
        // MySQL constraint names are unique per database, so the server names the copy's; PostgreSQL's are per table.
        let name = dialect.family == .postgres ? "CONSTRAINT \(dialect.quoteIdentifier(fk.name)) " : ""
        let referenced = fk.referenced == source ? target : fk.referenced  // a self-reference follows the copy
        let local = fk.columns.map(dialect.quoteIdentifier).joined(separator: ", ")
        let remote = fk.referencedColumns.map(dialect.quoteIdentifier).joined(separator: ", ")
        var sql = "ALTER TABLE \(dialect.qualified(target)) ADD \(name)FOREIGN KEY (\(local)) REFERENCES \(dialect.qualified(referenced)) (\(remote))"
        // NO ACTION is the default; on MySQL RESTRICT is the same thing, on PostgreSQL it is not.
        func isDefault(_ action: String) -> Bool { action == "NO ACTION" || (dialect.family == .mysql && action == "RESTRICT") }
        if let onUpdate = fk.onUpdate, !isDefault(onUpdate) { sql += " ON UPDATE \(onUpdate)" }
        if let onDelete = fk.onDelete, !isDefault(onDelete) { sql += " ON DELETE \(onDelete)" }
        return sql
    }

    // MARK: Maintenance

    /// The commands that apply to a table of this engine, in display order.
    public static func availableMaintenance(dialect: SQLDialect, storageEngine: String?) -> [TableMaintenanceCommand] {
        switch dialect.family {
        case .mysql:
            var commands: [TableMaintenanceCommand] = [.analyze, .check, .checksum, .optimize, .flush]
            if let engine = storageEngine?.lowercased(), ["myisam", "aria", "archive", "csv"].contains(engine) { commands.append(.repair) }
            return commands
        case .postgres:
            return [.analyze, .vacuum, .vacuumFull, .reindex]
        }
    }

    public static func maintenance(_ command: TableMaintenanceCommand, on table: TableRef, dialect: SQLDialect) throws -> String {
        let name = dialect.qualified(table)
        switch (dialect.family, command) {
        case (.mysql, .analyze): return "ANALYZE TABLE \(name)"
        case (.mysql, .check): return "CHECK TABLE \(name)"
        case (.mysql, .checksum): return "CHECKSUM TABLE \(name)"
        case (.mysql, .optimize): return "OPTIMIZE TABLE \(name)"
        case (.mysql, .repair): return "REPAIR TABLE \(name)"
        case (.mysql, .flush): return "FLUSH TABLE \(name)"
        case (.postgres, .analyze): return "ANALYZE \(name)"
        case (.postgres, .vacuum): return "VACUUM \(name)"
        case (.postgres, .vacuumFull): return "VACUUM (FULL) \(name)"
        case (.postgres, .reindex): return "REINDEX TABLE \(name)"
        default: throw TableAlterationError.unsupported("\(command.title) isn't available on this server.")
        }
    }

    // MARK: Empty

    /// `DELETE FROM` (row by row, fires triggers, keeps the counter) as opposed to `TRUNCATE`.
    public static func deleteAllRows(_ table: TableRef, dialect: SQLDialect) -> String {
        "DELETE FROM \(dialect.qualified(table))"
    }

    // MARK: Helpers

    /// `utf8mb4_unicode_ci` → `utf8mb4`; a bare name such as `binary` is its own charset.
    static func charset(of collation: String) -> String {
        collation.firstIndex(of: "_").map { String(collation[..<$0]) } ?? collation
    }

    private static func same(_ a: String, _ b: String?) -> Bool {
        b.map { a.caseInsensitiveCompare($0) == .orderedSame } ?? false
    }

    private static func validateKeyword(_ name: String) throws {
        let ok = !name.isEmpty && name.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "_"
        }
        guard ok else { throw TableAlterationError.invalidName(name) }
    }
}
