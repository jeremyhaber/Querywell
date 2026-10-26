import Foundation
import QuerywellCore
import Testing
@testable import Querywell

// MARK: - Console

@MainActor
private struct ConsoleHarness {
    let model: ConsoleTabModel
    let session: FakeSession
    let services: QueryServices
    let profile: ConnectionProfile
    let confirmations: TabHarness.Box<[ConfirmationRequest]>
    let answer: TabHarness.Box<Bool>
    let quit = TabHarness.Box(false)
    let openedInGrid = TabHarness.Box<[String]>([])

    init(production: Bool = false, readOnly: Bool = false, engine: DatabaseEngine = .mysql) {
        var p = ConnectionProfile(name: "test", engine: engine, user: "u", defaultDatabase: "app")
        p.readOnly = readOnly
        if production { p.colorTag = .production }
        profile = p
        let final = p
        let session = FakeSession(engine: engine)
        self.session = session
        services = QueryServices()
        let gate = WriteGate()
        gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db ?? "app") }
        gate.sessionProvider = { session }
        let seen = TabHarness.Box<[ConfirmationRequest]>([])
        let answer = TabHarness.Box(true)
        gate.confirmationHandler = { request in seen.value.append(request); return answer.value }
        confirmations = seen
        self.answer = answer
        let model = ConsoleTabModel(profile: p)
        model.sessionProvider = { session }
        let inspector = FakeInspector(tables: [
            TableInfo(ref: TableRef(schema: "app", name: "posts"), kind: .table),
            TableInfo(ref: TableRef(schema: "app", name: "postmeta"), kind: .table),
            TableInfo(ref: TableRef(schema: "app", name: "users"), kind: .table),
        ])
        model.inspectorProvider = { inspector }
        model.gate = gate
        model.history = services.history(for: p.id)
        self.model = model
        let q = quit, g = openedInGrid
        model.onQuit = { q.value = true }
        model.onOpenInGrid = { g.value.append($0) }
    }

    var text: [String] { model.scrollback.map(\.plainText) }
}

@MainActor
@Suite("Console model")
struct ConsoleTabModelTests {
    @Test func selectPrintsAnAsciiTableAndTiming() async {
        let h = ConsoleHarness()
        await h.model.startIfNeeded()
        await h.model.submit("SELECT * FROM posts;")
        let lines = h.text
        #expect(lines.contains("mysql> SELECT * FROM posts;"))
        #expect(lines.contains("+----+---------+---------+"))
        #expect(lines.contains("| ID | title   | status  |"))
        #expect(lines.contains("|  1 | Home    | publish |"))
        #expect(lines.contains("|  3 | Contact | NULL    |"))
        #expect(lines.contains { $0.hasPrefix("3 rows in set (") })
        #expect(lines.contains("↗ Open in grid"))
        #expect(h.model.lastResultSQL == "SELECT * FROM posts")
        #expect(h.model.editor.isEmpty)
    }

    @Test func openInGridHandsTheSQLToTheWorkspace() async {
        let h = ConsoleHarness()
        await h.model.submit("SELECT * FROM posts;")
        h.model.openLastResultInGrid()
        #expect(h.openedInGrid.value == ["SELECT * FROM posts"])
    }

    @Test func verticalTerminatorPrintsRecords() async {
        let h = ConsoleHarness()
        await h.model.submit("SELECT * FROM posts\\G")
        #expect(h.text.contains("*************************** 1. row ***************************"))
        #expect(h.text.contains(" title: Home"))
        #expect(h.text.contains("    ID: 1"))
        #expect(!h.text.contains { $0.hasPrefix("+--") })
    }

    @Test func serverErrorsLookLikeTheMysqlClient() async {
        let h = ConsoleHarness()
        await h.session.setFailWhenContaining("boom")
        await h.model.submit("SELECT boom;")
        #expect(h.text.contains("ERROR 1406 (22001): Data too long for column 'title'"))
    }

