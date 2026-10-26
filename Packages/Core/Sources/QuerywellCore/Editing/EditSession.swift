import Foundation

// Inline grid editing with review (DECISIONS #29 addressing, brief safety rule: nothing is written
// until the user opens Review, sees the exact SQL and commits; Discard reverts).
//
// `EditSession` is a pure value: it records pending changes and renders them to SQL through
// `SQLDialect`. `commit(on:)` runs exactly the statements `statements(dialect:)` returns.

public enum EditSessionError: Error, Sendable, Equatable {
    /// The table has no primary key, so rows can't be addressed safely.
    case noPrimaryKey
    case unknownColumn(String)
    /// A primary-key column isn't among the supplied column definitions.
    case primaryKeyColumnMissing(String)
    /// A row key doesn't hold one value per primary-key column, or holds NULL.
    case invalidRowKey
}

/// Identifies a row by its primary-key values, in primary-key order.
public struct RowKey: Hashable, Sendable {
    public var values: [DatabaseValue]

    public init(_ values: [DatabaseValue]) { self.values = values }

    /// Builds a key from a full row (`column name → value`); nil if a key column is missing.
    public static func make(primaryKey: [String], row: [String: DatabaseValue]) -> RowKey? {
        var out: [DatabaseValue] = []
        for c in primaryKey {
            guard let v = row[c] else { return nil }
            out.append(v)
        }
        return RowKey(out)
    }
}

/// Opaque handle for a row that has been added in the grid but not yet inserted.
public struct InsertedRowID: Hashable, Sendable {
    let raw: Int
}

public struct EditSession: Sendable {
    public let table: TableRef
    public let primaryKey: [String]
    public let columns: [ColumnDefinition]

    /// Include the original values of edited columns in the UPDATE's WHERE clause, so a row that was
    /// changed by someone else in the meantime is reported as a conflict instead of overwritten.
    public var optimisticConcurrency: Bool = true

    // MARK: Pending state

    struct CellChange: Sendable, Equatable {
        var original: DatabaseValue?
        var new: DatabaseValue
    }
    struct RowUpdate: Sendable {
        var key: RowKey
        var cells: [String: CellChange] = [:]
        var order: [String] = []
    }
    struct InsertedRow: Sendable {
        var id: InsertedRowID
        var values: [String: DatabaseValue] = [:]
    }

    private var updates: [RowKey: RowUpdate] = [:]
    private var updateOrder: [RowKey] = []
    private var inserted: [InsertedRow] = []
    private var deleted: [RowKey] = []
    private var nextInsertID = 0

    // MARK: Init

    /// - Throws: ``EditSessionError/noPrimaryKey`` for tables without a primary key.
    public init(table: TableRef, primaryKey: [String], columns: [ColumnDefinition]) throws {
        guard !primaryKey.isEmpty else { throw EditSessionError.noPrimaryKey }
        for c in primaryKey where !columns.contains(where: { $0.name == c }) {
            throw EditSessionError.primaryKeyColumnMissing(c)
        }
        self.table = table
        self.primaryKey = primaryKey
        self.columns = columns
    }

    /// Convenience for a structure from the inspector.
    public init(structure: TableStructure) throws {
        try self.init(table: structure.info.ref, primaryKey: structure.primaryKey, columns: structure.columns)
    }

    // MARK: Queries

    public var hasChanges: Bool { changeCount > 0 }

    /// Number of rows with pending changes (updated + inserted + deleted) — one SQL statement each.
    public var changeCount: Int { updates.count + inserted.count + deleted.count }

    /// Number of individual edited cells.
    public var editedCellCount: Int { updates.values.reduce(0) { $0 + $1.cells.count } }

    public var updatedRowCount: Int { updates.count }
    public var insertedRowCount: Int { inserted.count }
    public var deletedRowCount: Int { deleted.count }

    public func isCellEdited(_ row: RowKey, column: String) -> Bool {
        updates[row]?.cells[column] != nil
    }

    /// The pending new value for a cell, if edited.
    public func editedValue(_ row: RowKey, column: String) -> DatabaseValue? {
        updates[row]?.cells[column]?.new
    }

    public func isRowDeleted(_ row: RowKey) -> Bool { deleted.contains(row) }

    public func hasPendingChanges(for row: RowKey) -> Bool {
        updates[row] != nil || isRowDeleted(row)
    }

    public var insertedRowIDs: [InsertedRowID] { inserted.map(\.id) }

    /// One pending cell edit with the value it will replace.
    public struct CellChangeInfo: Sendable, Hashable {
        public var column: String
        /// The value read from the server (nil when the caller didn't supply it).
        public var original: DatabaseValue?
        public var new: DatabaseValue
    }

    /// Rows with pending cell edits, in the order they were first edited.
    public var updatedRowKeys: [RowKey] { updateOrder }

