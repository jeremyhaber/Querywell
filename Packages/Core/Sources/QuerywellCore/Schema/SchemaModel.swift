import Foundation

// Shared schema contracts for the table browser (Phase 4). Engine-specific introspection
// lives in Schema/MySQL and Schema/Postgres behind `SchemaInspector`.
//
// Namespacing (DECISIONS #29): `schema` is the MySQL/MariaDB *database* or the Postgres
// *schema* inside the session's current database. Switching Postgres databases reconnects.

/// A table or view, addressed independent of the session's current database.
public struct TableRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var schema: String
    public var name: String

    public init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }

    public var description: String { "\(schema).\(name)" }
}

public enum TableKind: String, Sendable, Codable, Hashable {
    case table, view, materializedView
}

/// Sidebar-level facts about a table. Sizes/counts are server estimates and may be nil.
public struct TableInfo: Hashable, Sendable, Identifiable {
    public var ref: TableRef
    public var kind: TableKind
    /// MySQL storage engine ("InnoDB", "MyISAM"); nil for views and Postgres.
    public var engine: String?
    /// Estimated row count (MySQL `TABLE_ROWS`, Postgres `reltuples`); not exact.
    public var estimatedRows: Int64?
    public var dataBytes: Int64?
    public var indexBytes: Int64?
    /// Table default collation (MySQL); nil for Postgres.
    public var collation: String?
    public var comment: String?

    public var id: TableRef { ref }

    public init(ref: TableRef, kind: TableKind, engine: String? = nil, estimatedRows: Int64? = nil,
                dataBytes: Int64? = nil, indexBytes: Int64? = nil, collation: String? = nil, comment: String? = nil) {
        self.ref = ref
        self.kind = kind
        self.engine = engine
        self.estimatedRows = estimatedRows
        self.dataBytes = dataBytes
        self.indexBytes = indexBytes
        self.collation = collation
        self.comment = comment
    }
}

/// A column's full definition (Structure view, editing, filters).
public struct ColumnDefinition: Hashable, Sendable, Identifiable {
    public var name: String
    /// 1-based position.
    public var ordinal: Int
    /// Base type, lowercased: "varchar", "bigint", "jsonb", "enum".
    public var dataType: String
    /// Full declared type: "varchar(255)", "bigint(20) unsigned", "enum('a','b')", "numeric(10,2)".
    public var fullType: String
    public var isNullable: Bool
    /// Default expression as the server reports it (already SQL text), nil when none.
    public var defaultExpression: String?
    public var isPrimaryKey: Bool
    /// AUTO_INCREMENT / identity / serial.
    public var isAutoIncrement: Bool
    public var characterSet: String?
    public var collation: String?
    public var comment: String?
    /// Allowed values for enum/set types.
    public var enumValues: [String]?

    public var id: String { name }

    public init(name: String, ordinal: Int, dataType: String, fullType: String, isNullable: Bool,
                defaultExpression: String? = nil, isPrimaryKey: Bool = false, isAutoIncrement: Bool = false,
                characterSet: String? = nil, collation: String? = nil, comment: String? = nil, enumValues: [String]? = nil) {
        self.name = name
        self.ordinal = ordinal
        self.dataType = dataType
        self.fullType = fullType
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.enumValues = enumValues
    }
}

public struct IndexDefinition: Hashable, Sendable, Identifiable {
    public var name: String
    /// Column names (or expressions for functional indexes) in key order.
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    /// "BTREE", "HASH", "FULLTEXT", "SPATIAL", "gin", "gist", …
    public var method: String?
    /// Partial index predicate (Postgres), nil otherwise.
    public var predicate: String?

    public var id: String { name }

    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool, method: String? = nil, predicate: String? = nil) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.predicate = predicate
    }
}

public struct ForeignKeyDefinition: Hashable, Sendable, Identifiable {
    public var name: String
    /// The table that owns the constraint (the referencing side). Always set by the inspectors;
    /// needed for `TableStructure.referencedBy`, where it is the *other* table.
    public var table: TableRef?
    public var columns: [String]
    public var referenced: TableRef
    public var referencedColumns: [String]
    /// "CASCADE", "SET NULL", "RESTRICT", "NO ACTION", "SET DEFAULT".
    public var onUpdate: String?
    public var onDelete: String?

