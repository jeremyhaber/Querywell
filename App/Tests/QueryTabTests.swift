import Foundation
import QuerywellCore
import Testing
@testable import Querywell

/// A session that answers by statement prefix (Explain output and the like).
actor ScriptedSession: DatabaseSession {
    nonisolated let engine: DatabaseEngine
    nonisolated let serverInfo: ServerInfo
    private(set) var executed: [String] = []
    var responses: [(prefix: String, result: QueryResult)] = []

    init(engine: DatabaseEngine = .mysql) {
        self.engine = engine
        serverInfo = ServerInfo(engine: engine, versionString: "8.4.0", major: 8, minor: 4, patch: 0, tlsActive: false)
    }

    func respond(prefix: String, with result: QueryResult) { responses.append((prefix.uppercased(), result)) }
    func execute(_ sql: String) async throws -> QueryResult {
        executed.append(sql)
        let upper = sql.uppercased()
        return responses.first { upper.hasPrefix($0.prefix) }?.result ?? QueryResult()
    }
    func listDatabases() async throws -> [String] { ["app"] }
    func currentDatabase() async throws -> String? { "app" }
    func close() async {}
}

@MainActor
struct TabHarness {
    let model: QueryTabModel
    let session: FakeSession
    let gate: WriteGate
    let services: QueryServices
    let profile: ConnectionProfile
    /// Requests the confirmation handler saw.
    let confirmations: Box<[ConfirmationRequest]>
    let answer: Box<Bool>

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    init(production: Bool = false, readOnly: Bool = false, text: String = "", services: QueryServices? = nil, session: FakeSession = FakeSession()) {
        var p = ConnectionProfile(name: "test", engine: .mysql, user: "u")
        p.readOnly = readOnly
        if production { p.colorTag = .production }
        profile = p
        let final = p
        let services = services ?? QueryServices()
        self.services = services
        self.session = session
        let gate = WriteGate()
        gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db ?? "app") }
        gate.sessionProvider = { session }
        let seen = Box<[ConfirmationRequest]>([])
        let answer = Box(true)
        gate.confirmationHandler = { request in seen.value.append(request); return answer.value }
        confirmations = seen
        self.answer = answer
        self.gate = gate
        let model = QueryTabModel(profile: p, text: text)
        model.sessionProvider = { session }
        let inspector = FakeInspector()
        model.inspectorProvider = { inspector }
        model.schemaProvider = { "app" }
        model.gate = gate
        model.history = services.history(for: p.id)
        model.savedQueries = services.savedQueries
        self.model = model
    }
}

@MainActor
@Suite("Query tab model")
struct QueryTabModelTests {
    @Test func runStreamsResultsAndRecordsHistory() async throws {
        let h = TabHarness(text: "SELECT * FROM posts;\nSELECT 1")
        await h.model.run(.all)
        #expect(h.model.results.count == 2)
        #expect(h.model.results.map(\.title) == ["Result 1 · 3 rows", "Result 2 · 3 rows"])
        #expect(h.model.selectedItem?.statementIndex == 0)
        #expect(h.model.footerSummary?.hasPrefix("2 statements · ") == true)
        #expect(h.model.messages.contains { $0.text.contains("3 rows returned") })
        #expect(!h.model.isRunning)

        let history = try await h.services.history(for: h.profile.id).recent()
        #expect(history.count == 2)
        #expect(history.first?.sql == "SELECT 1")
        #expect(history.last?.rowCount == 3)
        #expect(history.first?.database == "app")
    }

    @Test func selectionRunsOnlyTheSelectedSQL() async {
        let h = TabHarness(text: "SELECT 1; SELECT 2")
        h.model.selection = NSRange(location: 10, length: 8)  // "SELECT 2"
        await h.model.run(.auto)
        let executed = await h.session.executed
        #expect(executed == ["SELECT 2"])
        await h.model.run(.currentStatement)
        #expect(await h.session.executed.count == 2)
    }

    @Test func writesReportRowsAffectedAndUpdateTheFooterHint() async {
        let h = TabHarness(text: "INSERT INTO posts (title) VALUES ('x')")
        await h.model.run(.all)
        #expect(h.model.results.first?.title == "Result 1 · 1 row affected")
        #expect(h.confirmations.value.isEmpty)
        h.model.refreshGuardHint()
        #expect(h.model.guardHint == .writesNoConfirmation)
        h.model.text = "SELECT 1"
        h.model.refreshGuardHint()
        #expect(h.model.guardHint.text == "Read-only query — no confirmation needed")
    }