    /// Rows marked for deletion, in marking order.
    public var deletedRowKeys: [RowKey] { deleted }

    /// The pending edits of one row, in edit order.
    public func cellChanges(for row: RowKey) -> [CellChangeInfo] {
        guard let u = updates[row] else { return [] }
        return u.order.compactMap { name in
            u.cells[name].map { CellChangeInfo(column: name, original: $0.original, new: $0.new) }
        }
    }

    /// The value first read from the server for an edited cell, if the caller supplied it.
    public func originalValue(_ row: RowKey, column: String) -> DatabaseValue? {
        updates[row]?.cells[column]?.original
    }

    /// "ID 1042" / "id 3, tenant 7": names the row for messages.
    public func rowLabel(_ key: RowKey) -> String {
        zip(primaryKey, key.values).map { "\($0) \($1.displayString)" }.joined(separator: ", ")
    }

    public func insertedValues(_ id: InsertedRowID) -> [String: DatabaseValue]? {
        inserted.first(where: { $0.id == id })?.values
    }

    // MARK: Mutations

    /// Records an edit of one cell. Setting the value back to `original` removes the change.
    /// Pass `original` (the value last read from the server) to enable conflict detection.
    public mutating func setCell(row: RowKey, column: String, original: DatabaseValue?, new: DatabaseValue) throws {
        guard columns.contains(where: { $0.name == column }) else { throw EditSessionError.unknownColumn(column) }
        guard row.values.count == primaryKey.count, !row.values.contains(.null) else { throw EditSessionError.invalidRowKey }
        // The first recorded original wins: later edits of the same cell keep comparing to the server value.
        let baseline = updates[row]?.cells[column]?.original ?? original
        if let baseline, baseline == new {
            removeCell(row: row, column: column)
            return
        }
        var u = updates[row] ?? RowUpdate(key: row)
        if u.cells[column] == nil { u.order.append(column) }
        u.cells[column] = CellChange(original: baseline, new: new)
        if updates[row] == nil { updateOrder.append(row) }
        updates[row] = u
    }

    /// Replaces the recorded server value of an edited cell, after the row was reloaded: the edit now
    /// overwrites what is there today instead of what was there at first load. An edit that equals the
    /// fresh value disappears.
    public mutating func rebaseOriginal(row: RowKey, column: String, original: DatabaseValue) {
        guard var u = updates[row], var change = u.cells[column] else { return }
        if change.new == original {
            removeCell(row: row, column: column)
            return
        }
        change.original = original
        u.cells[column] = change
        updates[row] = u
    }

    /// Reverts one cell edit.
    public mutating func revertCell(row: RowKey, column: String) { removeCell(row: row, column: column) }

    private mutating func removeCell(row: RowKey, column: String) {
        guard var u = updates[row] else { return }
        u.cells[column] = nil
        u.order.removeAll { $0 == column }
        if u.cells.isEmpty {
            updates[row] = nil
            updateOrder.removeAll { $0 == row }
        } else {
            updates[row] = u
        }
    }

    /// Marks a row for deletion (its pending cell edits are dropped).
    public mutating func markDeleted(_ row: RowKey) throws {
        guard row.values.count == primaryKey.count, !row.values.contains(.null) else { throw EditSessionError.invalidRowKey }
        updates[row] = nil
        updateOrder.removeAll { $0 == row }
        if !deleted.contains(row) { deleted.append(row) }
    }

    public mutating func unmarkDeleted(_ row: RowKey) { deleted.removeAll { $0 == row } }

    /// Adds a new row. Columns absent from `values` are left to the server (defaults, auto-increment).
    @discardableResult
    public mutating func insertRow(_ values: [String: DatabaseValue] = [:]) throws -> InsertedRowID {
        for c in values.keys where !columns.contains(where: { $0.name == c }) { throw EditSessionError.unknownColumn(c) }
        let id = InsertedRowID(raw: nextInsertID)
        nextInsertID += 1
        inserted.append(InsertedRow(id: id, values: values))
        return id
    }

    /// Sets a column on an inserted row; `nil` clears it back to "let the server decide".
    public mutating func setInsertedCell(_ id: InsertedRowID, column: String, value: DatabaseValue?) throws {
        guard columns.contains(where: { $0.name == column }) else { throw EditSessionError.unknownColumn(column) }
        guard let i = inserted.firstIndex(where: { $0.id == id }) else { return }
        inserted[i].values[column] = value
    }

    public mutating func removeInsertedRow(_ id: InsertedRowID) { inserted.removeAll { $0.id == id } }

    /// Reverts every pending change.
    public mutating func discardAll() {
        updates = [:]
        updateOrder = []
        inserted = []
        deleted = []
    }

