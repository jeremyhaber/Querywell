import Foundation
import QuerywellCore
import Testing
@testable import Querywell

// MARK: - Fakes

/// An in-memory `wp_posts`-like table behind the `DatabaseSession` contract: SELECT returns the rows,
/// UPDATE / DELETE / INSERT change them, transactions are recorded. No server needed.
actor FakeSession: DatabaseSession {
    nonisolated let engine: DatabaseEngine
    nonisolated let serverInfo: ServerInfo
    private(set) var executed: [String] = []
    private var rows: [[DatabaseValue]]
    /// UPDATE / DELETE report this many affected rows when set (0 simulates a concurrent change).
    var forcedAffectedRows: UInt64?
    /// Statements containing this text fail with a server error.
    var failWhenContaining: String?

    static let columns = [
        ColumnInfo(name: "ID", typeName: "bigint"), ColumnInfo(name: "title", typeName: "varchar"),
        ColumnInfo(name: "status", typeName: "varchar"),
    ]

    init(engine: DatabaseEngine = .mysql, rows: [[DatabaseValue]]? = nil) {
        self.engine = engine
        self.serverInfo = ServerInfo(engine: engine, versionString: "8.4.0", major: 8, minor: 4, patch: 0, tlsActive: false)
        self.rows = rows ?? [
            [.integer(1), .text("Home"), .text("publish")],
            [.integer(2), .text("About"), .text("draft")],
            [.integer(3), .text("Contact"), .null],
        ]
    }

    func setForcedAffectedRows(_ n: UInt64?) { forcedAffectedRows = n }
    func setFailWhenContaining(_ text: String?) { failWhenContaining = text }
    func currentRows() -> [[DatabaseValue]] { rows }
    func replaceRows(_ new: [[DatabaseValue]]) { rows = new }

    func execute(_ sql: String) async throws -> QueryResult {
        executed.append(sql)
        if let failWhenContaining, sql.contains(failWhenContaining) {
            throw DatabaseError.query(message: "Data too long for column 'title'", code: "1406")
        }
        let upper = sql.uppercased()
        if upper.hasPrefix("SELECT") {
            return QueryResult(columns: Self.columns, rows: rows, duration: .milliseconds(1))
        }
        if upper.hasPrefix("UPDATE") || upper.hasPrefix("DELETE") {
            if let forcedAffectedRows { return QueryResult(rowsAffected: forcedAffectedRows) }
            return QueryResult(rowsAffected: apply(sql))
        }
        if upper.hasPrefix("INSERT") {
            rows.append([.integer(Int64(rows.count + 1)), .text("new"), .text("draft")])
            return QueryResult(rowsAffected: 1)
        }
        return QueryResult()
    }

    /// Only the shapes the tests produce: `… SET `title` = '…' WHERE `ID` = n …` and `DELETE … WHERE `ID` = n`.
    private func apply(_ sql: String) -> UInt64 {
        guard let idRange = sql.range(of: "`ID` = ") else { return 0 }
        let digits = sql[idRange.upperBound...].prefix { $0.isNumber }
        guard let id = Int64(digits), let index = rows.firstIndex(where: { $0[0] == .integer(id) }) else { return 0 }
        if sql.uppercased().hasPrefix("DELETE") {
            rows.remove(at: index)
            return 1
        }
        for (c, name) in ["title", "status"].enumerated() {
            let marker = "`\(name)` = '"
            if let start = sql.range(of: marker), let setEnd = sql.range(of: " WHERE ") , start.upperBound < setEnd.lowerBound {
                let tail = sql[start.upperBound..<setEnd.lowerBound]
                if let quote = tail.firstIndex(of: "'") { rows[index][c + 1] = .text(String(tail[..<quote])) }
            }
        }
        return 1
    }

    func listDatabases() async throws -> [String] { ["app"] }
    func currentDatabase() async throws -> String? { "app" }
    func close() async {}
}

struct FakeInspector: SchemaInspector {
    var primaryKey = true
    var tables: [TableInfo] = []
    var engines = ["InnoDB", "MyISAM", "MEMORY"]
    var collations = [
        CollationInfo(name: "utf8mb4_0900_ai_ci", characterSet: "utf8mb4", isDefault: true),
        CollationInfo(name: "utf8mb4_unicode_ci", characterSet: "utf8mb4", isDefault: false),
        CollationInfo(name: "utf8mb3_general_ci", characterSet: "utf8mb3", isDefault: true),
    ]

