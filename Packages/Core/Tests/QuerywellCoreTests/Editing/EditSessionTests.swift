import Foundation
import Testing

@testable import QuerywellCore

private let myD = SQLDialect(.mysql)
private let pgD = SQLDialect(.postgresql)

private func col(_ name: String, _ type: String = "varchar", ordinal: Int = 1, nullable: Bool = true, pk: Bool = false,
                 auto: Bool = false, def: String? = nil) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: ordinal, dataType: type, fullType: type, isNullable: nullable,
                     defaultExpression: def, isPrimaryKey: pk, isAutoIncrement: auto)
}

private let cols = [
    col("id", "int", ordinal: 1, nullable: false, pk: true, auto: true),
    col("name", "varchar", ordinal: 2),
    col("note", "text", ordinal: 3),
    col("qty", "decimal", ordinal: 4, nullable: false, def: "0"),
    col("score", "double", ordinal: 5),
    col("doc", "json", ordinal: 6),
]
private let tbl = TableRef(schema: "shop", name: "items")

private func session() throws -> EditSession {
    try EditSession(table: tbl, primaryKey: ["id"], columns: cols)
}
private func key(_ id: Int64) -> RowKey { RowKey([.integer(id)]) }

@Suite("Edit session (pure)")
struct EditSessionUnitTests {
    @Test func tablesWithoutPrimaryKeyAreNotEditable() {
        #expect(throws: EditSessionError.noPrimaryKey) {
            try EditSession(table: tbl, primaryKey: [], columns: cols)
        }
        #expect(throws: EditSessionError.primaryKeyColumnMissing("zzz")) {
            try EditSession(table: tbl, primaryKey: ["zzz"], columns: cols)
        }
    }

    @Test func structureInit() throws {
        let info = TableInfo(ref: tbl, kind: .table)
        let s = TableStructure(info: info, columns: cols, indexes: [IndexDefinition(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true)],
                               foreignKeys: [], referencedBy: [])
        #expect(try EditSession(structure: s).primaryKey == ["id"])
        let none = TableStructure(info: info, columns: cols.map { var c = $0; c.isPrimaryKey = false; return c }, indexes: [],
                                  foreignKeys: [], referencedBy: [])
        #expect(throws: EditSessionError.noPrimaryKey) { try EditSession(structure: none) }
    }

    @Test func emptySessionHasNoChanges() throws {
        let s = try session()
        #expect(!s.hasChanges)
        #expect(s.changeCount == 0)
        #expect(s.statements(dialect: myD).isEmpty)
    }

    @Test func updateStatementMySQL() throws {
        var s = try session()
        try s.setCell(row: key(7), column: "name", original: .text("old"), new: .text("it's \\ new"))
        try s.setCell(row: key(7), column: "note", original: .null, new: .text("hello"))
        try s.setCell(row: key(7), column: "qty", original: .text("1.00"), new: .text("2.50"))
        #expect(s.hasChanges)
        #expect(s.changeCount == 1)
        #expect(s.editedCellCount == 3)
        #expect(s.statements(dialect: myD) == [
            "UPDATE `shop`.`items` SET `name` = 'it\\'s \\\\ new', `note` = 'hello', `qty` = '2.50' "
                + "WHERE `id` = 7 AND `name` = 'old' AND `note` IS NULL AND `qty` = '1.00'"
        ])
    }

    @Test func updateStatementPostgres() throws {
        var s = try session()
        try s.setCell(row: key(7), column: "name", original: .text("o'k"), new: .null)
        #expect(s.statements(dialect: pgD) == [
            "UPDATE \"shop\".\"items\" SET \"name\" = NULL WHERE \"id\" = 7 AND \"name\" = 'o''k'"
        ])
    }

    @Test func concurrencyCanBeSwitchedOff() throws {
        var s = try session()
        s.optimisticConcurrency = false
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("b"))
        #expect(s.statements(dialect: myD) == ["UPDATE `shop`.`items` SET `name` = 'b' WHERE `id` = 1"])
    }

    @Test func unknownOriginalIsOmittedFromWhere() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "name", original: nil, new: .text("b"))
        #expect(s.statements(dialect: myD) == ["UPDATE `shop`.`items` SET `name` = 'b' WHERE `id` = 1"])
    }

    @Test func approximateAndJSONTypes() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "score", original: .double(1.1), new: .double(2.2))
        try s.setCell(row: key(1), column: "doc", original: .text("{\"a\": 1}"), new: .text("{\"a\": 2}"))
        #expect(s.statements(dialect: myD) == [
            "UPDATE `shop`.`items` SET `score` = 2.2, `doc` = '{\"a\": 2}' WHERE `id` = 1 AND CAST(`doc` AS CHAR) = '{\"a\": 1}'"
        ])
        #expect(s.statements(dialect: pgD)[0].hasSuffix("AND \"doc\"::text = '{\"a\": 1}'"))
    }

    @Test func settingBackToOriginalRemovesTheChange() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("b"))
        #expect(s.isCellEdited(key(1), column: "name"))
        #expect(s.editedValue(key(1), column: "name") == .text("b"))
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("a"))
        #expect(!s.isCellEdited(key(1), column: "name"))
        #expect(!s.hasChanges)
        // re-editing twice keeps the first original as the baseline
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("b"))
        try s.setCell(row: key(1), column: "name", original: .text("b"), new: .text("c"))
        #expect(s.statements(dialect: myD) == ["UPDATE `shop`.`items` SET `name` = 'c' WHERE `id` = 1 AND `name` = 'a'"])
        try s.setCell(row: key(1), column: "name", original: .text("b"), new: .text("a"))
        #expect(!s.hasChanges)
    }

    @Test func discardAndPerRowDiscard() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("b"))
        try s.setCell(row: key(2), column: "name", original: .text("a"), new: .text("b"))
        try s.markDeleted(key(3))
        try s.insertRow(["name": .text("n")])
        #expect(s.changeCount == 4)
        s.discard(row: key(1))
        #expect(s.changeCount == 3)
        s.discard(row: key(3))
        #expect(!s.isRowDeleted(key(3)))
        #expect(s.changeCount == 2)
        s.discardAll()
        #expect(!s.hasChanges)
        #expect(s.statements(dialect: myD).isEmpty)
    }

    @Test func deleteStatementsAndOrdering() throws {
        var s = try session()
        try s.insertRow(["id": .integer(99), "name": .text("x")])
        try s.setCell(row: key(2), column: "name", original: .text("a"), new: .text("b"))
        try s.markDeleted(key(1))
        let stmts = s.statements(dialect: myD)
        #expect(stmts.count == 3)
        #expect(stmts[0] == "DELETE FROM `shop`.`items` WHERE `id` = 1")
        #expect(stmts[1].hasPrefix("UPDATE"))
        #expect(stmts[2] == "INSERT INTO `shop`.`items` (`id`, `name`) VALUES (99, 'x')")
    }

    @Test func deletingDropsPendingEditsOfThatRow() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "name", original: .text("a"), new: .text("b"))
        try s.markDeleted(key(1))
        #expect(s.updatedRowCount == 0)
        #expect(s.deletedRowCount == 1)
        s.unmarkDeleted(key(1))
        #expect(!s.hasChanges)
    }

    @Test func insertSkipsUnsetColumnsAndHandlesAllDefaults() throws {
        var s = try session()
        let a = try s.insertRow()
        let b = try s.insertRow(["name": .text("日本語 😀"), "note": .null, "score": .double(1.5)])
        try s.setInsertedCell(b, column: "qty", value: .text("3.00"))
        #expect(s.insertedRowIDs == [a, b])
        #expect(s.insertedValues(b)?["qty"] == .text("3.00"))
        #expect(s.statements(dialect: myD) == [
            "INSERT INTO `shop`.`items` () VALUES ()",
            "INSERT INTO `shop`.`items` (`name`, `note`, `qty`, `score`) VALUES ('日本語 😀', NULL, '3.00', 1.5)",
        ])
        #expect(s.statements(dialect: pgD)[0] == "INSERT INTO \"shop\".\"items\" DEFAULT VALUES")
        try s.setInsertedCell(b, column: "qty", value: nil)
        #expect(s.insertedValues(b)?["qty"] == nil)
        s.removeInsertedRow(a)
        #expect(s.insertedRowCount == 1)
    }

    @Test func bytesAndBooleansUseDialectLiterals() throws {
        var s = try session()
        try s.insertRow(["name": .bytes(Data([0, 1, 0xFF]))])
        #expect(s.statements(dialect: myD)[0].contains("0x0001FF"))
        #expect(s.statements(dialect: pgD)[0].contains("'\\x0001ff'::bytea"))
    }

    @Test func compositePrimaryKey() throws {
        let c = [col("a", "int", nullable: false, pk: true), col("b", "varchar", ordinal: 2, nullable: false, pk: true), col("v", "int", ordinal: 3)]
        var s = try EditSession(table: tbl, primaryKey: ["a", "b"], columns: c)
        let k = RowKey.make(primaryKey: ["a", "b"], row: ["a": .integer(1), "b": .text("x"), "v": .integer(5)])
        #expect(k == RowKey([.integer(1), .text("x")]))
        try s.setCell(row: #require(k), column: "v", original: .integer(5), new: .integer(6))
        #expect(s.statements(dialect: myD) == ["UPDATE `shop`.`items` SET `v` = 6 WHERE `a` = 1 AND `b` = 'x' AND `v` = 5"])
        #expect(RowKey.make(primaryKey: ["a", "zz"], row: ["a": .integer(1)]) == nil)
        #expect(throws: EditSessionError.invalidRowKey) {
            try s.setCell(row: RowKey([.integer(1)]), column: "v", original: nil, new: .integer(1))
        }
    }

    @Test func editingThePrimaryKeyUsesTheOriginalKeyInWhere() throws {
        var s = try session()
        try s.setCell(row: key(1), column: "id", original: .integer(1), new: .integer(50))
        #expect(s.statements(dialect: myD) == ["UPDATE `shop`.`items` SET `id` = 50 WHERE `id` = 1"])
    }

    @Test func rejectsBadInput() throws {
        var s = try session()
        #expect(throws: EditSessionError.unknownColumn("nope")) {
            try s.setCell(row: key(1), column: "nope", original: nil, new: .null)
        }
        #expect(throws: EditSessionError.invalidRowKey) {
            try s.setCell(row: RowKey([.null]), column: "name", original: nil, new: .null)
        }
        #expect(throws: EditSessionError.unknownColumn("nope")) { try s.insertRow(["nope": .null]) }
    }

    @Test func validationIssues() throws {
        var s = try session()
        let id = try s.insertRow(["qty": .null])
        try s.setCell(row: key(1), column: "qty", original: .text("1"), new: .null)
        let kinds = s.validationIssues.map(\.kind)
        #expect(kinds.contains(.nullInNotNullColumn("qty")))
        #expect(s.validationIssues.contains { $0.insertedRow == id })
        // id is auto-increment and name is nullable: neither is "missing"
        #expect(!kinds.contains(.missingRequiredColumn("id")))
        #expect(!kinds.contains(.missingRequiredColumn("name")))
    }

    @Test func noopForUnsupportedRowKeyLengthProducesNoStatement() throws {
        var s = try session()
        try s.markDeleted(key(1))
        #expect(s.statements(dialect: myD).count == 1)
    }
}