    public var id: String { name }

    public init(name: String, columns: [String], referenced: TableRef, referencedColumns: [String],
                onUpdate: String? = nil, onDelete: String? = nil, table: TableRef? = nil) {
        self.name = name
        self.table = table
        self.columns = columns
        self.referenced = referenced
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

/// Everything the Structure / Indexes / Relations views and the editor need about one table.
public struct TableStructure: Hashable, Sendable {
    public var info: TableInfo
    public var columns: [ColumnDefinition]
    public var indexes: [IndexDefinition]
    /// Outgoing FKs (this table references others).
    public var foreignKeys: [ForeignKeyDefinition]
    /// Incoming FKs (other tables reference this one), for the Relations view.
    public var referencedBy: [ForeignKeyDefinition]
    /// `SHOW CREATE TABLE` / reconstructed DDL, when available.
    public var createStatement: String?

    public init(info: TableInfo, columns: [ColumnDefinition], indexes: [IndexDefinition],
                foreignKeys: [ForeignKeyDefinition], referencedBy: [ForeignKeyDefinition], createStatement: String? = nil) {
        self.info = info
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.referencedBy = referencedBy
        self.createStatement = createStatement
    }

    /// Primary-key columns in key order; empty when the table has none (rows aren't editable).
    public var primaryKey: [String] {
        indexes.first(where: \.isPrimary)?.columns ?? columns.filter(\.isPrimaryKey).map(\.name)
    }
}

public enum RoutineKind: String, Sendable, Codable, Hashable { case procedure, function }

public struct RoutineInfo: Hashable, Sendable, Identifiable {
    public var schema: String
    public var name: String
    public var kind: RoutineKind
    public var id: String { "\(schema).\(name).\(kind.rawValue)" }

    public init(schema: String, name: String, kind: RoutineKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}

/// Reads schema metadata over an open session. One per session; implementations may cache.
public protocol SchemaInspector: Sendable {
    /// MySQL: databases; Postgres: schemas in the current database (system ones excluded).
    func listSchemas() async throws -> [String]
    /// Tables and views (with estimates) in `schema`, sorted by name.
    func listTables(schema: String) async throws -> [TableInfo]
    func listRoutines(schema: String) async throws -> [RoutineInfo]
    func structure(of table: TableRef) async throws -> TableStructure
    /// Character sets/collations the server supports (MySQL `SHOW COLLATION`); empty for Postgres.
    func availableCollations() async throws -> [CollationInfo]
    /// Storage engines the server supports (MySQL `SHOW ENGINES`, enabled ones); empty for Postgres.
    func availableEngines() async throws -> [String]
    /// Engine, collation, comment, counter, row format … for the Operations tab.
    func tableOptions(of table: TableRef) async throws -> TableOptions
    /// The table's triggers, sorted by name (MySQL: by timing, event and order).
    func triggers(on table: TableRef) async throws -> [TriggerInfo]
    /// `SHOW CREATE TRIGGER` / `pg_get_triggerdef`.
    func triggerDefinition(_ trigger: TriggerInfo) async throws -> String
    /// PostgreSQL: argument-less functions returning `trigger` in `schema`; empty for MySQL.
    func triggerFunctions(schema: String) async throws -> [TableRef]
    /// PostgreSQL `pg_get_functiondef`; nil for MySQL or a missing function.
    func functionDefinition(_ function: TableRef) async throws -> String?
}

/// Defaults so lightweight inspectors (tests, stubs) only implement what they use.
extension SchemaInspector {
    public func tableOptions(of table: TableRef) async throws -> TableOptions { TableOptions() }
    public func triggers(on table: TableRef) async throws -> [TriggerInfo] { [] }
    public func triggerDefinition(_ trigger: TriggerInfo) async throws -> String { "" }
    public func triggerFunctions(schema: String) async throws -> [TableRef] { [] }
    public func functionDefinition(_ function: TableRef) async throws -> String? { nil }
}

public struct CollationInfo: Hashable, Sendable {
    public var name: String
    public var characterSet: String
    public var isDefault: Bool

    public init(name: String, characterSet: String, isDefault: Bool) {
        self.name = name
        self.characterSet = characterSet
        self.isDefault = isDefault
    }
}