    @Test func multiLineInputContinuesUntilTheSemicolon() async {
        let h = ConsoleHarness()
        h.model.edit { $0.insert("SELECT *") }
        h.model.enter()
        #expect(h.model.editor.lines == ["SELECT *", ""])
        #expect(h.model.prompt(forLine: 1) == "    -> ")
        #expect(h.text.isEmpty, "an unfinished statement is not echoed or run")
        h.model.edit { $0.insert("FROM posts;") }
        h.model.enter()
        try? await waitUntil { !h.model.isRunning && h.text.contains { $0.hasPrefix("3 rows in set") } }
        #expect(h.text.contains("mysql> SELECT *"))
        #expect(h.text.contains("    -> FROM posts;"))
        let executed = await h.session.executed
        #expect(executed.contains("SELECT *\nFROM posts"))
    }

    @Test func productionWriteAsksForConfirmationAndCancelPrintsCancelled() async {
        let h = ConsoleHarness(production: true)
        h.answer.value = false
        await h.model.submit("DELETE FROM posts;")
        #expect(h.confirmations.value.count == 1)
        #expect(h.confirmations.value.first?.requiresTypedName == "app")
        #expect(h.text.contains("Cancelled."))
        let executed = await h.session.executed
        #expect(!executed.contains { $0.hasPrefix("DELETE") })
    }

    @Test func confirmedProductionWriteRunsAndReportsRowsAffected() async {
        let h = ConsoleHarness(production: true)
        h.answer.value = true
        await h.session.setForcedAffectedRows(412)
        await h.model.submit("DELETE FROM posts WHERE ID = 1;")
        #expect(h.confirmations.value.count == 1)
        #expect(h.text.contains { $0.hasPrefix("Query OK, 412 rows affected (") })
        let executed = await h.session.executed
        #expect(executed.contains { $0.hasPrefix("DELETE") })
    }

    @Test func readsDontAskForConfirmationEvenOnProduction() async {
        let h = ConsoleHarness(production: true)
        await h.model.submit("SELECT 1;")
        #expect(h.confirmations.value.isEmpty)
    }

    @Test func readOnlyConnectionsBlockWrites() async {
        let h = ConsoleHarness(readOnly: true)
        await h.model.submit("UPDATE posts SET title = 'x' WHERE ID = 1;")
        #expect(h.text.contains { $0.hasPrefix("ERROR: ") && $0.localizedCaseInsensitiveContains("read-only") })
        let executed = await h.session.executed
        #expect(!executed.contains { $0.hasPrefix("UPDATE") })
        #expect(h.confirmations.value.isEmpty)
    }

    @Test func historyIsSharedWithTheQueryEditorAndBrowsableWithTheArrowKeys() async throws {
        let h = ConsoleHarness()
        await h.model.submit("SELECT 1;")
        await h.model.submit("SELECT 2;")
        // Same store the query editor writes to.
        let stored = try await h.services.history(for: h.profile.id).recent()
        #expect(stored.map(\.sql) == ["SELECT 2", "SELECT 1"])
        h.model.edit { $0.insert("draft") }
        h.model.historyPrevious()
        #expect(h.model.editor.text == "SELECT 2")
        h.model.historyPrevious()
        #expect(h.model.editor.text == "SELECT 1")
        h.model.historyNext()
        h.model.historyNext()
        #expect(h.model.editor.text == "draft")
    }

    @Test func historyLoadedFromEarlierSessions() async throws {
        let h = ConsoleHarness()
        _ = try await h.services.history(for: h.profile.id).record(HistoryEntry(sql: "SHOW TABLES", rowCount: 3))
        await h.model.startIfNeeded()
        h.model.historyPrevious()
        #expect(h.model.editor.text == "SHOW TABLES")
    }

    @Test func clientCommands() async {
        let h = ConsoleHarness()
        await h.model.submit("help")
        #expect(h.text.contains { $0.contains("use <database>") })
        await h.model.submit("use other_db")
        #expect(h.text.contains("Database changed"))
        #expect(h.model.currentDatabase == "other_db")
        let executed = await h.session.executed
        #expect(executed.contains("USE `other_db`"))
        await h.model.submit("clear")
        #expect(h.model.scrollback.isEmpty)
        await h.model.submit("\\q")
        #expect(h.quit.value)
    }