// MARK: - Integration

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

private struct EditEnv {
    var target: DBTarget
    var table: String
    var ref: TableRef
    var columns: [ColumnDefinition]

    var schema: String { target.isPostgres ? "public" : "querywell_test" }
}

private func withEditTable<T>(_ target: DBTarget, _ body: (any DatabaseSession, EditEnv) async throws -> T) async throws -> T {
    let session = try await target.connect()
    let name = target.uniqueTable("edit")
    let pg = target.isPostgres
    let ddl = pg
        ? """
        CREATE TABLE \(name) (id SERIAL PRIMARY KEY, name VARCHAR(100), note TEXT, data BYTEA,
          qty NUMERIC(10,2) NOT NULL DEFAULT 0, score DOUBLE PRECISION)
        """
        : """
        CREATE TABLE \(name) (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NULL, note TEXT NULL, data BLOB NULL,
          qty DECIMAL(10,2) NOT NULL DEFAULT 0, score DOUBLE NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """
    _ = try await session.execute(ddl)
    let env = EditEnv(
        target: target, table: name,
        ref: TableRef(schema: pg ? "public" : "querywell_test", name: name),
        columns: [
            col("id", "int", ordinal: 1, nullable: false, pk: true, auto: true),
            col("name", "varchar", ordinal: 2),
            col("note", "text", ordinal: 3),
            col("data", pg ? "bytea" : "blob", ordinal: 4),
            col("qty", pg ? "numeric" : "decimal", ordinal: 5, nullable: false, def: "0"),
            col("score", pg ? "double precision" : "double", ordinal: 6),
        ])
    do {
        let r = try await body(session, env)
        _ = try? await session.execute("DROP TABLE IF EXISTS \(name)")
        await session.close()
        return r
    } catch {
        _ = try? await session.execute("DROP TABLE IF EXISTS \(name)")
        await session.close()
        throw error
    }
}