    func listSchemas() async throws -> [String] { ["app"] }
    func listTables(schema: String) async throws -> [TableInfo] { tables }
    func listRoutines(schema: String) async throws -> [RoutineInfo] { [] }
    func structure(of table: TableRef) async throws -> TableStructure {
        let cols = [
            ColumnDefinition(name: "ID", ordinal: 1, dataType: "bigint", fullType: "bigint unsigned", isNullable: false, isPrimaryKey: primaryKey, isAutoIncrement: true),
            ColumnDefinition(name: "title", ordinal: 2, dataType: "varchar", fullType: "varchar(20)", isNullable: false, defaultExpression: ""),
            ColumnDefinition(name: "status", ordinal: 3, dataType: "varchar", fullType: "varchar(20)", isNullable: true, defaultExpression: "draft"),
        ]
        let info = TableInfo(ref: table, kind: .table, engine: "InnoDB", estimatedRows: 3, collation: "utf8mb4_0900_ai_ci")
        let indexes = primaryKey ? [IndexDefinition(name: "PRIMARY", columns: ["ID"], isUnique: true, isPrimary: true)] : []
        return TableStructure(info: info, columns: cols, indexes: indexes, foreignKeys: [], referencedBy: [])
    }
    func availableCollations() async throws -> [CollationInfo] { collations }
    func availableEngines() async throws -> [String] { engines }
}