    @Test func tabCompletesTableNamesAndListsAmbiguousOnes() async {
        let h = ConsoleHarness()
        await h.model.startIfNeeded()
        h.model.edit { $0.insert("SELECT * FROM us") }
        await h.model.complete()
        #expect(h.model.editor.text == "SELECT * FROM users ")
        h.model.edit { $0.set(text: "SELECT * FROM pos") }
        await h.model.complete()
        #expect(h.model.editor.text == "SELECT * FROM post", "the common prefix of posts and postmeta is inserted first")
        await h.model.complete()
        #expect(h.model.editor.text == "SELECT * FROM post", "nothing more to add: the candidates are listed instead")
        #expect(h.text.contains { $0.contains("posts") && $0.contains("postmeta") })
    }

    @Test func wideCellsAreTruncatedAccordingToTheSetting() async {
        let h = ConsoleHarness()
        h.model.formatOptions = { ConsoleFormatOptions(maxCellWidth: 5) }
        await h.model.submit("SELECT * FROM posts;")
        #expect(h.text.contains("|  3 | Cont… | NULL   |") || h.text.contains { $0.contains("Cont…") })
    }

    @Test func postgresPromptShowsTheDatabase() async {
        let h = ConsoleHarness(engine: .postgresql)
        await h.model.startIfNeeded()
        #expect(h.model.primaryPrompt == "app=# ")
    }
}

// MARK: - Terminal

@MainActor
@Suite("Terminal tab model")
struct TerminalTabModelTests {
    @Test func unavailableWithoutSSH() {
        let model = TerminalTabModel(profile: ConnectionProfile(name: "local", engine: .mysql, user: "u"))
        guard case .unavailable(let reason) = model.state else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("doesn't use SSH"))
        model.start()
        #expect(!model.isRunning)
    }

    @Test func commandUsesTheSharedSSHOptionsAndAForcedTTY() {
        let ssh = SSHTunnelConfig(host: "web01", port: 2200, user: "deploy", auth: .password)
        let model = TerminalTabModel(profile: ConnectionProfile(name: "p", engine: .mysql, user: "u", ssh: ssh))
        model.secretProvider = { "pw" }
        let cmd = model.command
        #expect(cmd?.executable == "/usr/bin/ssh")
        #expect(cmd?.arguments.suffix(2) == ["-t", "deploy@web01"])
        #expect(cmd?.arguments.contains("StrictHostKeyChecking=accept-new") == true)
        #expect(cmd?.arguments.joined(separator: " ").contains("pw") == false, "the secret never appears in argv")
        #expect(model.title == "deploy@web01:2200")
    }
}

// MARK: - Export

private let mysql8 = ServerInfo(engine: .mysql, versionString: "8.4.0", major: 8, minor: 4, patch: 0, tlsActive: false)

private func exportTables() -> [TableInfo] {
    [
        TableInfo(ref: TableRef(schema: "wp", name: "wp_options"), kind: .table, dataBytes: 14_000_000, indexBytes: 100_000),
        TableInfo(ref: TableRef(schema: "wp", name: "wp_posts"), kind: .table, dataBytes: 9_000_000, indexBytes: 1_000_000),
        TableInfo(ref: TableRef(schema: "wp", name: "wp_postmeta"), kind: .table, dataBytes: 92_000_000, indexBytes: 8_000_000),
    ]
}

private func sshProfile(password: String = "s3cr3t-db-pw") -> (ConnectionProfile, InMemorySecretStore) {
    let ssh = SSHTunnelConfig(host: "web01", port: 22, user: "deploy", auth: .password)
    let profile = ConnectionProfile(name: "web01", engine: .mysql, host: "mysql8", user: "wp", defaultDatabase: "wp", ssh: ssh)
    let store = InMemorySecretStore()
    try? store.write(password, for: SecretKey(ownerID: profile.id.uuidString, kind: .databasePassword))
    try? store.write("ssh-pw", for: SecretKey(ownerID: profile.id.uuidString, kind: .sshPassword))
    return (profile, store)
}

private let homebrewMysqldump = ToolInfo(
    path: "/opt/homebrew/opt/mysql-client/bin/mysqldump", name: "mysqldump", role: .dump, flavour: .mysql,
    version: ToolVersion(8, 4, 2), versionOutput: "mysqldump  Ver 8.4.2 for macos14.2 on arm64 (Homebrew)")

