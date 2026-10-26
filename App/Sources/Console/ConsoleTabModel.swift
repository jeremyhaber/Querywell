import Foundation
import Observation
import QuerywellCore

/// How a piece of scrollback is coloured.
enum ConsoleRole: Equatable {
    case prompt, input, text, muted, border, header, row, footer, success, error, warning
    /// Clickable "Open in grid"; the payload is the SQL to open.
    case link(sql: String)
}

struct ConsoleSegment: Equatable {
    var text: String
    var role: ConsoleRole
}

/// One line of scrollback (no trailing newline).
struct ConsoleLine: Identifiable, Equatable {
    let id: Int
    var segments: [ConsoleSegment]
    var plainText: String { segments.map(\.text).joined() }
}

/// State and behaviour of the SQL console tab. Statements go through `QueryRunner`, so the PROD guard
/// and read-only mode apply exactly as in the query editor; every confirmation uses the shared `WriteGate`.
@MainActor @Observable
final class ConsoleTabModel {
    /// Rows printed per result set; the rest is summarised (open the query in the grid to see everything).
    static let maxRowsShown = 1_000
    static let maxScrollbackLines = 8_000

    // MARK: Environment (injected by the workspace; tests inject fakes)

    @ObservationIgnored var profile: ConnectionProfile
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var inspectorProvider: @MainActor () -> (any SchemaInspector)? = { nil }
    @ObservationIgnored var initialDatabaseProvider: @MainActor () -> String? = { nil }
    @ObservationIgnored var gate: WriteGate?
    @ObservationIgnored var history: QueryHistoryStore?
    @ObservationIgnored var formatOptions: @MainActor () -> ConsoleFormatOptions = { ConsoleFormatOptions() }
    @ObservationIgnored var onHistoryChanged: @MainActor () -> Void = {}
    /// `quit` / `\q`.
    @ObservationIgnored var onQuit: @MainActor () -> Void = {}
    /// "Open in grid": a new query tab with this SQL, run there.
    @ObservationIgnored var onOpenInGrid: @MainActor (String) -> Void = { _ in }
    /// `USE db` succeeded: the window's schema selection follows.
    @ObservationIgnored var onDatabaseChanged: @MainActor (String) -> Void = { _ in }

    // MARK: State

    private(set) var scrollback: [ConsoleLine] = []
    /// Bumped by `clear` so the view knows to rebuild instead of append.
    private(set) var clearCount = 0
    private(set) var editor = ConsoleLineEditor()
    private(set) var continuation: ConsoleContinuation = .statement
    private(set) var isRunning = false
    private(set) var currentDatabase: String?
    /// `nil` until known (PostgreSQL has no session autocommit switch we track).
    private(set) var autocommit: Bool? = true
    /// SQL of the latest result set, for ⇧⌘G.
    private(set) var lastResultSQL: String?
    private(set) var historyNavigator = ConsoleHistoryNavigator()
    @ObservationIgnored private var nextLineID = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var loader: SchemaCatalogLoader?
    @ObservationIgnored private var hasStarted = false

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    var dialect: SQLDialect { SQLDialect(profile.engine) }
    var engine: DatabaseEngine { profile.engine }

    /// The live prompt, for the current continuation state.
    var primaryPrompt: String { ConsolePrompt.primary(engine: engine, database: currentDatabase ?? profile.defaultDatabase) }

    func prompt(forLine index: Int) -> String {
        if index == 0 { return primaryPrompt }
        let kind: ConsoleContinuation = index == editor.lines.count - 1 ? continuation : .statement
        return ConsolePrompt.continuation(kind, engine: engine, database: currentDatabase ?? profile.defaultDatabase)
    }