@MainActor
private func makeModel(
    session: FakeSession, primaryKey: Bool = true, readOnly: Bool = false, production: Bool = false
) async throws -> (TableDataModel, WriteGate) {
    let model = TableDataModel(table: TableRef(schema: "app", name: "posts"))
    model.sessionProvider = { session }
    let inspector = FakeInspector(primaryKey: primaryKey)
    model.inspectorProvider = { inspector }
    let gate = WriteGate()
    var profile = ConnectionProfile(name: "test", engine: .mysql, user: "u")
    profile.readOnly = readOnly
    if production { profile.colorTag = .production }
    let finalProfile = profile
    gate.contextProvider = { db in GuardContext(profile: finalProfile, currentDatabase: db) }
    gate.sessionProvider = { session }
    gate.confirmationHandler = { _ in true }
    model.gate = gate
    model.isReadOnlyProvider = { readOnly }
    model.loadIfNeeded(epoch: 1)
    try await waitUntil { model.hasLoaded && !model.isLoading }
    return (model, gate)
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

// MARK: - Tests

@MainActor
@Suite("Table edit flow (fake session)")
struct EditFlowTests {
    @Test func editingACellSubstitutesTheValueAndMarksItEdited() async throws {
        let session = FakeSession()
        let (model, _) = try await makeModel(session: session)
        var dirtyChanges: [Bool] = []
        model.onDirtyChange = { dirtyChanges.append($0) }
        #expect(model.canEdit)
        #expect(model.content?.rows.count == 3)

        #expect(model.applyText(displayRow: 1, column: "title", text: "About us") == nil)
        #expect(model.content?.rows[1][1] == .text("About us"))
        #expect(model.content?.isEdited(row: 1, column: 1) == true)
        #expect(model.content?.isEdited(row: 0, column: 1) == false)
        #expect(model.pendingEditCount == 1)
        #expect(model.pendingSummary == "1 unsaved edit")
        #expect(dirtyChanges == [true])
        #expect(model.pendingSQL(forDisplayRow: 1)?.hasPrefix("UPDATE `app`.`posts` SET `title` = 'About us' WHERE `ID` = 2") == true)
        #expect(model.pendingSQL(forDisplayRow: 0) == nil)

        // Typing the original value back removes the edit.
        #expect(model.applyText(displayRow: 1, column: "title", text: "About") == nil)
        #expect(model.pendingEditCount == 0)
        #expect(dirtyChanges == [true, false])
        #expect(model.content === model.loadedContent)

        model.applyText(displayRow: 0, column: "title", text: "Start")
        model.revertCell(displayRow: 0, column: "title")
        #expect(model.hasPendingChanges == false)
    }

    @Test func invalidTextIsRejectedWithoutChangingAnything() async throws {
        let (model, _) = try await makeModel(session: FakeSession())
        let error = model.applyText(displayRow: 0, column: "title", text: String(repeating: "x", count: 21))
        #expect(error?.message.contains("at most 20") == true)
        #expect(model.hasPendingChanges == false)
        // NOT NULL column can't be emptied via NULL.
        model.setNull(displayRow: 0, column: "title")
        #expect(model.hasPendingChanges == false)
        #expect(model.toast?.isError == true)
        // Nullable column can.
        model.setNull(displayRow: 0, column: "status")
        #expect(model.content?.rows[0][2] == .null)
    }

    @Test func cellInfoDescribesWhatTheMenuMayOffer() async throws {
        let (model, _) = try await makeModel(session: FakeSession())
        let title = model.editInfo(displayRow: 0, column: "title")
        #expect(title.canEdit && !title.isNullable && title.canSetEmpty && !title.canSetDefault)
        let status = model.editInfo(displayRow: 2, column: "status")
        #expect(status.isNullable && status.currentIsNull && status.canSetDefault)
        model.setDefault(displayRow: 2, column: "status")
        #expect(model.content?.rows[2][2] == .text("draft"))
        #expect(model.editInfo(displayRow: 2, column: "status").isEdited)
    }

    @Test func addDuplicateAndDeleteRows() async throws {
        let (model, _) = try await makeModel(session: FakeSession())
        model.addRow()
        #expect(model.content?.insertedCount == 1)
        #expect(model.content?.mark(0) == .inserted)
        #expect(model.content?.rows.count == 4)
        #expect(model.content?.isUnset(row: 0, column: 1) == true)
        #expect(model.editRequest?.row == 0 && model.editRequest?.column == "title")
        #expect(model.inspectorTitle == "New row")
        model.applyText(displayRow: 0, column: "title", text: "Fresh")
        #expect(model.content?.rows[0][1] == .text("Fresh"))
        #expect(model.content?.isUnset(row: 0, column: 1) == false)
        #expect(model.pendingSQL(forDisplayRow: 0)?.hasPrefix("INSERT INTO `app`.`posts` (`title`) VALUES ('Fresh')") == true)

        // Duplicate loaded row 1 (display row 2 now): auto-increment ID is left to the server.
        model.duplicateRows([1])
        #expect(model.content?.insertedCount == 2)
        #expect(model.content?.rows[0][1] == .text("Home"))
        #expect(model.content?.isUnset(row: 0, column: 0) == true)

        // Delete marks, deleting again restores; deleting an inserted row removes it.
        model.deleteRows([3])
        #expect(model.content?.mark(3) == .deleted)
        model.deleteRows([3])
        #expect(model.content?.mark(3) == .normal)
        model.deleteRows([3])
        model.deleteRows([0])
        #expect(model.content?.insertedCount == 1)
        #expect(model.pendingEditCount == 2)  // one insert + one delete
        model.revertRows([0, 1 + 1])
        model.discardAll()
        #expect(model.hasPendingChanges == false)
        #expect(model.content?.rows.count == 3)
    }

    @Test func commitWritesInOneTransactionAndReloads() async throws {
        let session = FakeSession()
        let (model, _) = try await makeModel(session: session)
        model.applyText(displayRow: 0, column: "title", text: "Welcome")
        model.applyText(displayRow: 1, column: "status", text: "publish")
        model.setSelection([1])
        let report = await model.commit()
        #expect(report?.isSuccess == true)
        #expect(report?.headline == "Committed 2 changes")
        #expect(model.toast?.message == "Committed 2 changes")
        #expect(model.hasPendingChanges == false)
        let executed = await session.executed
        #expect(executed.filter { $0.hasPrefix("UPDATE") }.count == 2)
        let begin = executed.firstIndex(of: "START TRANSACTION")
        let commit = executed.firstIndex(of: "COMMIT")
        #expect(begin != nil && commit != nil && begin! < commit!)
        try await waitUntil { model.content?.rows[0][1] == .text("Welcome") && !model.isLoading }
        #expect(model.content?.rows[0][1] == .text("Welcome"))
        #expect(model.content?.preservesViewport == true)
        #expect(model.selectedRows == [1])
    }

    @Test func declinedConfirmationWritesNothing() async throws {
        let session = FakeSession()
        let (model, gate) = try await makeModel(session: session, production: true)
        gate.confirmationHandler = { request in
            // Production edits always confirm; PK-targeted grid UPDATEs by click, not by typing the name.
            #expect(request.isProduction && request.requiresTypedName == nil)
            return false
        }
        model.applyText(displayRow: 0, column: "title", text: "Nope")
        #expect(await model.commit() == nil)
        #expect(model.hasPendingChanges)
        #expect(await session.executed.contains { $0.hasPrefix("UPDATE") } == false)
    }

    @Test func conflictKeepsEditsAndExplainsThenRebases() async throws {
        let session = FakeSession()
        let (model, _) = try await makeModel(session: session)
        model.applyText(displayRow: 0, column: "title", text: "Mine")
        await session.setForcedAffectedRows(0)  // someone else changed the row
        let report = await model.commit()
        #expect(report?.status == .conflict)
        #expect(report?.headline == "Row ID 1 was changed by someone else since you loaded it — nothing was saved.")
        #expect(model.commitReport?.status == .conflict)
        #expect(model.hasPendingChanges)
        let executed = await session.executed
        #expect(executed.contains("ROLLBACK"))

        // The row really changed on the server: reload and keep my edit on top of the new value.
        await session.setForcedAffectedRows(nil)
        await session.replaceRows([
            [.integer(1), .text("Theirs"), .text("publish")], [.integer(2), .text("About"), .text("draft")], [.integer(3), .text("Contact"), .null],
        ])
        model.reloadKeepingEdits()
        try await waitUntil { model.loadedContent?.rows[0][1] == .text("Theirs") }
        #expect(model.commitReport == nil)
        #expect(model.reviewChanges.first?.cells.first?.before == .text("Theirs"))
        #expect(model.reviewChanges.first?.sql.contains("`title` = 'Theirs'") == true)
        let second = await model.commit()
        #expect(second?.isSuccess == true)
    }

    @Test func serverErrorsKeepEditsAndShowTheServerMessage() async throws {
        let session = FakeSession()
        let (model, _) = try await makeModel(session: session)
        model.applyText(displayRow: 0, column: "title", text: "Boom")
        await session.setFailWhenContaining("Boom")
        let report = await model.commit()
        #expect(report?.status == .failed)
        #expect(report?.serverError == "Data too long for column 'title'")
        #expect(report?.statement?.contains("Boom") == true)
        #expect(model.hasPendingChanges)
    }

    @Test func readOnlyConnectionsAndTablesWithoutKeysCannotBeEdited() async throws {
        let (readOnly, _) = try await makeModel(session: FakeSession(), readOnly: true)
        #expect(readOnly.editBlock == .readOnlyConnection)
        #expect(readOnly.canEdit == false)
        #expect(readOnly.setValue(displayRow: 0, column: "title", value: .text("x")) == false)
        #expect(readOnly.editInfo(displayRow: 0, column: "title").canEdit == false)

        let (noKey, _) = try await makeModel(session: FakeSession(), primaryKey: false)
        #expect(noKey.editBlock == .noPrimaryKey)
        #expect(EditBlock.noPrimaryKey.message == "No primary key — rows can't be edited safely.")
        #expect(noKey.canEdit == false)
        #expect(noKey.content?.rows.count == 3)
    }

    @Test func editsSurviveReloadsAndSorting() async throws {
        let (model, _) = try await makeModel(session: FakeSession())
        model.applyText(displayRow: 2, column: "title", text: "Reach us")
        model.reload()
        try await waitUntil { !model.isLoading }
        #expect(model.content?.rows[2][1] == .text("Reach us"))
        #expect(model.content?.isEdited(row: 2, column: 1) == true)
    }
}

// MARK: - Write gate

@MainActor
@Suite("Write gate")
struct WriteGateTests {
    private func gate(production: Bool = false, readOnly: Bool = false, database: String = "app") -> WriteGate {
        var profile = ConnectionProfile(name: "p", engine: .mysql, user: "u")
        profile.readOnly = readOnly
        if production { profile.colorTag = .production }
        let final = profile
        let gate = WriteGate()
        gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db ?? database) }
        return gate
    }

    @Test func plainWritesOnLocalConnectionsRunImmediately() async {
        let g = gate()
        #expect(await g.authorize(statements: ["UPDATE `t` SET a = 1 WHERE id = 3"]))
        if case .allow = g.lastDecision {} else { Issue.record("expected allow, got \(String(describing: g.lastDecision))") }
        #expect(await g.authorize(statements: ["SELECT 1"]))
    }

    @Test func productionAlwaysConfirmsAndDestructiveNeedsTheDatabaseName() async {
        let g = gate(production: true)
        var seen: ConfirmationRequest?
        g.confirmationHandler = { seen = $0; return true }
        #expect(await g.authorize(statements: ["INSERT INTO t (a) VALUES (1)"]))
        #expect(seen?.reasons.contains(.productionWrite) == true)
        #expect(seen?.requiresTypedName == nil)

        #expect(await g.authorize(statements: ["TRUNCATE TABLE `app`.`t`"], escalateToDestructive: true, database: "shop"))
        #expect(seen?.requiresTypedName == "shop")
        #expect(seen?.dryRuns.first?.sql == "SELECT COUNT(*) FROM `app`.`t`")
        #expect(seen?.isSatisfied(byTyped: " shop ") == true)
        #expect(seen?.isSatisfied(byTyped: "app") == false)
    }

    @Test func escalationMakesLocalBatchChangesConfirm() async {
        let g = gate()
        var confirmed = false
        g.confirmationHandler = { _ in confirmed = true; return false }
        #expect(await g.authorize(statements: ["ALTER TABLE `a`.`b` ENGINE=InnoDB"], escalateToDestructive: true) == false)
        #expect(confirmed)
    }

    @Test func readOnlyConnectionsBlockWithTheReason() async {
        let g = gate(readOnly: true)
        g.confirmationHandler = { _ in
            Issue.record("must not ask")
            return true
        }
        #expect(await g.authorize(statements: ["DELETE FROM t WHERE id = 1"]) == false)
        #expect(g.lastBlockedReason?.contains("read-only") == true)
        // Reads are fine even then.
        #expect(await g.authorize(statements: ["SELECT * FROM t"]))
    }

    @Test func notConnectedMeansNoWrite() async {
        #expect(await WriteGate().authorize(statements: ["DELETE FROM t WHERE id = 1"]) == false)
    }

    @Test func confirmationCopyIsPlainEnglish() {
        let c = StatementClassifier(dialect: SQLDialect(.mysql))
        let request = ConfirmationRequest(
            statements: [c.classify(text: "DELETE FROM t")],
            reasons: [.productionWrite, .unfilteredMutation(statementIndex: 0), .destructiveOnProduction],
            requiresTypedName: "shop", dryRuns: [], isProduction: true)
        let lines = ConfirmationCopy.reasons(for: request)
        #expect(lines.count == 3)
        #expect(lines[0].contains("production"))
        #expect(lines[1] == "This statement has no WHERE clause, so it applies to every row in the table.")
        #expect(ConfirmationCopy.isDestructive(request))
        let plan = DryRunPlan(statementIndex: 0, subject: "t", sql: "SELECT COUNT(*) FROM t", explanation: "Rows matched")
        #expect(ConfirmationCopy.impact(DryRunResult(plan: plan, count: 1204)) == "Affects ~1,204 rows")
        #expect(ConfirmationCopy.impact(DryRunResult(plan: plan, count: 1)) == "Affects ~1 row")
        let unknown = DryRunPlan(statementIndex: 0, subject: "x", sql: nil, explanation: "Can't estimate affected rows: joins.")
        #expect(ConfirmationCopy.impact(DryRunResult(plan: unknown, count: nil)) == "Can't estimate affected rows: joins.")
    }
}