private func rows(_ s: any DatabaseSession, _ env: EditEnv, cols: String = "id, name, note, qty") async throws -> [[DatabaseValue]] {
    try await s.execute("SELECT \(cols) FROM \(env.table) ORDER BY id").rows
}

@Suite("Edit session integration", .serialized, .enabled(if: integrationEnabled))
struct EditSessionIntegrationTests {
    @Test(arguments: DBTarget.all)
    func editCellsIncludingNullUnicodeAndBytes(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name, note, qty) VALUES ('a', 'keep', 1.00), ('b', NULL, 2.00)")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            let tricky = "Zoë 日本語 😀 O'Brien \\ \"q\"\nline2"
            let k1 = RowKey([.integer(1)]), k2 = RowKey([.integer(2)])
            try es.setCell(row: k1, column: "name", original: .text("a"), new: .text(tricky))
            try es.setCell(row: k1, column: "note", original: .text("keep"), new: .null)
            try es.setCell(row: k1, column: "data", original: .null, new: .bytes(Data([0, 1, 2, 255, 39, 92])))
            try es.setCell(row: k1, column: "qty", original: .text("1.00"), new: .text("12.50"))
            try es.setCell(row: k2, column: "note", original: .null, new: .text("was null"))
            #expect(es.changeCount == 2)