    /// "wp_sunset · autocommit on", shown in the header.
    var statusText: String {
        var parts = [currentDatabase ?? "no database selected"]
        if engine != .postgresql, let autocommit { parts.append("autocommit " + (autocommit ? "on" : "off")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Lifecycle

    /// Loads the current database and history the first time the tab is shown.
    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        if let session = sessionProvider() {
            currentDatabase = (try? await session.currentDatabase()) ?? initialDatabaseProvider()
            if engine != .postgresql { await refreshAutocommit() }
        } else {
            currentDatabase = initialDatabaseProvider()
        }
        await reloadHistory()
        if scrollback.isEmpty { printBanner() }
    }

    private func printBanner() {
        let server = sessionProvider()?.serverInfo.versionString ?? ""
        append([ConsoleSegment(text: "Querywell console · \(profile.name)" + (server.isEmpty ? "" : " · \(server)"), role: .muted)])
        append([ConsoleSegment(text: "Type help for commands. Statements end with ; or \\G.", role: .muted)])
        appendBlank()
    }

    func reloadHistory() async {
        guard let history, let entries = try? await history.recent(limit: 300) else { return }
        // Newest first from the store; the navigator wants oldest first.
        historyNavigator.replace(with: entries.reversed().compactMap { $0.rerunScript }.reduce(into: [String]()) { acc, sql in
            if acc.last != sql { acc.append(sql) }
        })
    }

    // MARK: Scrollback

    @discardableResult
    private func append(_ segments: [ConsoleSegment]) -> Int {
        let line = ConsoleLine(id: nextLineID, segments: segments)
        nextLineID += 1
        scrollback.append(line)
        if scrollback.count > Self.maxScrollbackLines {
            scrollback.removeFirst(scrollback.count - Self.maxScrollbackLines)
            clearCount += 1  // the view rebuilds: its append-only bookkeeping no longer matches
        }
        return line.id
    }

    private func appendBlank() { append([ConsoleSegment]()) }

    private func append(_ output: [ConsoleOutputLine]) {
        for line in output { append([ConsoleSegment(text: line.text, role: Self.role(for: line.kind))]) }
    }

    private static func role(for kind: ConsoleOutputLine.Kind) -> ConsoleRole {
        switch kind {
        case .border: .border
        case .header: .header
        case .row: .row
        case .text: .text
        case .footer: .footer
        case .success: .success
        case .error: .error
        case .warning: .warning
        }
    }

    /// Wipes the screen (`clear`, ⌘K, ⌃L). Input and history stay.
    func clearScreen() {
        scrollback = []
        clearCount += 1
    }

    /// Echoes what was typed, with prompts, as it stood when Enter was pressed.
    private func echo(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, l) in lines.enumerated() {
            let p = i == 0 ? primaryPrompt : ConsolePrompt.continuation(.statement, engine: engine, database: currentDatabase ?? profile.defaultDatabase)
            append([ConsoleSegment(text: p, role: .prompt), ConsoleSegment(text: l, role: .input)])
        }
    }

    // MARK: Editing (called by the view)

    func edit(_ change: (inout ConsoleLineEditor) -> Void) {
        guard !isRunning else { return }
        change(&editor)
        historyNavigator.reset()
    }

    func moveCaret(_ change: (inout ConsoleLineEditor) -> Void) {
        change(&editor)
    }

    func historyPrevious() {
        guard !isRunning else { return }
        if !editor.isOnFirstLine { editor.moveUp(); return }
        if let text = historyNavigator.previous(current: editor.text) { editor.set(text: text) }
    }

    func historyNext() {
        guard !isRunning else { return }
        if !editor.isOnLastLine { editor.moveDown(); return }
        if let text = historyNavigator.next() { editor.set(text: text) }
    }

    /// ⌃C: stops a running script (between statements) or abandons the line being typed.
    func interrupt() {
        if isRunning {
            runTask?.cancel()
            return
        }
        echo(editor.text + "^C")
        editor.clear()
        continuation = .statement
    }

    // MARK: Enter

    /// Enter: runs the input when it is complete, otherwise continues on a new line.
    func enter() {
        guard !isRunning else { return }
        let text = editor.text
        switch ConsoleInput.analyze(text, dialect: dialect) {
        case .incomplete(let kind):
            continuation = kind
            editor.moveTo(line: editor.lines.count - 1, column: editor.lines.last?.count ?? 0)
            editor.newline()
        case .empty:
            echo(text)
            editor.clear()
            continuation = .statement
        case .command(let command):
            echo(text)
            editor.clear()
            continuation = .statement
            runTask = Task { [weak self] in await self?.handle(command) }
        case .run(let statements, let remainder):
            // Echo only what is being run; an unfinished tail stays in the editor like the mysql client.
            let consumed = remainder.isEmpty ? text : String(text.dropLast(text.hasSuffix(remainder) ? remainder.count : 0))
            echo(consumed.trimmingCharacters(in: .newlines))
            historyNavigator.reset()
            editor.set(text: remainder)
            continuation = .statement
            runTask = Task { [weak self] in await self?.run(statements) }
        }
    }

    /// Test and automation entry: sets the input and presses Enter, returning when the work is done.
    func submit(_ text: String) async {
        editor.set(text: text)
        enter()
        await runTask?.value
    }

    // MARK: Client commands

    func handle(_ command: ConsoleClientCommand) async {
        switch command {
        case .quit:
            onQuit()
        case .clear:
            clearScreen()
        case .cancelInput:
            break
        case .help:
            for line in ConsoleHelp.text(engine: engine) { append([ConsoleSegment(text: line, role: .text)]) }
        case .use(let name):
            await use(database: name)
        }
    }

    private func use(database name: String) async {
        guard !name.isEmpty else { printError("ERROR: USE must be followed by a database name"); return }
        guard let session = sessionProvider() else { printError("ERROR: not connected"); return }
        switch engine {
        case .mysql, .mariadb:
            do {
                _ = try await session.execute("USE \(dialect.quoteIdentifier(name))")
                currentDatabase = name
                loader = nil
                append([ConsoleSegment(text: "Database changed", role: .success)])
                onDatabaseChanged(name)
            } catch let error as DatabaseError {
                printError(ConsoleFormatter.error(error, engine: engine))
            } catch {
                printError("ERROR: \(error.localizedDescription)")
            }
        case .postgresql:
            do {
                _ = try await session.execute("SET search_path TO \(dialect.quoteIdentifier(name))")
                loader = nil
                append([ConsoleSegment(text: "SET", role: .success)])
            } catch let error as DatabaseError {
                printError(ConsoleFormatter.error(error, engine: engine))
            } catch {
                printError("ERROR: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Running statements

    private func printError(_ text: String) {
        append([ConsoleSegment(text: text, role: .error)])
    }

    /// Runs statements in order through the guard. A cancelled confirmation prints "Cancelled." and moves on.
    func run(_ statements: [ConsoleStatement]) async {
        isRunning = true
        defer {
            isRunning = false
            runTask = nil
        }
        for statement in statements {
            if Task.isCancelled { append([ConsoleSegment(text: "Interrupted.", role: .warning)]); break }
            let proceed = await run(statement)
            if !proceed { break }
        }
    }

    /// Returns false when the session is gone and later statements should not run.
    private func run(_ statement: ConsoleStatement) async -> Bool {
        guard let session = sessionProvider(), let gate, let context = gate.contextProvider(currentDatabase) else {
            printError("ERROR: not connected")
            return false
        }
        let runner = QueryRunner(guardContext: context, safety: gate.settingsProvider(),
                                 options: QueryRunOptions(maxRowsPerResult: Self.maxRowsShown))
        let script: PreparedScript
        switch runner.prepare(script: statement.sql) {
        case .empty:
            return true
        case .blocked(let reason):
            printError("ERROR: \(reason)")
            return true
        case .ready(let s):
            script = s
        case .needsConfirmation(let pending):
            let title = profile.isProduction ? "Run on PROD" : "Run"
            guard await gate.confirm(pending.request, actionTitle: title),
                  let confirmed = pending.confirm(typed: pending.request.requiresTypedName ?? "") else {
                append([ConsoleSegment(text: "Cancelled.", role: .muted)])
                appendBlank()
                return true
            }
            script = confirmed
        }

        let result = await runner.run(script, on: session)
        var keepGoing = true
        for r in result.results {
            switch r.outcome {
            case .resultSet(let res):
                printResult(res, statement: statement, result: r)
                lastResultSQL = statement.sql
            case .affected(let rows, _):
                let text = ConsoleFormatter.affected(sql: statement.sql, rows: rows, duration: r.duration, engine: engine)
                append([ConsoleSegment(text: text, role: .success)])
            case .error(let e):
                printError(ConsoleFormatter.error(e, engine: engine))
                if e == .sessionClosed { keepGoing = false }
            case .skipped:
                break
            }
            if let entry = HistoryEntry.make(from: r, database: currentDatabase), let history {
                _ = try? await history.record(entry)
            }
        }
        historyNavigator.record(statement.sql)
        onHistoryChanged()
        appendBlank()
        if Self.touchesTransactionState(statement.sql) { await refreshAutocommit() }
        return keepGoing
    }

    private func printResult(_ res: QueryResult, statement: ConsoleStatement, result r: StatementResult) {
        let options = formatOptions()
        let total = r.totalRows ?? res.rows.count
        let body = statement.vertical
            ? ConsoleFormatter.vertical(columns: res.columns, rows: res.rows, options: options)
            : ConsoleFormatter.table(columns: res.columns, rows: res.rows, options: options)
        append(body)
        let footer = ConsoleFormatter.footer(rowCount: total, duration: r.duration)
        // "2 rows in set" in the text colour, the "(0.02 sec)" timing muted, as in the design.
        if let paren = footer.firstIndex(of: "(") {
            append([ConsoleSegment(text: String(footer[..<paren]), role: .footer), ConsoleSegment(text: String(footer[paren...]), role: .muted)])
        } else {
            append([ConsoleSegment(text: footer, role: .footer)])
        }
        if r.isTruncated {
            append([ConsoleSegment(
                text: "Showing the first \(res.rows.count.formatted()) of \(total.formatted()) rows. Open the query in the grid to see more.",
                role: .warning)])
        }
        if !res.columns.isEmpty {
            append([ConsoleSegment(text: "↗ Open in grid", role: .link(sql: statement.sql))])
        }
    }

    // MARK: Transaction state

    static func touchesTransactionState(_ sql: String) -> Bool {
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("set ") && head.contains("autocommit")
            || head.hasPrefix("begin") || head.hasPrefix("start transaction") || head.hasPrefix("commit") || head.hasPrefix("rollback")
    }

    private func refreshAutocommit() async {
        guard engine != .postgresql, let session = sessionProvider() else { return }
        if let result = try? await session.execute("SELECT @@autocommit"), let value = result.rows.first?.first {
            switch value {
            case .integer(let v): autocommit = v != 0
            case .unsignedInteger(let v): autocommit = v != 0
            case .bool(let b): autocommit = b
            case .text(let t): autocommit = t != "0"
            default: break
            }
        }
    }

    // MARK: Completion

    /// Tab: completes at the caret, or lists the candidates.
    func complete() async {
        guard !isRunning, let inspector = inspectorProvider() else { return }
        let text = editor.text
        let caret = editor.caretUTF16Offset
        let l: SchemaCatalogLoader
        if let loader { l = loader } else {
            l = SchemaCatalogLoader(inspector: inspector)
            loader = l
            if let db = currentDatabase { try? await l.loadOverview(schemas: [db]) } else { try? await l.loadOverview(schemas: []) }
        }
        let result = await l.complete(text: text, cursor: caret, dialect: dialect, currentSchema: currentDatabase)
        // The input may have changed while the catalog loaded.
        guard editor.text == text, editor.caretUTF16Offset == caret else { return }
        let plan = ConsoleCompletionPlan.make(for: result, in: text)
        if let r = plan.replacement {
            editor.replace(utf16Range: r.range, with: r.text)
        } else if !plan.candidates.isEmpty {
            echo(text)
            for row in ConsoleCompletionPlan.columns(plan.candidates, width: 100) { append([ConsoleSegment(text: row, role: .muted)]) }
        }
    }

    /// Forgets the cached schema (⌘R in the window).
    func invalidateCatalog() { loader = nil }

    // MARK: Grid

    func openLastResultInGrid() {
        if let sql = lastResultSQL { onOpenInGrid(sql) }
    }
}