    /// Reverts the pending edits and deletion of one existing row.
    public mutating func discard(row: RowKey) {
        updates[row] = nil
        updateOrder.removeAll { $0 == row }
        deleted.removeAll { $0 == row }
    }

    // MARK: Validation

    public struct Issue: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// A NOT NULL column without default / auto-increment has no value in a new row.
            case missingRequiredColumn(String)
            /// NULL assigned to a NOT NULL column.
            case nullInNotNullColumn(String)
        }
        public var kind: Kind
        /// The inserted row concerned; nil for edits of existing rows.
        public var insertedRow: InsertedRowID?
        public var row: RowKey?
    }

    /// Problems the server would reject, found without a round trip. Informational: commit still runs
    /// the statements (the server is the authority) so nothing is silently dropped.
    public var validationIssues: [Issue] {
        var out: [Issue] = []
        for r in inserted {
            for c in columns where !c.isNullable && c.defaultExpression == nil && !c.isAutoIncrement {
                if r.values[c.name] == nil {
                    out.append(Issue(kind: .missingRequiredColumn(c.name), insertedRow: r.id))
                } else if r.values[c.name] == .some(.null) {
                    out.append(Issue(kind: .nullInNotNullColumn(c.name), insertedRow: r.id))
                }
            }
            for c in columns where !c.isNullable && r.values[c.name] == .some(.null) && (c.defaultExpression != nil || c.isAutoIncrement) {
                out.append(Issue(kind: .nullInNotNullColumn(c.name), insertedRow: r.id))
            }
        }
        for key in updateOrder {
            guard let u = updates[key] else { continue }
            for (name, change) in u.cells where change.new == .null {
                if columns.first(where: { $0.name == name })?.isNullable == false {
                    out.append(Issue(kind: .nullInNotNullColumn(name), insertedRow: nil, row: key))
                }
            }
        }
        return out
    }

    // MARK: SQL generation

    public enum ChangeKind: Sendable, Hashable { case update, insert, delete }

    /// One generated statement together with what commit should expect from it.
    public struct PlannedStatement: Sendable, Hashable {
        public var kind: ChangeKind
        public var sql: String
        /// The existing row addressed (update/delete); nil for inserts.
        public var row: RowKey?
        public var insertedRow: InsertedRowID?
    }

    /// Deletes first (frees keys), then updates, then inserts.
    public func plannedStatements(dialect: SQLDialect) -> [PlannedStatement] {
        var out: [PlannedStatement] = []
        let tbl = dialect.qualified(table)

        for key in deleted {
            guard let cond = keyCondition(key, dialect: dialect) else { continue }
            out.append(PlannedStatement(kind: .delete, sql: "DELETE FROM \(tbl) WHERE \(cond)", row: key))
        }

        for key in updateOrder {
            guard let u = updates[key], let keyCond = keyCondition(key, dialect: dialect) else { continue }
            let set = u.order.compactMap { name -> String? in
                guard let change = u.cells[name] else { return nil }
                return "\(dialect.quoteIdentifier(name)) = \(dialect.literal(change.new))"
            }.joined(separator: ", ")
            var conds = [keyCond]
            if optimisticConcurrency {
                for name in u.order {
                    guard let change = u.cells[name], let original = change.original,
                          let col = columns.first(where: { $0.name == name }),
                          let cond = comparison(column: col, value: original, dialect: dialect) else { continue }
                    // The key columns are already pinned by the key condition.
                    if primaryKey.contains(name) { continue }
                    conds.append(cond)
                }
            }
            out.append(PlannedStatement(
                kind: .update, sql: "UPDATE \(tbl) SET \(set) WHERE \(conds.joined(separator: " AND "))", row: key))
        }

        for r in inserted {
            let cols = columns.map(\.name).filter { r.values[$0] != nil }
            let sql: String
            if cols.isEmpty {
                sql = dialect.family == .mysql ? "INSERT INTO \(tbl) () VALUES ()" : "INSERT INTO \(tbl) DEFAULT VALUES"
            } else {
                let names = cols.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
                let vals = cols.map { dialect.literal(r.values[$0] ?? .null) }.joined(separator: ", ")
                sql = "INSERT INTO \(tbl) (\(names)) VALUES (\(vals))"
            }
            out.append(PlannedStatement(kind: .insert, sql: sql, insertedRow: r.id))
        }
        return out
    }

    /// The exact SQL a commit runs, in order (what the Review sheet shows).
    public func statements(dialect: SQLDialect) -> [String] {
        plannedStatements(dialect: dialect).map(\.sql)
    }

    private func keyCondition(_ key: RowKey, dialect: SQLDialect) -> String? {
        guard key.values.count == primaryKey.count else { return nil }
        return zip(primaryKey, key.values).map { name, value in
            let col = columns.first(where: { $0.name == name })
            return comparison(column: col, name: name, value: value, dialect: dialect, forceExact: true) ?? "1 = 0"
        }.joined(separator: " AND ")
    }

    private func comparison(column: ColumnDefinition, value: DatabaseValue, dialect: SQLDialect) -> String? {
        comparison(column: column, name: column.name, value: value, dialect: dialect, forceExact: false)
    }

    /// `col = literal` / `col IS NULL`, with per-type care so the optimistic check doesn't produce
    /// false conflicts. Approximate numerics (float/double/real) can't be compared reliably through a
    /// text round trip and are skipped for the concurrency check (nil), never for the primary key.
    private func comparison(column: ColumnDefinition?, name: String, value: DatabaseValue, dialect: SQLDialect,
                            forceExact: Bool) -> String? {
        let ident = dialect.quoteIdentifier(name)
        let type = column?.dataType.lowercased() ?? ""
        if !forceExact, Self.approximateTypes.contains(type) { return nil }
        if value == .null { return "\(ident) IS NULL" }
        var lhs = ident
        switch (dialect.family, type) {
        case (.postgres, "json"): lhs = "\(ident)::text"
        case (.mysql, "json"): lhs = "CAST(\(ident) AS CHAR)"
        default: break
        }
        return "\(lhs) = \(dialect.literal(value))"
    }

    private static let approximateTypes: Set<String> = [
        "float", "double", "real", "float4", "float8", "double precision", "geometry", "point", "linestring", "polygon",
        "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geography", "xml",
    ]

    // MARK: Commit

    public enum StatementOutcome: Sendable, Hashable {
        /// Ran; `rowsAffected` as reported by the server.
        case applied(rowsAffected: UInt64?)
        /// An UPDATE/DELETE matched no row: the row changed or vanished since it was read.
        case conflict
        case failed(String)
        /// Not executed because an earlier statement failed or conflicted.
        case notRun
    }

    public enum RollbackReason: Sendable, Hashable {
        /// `statementIndex` indexes ``CommitResult/statements``.
        case conflict(statementIndex: Int)
        case error(statementIndex: Int?, message: String)
    }

    public enum CommitStatus: Sendable, Hashable {
        case committed
        case rolledBack(RollbackReason)
    }

    public struct CommitResult: Sendable, Hashable {
        public var status: CommitStatus
        public var statements: [PlannedStatement]
        /// One per statement, same order.
        public var outcomes: [StatementOutcome]
        public var duration: Duration

        public var isCommitted: Bool { status == .committed }
        public var conflictCount: Int { outcomes.filter { $0 == .conflict }.count }
    }

    /// Runs the pending changes in one transaction. Rolls back on the first error or conflict
    /// (an UPDATE/DELETE that affects 0 rows) and reports per-statement outcomes; nothing is left
    /// half-applied on transactional engines.
    ///
    /// Throws only when the transaction can't be started. Statement and COMMIT failures come back
    /// as ``CommitStatus/rolledBack(_:)``.
    ///
    /// - Note: MyISAM and other non-transactional MySQL tables can't be rolled back; the outcomes still
    ///   say exactly what ran.
    public func commit(on session: any DatabaseSession) async throws -> CommitResult {
        let dialect = SQLDialect(session.engine)
        let planned = plannedStatements(dialect: dialect)
        let clock = ContinuousClock()
        let start = clock.now
        guard !planned.isEmpty else {
            return CommitResult(status: .committed, statements: [], outcomes: [], duration: .zero)
        }

        _ = try await session.execute(dialect.family == .mysql ? "START TRANSACTION" : "BEGIN")

        var outcomes: [StatementOutcome] = []
        var failure: RollbackReason?
        for (i, stmt) in planned.enumerated() {
            if failure != nil { outcomes.append(.notRun); continue }
            do {
                let r = try await session.execute(stmt.sql)
                if stmt.kind != .insert, (r.rowsAffected ?? 0) == 0 {
                    outcomes.append(.conflict)
                    failure = .conflict(statementIndex: i)
                } else {
                    outcomes.append(.applied(rowsAffected: r.rowsAffected))
                }
            } catch {
                let message = Self.describe(error)
                outcomes.append(.failed(message))
                failure = .error(statementIndex: i, message: message)
            }
        }

        if failure == nil {
            do {
                _ = try await session.execute("COMMIT")
            } catch {
                failure = .error(statementIndex: nil, message: Self.describe(error))
            }
        }
        if let failure {
            _ = try? await session.execute("ROLLBACK")
            return CommitResult(status: .rolledBack(failure), statements: planned, outcomes: outcomes, duration: clock.now - start)
        }
        return CommitResult(status: .committed, statements: planned, outcomes: outcomes, duration: clock.now - start)
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? DatabaseError { return DryRunExecutor.describe(e) }
        return error.localizedDescription
    }
}