@MainActor
@Suite("Export sheet model")
struct ExportSheetModelTests {
    private func make(tools: [ToolInfo] = [homebrewMysqldump], ssh: Bool = true) async -> (ExportSheetModel, String) {
        let password = "s3cr3t-db-pw"
        let (profile, store) = ssh ? sshProfile(password: password) : {
            var p = ConnectionProfile(name: "local", engine: .mysql, user: "wp", defaultDatabase: "wp")
            p.ssh = nil
            let s = InMemorySecretStore()
            try? s.write(password, for: SecretKey(ownerID: p.id.uuidString, kind: .databasePassword))
            return (p, s)
        }()
        let model = ExportSheetModel(profile: profile, database: "wp", serverInfo: mysql8, tables: exportTables(), secretStore: store, tunnelLocalPort: 54321)
        model.toolLocator = { tools }
        await model.load(inspector: nil)
        return (model, password)
    }

    @Test func defaultsToTheServerWhenThereIsSSH() async {
        let (model, _) = await make()
        #expect(model.location == .remoteOverSSH)
        #expect(model.plan?.location == .remoteOverSSH)
        #expect(model.subtitle == "web01 · MySQL 8.4 · 3 tables · about 124 MB" || model.subtitle.hasPrefix("web01 · MySQL 8.4 · 3 tables · about "))
    }

    @Test func planRegeneratesWhenOptionsChange() async {
        let (model, _) = await make()
        #expect(model.commandPreview.contains("--single-transaction"))
        model.singleTransaction = false
        #expect(!model.commandPreview.contains("--single-transaction"))
        model.scope = .structureOnly
        #expect(model.commandPreview.contains("--no-data"))
        model.gzip = false
        #expect(model.plan?.outputFilename.hasSuffix(".sql") == true)
        #expect(model.destination.lastPathComponent == model.plan?.outputFilename, "the default destination follows the file name")
        model.addDropTable = false
        #expect(model.commandPreview.contains("--skip-add-drop-table"))
    }

    @Test func tableSelectionLimitsTheDump() async {
        let (model, _) = await make()
        #expect(model.plan?.tables == nil)
        model.selectedTables = ["wp_posts"]
        #expect(model.plan?.tables == ["wp_posts"])
        #expect(model.tablesSummary == "1 of 3 tables")
        model.selectNoTables()
        #expect(model.plan == nil)
        #expect(model.planError == "Choose at least one table to export.")
        model.selectAllTables()
        #expect(model.plan != nil && model.tablesSummary == "All 3 tables")
    }

    @Test func previewRedactsThePassword() async {
        let (model, password) = await make()
        #expect(!model.commandPreview.contains(password))
        #expect(model.commandPreview.contains("****"))
        model.location = .localThroughTunnel
        #expect(!model.commandPreview.contains(password))
        #expect(model.commandPreview.contains("****"))
        #expect(model.commandPreview.contains("/opt/homebrew/opt/mysql-client/bin/mysqldump"))
        #expect(model.commandPreview.contains("--port=54321"), "local exports use the tunnel's port")
    }

    @Test func localToolIsDescribedAndIssuesSurface() async {
        let (model, _) = await make()
        model.location = .localThroughTunnel
        #expect(model.locationDetail.local == "Uses mysqldump from Homebrew (found: 8.4.2). Slower on large tables.")
        #expect(model.toolIssues.isEmpty)
        #expect(model.installHint == nil)

        let older = ToolInfo(path: "/usr/local/bin/mysqldump", name: "mysqldump", role: .dump, flavour: .mysql,
                             version: ToolVersion(5, 7, 40), versionOutput: "mysqldump  Ver 10.13 Distrib 5.7.40")
        let (outdated, _) = await make(tools: [older])
        outdated.location = .localThroughTunnel
        #expect(outdated.toolIssues.contains { if case .toolOlderThanServer = $0 { true } else { false } })
        #expect(outdated.plan != nil, "an older tool still works; it only warns")
    }

    @Test func missingToolShowsTheInstallHintAndBlocksLocalExport() async {
        let (model, _) = await make(tools: [])
        model.location = .localThroughTunnel
        #expect(model.plan == nil)
        #expect(model.toolIssues.contains { if case .noToolFound = $0 { true } else { false } })
        #expect(model.installHint == "brew install mysql-client")
        #expect(model.planError?.contains("brew install") == true)
        model.location = .remoteOverSSH
        #expect(model.plan != nil, "the server export doesn't need a local tool")
    }