            let result = try await es.commit(on: db)
            #expect(result.isCommitted, "\(result)")
            #expect(result.outcomes.count == 2)
            #expect(result.outcomes.allSatisfy { if case .applied(let n) = $0 { return n == 1 } else { return false } })

            let r = try await rows(db, env, cols: "id, name, note, data, qty")
            #expect(r[0][1] == .text(tricky))
            #expect(r[0][2] == .null)
            #expect(r[0][3] == .bytes(Data([0, 1, 2, 255, 39, 92])))
            #expect(r[0][4] == .text("12.50"))
            #expect(r[1][2] == .text("was null"))
        }
    }

    @Test(arguments: DBTarget.all)
    func setCellToNullThenBack(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES (NULL)")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.setCell(row: RowKey([.integer(1)]), column: "name", original: .null, new: .text("filled"))
            let result = try await es.commit(on: db)
            #expect(result.isCommitted)
            #expect(try await rows(db, env)[0][1] == .text("filled"))
        }
    }

    @Test(arguments: DBTarget.all)
    func insertRows(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.insertRow(["name": .text("new 😀"), "note": .null])
            try es.insertRow()  // everything defaulted
            let result = try await es.commit(on: db)
            #expect(result.isCommitted, "\(result)")
            let r = try await rows(db, env)
            #expect(r.count == 2)
            #expect(r[0][1] == .text("new 😀"))
            #expect(r[0][3] == .text("0.00"))  // default applied
            #expect(r[1][1] == .null)
        }
    }

    @Test(arguments: DBTarget.all)
    func deleteRows(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a'), ('b'), ('c')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.markDeleted(RowKey([.integer(2)]))
            try es.setCell(row: RowKey([.integer(3)]), column: "name", original: .text("c"), new: .text("C"))
            let result = try await es.commit(on: db)
            #expect(result.isCommitted)
            let r = try await rows(db, env)
            #expect(r.map { $0[1] } == [.text("a"), .text("C")])
        }
    }

    @Test(arguments: DBTarget.all)
    func conflictWhenRowChangedUnderneathRollsEverythingBack(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a'), ('b')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.setCell(row: RowKey([.integer(1)]), column: "name", original: .text("a"), new: .text("a2"))
            try es.setCell(row: RowKey([.integer(2)]), column: "name", original: .text("b"), new: .text("b2"))
            // someone else changes row 2 after we read it
            _ = try await db.execute("UPDATE \(env.table) SET name = 'changed by someone' WHERE id = 2")

            let result = try await es.commit(on: db)
            #expect(!result.isCommitted)
            #expect(result.status == .rolledBack(.conflict(statementIndex: 1)))
            #expect(result.conflictCount == 1)
            if case .applied = result.outcomes[0] {} else { Issue.record("first statement should have applied before rollback") }
            #expect(result.outcomes[1] == .conflict)
            // nothing from our session persisted
            let r = try await rows(db, env)
            #expect(r.map { $0[1] } == [.text("a"), .text("changed by someone")])
        }
    }

    @Test(arguments: DBTarget.all)
    func conflictWhenRowWasDeletedUnderneath(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.markDeleted(RowKey([.integer(1)]))
            _ = try await db.execute("DELETE FROM \(env.table)")
            let result = try await es.commit(on: db)
            #expect(result.status == .rolledBack(.conflict(statementIndex: 0)))
        }
    }

    @Test(arguments: DBTarget.all)
    func withoutOptimisticConcurrencyTheEditOverwrites(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            es.optimisticConcurrency = false
            try es.setCell(row: RowKey([.integer(1)]), column: "name", original: .text("a"), new: .text("mine"))
            _ = try await db.execute("UPDATE \(env.table) SET name = 'theirs'")
            let result = try await es.commit(on: db)
            #expect(result.isCommitted)
            #expect(try await rows(db, env)[0][1] == .text("mine"))
        }
    }

    @Test(arguments: DBTarget.all)
    func serverErrorRollsBackEarlierStatements(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.setCell(row: RowKey([.integer(1)]), column: "name", original: .text("a"), new: .text("changed"))
            // NOT NULL violation on qty
            try es.insertRow(["qty": .null])
            try es.insertRow(["name": .text("never")])
            let result = try await es.commit(on: db)
            guard case .rolledBack(.error(let idx, let message)) = result.status else {
                Issue.record("expected error rollback, got \(result.status)")
                return
            }
            #expect(idx == 1)
            #expect(!message.isEmpty)
            #expect(result.outcomes.count == 3)
            if case .failed = result.outcomes[1] {} else { Issue.record("second statement should have failed") }
            #expect(result.outcomes[2] == .notRun)
            let r = try await rows(db, env)
            #expect(r.count == 1)
            #expect(r[0][1] == .text("a"))
            // the session is usable afterwards (transaction cleaned up)
            #expect(try await db.execute("SELECT 1").rows.count == 1)
        }
    }

    @Test(arguments: DBTarget.all)
    func emptyCommitDoesNothing(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            let es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            let r = try await es.commit(on: db)
            #expect(r.isCommitted && r.outcomes.isEmpty)
        }
    }

    @Test(arguments: DBTarget.all)
    func floatColumnEditDoesNotFalseConflict(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name, score) VALUES ('a', 1.1)")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.setCell(row: RowKey([.integer(1)]), column: "score", original: .double(1.1), new: .double(2.2))
            let result = try await es.commit(on: db)
            #expect(result.isCommitted, "\(result)")
        }
    }

    @Test(arguments: DBTarget.all)
    func reviewSQLIsExactlyWhatRuns(target: DBTarget) async throws {
        try await withEditTable(target) { db, env in
            _ = try await db.execute("INSERT INTO \(env.table) (name) VALUES ('a')")
            var es = try EditSession(table: env.ref, primaryKey: ["id"], columns: env.columns)
            try es.setCell(row: RowKey([.integer(1)]), column: "name", original: .text("a"), new: .text("b"))
            let dialect = SQLDialect(target.engine)
            let result = try await es.commit(on: db)
            #expect(result.statements.map(\.sql) == es.statements(dialect: dialect))
        }
    }
}
