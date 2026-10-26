import Foundation
import Observation
import QuerywellCore

/// State and logic of one query tab: the editor text, running scripts through `QueryRunner`
/// (and so through the write guard), the result strip, history, saved-query link, Explain and Format.
///
/// The model never executes SQL itself: `run` goes `prepare → (confirm) → run`, so a PROD write
/// can't skip the confirmation whatever its origin (typed, history re-run, AI insert).
@MainActor @Observable
final class QueryTabModel {
    enum RunKind: Equatable {
        /// ⌘↵: the selection when there is one, otherwise the whole editor.
        case auto
        case selection
        case currentStatement
        case all
    }

    enum ExplainState: Equatable {
        case idle
        case running
        case done(ExplainOutcome)
        case failed(String)
    }

    // MARK: Environment (injected by the workspace; tests inject stubs)

    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var inspectorProvider: @MainActor () -> (any SchemaInspector)? = { nil }
    @ObservationIgnored var schemaProvider: @MainActor () -> String? = { nil }
    @ObservationIgnored var profile: ConnectionProfile
    @ObservationIgnored var gate: WriteGate?
    @ObservationIgnored var history: QueryHistoryStore?
    @ObservationIgnored var savedQueries: SavedQueryStore?
    @ObservationIgnored var maxRowsPerResult = 50_000
    @ObservationIgnored var nullDisplay = "NULL"
    /// A history entry was written (the sidebar reloads).
    @ObservationIgnored var onHistoryChanged: @MainActor () -> Void = {}
    @ObservationIgnored var onDirtyChange: @MainActor (Bool) -> Void = { _ in }
    /// Debounced editor text, for the workspace tab state.
    @ObservationIgnored var onTextPersist: @MainActor (String) -> Void = { _ in }
    /// The tab got a saved query's name (Save as…).
    @ObservationIgnored var onLinked: @MainActor (SavedQuery) -> Void = { _ in }
    @ObservationIgnored let editor = SQLEditorController()
    /// The AI panel's state; the view wires its environment.
    let assistant = AIAssistantModel()
    var showsAssistant = false
    /// Replaces the configured AI provider (tests and previews stream canned answers).
    @ObservationIgnored var assistantProviderOverride: (@MainActor () throws -> any AIProvider)?

    // MARK: Editor state

    /// The editor text. Kept in sync from the editor view; set it directly in tests.
    @ObservationIgnored var text: String {
        didSet { if text != oldValue { textDidChange() } }
    }
    @ObservationIgnored var selection = NSRange(location: 0, length: 0) {
        didSet { if selection != oldValue { scheduleGuardHint() } }
    }
    private(set) var hasText: Bool
    private(set) var hasSelection = false

    // MARK: Saved query link

    private(set) var linkedQuery: SavedQuery?
    @ObservationIgnored private var savedSQL: String?
    private(set) var isDirty = false
    var saveSheet: SaveQuerySheetRequest?
    var snippetSheet: SnippetSheetRequest?

    // MARK: Run state

    private(set) var isRunning = false
    private(set) var results: [QueryResultItem] = []
    private(set) var lastRun: QueryRunResult?
    private(set) var lastError: (statement: ClassifiedStatement, message: String)?
    var selected: QueryResultSelection?
    private(set) var blockedReason: String?
    private(set) var guardHint: GuardHint = .none
    private(set) var explainState: ExplainState = .idle
    var explainAnalyze = false
    var toast: ModelToast?
    /// Statement index → editor range of the last run, for jumping from Messages.
    @ObservationIgnored private(set) var statementRanges: [Int: NSRange] = [:]
    @ObservationIgnored private var received = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTasks: [Task<Void, Never>] = []

    init(profile: ConnectionProfile, text: String = "") {
        self.profile = profile
        self.text = text
        hasText = !text.isEmpty
        editor.onTextChange = { [weak self] new in self?.text = new }
        editor.onSelectionChange = { [weak self] range in
            self?.selection = range
            self?.hasSelection = range.length > 0
        }
        editor.completionProvider = { [weak self] text, caret in
            guard let self else { return nil }
            return await self.complete(text: text, caret: caret)
        }
        scheduleGuardHint()
    }