// MARK: - Batch operations

@MainActor
@Suite("Batch table operations model")
struct BatchOperationsModelTests {
    private func tables() -> [TableInfo] {
        let ref = { TableRef(schema: "app", name: $0) }
        return [
            TableInfo(ref: ref("a_innodb"), kind: .table, engine: "InnoDB", estimatedRows: 10, collation: "utf8mb4_0900_ai_ci"),
            TableInfo(ref: ref("b_myisam"), kind: .table, engine: "MyISAM", estimatedRows: 20, collation: "utf8mb3_general_ci"),
            TableInfo(ref: ref("c_myisam"), kind: .table, engine: "MyISAM", estimatedRows: 30, collation: "utf8mb4_0900_ai_ci"),
            TableInfo(ref: ref("v_view"), kind: .view),
        ]
    }

    private func model(session: FakeSession) -> (BatchOperationsModel, WriteGate) {
        let gate = WriteGate()
        gate.contextProvider = { db in GuardContext(profile: ConnectionProfile(name: "x", engine: .mysql, user: "u"), currentDatabase: db) }
        gate.confirmationHandler = { _ in true }
        let m = BatchOperationsModel(
            schema: "app", tables: tables(), server: session.serverInfo, inspector: FakeInspector(), session: session, gate: gate)
        return (m, gate)
    }