    @Test func productionWritesNeedTheConfirmationAndStopWhenDeclined() async throws {
        let h = TabHarness(production: true, text: "UPDATE posts SET title = 'x' WHERE ID = 1")
        h.answer.value = false
        await h.model.run(.all)
        #expect(h.confirmations.value.count == 1)
        #expect(h.confirmations.value.first?.reasons.contains(.productionWrite) == true)
        #expect(await h.session.executed.isEmpty)
        #expect(h.model.results.isEmpty)
        #expect(try await h.services.history(for: h.profile.id).recent().isEmpty)

        h.answer.value = true
        await h.model.run(.all)
        #expect(h.confirmations.value.count == 2)
        #expect(await h.session.executed.count == 1)
        #expect(h.model.results.count == 1)
        h.model.refreshGuardHint()
        #expect(h.model.guardHint.text == "Writes need confirmation on PROD")
    }

    @Test func destructiveStatementsOnProductionAskForTheDatabaseName() async {
        let h = TabHarness(production: true, text: "DROP TABLE posts")
        h.answer.value = true
        await h.model.run(.all)
        #expect(h.confirmations.value.first?.requiresTypedName == "app")
        #expect(await h.session.executed == ["DROP TABLE posts"])
    }

    @Test func readOnlyConnectionsBlockWritesWithoutRunning() async {
        let h = TabHarness(readOnly: true, text: "DELETE FROM posts WHERE ID = 1")
        await h.model.run(.all)
        #expect(h.model.blockedReason != nil)
        #expect(await h.session.executed.isEmpty)
        #expect(h.gate.lastBlockedReason != nil)
        h.model.refreshGuardHint()
        #expect(h.model.guardHint == .blocked)
    }