    @Test func connectionsWithoutSSHCanOnlyExportLocally() async {
        let (model, _) = await make(ssh: false)
        #expect(model.location == .localThroughTunnel)
        #expect(!model.canExportOnServer)
        model.location = .remoteOverSSH
        #expect(model.plan == nil)
        #expect(model.planError != nil)
    }

    @Test func collationChoicesMapToCoreMappings() async {
        let (model, _) = await make()
        #expect(model.plan?.collation == nil)
        model.collationChoice = .mysql57
        #expect(model.plan?.collation == .mysql57MariaDBCompatible)
        #expect(model.plan?.localStages.contains("collation rewrite") == true)
        model.collationChoice = .legacy
        #expect(model.plan?.collation == .legacyUnicodeCI)
        model.collationChoice = .custom
        model.customCharset = "utf8mb4"
        model.customCollation = "utf8mb4_general_ci"
        #expect(model.plan?.collation == .custom(charset: "utf8mb4", collation: "utf8mb4_general_ci"))
    }

    @Test func transientsNeedAWordPressOptionsTable() async {
        let (model, _) = await make()
        #expect(!model.supportsTransients)
        model.skipTransients = true
        #expect(model.plan != nil, "ignored while no options table was detected")
        let inspector = FakeInspector()
        // FakeInspector's columns are ID/title/status: not an options table.
        await model.detectWordPress(inspector: inspector)
        #expect(model.optionsTables.isEmpty && !model.skipTransients)
    }

    @Test func destinationDefaultsToDownloads() async {
        let (model, _) = await make()
        #expect(model.destinationDisplay.hasPrefix("~/Downloads/wp-"))
        let chosen = URL(fileURLWithPath: "/tmp/mine.sql.gz")
        model.chooseDestination(chosen)
        model.gzip = false
        #expect(model.destination == chosen, "a chosen destination is kept when options change")
    }
}

// MARK: - Import

private func writeTempSQL(_ text: String, name: String = "dump.sql") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-import-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
private func importModel(production: Bool = false, readOnly: Bool = false, file: URL, answer: Bool = true) -> (ImportSheetModel, FakeSession, TabHarness.Box<[ConfirmationRequest]>) {
    var profile = ConnectionProfile(name: "test", engine: .mysql, user: "u", defaultDatabase: "app")
    profile.readOnly = readOnly
    if production { profile.colorTag = .production }
    let final = profile
    let session = FakeSession()
    let gate = WriteGate()
    gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db ?? "app") }
    gate.sessionProvider = { session }
    let seen = TabHarness.Box<[ConfirmationRequest]>([])
    gate.confirmationHandler = { request in seen.value.append(request); return answer }
    let model = ImportSheetModel(file: file, profile: profile, schemas: ["app", "other"], currentSchema: "app")
    model.sessionProvider = { session }
    // Supported: MySQL 5.7-like server without the 0900 collations.
    var inspector = FakeInspector()
    inspector.collations = [
        CollationInfo(name: "utf8mb4_general_ci", characterSet: "utf8mb4", isDefault: true),
        CollationInfo(name: "utf8mb4_unicode_ci", characterSet: "utf8mb4", isDefault: false),
        CollationInfo(name: "utf8mb4_unicode_520_ci", characterSet: "utf8mb4", isDefault: false),
        CollationInfo(name: "utf8_general_ci", characterSet: "utf8", isDefault: true),
    ]
    let captured = inspector
    model.inspectorProvider = { captured }
    model.gate = gate
    return (model, session, seen)
}

private let dump0900 = """
CREATE TABLE `posts` (
  `id` int NOT NULL,
  `title` varchar(100) COLLATE utf8mb4_0900_ai_ci DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
INSERT INTO `posts` VALUES (1,'utf8mb4_0900_ai_ci stays in data');
"""

@MainActor
@Suite("Import sheet model")
struct ImportSheetModelTests {
    @Test func scanFindsUnsupportedCollationsAndPreselectsTheSuggestedMapping() async throws {
        let url = try writeTempSQL(dump0900)
        let (model, _, _) = importModel(file: url)
        await model.loadAndScan()
        guard case .done(let summary) = model.scan else { Issue.record("scan: \(model.scan)"); return }
        #expect(summary.unsupportedCollations == ["utf8mb4_0900_ai_ci"])
        #expect(summary.suggestedName == "MySQL 5.7 / MariaDB compatible")
        #expect(model.collationChoice == .suggested)
        #expect(model.collationMapping == .mysql57MariaDBCompatible)
    }

