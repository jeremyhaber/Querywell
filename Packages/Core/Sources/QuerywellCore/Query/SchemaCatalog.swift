import Foundation

/// A pure, lazily filled snapshot of the schema objects the editor can complete against:
/// schemas → tables (cheap, one listing per schema) → columns (loaded per table on demand) and routines.
///
/// The catalog never touches the network; ``SchemaCatalogLoader`` fills it from a ``SchemaInspector``.
/// Completion reports which tables it needed but didn't have (``CompletionResult/missingColumns``) so the
/// caller can load them and ask again.
public struct SchemaCatalog: Sendable {
    public private(set) var schemas: [String]
    private var tablesBySchema: [String: [TableInfo]]
    private var columnsByTable: [TableRef: [ColumnDefinition]]
    private var routinesBySchema: [String: [RoutineInfo]]

    public init(
        schemas: [String] = [],
        tables: [String: [TableInfo]] = [:],
        columns: [TableRef: [ColumnDefinition]] = [:],
        routines: [String: [RoutineInfo]] = [:]
    ) {
        self.schemas = schemas
        tablesBySchema = tables
        columnsByTable = columns
        routinesBySchema = routines
    }

    // MARK: Queries

    public func tables(in schema: String) -> [TableInfo] {
        tablesBySchema[schema] ?? tablesBySchema.first { $0.key.caseInsensitiveCompare(schema) == .orderedSame }?.value ?? []
    }

    public func hasLoadedTables(in schema: String) -> Bool {
        tablesBySchema[schema] != nil
    }

    public func routines(in schema: String) -> [RoutineInfo] {
        routinesBySchema[schema] ?? []
    }

    /// The canonical spelling of a schema name (`"WP"` → `"wp"`), nil when unknown.
    public func schema(named name: String) -> String? {
        if schemas.contains(name) { return name }
        return schemas.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Finds a table by name in `schema`, exact match first, then case-insensitive.
    public func table(_ name: String, in schema: String) -> TableInfo? {
        let list = tables(in: schema)
        return list.first { $0.ref.name == name } ?? list.first { $0.ref.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Columns of `ref` when loaded (nil = not loaded yet, empty = loaded and has none).
    public func columns(of ref: TableRef) -> [ColumnDefinition]? {
        if let c = columnsByTable[ref] { return c }
        guard let canonical = table(ref.name, in: ref.schema)?.ref else { return nil }
        return columnsByTable[canonical]
    }

    /// Canonical `TableRef` for a possibly differently-cased reference, when the table is known.
    public func canonical(_ ref: TableRef) -> TableRef? {
        let s = schema(named: ref.schema) ?? ref.schema
        return table(ref.name, in: s)?.ref
    }

    // MARK: Filling

    public mutating func setSchemas(_ names: [String]) { schemas = names }
    public mutating func setTables(_ tables: [TableInfo], in schema: String) { tablesBySchema[schema] = tables }
    public mutating func setColumns(_ columns: [ColumnDefinition], for ref: TableRef) { columnsByTable[ref] = columns }
    public mutating func setRoutines(_ routines: [RoutineInfo], in schema: String) { routinesBySchema[schema] = routines }

    /// Adds a fully loaded structure (tables list entry is added if the schema's list lacks it).
    public mutating func add(_ structure: TableStructure) {
        let ref = structure.info.ref
        columnsByTable[ref] = structure.columns
        var list = tablesBySchema[ref.schema] ?? []
        if !list.contains(where: { $0.ref == ref }) {
            list.append(structure.info)
            tablesBySchema[ref.schema] = list
        }
        if !schemas.contains(ref.schema) { schemas.append(ref.schema) }
    }
}

/// Fills a ``SchemaCatalog`` from a live inspector, on demand. Holds the latest snapshot.
public actor SchemaCatalogLoader {
    private let inspector: any SchemaInspector
    public private(set) var catalog = SchemaCatalog()
    private var loadingColumns: Set<TableRef> = []

    public init(inspector: any SchemaInspector) {
        self.inspector = inspector
    }

    /// Loads the schema list and the table list of `schemas` (usually just the current one).
    public func loadOverview(schemas wanted: [String]) async throws {
        catalog.setSchemas(try await inspector.listSchemas())
        for schema in wanted where !catalog.hasLoadedTables(in: schema) {
            catalog.setTables(try await inspector.listTables(schema: schema), in: schema)
            catalog.setRoutines((try? await inspector.listRoutines(schema: schema)) ?? [], in: schema)
        }
    }

    /// Loads the table list of `schema` if not loaded yet (e.g. after the user typed `other_db.`).
    public func loadTables(in schema: String) async throws {
        guard !catalog.hasLoadedTables(in: schema) else { return }
        catalog.setTables(try await inspector.listTables(schema: schema), in: schema)
    }

    /// Loads columns for each table not yet in the catalog. Failures for single tables are skipped.
    public func loadColumns(for refs: [TableRef]) async {
        for ref in refs where catalog.columns(of: ref) == nil && !loadingColumns.contains(ref) {
            loadingColumns.insert(ref)
            defer { loadingColumns.remove(ref) }
            if let structure = try? await inspector.structure(of: ref) { catalog.add(structure) }
        }
    }

    /// Completes, loading whatever the first pass reported missing, then completes again.
    public func complete(
        text: String, cursor: Int, dialect: SQLDialect, currentSchema: String?, limit: Int = 60
    ) async -> CompletionResult {
        let first = SQLCompletion.complete(text: text, cursor: cursor, dialect: dialect, catalog: catalog,
                                           currentSchema: currentSchema, limit: limit)
        guard !first.missingColumns.isEmpty else { return first }
        await loadColumns(for: first.missingColumns)
        return SQLCompletion.complete(text: text, cursor: cursor, dialect: dialect, catalog: catalog,
                                      currentSchema: currentSchema, limit: limit)
    }
}