    // MARK: Derived

    var dialect: SQLDialect { SQLDialect(profile.engine) }

    var selectedItem: QueryResultItem? {
        if case .result(let id) = selected { return results.first { $0.id == id } }
        return nil
    }

    var messages: [QueryMessage] { lastRun?.messages ?? [] }

    /// Statements that actually ran.
    var ranStatementCount: Int { lastRun?.results.filter { $0.outcome != .skipped }.count ?? 0 }

    var footerSummary: String? {
        guard let run = lastRun else { return nil }
        let n = ranStatementCount
        return "\(n) statement\(n == 1 ? "" : "s") · \(QueryRunner.format(run.totalDuration))"
    }

    /// Edit models with unsaved edits, in result order.
    var pendingEditModels: [TableDataModel] {
        results.compactMap(\.editModel).filter(\.hasPendingChanges)
    }

    // MARK: Text

    /// The selection, or everything when nothing is selected.
    var selectedTextOrAll: String {
        let ns = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= ns.length { return ns.substring(with: selection) }
        return text
    }

    /// SQL the assistant's Explain / Optimize apply to: the selection, else the statement at the caret, else everything.
    var assistantSQL: String {
        if selection.length == 0 { return statementForExplain()?.text ?? text }
        return selectedTextOrAll
    }