    @Test func compatibleFilesNeedNoRewrite() async throws {
        let url = try writeTempSQL("CREATE TABLE t (a int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\n")
        let (model, _, _) = importModel(file: url)
        await model.loadAndScan()
        guard case .done(let summary) = model.scan else { Issue.record("scan failed"); return }
        #expect(!summary.needsRewrite)
        #expect(model.collationChoice == .none)
        #expect(model.collationMapping == nil)
    }

    @Test func productionRequiresTheTypedDatabaseName() async throws {
        let url = try writeTempSQL("SELECT 1;\n")
        let (model, _, seen) = importModel(production: true, file: url)
        let request = model.confirmationRequest()
        #expect(request?.requiresTypedName == "app")
        #expect(request?.statements.first?.text.hasPrefix("SOURCE ") == true)
        model.targetSchema = "other"
        #expect(model.confirmationRequest()?.requiresTypedName == "other", "the target schema is what has to be typed")
        let token = await model.authorize()
        #expect(token != nil)
        #expect(seen.value.count == 1)
        #expect(seen.value.first?.requiresTypedName == "other")
    }

    @Test func nonProductionAsksOnlyForWhatTheGuardNeeds() async throws {
        let url = try writeTempSQL("SELECT 1;\n")
        let (model, _, seen) = importModel(file: url)
        let request = model.confirmationRequest()
        #expect(request == nil || request?.requiresTypedName == nil)
        _ = await model.authorize()
        #expect(seen.value.allSatisfy { $0.requiresTypedName == nil })
    }

    @Test func declinedConfirmationRunsNothing() async throws {
        let url = try writeTempSQL("DROP TABLE a;\nCREATE TABLE a (x int);\n")
        let (model, session, _) = importModel(production: true, file: url, answer: false)
        await model.loadAndScan()
        await model.start()
        #expect(model.phase == .setup)
        let executed = await session.executed
        #expect(executed.isEmpty)
    }

    @Test func readOnlyConnectionsCannotImport() async throws {
        let url = try writeTempSQL("SELECT 1;\n")
        let (model, _, _) = importModel(readOnly: true, file: url)
        #expect(!model.canStart)
        let token = await model.authorize()
        #expect(token == nil)
    }

    @Test func runUsesTheTargetSchemaAndReportsProgress() async throws {
        let url = try writeTempSQL("CREATE TABLE a (x int);\nINSERT INTO a VALUES (1);\n")
        let (model, session, _) = importModel(file: url)
        model.targetSchema = "other"
        await model.loadAndScan()
        var finishedFor: String?
        model.onFinished = { finishedFor = $0 ?? "-" }
        await model.start()
        #expect(model.phase == .finished)
        #expect(model.report?.statementsExecuted == 2 && model.report?.succeeded == true)
        let executed = await session.executed
        #expect(executed.first == "USE `other`")
        #expect(executed.contains("CREATE TABLE a (x int)"))
        #expect(finishedFor == "other")
        #expect(model.fraction == 1)
    }

    @Test func stopOnErrorOffAsksAndStopsWhenToldTo() async throws {
        let url = try writeTempSQL("INSERT INTO a VALUES (1);\nINSERT INTO a VALUES ('FAIL');\nINSERT INTO a VALUES (3);\n")
        let (model, session, _) = importModel(file: url)
        await session.setFailWhenContaining("FAIL")
        model.stopOnError = false
        await model.loadAndScan()
        let run = Task { await model.start() }
        try await waitUntil(.seconds(5)) { model.pendingError != nil }
        #expect(model.pendingError?.error.statementIndex == 1)
        model.resolveError(.stop)
        await run.value
        #expect(model.report?.stoppedOnError == true)
        #expect(model.errorCount == 1)
        let executed = await session.executed
        #expect(!executed.contains { $0.contains("(3)") })
    }