    @Test func enginePlanSkipsMatchingTablesAndViews() async throws {
        let session = FakeSession()
        let (m, _) = model(session: session)
        await m.loadMetadata()
        #expect(m.engines == ["InnoDB", "MyISAM", "MEMORY"])
        #expect(m.engine == "InnoDB")
        #expect(m.skipReasons[TableRef(schema: "app", name: "a_innodb")] == "Already InnoDB")
        #expect(m.skipReasons[TableRef(schema: "app", name: "v_view")] != nil)
        #expect(m.plan?.statements == [
            "ALTER TABLE `app`.`b_myisam` ENGINE=InnoDB", "ALTER TABLE `app`.`c_myisam` ENGINE=InnoDB",
        ])
        #expect(m.previewSQL.hasSuffix(";"))
        #expect(m.plan?.warnings.isEmpty == false)  // DDL isn't transactional
        // Unchecking a table drops its statement; skipped tables can't be toggled.
        m.toggle(TableRef(schema: "app", name: "c_myisam"))
        #expect(m.statementCount == 1)
        m.toggle(TableRef(schema: "app", name: "a_innodb"))
        #expect(m.included.contains(TableRef(schema: "app", name: "a_innodb")))
    }

    @Test func convertDefaultsToUtf8mb4AndFiltersCollationsByCharset() async throws {
        let (m, _) = model(session: FakeSession())
        await m.loadMetadata()
        m.operation = .convert
        #expect(m.charset == "utf8mb4")
        #expect(m.collation == "utf8mb4_0900_ai_ci")
        #expect(m.collationsForCharset.map(\.name) == ["utf8mb4_0900_ai_ci", "utf8mb4_unicode_ci"])
        #expect(m.characterSets == ["utf8mb4", "utf8mb3"])
        #expect(m.skipReasons[TableRef(schema: "app", name: "a_innodb")] != nil)
        #expect(m.statementCount == 1)  // only b_myisam (utf8mb3); c already has the target collation
        m.alsoSetDatabaseDefault = true
        #expect(m.plan?.statements.last == "ALTER DATABASE `app` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci")
        m.charset = "utf8mb3"
        #expect(m.collation == "utf8mb3_general_ci")
    }

    @Test func runningExecutesStatementsAndReportsPerTable() async throws {
        let session = FakeSession()
        let (m, _) = model(session: session)
        await m.loadMetadata()
        var finished = false
        m.onFinished = { finished = true }
        await m.run()
        guard case .finished(let report) = m.runState else {
            Issue.record("expected finished, got \(m.runState)")
            return
        }
        #expect(report.succeededCount == 2)
        #expect(report.isClean)
        let executed = await session.executed.filter { $0.hasPrefix("ALTER") }
        #expect(executed == m.plan?.statements)
        #expect(m.summary?.hasPrefix("2 changed") == true)
        #expect(finished)
    }

    @Test func stopOnErrorLeavesTheRestNotRun() async throws {
        let session = FakeSession()
        await session.setFailWhenContaining("b_myisam")
        let (m, _) = model(session: session)
        await m.loadMetadata()
        m.stopOnError = true
        await m.run()
        guard case .finished(let report) = m.runState else { Issue.record("not finished"); return }
        #expect(report.failedCount == 1 && report.notRunCount == 1)
        let failed = m.plan?.steps.first { $0.table?.name == "b_myisam" }
        #expect(failed.flatMap { m.statuses[$0.id] } == .failed("Data too long for column 'title'"))
        let rest = m.plan?.steps.first { $0.table?.name == "c_myisam" }
        #expect(rest.flatMap { m.statuses[$0.id] } == .notRun("Not run after the error"))
    }

    @Test func declinedConfirmationRunsNothing() async throws {
        let session = FakeSession()
        let (m, gate) = model(session: session)
        gate.confirmationHandler = { _ in false }
        await m.loadMetadata()
        await m.run()
        #expect(m.runState == .idle)
        #expect(m.authorizationDeclined)
        #expect(await session.executed.contains { $0.hasPrefix("ALTER") } == false)
    }

    @Test func postgresHasNoBatchOperations() {
        #expect(BatchOperationsModel.unsupportedReason(for: .postgresql) != nil)
        #expect(BatchOperationsModel.unsupportedReason(for: .mysql) == nil)
        #expect(BatchOperationsModel.unsupportedReason(for: .mariadb) == nil)
    }
}