    private func textDidChange() {
        hasText = !text.isEmpty
        updateDirty()
        scheduleGuardHint()
        persistTask?.cancel()
        let snapshot = text
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onTextPersist(snapshot)
        }
    }

    /// Replaces the editor contents (history, saved queries, AI "Replace editor"). Undoable in the editor.
    func setEditorText(_ new: String) {
        if editor.textView != nil { editor.replaceAll(new) } else { text = new }
    }

    /// Inserts at the caret / over the selection (AI "Insert into editor", snippets, history with ⌥).
    func insertIntoEditor(_ sql: String) {
        if editor.textView != nil {
            editor.insert(sql)
        } else {
            let ns = text as NSString
            let r = NSRange(location: min(selection.location, ns.length), length: min(selection.length, ns.length - min(selection.location, ns.length)))
            text = ns.replacingCharacters(in: r, with: sql)
        }
    }

    func insertSnippet(_ template: String) {
        if editor.textView != nil { editor.insertSnippet(template) } else { insertIntoEditor(SnippetTemplate.parse(template).text) }
    }

    // MARK: Run

    func startRun(_ kind: RunKind) {
        guard !isRunning else { return }
        runTask = Task { [weak self] in await self?.run(kind) }
    }

    func cancel() { runTask?.cancel() }

    private func scope(for kind: RunKind) -> RunScope? {
        switch kind {
        case .all: return .all
        case .auto: return selection.length > 0 ? .selection(selection.location..<NSMaxRange(selection)) : .all
        case .selection: return selection.length > 0 ? .selection(selection.location..<NSMaxRange(selection)) : nil
        case .currentStatement: return .currentStatement(cursor: selection.location)
        }
    }

    /// Prepares, confirms if the guard asks to, and runs. Returns when the run (or the refusal) is complete.
    func run(_ kind: RunKind) async {
        guard !isRunning else { return }
        guard let session = sessionProvider(), let gate, let context = gate.contextProvider(nil) else {
            show(toast: "Not connected.", isError: true)
            return
        }
        guard let scope = scope(for: kind) else {
            show(toast: "Select some SQL first.", isError: false)
            return
        }
        let runner = QueryRunner(guardContext: context, safety: gate.settingsProvider(),
                                 options: QueryRunOptions(maxRowsPerResult: maxRowsPerResult))
        blockedReason = nil
        switch runner.prepare(editorText: text, scope: scope) {
        case .empty:
            show(toast: "Nothing to run.", isError: false)
        case .blocked(let reason):
            blockedReason = reason
            await gate.reportBlocked(reason)
        case .ready(let script):
            await execute(script, runner: runner, session: session)
        case .needsConfirmation(let pending):
            guard await gate.confirm(pending.request, actionTitle: "Run") else { return }
            // The sheet enforced the typed name; hand it to the runner's own check.
            guard let script = pending.confirm(typed: pending.request.requiresTypedName ?? "") else { return }
            await execute(script, runner: runner, session: session)
        }
    }

    /// Loads `sql` into the editor and runs it through the guard (history "Run Again", saved "Run").
    func loadAndRun(_ sql: String) async {
        setEditorText(sql)
        text = sql
        selection = NSRange(location: (sql as NSString).length, length: 0)
        await run(.all)
    }

    private func execute(_ script: PreparedScript, runner: QueryRunner, session: any DatabaseSession) async {
        isRunning = true
        resetResults()
        explainState = .idle
        statementRanges = [:]
        for (i, s) in script.statements.enumerated() {
            if let r = s.source?.utf16Range { statementRanges[i] = NSRange(location: script.baseUTF16Offset + r.lowerBound, length: r.count) }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: StatementResult.self)
        let consumer = Task { @MainActor [weak self] in
            for await r in stream { self?.receive(r) }
        }
        let result = await runner.run(script, on: session) { continuation.yield($0) }
        continuation.finish()
        await consumer.value
        await finish(result)
    }

    private func resetResults() {
        for t in analysisTasks { t.cancel() }
        analysisTasks = []
        results = []
        received = 0
        lastRun = nil
        lastError = nil
        selected = nil
        editor.setDiagnostics([])
    }

    private func receive(_ r: StatementResult) {
        let index = received
        received += 1
        let item: QueryResultItem
        switch r.outcome {
        case .resultSet(let result):
            var i = QueryResultItem(statementIndex: index, statement: r.statement,
                                    payload: .rows(result, truncated: r.isTruncated, total: r.totalRows ?? result.rows.count),
                                    duration: r.duration)
            i.grid = ResultGridModel(result: result)
            item = i
        case .affected(let rows, let id):
            item = QueryResultItem(statementIndex: index, statement: r.statement, payload: .affected(rows: rows, lastInsertID: id),
                                   duration: r.duration)
        case .error, .skipped:
            return
        }
        results.append(item)
        if selected == nil { selected = .result(item.id) }
    }

    private func finish(_ result: QueryRunResult) async {
        lastRun = result
        isRunning = false
        let failed = result.results.filter(\.isError).count
        Announce.post(failed > 0 ? "Query failed. \(failed) \(failed == 1 ? "statement" : "statements") had errors."
                      : "Query finished. \(result.results.count) \(result.results.count == 1 ? "result" : "results").", important: failed > 0)
        // The first error: highlight its statement and remember it for "Fix error".
        if let index = result.results.firstIndex(where: \.isError), case .error(let e) = result.results[index].outcome {
            let r = result.results[index]
            lastError = (r.statement, QueryRunner.describe(e))
            if let range = statementRanges[index] {
                editor.setDiagnostics([EditorDiagnostic(range: range, message: QueryRunner.describe(e))])
            }
        }
        if results.isEmpty { selected = .messages }
        else if result.hasErrors, selected == nil { selected = .messages }

        // History: every statement that ran.
        if let history {
            let database = schemaProvider()
            for r in result.results {
                if let entry = HistoryEntry.make(from: r, database: database) { _ = try? await history.record(entry) }
            }
            onHistoryChanged()
        }
        if let linkedQuery, let savedQueries { try? await savedQueries.markRun(id: linkedQuery.id) }
        for item in results where item.isRowSet { analyzeEditable(itemID: item.id) }
        scheduleGuardHint()
    }

    // MARK: Editable results

    private func analyzeEditable(itemID: UUID) {
        guard let item = results.first(where: { $0.id == itemID }), let result = item.result else { return }
        let readOnly = profile.effectiveReadOnly
        let inspector = inspectorProvider()
        let schema = schemaProvider()
        let dialect = dialect
        let sql = item.statement.text
        let task = Task { [weak self] in
            let verdict: EditableResultVerdict
            if readOnly {
                verdict = .notEditable("Read-only connection")
            } else if let inspector, let schema {
                verdict = await EditableResultAnalyzer.analyze(
                    sql: sql, dialect: dialect, currentSchema: schema, resultColumns: result.columns, inspector: inspector)
            } else {
                verdict = .notEditable("Not connected")
            }
            guard !Task.isCancelled else { return }
            self?.applyVerdict(verdict, itemID: itemID)
        }
        analysisTasks.append(task)
    }

    private func applyVerdict(_ verdict: EditableResultVerdict, itemID: UUID) {
        guard let index = results.firstIndex(where: { $0.id == itemID }), let result = results[index].result else { return }
        results[index].verdict = verdict
        guard let info = verdict.info else { return }
        let model = TableDataModel(table: info.table)
        model.sessionProvider = sessionProvider
        model.inspectorProvider = inspectorProvider
        model.gate = gate
        model.connectionID = profile.id
        model.nullDisplay = nullDisplay
        model.isReadOnlyProvider = { [weak self] in self?.profile.effectiveReadOnly ?? true }
        model.fixedQuery = TableDataModel.FixedQuery(sql: results[index].statement.text, columnMap: info.columnMap, seed: result)
        model.reload()
        results[index].editModel = model
    }

    // MARK: Explain

    /// The statement Explain applies to: the selection's first statement, else the one at the caret.
    func statementForExplain() -> ClassifiedStatement? {
        let classifier = StatementClassifier(dialect: dialect)
        let ns = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            let sel = ns.substring(with: selection)
            return StatementSplitter.split(sel, dialect: dialect).first.map { classifier.classify($0) }
        }
        let all = StatementSplitter.split(text, dialect: dialect)
        return StatementSplitter.statement(at: selection.location, in: all).map { classifier.classify($0) }
    }

    func explain() async {
        guard let session = sessionProvider() else { show(toast: "Not connected.", isError: true); return }
        guard let statement = statementForExplain() else { show(toast: "Nothing to explain.", isError: false); return }
        explainState = .running
        selected = .plan
        do {
            let (plan, built) = try await ExplainPlanner.explain(statement, on: session, analyze: explainAnalyze)
            explainState = .done(ExplainOutcome(plan: plan, sql: built.sql, explained: statement.text, note: built.note))
        } catch let e as ExplainError {
            switch e {
            case .unsupported(let m), .unparseable(let m): explainState = .failed(m)
            }
        } catch let e as DatabaseError {
            explainState = .failed(QueryRunner.describe(e))
        } catch {
            explainState = .failed(error.localizedDescription)
        }
    }

    /// Plan JSON for the AI "Optimize" action; nil when the statement can't be explained.
    func planForOptimize() async -> (sql: String, plan: String?) {
        guard let statement = statementForExplain() else { return (text, nil) }
        guard let session = sessionProvider() else { return (statement.text, nil) }
        let plan = try? await ExplainPlanner.explain(statement, on: session, analyze: false).plan.raw
        return (statement.text, plan)
    }

    // MARK: Format

    func format() {
        let ns = text as NSString
        let useSelection = selection.length > 0 && NSMaxRange(selection) <= ns.length
        let source = useSelection ? ns.substring(with: selection) : text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let result = SQLFormatter.formatDetailed(source, dialect: dialect)
        guard result.didFormat else {
            show(toast: "Couldn't format safely — left unchanged", isError: true)
            return
        }
        guard result.text != source else { return }
        if useSelection {
            if editor.textView != nil {
                editor.insert(result.text)
            } else {
                text = ns.replacingCharacters(in: selection, with: result.text)
            }
        } else {
            setEditorText(result.text)
        }
    }

    // MARK: Completion

    @ObservationIgnored private var completionLoader: SchemaCatalogLoader?

    private func loader() async -> SchemaCatalogLoader? {
        guard let inspector = inspectorProvider() else { return nil }
        if let completionLoader { return completionLoader }
        let l = SchemaCatalogLoader(inspector: inspector)
        completionLoader = l
        if let schema = schemaProvider() { try? await l.loadOverview(schemas: [schema]) }
        return l
    }

    /// Drops the cached catalog (schema refresh, reconnect). The schema sidebar reloads when `catalogVersion` changes.
    func invalidateCatalog() {
        completionLoader = nil
        knownTables = []
        tablesLoaded = false
        catalogVersion += 1
    }

    // MARK: Schema (sidebar) and quick queries

    /// Bumped by `invalidateCatalog()`: anything showing catalog data reloads.
    private(set) var catalogVersion = 0
    /// Tables of the current database, from the same catalog the autocomplete uses.
    private(set) var knownTables: [TableInfo] = []
    private(set) var tablesLoaded = false
    /// A table chosen in the Quick queries menu; nil = the table named at the caret.
    var quickTable: TableRef?

    /// Loads the table list of the current database into `knownTables` (a no-op when already there).
    func refreshTables() async {
        guard let schema = schemaProvider(), let l = await loader() else { return }
        try? await l.loadTables(in: schema)
        let tables = await l.catalog.tables(in: schema)
        guard schemaProvider() == schema else { return }
        knownTables = tables
        tablesLoaded = true
    }

    /// Columns, keys and indexes of `ref`, loaded lazily (and so available to autocomplete afterwards).
    func structure(of ref: TableRef) async -> TableStructure? {
        guard let l = await loader() else { return nil }
        return await l.structure(of: ref)
    }

    /// The table quick queries act on: the one chosen in the menu, else the one named at the caret.
    func quickQueryTable() -> TableRef? {
        quickTable ?? QuickQueryTableFinder.table(in: text, caret: selection.location, tables: knownTables, dialect: dialect)
    }

    /// Inserts a quick query into the editor (at the caret, as a snippet whose first placeholder is selected).
    /// It is only inserted: running it goes through `run`, the guard and the confirmation like any typed SQL.
    func insertQuickQuery(_ kind: QuickQueryKind, table explicit: TableRef? = nil) async {
        var context = QuickQueryContext(dialect: dialect, currentSchema: schemaProvider())
        if kind.needsTable {
            await refreshTables()
            guard let ref = explicit ?? quickQueryTable() else {
                show(toast: "Click a table name in the editor, or choose a table in the Quick queries menu.", isError: false)
                return
            }
            context.table = ref
            context.structure = await structure(of: ref)
        }
        guard let template = QuickQueries.template(kind, context) else {
            show(toast: "Choose a database first.", isError: false)
            return
        }
        insertSnippet(QuickQueries.separated(template, editorText: text, caret: selection.location, selectionLength: selection.length))
        editor.focus()
    }

    /// Inserts a quoted identifier at the caret (schema sidebar double-click).
    func insertIdentifier(_ name: String) {
        insertIntoEditor(dialect.quoteIdentifier(name))
        editor.focus()
    }

    func complete(text: String, caret: Int) async -> CompletionResult? {
        guard let l = await loader() else { return nil }
        return await l.complete(text: text, cursor: caret, dialect: dialect, currentSchema: schemaProvider())
    }

    // MARK: Guard hint

    func scheduleGuardHint() {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.refreshGuardHint()
        }
    }

    func refreshGuardHint() {
        guard hasText, let gate, let context = gate.contextProvider(nil) else { guardHint = .none; return }
        let runner = QueryRunner(guardContext: context, safety: gate.settingsProvider())
        let scope: RunScope = selection.length > 0 ? .selection(selection.location..<NSMaxRange(selection)) : .all
        switch runner.prepare(editorText: text, scope: scope) {
        case .empty: guardHint = .none
        case .blocked: guardHint = .blocked
        case .needsConfirmation: guardHint = .needsConfirmation(production: profile.isProduction)
        case .ready(let script):
            guardHint = script.statements.contains { $0.kind.isWriteLike } ? .writesNoConfirmation : .readOnlyQuery
        }
    }

    // MARK: Results helpers

    /// CSV of the selected result set (header included).
    func csvOfSelectedResult() -> String? {
        guard let item = selectedItem, let result = item.result else { return nil }
        let names = item.grid?.columnNames ?? result.columns.map(\.name)
        let rows = item.editModel?.content?.rows ?? item.grid?.rows ?? result.rows
        return RowCopy.text(format: .csv, columns: names, rows: rows, table: nil, dialect: dialect,
                            includeHeader: true, nullText: "NULL")
    }

    func jumpToStatement(_ index: Int) {
        guard let range = statementRanges[index] else { return }
        editor.select(range)
        editor.focus()
    }

    func show(toast message: String, isError: Bool) {
        let t = ModelToast(message: message, isError: isError)
        toast = t
        Announce.post(message, important: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 5 : 3))
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            self.toast = nil
        }
    }

    // MARK: Saved queries

    /// Links this tab to `query` (opened from the sidebar or just saved).
    func attach(saved query: SavedQuery) {
        linkedQuery = query
        savedSQL = query.sql
        updateDirty()
    }

    func detachSaved() {
        linkedQuery = nil
        savedSQL = nil
        updateDirty()
    }

    private func updateDirty() {
        let dirty = linkedQuery != nil && savedSQL != text
        if dirty != isDirty {
            isDirty = dirty
            onDirtyChange(dirty)
        }
    }

    /// ⌘S: updates the linked saved query, or asks for details when there is none.
    func save() async {
        guard let savedQueries else { return }
        guard let linked = linkedQuery else {
            saveSheet = SaveQuerySheetRequest(sql: text, defaultName: SavedQueryNaming.suggestedName(for: text), isGlobal: false)
            return
        }
        do {
            let updated = try await savedQueries.update(id: linked.id, sql: text)
            attach(saved: updated)
            show(toast: "Saved “\(updated.name)”", isError: false)
        } catch {
            show(toast: "Couldn't save: \(error.localizedDescription)", isError: true)
        }
    }

    /// Creates a saved query from the editor and links the tab to it.
    @discardableResult
    func saveAs(name: String, notes: String?, tags: [String], global: Bool) async -> SavedQuery? {
        guard let savedQueries else { return nil }
        do {
            let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            let q = try await savedQueries.save(
                name: name, sql: text, connectionID: global ? nil : profile.id,
                notes: (n?.isEmpty ?? true) ? nil : n, tags: tags)
            attach(saved: q)
            onLinked(q)
            show(toast: "Saved “\(q.name)”", isError: false)
            return q
        } catch {
            show(toast: "Couldn't save: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    /// The saved query changed elsewhere (renamed, edited, scope toggled) — keep the link current.
    func savedQueryUpdated(_ query: SavedQuery) {
        guard linkedQuery?.id == query.id else { return }
        linkedQuery = query
        // Text edited in the sidebar sheet isn't pushed into an open editor; only metadata follows.
        savedSQL = query.sql == savedSQL ? savedSQL : query.sql
        updateDirty()
    }
}

/// Request to show the "Save as…" sheet.
struct SaveQuerySheetRequest: Identifiable, Equatable {
    let id = UUID()
    var sql: String
    var defaultName: String
    var isGlobal: Bool
}

/// Request to show the snippet sheet (create from the editor, or edit).
struct SnippetSheetRequest: Identifiable, Equatable {
    let id = UUID()
    var snippet: Snippet?
    var sql: String
}

enum SavedQueryNaming {
    /// "Pages edited this month" from a leading `-- comment`, else the first words of the SQL.
    static func suggestedName(for sql: String) -> String {
        let lines = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let comment = lines.first(where: { $0.hasPrefix("--") }) {
            let t = comment.drop(while: { $0 == "-" || $0 == " " })
            if !t.isEmpty { return String(t.prefix(60)) }
        }
        let first = lines.first(where: { !$0.hasPrefix("--") && !$0.isEmpty }) ?? ""
        let collapsed = first.split(separator: " ").prefix(8).joined(separator: " ")
        return String(collapsed.prefix(60))
    }
}