    @Test func historyRerunGoesThroughTheGuard() async throws {
        let h = TabHarness(production: true)
        let services = h.services
        try await services.history(for: h.profile.id).record(HistoryEntry(sql: "DELETE FROM posts WHERE ID = 2", affected: 1))
        let entry = try #require(try await services.history(for: h.profile.id).recent().first)
        #expect(entry.rerunScript != nil)

        h.answer.value = false
        await h.model.loadAndRun(try #require(entry.rerunScript))
        #expect(h.model.text == "DELETE FROM posts WHERE ID = 2")
        #expect(h.confirmations.value.count == 1, "re-running a PROD write must ask first")
        #expect(await h.session.executed.isEmpty)

        // Truncated entries can't be re-run at all.
        let long = HistoryEntry(sql: "SELECT 1", isTruncated: true)
        #expect(long.rerunScript == nil)
        #expect(long.editorText.contains("truncated"))
    }

    @Test func failuresStopTheScriptKeepTheErrorAndMarkTheStatement() async throws {
        let session = FakeSession()
        await session.setFailWhenContaining("boom")
        let h = TabHarness(text: "SELECT 1;\nSELECT boom FROM posts;\nSELECT 3", session: session)
        await h.model.run(.all)
        #expect(h.model.results.count == 1)
        #expect(h.model.lastRun?.hasErrors == true)
        #expect(h.model.lastError?.statement.text.contains("boom") == true)
        #expect(h.model.lastError?.message.contains("Data too long") == true)
        #expect(h.model.selected != nil)
        #expect(h.model.statementRanges[1] == NSRange(location: 10, length: 22))
        h.model.jumpToStatement(1)  // no editor view in tests: must not crash
        let history = try await h.services.history(for: h.profile.id).recent()
        #expect(history.contains { $0.failed && $0.sql.contains("boom") })
        #expect(!history.contains { $0.sql.contains("SELECT 3") }, "skipped statements aren't history")
    }

    @Test func singleTableResultsBecomeEditableWithTheTableModel() async throws {
        let h = TabHarness(text: "SELECT * FROM posts")
        await h.model.run(.all)
        try await waitUntil { h.model.results.first?.verdict != nil }
        let item = try #require(h.model.results.first)
        #expect(item.verdict?.info?.table == TableRef(schema: "app", name: "posts"))
        let edit = try #require(item.editModel)
        try await waitUntil { edit.content != nil && !edit.isLoading }
        #expect(edit.content?.rows.count == 3)
        #expect(edit.canEdit)
        #expect(edit.applyText(displayRow: 0, column: "title", text: "Edited") == nil)
        #expect(h.model.pendingEditModels.count == 1)
        let report = await edit.commit()
        #expect(report?.isSuccess == true)
        let statements = await h.session.executed
        #expect(statements.contains { $0.hasPrefix("UPDATE") && $0.contains("Edited") })
    }

    @Test func joinsAndReadOnlyConnectionsAreNotEditable() async throws {
        let h = TabHarness(text: "SELECT p.ID FROM posts p JOIN users u ON u.ID = p.ID")
        await h.model.run(.all)
        try await waitUntil { h.model.results.first?.verdict != nil }
        #expect(h.model.results.first?.verdict?.reason == "Joins two tables")
        #expect(h.model.results.first?.editModel == nil)

        let ro = TabHarness(readOnly: true, text: "SELECT * FROM posts")
        await ro.model.run(.all)
        try await waitUntil { ro.model.results.first?.verdict != nil }
        #expect(ro.model.results.first?.verdict?.reason == "Read-only connection")
        #expect(ro.model.results.first?.editModel == nil)
    }

    @Test func formatLeavesUnsafeScriptsAlone() {
        let h = TabHarness(text: "select a,b from t where x=1")
        h.model.format()
        #expect(h.model.text.contains("\nFROM"))
        #expect(h.model.toast == nil)

        let unsafe = TabHarness(text: "DELIMITER $$\nselect 1$$")
        unsafe.model.format()
        #expect(unsafe.model.text == "DELIMITER $$\nselect 1$$")
        #expect(unsafe.model.toast?.message == "Couldn't format safely — left unchanged")
    }

    @Test func explainBuildsAPlanAndRefusesAnalyzeForWrites() async throws {
        let session = ScriptedSession()
        await session.respond(prefix: "EXPLAIN FORMAT=JSON", with: QueryResult(
            columns: [ColumnInfo(name: "EXPLAIN", typeName: "json")],
            rows: [[.text(#"{"query_block":{"select_id":1,"cost_info":{"query_cost":"1.20"},"table":{"table_name":"posts","access_type":"ALL","rows_examined_per_scan":3,"filtered":"100.00"}}}"#)]]))
        var profile = ConnectionProfile(name: "t", engine: .mysql, user: "u")
        profile.readOnly = false
        let model = QueryTabModel(profile: profile, text: "SELECT * FROM posts")
        model.sessionProvider = { session }
        await model.explain()
        guard case .done(let outcome) = model.explainState else { Issue.record("expected a plan, got \(model.explainState)"); return }
        #expect(outcome.plan.root.flattened.contains { $0.table == "posts" })
        #expect(model.selected == .plan)

        model.text = "UPDATE posts SET a = 1 WHERE ID = 1"
        model.explainAnalyze = true
        await model.explain()
        if case .done(let o) = model.explainState {
            #expect(o.note?.contains("only runs for read-only") == true)
            #expect(!o.sql.contains("ANALYZE"))
        }
        #expect(await session.executed.allSatisfy { !$0.uppercased().hasPrefix("UPDATE") }, "explain must never execute the write")
    }

    // MARK: Saved queries

    @Test func saveAsLinksTheTabAndCommandSUpdatesIt() async throws {
        let h = TabHarness(text: "SELECT * FROM wp_options WHERE autoload = 'yes'")
        var linked: SavedQuery?
        h.model.onLinked = { linked = $0 }
        var dirtyStates: [Bool] = []
        h.model.onDirtyChange = { dirtyStates.append($0) }

        await h.model.save()  // nothing linked yet: asks for details
        #expect(h.model.saveSheet != nil)
        let saved = try #require(await h.model.saveAs(name: "Autoloaded", notes: "heavy ones", tags: ["wp", "perf", "wp"], global: false))
        #expect(saved.connectionID == h.profile.id)
        #expect(saved.tags == ["wp", "perf"])
        #expect(linked?.id == saved.id)
        #expect(!h.model.isDirty)

        h.model.text += " LIMIT 10"
        #expect(h.model.isDirty)
        await h.model.save()
        #expect(!h.model.isDirty)
        #expect(dirtyStates == [true, false])
        let stored = try #require(try await h.services.savedQueries.query(id: saved.id))
        #expect(stored.sql.hasSuffix("LIMIT 10"))
    }

    @Test func savedQueriesHonourScopeAndRename() async throws {
        let services = QueryServices()
        let a = UUID(), b = UUID()
        let mine = try await services.savedQueries.save(name: "Only A", sql: "SELECT 1", connectionID: a)
        let shared = try await services.savedQueries.save(name: "Everywhere", sql: "SELECT 2", connectionID: nil)
        let library = QueryLibraryModel(connectionID: a, services: services)
        library.segment = .saved
        await library.reload()
        #expect(library.connectionSaved.map(\.name) == ["Only A"])
        #expect(library.globalSaved.map(\.name) == ["Everywhere"])
        #expect(library.allSaved.count == 2)

        let other = QueryLibraryModel(connectionID: b, services: services)
        other.segment = .saved
        await other.reload()
        #expect(other.saved.map(\.name) == ["Everywhere"])

        var renamed: SavedQuery?
        library.onSavedChanged = { renamed = $0 }
        await library.updateSaved(mine.id, name: "Renamed", notes: "n", tags: ["x"], global: true)
        #expect(renamed?.name == "Renamed" && renamed?.connectionID == nil)
        await other.reload()
        #expect(other.saved.map(\.name).sorted() == ["Everywhere", "Renamed"])

        library.search = "everyw"
        await library.reload()
        #expect(library.saved.map(\.name) == ["Everywhere"])
        _ = shared
    }

    @Test func historyAndSnippetSidebarData() async throws {
        let services = QueryServices()
        let id = UUID()
        let history = services.history(for: id)
        try await history.record(HistoryEntry(sql: "SELECT a FROM t", rowCount: 4))
        try await history.record(HistoryEntry(sql: "SELECT a FROM t", rowCount: 5))  // consecutive duplicate: run count
        try await history.record(HistoryEntry(sql: "DELETE FROM t", error: "boom"))
        let library = QueryLibraryModel(connectionID: id, services: services)
        library.segment = .history
        await library.reload()
        #expect(library.history.map(\.sql) == ["DELETE FROM t", "SELECT a FROM t"])
        #expect(library.history.last?.runCount == 2)
        library.search = "delete"
        await library.reload()
        #expect(library.history.first?.sql == "DELETE FROM t")
        await library.deleteHistory(library.history[0])
        #expect(library.history.allSatisfy { !$0.sql.contains("DELETE") })

        library.search = ""
        library.segment = .snippets
        let ok = await library.saveSnippet(existing: nil, name: "Drafts", sql: "SELECT * FROM ${1:t} WHERE post_status = 'draft'$0", tags: ["wp"], global: false)
        #expect(ok)
        await library.reload()
        #expect(library.snippets.map(\.name) == ["Drafts"])
        #expect(library.snippets.first?.connectionID == id)
    }

    @Test func insertAndReplaceWorkWithoutAnEditorView() {
        let h = TabHarness(text: "SELECT 1")
        h.model.selection = NSRange(location: 8, length: 0)
        h.model.insertIntoEditor("; SELECT 2")
        #expect(h.model.text == "SELECT 1; SELECT 2")
        h.model.insertSnippet("SELECT * FROM ${1:t} LIMIT ${2:10}$0")
        #expect(h.model.text.contains("SELECT * FROM t LIMIT 10"))
    }
}

@MainActor
@Suite("Workspace query tabs")
struct WorkspaceQueryTabTests {
    private func workspace() -> ConnectionWorkspace {
        let profile = ConnectionProfile(name: "x", engine: .mysql, user: "u")
        return ConnectionWorkspace(profile: profile, opener: ConnectionOpener(secretStore: InMemorySecretStore()), queryServices: QueryServices())
    }

    @Test func queryModelsKeepPersistedTextAndTrackDirtiness() async throws {
        let ws = workspace()
        let saved = try await ws.queryServices.savedQueries.save(name: "Drafts", sql: "SELECT 1", connectionID: ws.profile.id)
        ws.openSaved(saved)
        let tab = try #require(ws.tabs.selectedTab)
        #expect(tab.title == "Drafts" && tab.queryText == "SELECT 1")
        let model = try #require(ws.queryModel(forTab: tab))
        try await waitUntil { model.linkedQuery != nil }
        #expect(model.text == "SELECT 1" && !model.isDirty)
        model.text = "SELECT 2"
        #expect(model.isDirty)
        #expect(ws.tabs.tab(id: tab.id)?.isDirty == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(ws.tabs.tab(id: tab.id)?.queryText == "SELECT 2", "text is persisted into the tab state")
        // A second open focuses the same tab.
        ws.newQuery()
        ws.openSaved(saved)
        #expect(ws.tabs.selectedID == tab.id)

        // Renaming the saved query renames the tab; deleting unlinks it.
        ws.queryLibrary.segment = .saved
        await ws.queryLibrary.updateSaved(saved.id, name: "Renamed", notes: nil, tags: [], global: false)
        #expect(ws.tabs.tab(id: tab.id)?.title == "Renamed")
        await ws.queryLibrary.delete(saved)
        #expect(ws.tabs.tab(id: tab.id)?.savedQueryID == nil)
        #expect(model.linkedQuery == nil)
    }

    @Test func unsavedEditsInQueryResultsBlockCloseUntilResolved() async throws {
        let ws = workspace()
        let id = ws.tabs.newQuery()
        let tab = try #require(ws.tabs.tab(id: id))
        let model = try #require(ws.queryModel(forTab: tab))
        let session = FakeSession()
        model.sessionProvider = { session }
        let inspector = FakeInspector()
        model.inspectorProvider = { inspector }
        model.schemaProvider = { "app" }
        ws.gate.contextProvider = { _ in GuardContext(profile: ws.profile, currentDatabase: "app") }
        model.text = "SELECT * FROM posts"
        await model.run(.all)
        try await waitUntil { model.results.first?.editModel?.content != nil }
        let edit = try #require(model.results.first?.editModel)
        try await waitUntil { edit.canEdit }
        #expect(edit.applyText(displayRow: 1, column: "title", text: "Changed") == nil)
        #expect(ws.hasUnsavedEdits)
        ws.requestClose(tab: id)
        #expect(ws.closePrompt?.summary == "1 unsaved edit")
        #expect(ws.tabs.tab(id: id) != nil)
        ws.resolveClosePrompt(.discard)
        #expect(ws.tabs.tab(id: id) == nil)
    }
}

@Suite("Query tab wording")
struct QueryWordingTests {
    @Test func historyRowsReadLikeTheDesign() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_792_000_000)  // fixed
        func entry(_ sql: String, ago: TimeInterval, rows: Int? = nil, affected: Int? = nil, error: String? = nil) -> HistoryEntry {
            HistoryEntry(sql: sql, ranAt: now.addingTimeInterval(-ago), rowCount: rows, affected: affected, error: error)
        }
        #expect(HistoryRowFormat.title("-- note\nSELECT p.ID,\n  p.post_title\nFROM wp_posts p") == "SELECT p.ID, …")
        #expect(HistoryRowFormat.title("SHOW PROCESSLIST") == "SHOW PROCESSLIST")
        #expect(HistoryRowFormat.meta(entry("x", ago: 5, rows: 24), now: now, calendar: cal) == "Now · 24 rows")
        #expect(HistoryRowFormat.outcome(entry("x", ago: 0, rows: 1)) == "1 row")
        #expect(HistoryRowFormat.outcome(entry("x", ago: 0, affected: 1)) == "1 row changed")
        #expect(HistoryRowFormat.outcome(entry("x", ago: 0, affected: 412)) == "412 rows changed")
        #expect(HistoryRowFormat.outcome(entry("x", ago: 0, error: "Unknown column 'x'\nmore")) == "Unknown column 'x'")
        #expect(HistoryRowFormat.when(now.addingTimeInterval(-86_400 * 1.2), now: now, calendar: cal) == "Yesterday")
        #expect(HistoryRowFormat.when(now.addingTimeInterval(-86_400 * 200), now: now, calendar: cal).isEmpty == false)
    }

    @Test func suggestedNamesFollowCommentsOrFirstWords() {
        #expect(SavedQueryNaming.suggestedName(for: "-- Pages edited this month\nSELECT 1") == "Pages edited this month")
        #expect(SavedQueryNaming.suggestedName(for: "SELECT option_name, LENGTH(option_value) FROM wp_options WHERE autoload = 'yes'") ==
                "SELECT option_name, LENGTH(option_value) FROM wp_options WHE")
    }

    @Test func resultGridSortsClientSideAndDedupesColumnNames() async throws {
        let result = QueryResult(
            columns: [ColumnInfo(name: "ID", typeName: "bigint"), ColumnInfo(name: "id", typeName: "bigint"), ColumnInfo(name: "name", typeName: "varchar")],
            rows: [[.integer(10), .integer(1), .text("b")], [.integer(2), .integer(2), .text("a")], [.integer(33), .integer(3), .null]])
        let grid = await MainActor.run { ResultGridModel(result: result) }
        let names = await MainActor.run { grid.columnNames }
        #expect(names == ["ID", "id (2)", "name"])
        await MainActor.run {
            grid.toggleSort(column: "ID", additive: false)
            #expect(grid.rows.map { $0[0] } == [.integer(2), .integer(10), .integer(33)], "numeric, not lexicographic")
            grid.toggleSort(column: "ID", additive: false)
            #expect(grid.rows.first?[0] == .integer(33))
            grid.toggleSort(column: "name", additive: false)
            grid.toggleSort(column: "name", additive: false)
            grid.toggleSort(column: "name", additive: false)
            #expect(grid.rows.first?[0] == .integer(10), "third click clears the sort")
        }
    }
}