    @Test func stopOnErrorOffContinueKeepsGoingAndListsErrors() async throws {
        let url = try writeTempSQL("INSERT INTO a VALUES (1);\nINSERT INTO a VALUES ('FAIL');\nINSERT INTO a VALUES (3);\n")
        let (model, session, _) = importModel(file: url)
        await session.setFailWhenContaining("FAIL")
        model.stopOnError = false
        await model.loadAndScan()
        let run = Task { await model.start() }
        try await waitUntil(.seconds(5)) { model.pendingError != nil }
        model.resolveError(.continue, askAgain: false)
        await run.value
        #expect(model.report?.completed == true)
        #expect(model.errors.count == 1 && model.errors[0].message.contains("Data too long"))
        let executed = await session.executed
        #expect(executed.contains { $0.contains("(3)") })
    }
}

// MARK: - Result export

@MainActor
@Suite("Result export model")
struct ResultExportModelTests {
    private let result = QueryResult(
        columns: [ColumnInfo(name: "id", typeName: "int"), ColumnInfo(name: "note", typeName: "varchar")],
        rows: [[.integer(1), .text("a,b")], [.integer(2), .null]])

    private func export(_ configure: (ResultExportModel) -> Void) async throws -> String {
        let model = ResultExportModel(source: .result(result), name: "Result 1", engine: .mysql, schema: "app", tableName: "notes")
        configure(model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qw-\(UUID().uuidString).\(model.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        await model.run(to: url)
        guard case .finished(_, let rows, _) = model.state else { Issue.record("state: \(model.state)"); return "" }
        #expect(rows == 2)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func csvOptions() async throws {
        let text = try await export { $0.delimiter = .semicolon; $0.nullStyle = .backslashN }
        #expect(text == "id;note\r\n1;a,b\r\n2;\\N\r\n")
        let noHeader = try await export { $0.includeHeader = false; $0.nullStyle = .literal }
        #expect(noHeader == "1,\"a,b\"\r\n2,NULL\r\n")
        let model = ResultExportModel(source: .result(result), name: "r", engine: .mysql, schema: "app", tableName: "t")
        model.utf8BOM = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qw-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        await model.run(to: url)
        let bytes = try Data(contentsOf: url)
        #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF])
    }

    @Test func jsonLayouts() async throws {
        let array = try await export { $0.kind = .json }
        #expect(array.hasPrefix("[") && array.contains("\"note\""))
        let lines = try await export { $0.kind = .json; $0.jsonLayout = .lines }
        #expect(!lines.hasPrefix("[") && lines.split(separator: "\n").count == 2)
    }

    @Test func sqlInsertUsesTheTableNameAndBatchSize() async throws {
        let one = try await export { $0.kind = .sql; $0.rowsPerStatement = 1 }
        #expect(one.contains("INSERT INTO `app`.`notes`"))
        #expect(one.components(separatedBy: "INSERT INTO").count == 3)
        let batch = try await export { $0.kind = .sql; $0.insertTable = "other.copy"; $0.rowsPerStatement = 100 }
        #expect(batch.contains("`other`.`copy`") && batch.components(separatedBy: "INSERT INTO").count == 2)
    }

    @Test func suggestedFileNameFollowsTheFormat() {
        let model = ResultExportModel(source: .result(result), name: "wp_posts", engine: .mysql, schema: "app", tableName: "wp_posts")
        #expect(model.suggestedFileName == "wp_posts.csv")
        model.kind = .json
        #expect(model.suggestedFileName == "wp_posts.json")
        model.jsonLayout = .lines
        #expect(model.suggestedFileName == "wp_posts.jsonl")
        model.kind = .sql
        #expect(model.suggestedFileName == "wp_posts.sql")
        model.delimiter = .tab
        model.kind = .csv
        #expect(model.suggestedFileName == "wp_posts.tsv")
    }

    @Test func tableExportReadsEveryPageWithTheFiltersOfTheQuery() async throws {
        let session = FakeSession()
        let query = TableQuery(table: TableRef(schema: "app", name: "posts"), primaryKey: ["ID"])
        let model = ResultExportModel(source: .table(query), name: "posts", engine: .mysql, schema: "app", tableName: "posts")
        model.sessionProvider = { session }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qw-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        await model.run(to: url)
        guard case .finished(_, let rows, _) = model.state else { Issue.record("state: \(model.state)"); return }
        #expect(rows >= 3)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("ID,title,status"))
    }
}
