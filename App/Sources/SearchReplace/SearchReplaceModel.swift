import Foundation
import Observation
import QuerywellCore

/// The last search / replace pair per connection, kept in memory for the life of the app only
/// (never written to disk: no history of search terms).
@MainActor
enum SearchReplaceMemory {
    private static var pairs: [UUID: (search: String, replace: String)] = [:]

    static func pair(for connection: UUID) -> (search: String, replace: String)? { pairs[connection] }
    static func remember(search: String, replace: String, for connection: UUID) { pairs[connection] = (search, replace) }
    static func forget(connection: UUID) { pairs[connection] = nil }
}

enum WordPressDetection {
    /// The primary table prefix (`wp_`) when `names` contains the core `options`, `posts` and `users` tables.
    static func prefix(in names: [String]) -> String? { prefixes(in: names).first }

    /// Every installation's prefix (live `wp_` plus a staging copy `wpstg0_`).
    static func prefixes(in names: [String]) -> [String] { WordPressDetector.detectAll(tableNames: names).map(\.prefix) }
}

/// State of the Search & Replace sheet: options, table choice, the dry run and the apply run.
@MainActor @Observable
final class SearchReplaceModel {
    struct TableChoice: Identifiable, Equatable {
        var info: TableInfo
        var structure: TableStructure?
        /// Why the table can't be processed; such tables are greyed and can't be ticked.
        var ineligibleReason: String?
        /// Not transactional (MyISAM and friends): a failed or cancelled run can't be rolled back.
        var isNonTransactional: Bool
        var id: TableRef { info.ref }
        var name: String { info.ref.name }
    }

    enum Stage: Equatable {
        case configuring
        case running(SearchReplaceMode)
        case previewed
        case applied
    }

    struct Progress: Equatable {
        var scanned = 0
        var changed = 0
        var isRunning = false
    }

    /// Everything that changes what a run would do; a preview is only valid for the inputs it ran with.
    struct Inputs: Equatable {
        var search: String
        var replace: String
        var caseSensitive: Bool
        var regex: Bool
        var wholeWord: Bool
        var jsonKeys: Bool
        var phpKeys: Bool
        var escapedSlashes: Bool
        var guid: Bool
        var binary: Bool
        var tables: Set<TableRef>
    }

    // Environment, injected by the owner.
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var inspectorProvider: @MainActor () -> (any SchemaInspector)? = { nil }
    @ObservationIgnored var gate: WriteGate?
    /// Called after an apply run so open table tabs can refresh.
    @ObservationIgnored var onApplied: @MainActor () -> Void = {}
    /// Hands an invalid serialized value to the PHP editor (closes the sheet first).
    @ObservationIgnored var openInEditor: @MainActor (CellLocation) -> Void = { _ in }

    let connectionID: UUID
    let schema: String
    let engine: DatabaseEngine
    let isReadOnly: Bool
    let isProduction: Bool

    // Fields.
    var search = "" { didSet { remember() } }
    var replace = "" { didSet { remember() } }
    var caseSensitive = true
    var regex = false
    var wholeWord = false
    var includeJSONKeys = false
    var includePHPKeys = true
    var replaceEscapedSlashes = true
    var includeWordPressGUID = false
    var includeBinary = false
    var stopOnError = false

    // Tables.
    private(set) var tables: [TableChoice] = []
    var selected: Set<TableRef> = []
    var filter = ""
    private(set) var isLoadingTables = false
    private(set) var structuresLoaded = 0
    private(set) var tablesError: String?
    /// The WordPress installation whose tables are pre-selected (nil when the database isn't WordPress).
    private(set) var wordPressPrefix: String?
    /// All detected installations; more than one shows a picker.
    private(set) var wordPressInstalls: [WordPressInfo] = []

    // Run state.
    private(set) var stage: Stage = .configuring
    private(set) var inputError: String?
    private(set) var progress: [TableRef: Progress] = [:]
    private(set) var currentTable: TableRef?
    private(set) var tableIndex = 0
    private(set) var tableTotal = 0
    private(set) var liveReports: [SearchReplaceTableReport] = []
    private(set) var previewReport: SearchReplaceReport?
    private(set) var applyReport: SearchReplaceReport?
    private(set) var previewInputs: Inputs?
    private(set) var runError: String?
    var confirmingApply = false

    @ObservationIgnored private var runTask: Task<SearchReplaceReport, Never>?
    @ObservationIgnored private var structureTask: Task<Void, Never>?

    init(connectionID: UUID, schema: String, engine: DatabaseEngine, isReadOnly: Bool, isProduction: Bool) {
        self.connectionID = connectionID
        self.schema = schema
        self.engine = engine
        self.isReadOnly = isReadOnly
        self.isProduction = isProduction
        if let last = SearchReplaceMemory.pair(for: connectionID) {
            search = last.search
            replace = last.replace
        }
    }

    private func remember() {
        SearchReplaceMemory.remember(search: search, replace: replace, for: connectionID)
    }

    // MARK: Tables

    var dialect: SQLDialect { SQLDialect(engine) }

    /// Reads the table list (and, in the background, each table's structure) and applies the default
    /// selection: the sidebar selection if there is one, else WordPress tables when detected.
    func loadTables(preselect: Set<String>? = nil) async {
        guard let inspector = inspectorProvider() else {
            tablesError = "Not connected."
            return
        }
        isLoadingTables = true
        tablesError = nil
        structuresLoaded = 0
        resetRun()
        do {
            let infos = try await inspector.listTables(schema: schema)
            tables = infos.map { info in
                TableChoice(
                    info: info, structure: nil,
                    ineligibleReason: info.kind == .table ? nil : "Views can't be updated",
                    isNonTransactional: Self.isNonTransactional(info.engine, family: dialect.family))
            }
            wordPressInstalls = WordPressDetector.detectAll(tableNames: infos.filter { $0.kind == .table }.map(\.ref.name))
            if !wordPressInstalls.contains(where: { $0.prefix == wordPressPrefix }) { wordPressPrefix = wordPressInstalls.first?.prefix }
            if let preselect, !preselect.isEmpty {
                selected = Set(infos.filter { preselect.contains($0.ref.name) && $0.kind == .table }.map(\.ref))
            } else if let prefix = wordPressPrefix {
                selected = wordPressTables(prefix: prefix)
            } else {
                selected = selected.filter { ref in infos.contains { $0.ref == ref } }
            }
            isLoadingTables = false
            structureTask?.cancel()
            structureTask = Task { [weak self] in await self?.loadStructures(inspector: inspector) }
        } catch {
            isLoadingTables = false
            tablesError = SchemaBrowserModel.message(error)
        }
    }

    private func wordPressTables(prefix: String) -> Set<TableRef> {
        let names = tables.map(\.name)
        let owned = Set(WordPressDetector.tables(ofPrefix: prefix, in: names, among: wordPressInstalls))
        return Set(tables.filter { $0.info.kind == .table && owned.contains($0.name) && $0.ineligibleReason == nil }.map(\.id))
    }

    /// Picks which WordPress installation Search & Replace works on: selects exactly its tables.
    func chooseWordPress(prefix: String) {
        guard wordPressInstalls.contains(where: { $0.prefix == prefix }) else { return }
        wordPressPrefix = prefix
        selected = wordPressTables(prefix: prefix)
        resetRun()
    }

    private func loadStructures(inspector: any SchemaInspector) async {
        for info in tables.map(\.info) where info.kind == .table {
            if Task.isCancelled { return }
            if let structure = try? await inspector.structure(of: info.ref), let i = tables.firstIndex(where: { $0.id == info.ref }) {
                tables[i].structure = structure
                if structure.primaryKey.isEmpty {
                    tables[i].ineligibleReason = "No primary key: rows can't be addressed safely"
                    selected.remove(info.ref)
                }
            }
            structuresLoaded += 1
        }
    }

    /// Lets tests and the preview wait for the structures.
    func waitForStructures() async { await structureTask?.value }

    static func isNonTransactional(_ engine: String?, family: SQLDialect.Family) -> Bool {
        guard family == .mysql, let engine else { return false }
        return !["innodb", "ndbcluster", "ndb", "xtradb", "tokudb", "rocksdb"].contains(engine.lowercased())
    }

    var visibleTables: [TableChoice] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? tables : tables.filter { $0.name.lowercased().contains(q) }
    }

    var eligibleTables: [TableChoice] { tables.filter { $0.ineligibleReason == nil } }

    func selectAll() { selected.formUnion(visibleTables.filter { $0.ineligibleReason == nil }.map(\.id)) }
    func selectNone() { selected.subtract(visibleTables.map(\.id)) }

    func toggle(_ ref: TableRef) {
        guard let t = tables.first(where: { $0.id == ref }), t.ineligibleReason == nil else { return }
        if selected.contains(ref) { selected.remove(ref) } else { selected.insert(ref) }
    }

    var selectedCount: Int { selected.count }

    // MARK: Inputs

    var inputs: Inputs {
        Inputs(
            search: search, replace: replace, caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord,
            jsonKeys: includeJSONKeys, phpKeys: includePHPKeys, escapedSlashes: replaceEscapedSlashes,
            guid: includeWordPressGUID, binary: includeBinary, tables: selected)
    }

    var configuration: SearchReplaceConfiguration {
        SearchReplaceConfiguration(
            search: search, replace: replace,
            options: SafeReplaceOptions(
                caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord,
                replaceInJSONKeys: includeJSONKeys, replaceInPHPArrayKeys: includePHPKeys),
            includeBinaryColumns: includeBinary, includeWordPressGUID: includeWordPressGUID,
            stopOnError: stopOnError, replaceJSONEscapedSlashes: replaceEscapedSlashes)
    }

    /// Why a preview can't start, nil when it can.
    var previewBlocker: String? {
        if search.isEmpty { return "Enter something to search for." }
        if selected.isEmpty { return "Select at least one table." }
        if isLoadingTables { return "Reading the table list…" }
        if case .running = stage { return "A run is in progress." }
        return nil
    }

    var canPreview: Bool { previewBlocker == nil }

    /// A preview exists for exactly the current inputs.
    var previewIsCurrent: Bool { previewInputs == inputs && previewReport != nil }

    var previewTotals: (replacements: Int, rows: Int, tables: Int) {
        guard let r = previewReport else { return (0, 0, 0) }
        return (r.replacements, r.rowsChanged, r.tables.filter { $0.rowsChanged > 0 }.count)
    }

    var applySummary: String {
        let t = previewTotals
        return "Will update \(t.rows.formatted()) row\(t.rows == 1 ? "" : "s") in \(t.tables.formatted()) table\(t.tables == 1 ? "" : "s")"
    }

    /// Why Replace is unavailable, nil when it can run.
    var applyBlocker: String? {
        if isReadOnly { return "This connection is read-only." }
        if stage == .applied { return "Already applied. Preview again to run another replacement." }
        guard previewReport != nil else { return "Run the preview first." }
        if !previewIsCurrent { return "Options changed since the preview. Preview again." }
        if previewTotals.rows == 0 { return "The preview found nothing to replace." }
        if case .running = stage { return "A run is in progress." }
        return nil
    }

    var canApply: Bool { applyBlocker == nil }

    var isRunning: Bool {
        if case .running = stage { return true }
        return false
    }

    var visibleReport: SearchReplaceReport? { applyReport ?? previewReport }

    // MARK: Runs

    private func resetRun() {
        stage = .configuring
        progress = [:]
        liveReports = []
        previewReport = nil
        applyReport = nil
        previewInputs = nil
        runError = nil
        confirmingApply = false
    }

    private func makeRunner() -> (DatabaseSearchReplace, SearchReplacePlan)? {
        inputError = nil
        guard let session = sessionProvider() else {
            inputError = "Not connected."
            return nil
        }
        do {
            let runner = try DatabaseSearchReplace(session: session, configuration: configuration)
            let structures = tables.filter { selected.contains($0.id) }.compactMap(\.structure)
            return (runner, runner.plan(tables: structures))
        } catch SafeReplacerError.invalidRegex(let message) {
            inputError = "Invalid regular expression: \(message)"
        } catch SafeReplacerError.emptySearch {
            inputError = "Enter something to search for."
        } catch {
            inputError = error.localizedDescription
        }
        return nil
    }

    /// Step 1: plan and dry-run. Nothing is written.
    func runPreview() async {
        guard canPreview else { return }
        await waitForStructures()
        guard let (runner, plan) = makeRunner() else { return }
        let snapshot = inputs
        stage = .running(.dryRun)
        progress = [:]
        liveReports = []
        applyReport = nil
        previewReport = nil
        runError = nil
        confirmingApply = false
        tableTotal = plan.runnableTables.count
        let report = await execute(runner: runner, plan: plan, mode: .dryRun)
        previewReport = report
        previewInputs = snapshot
        stage = .previewed
    }

    /// Step 2 entry: asks for the in-sheet confirmation (the summary), then `confirmApply()`.
    func beginApply() {
        guard canApply else { return }
        confirmingApply = true
    }

    func cancelApplyConfirmation() { confirmingApply = false }

    /// Authorizes through the write gate (a mass UPDATE: typed database name on production) and applies.
    func confirmApply() async {
        confirmingApply = false
        guard canApply, let gate else { return }
        let statements = gateStatements()
        guard !statements.isEmpty else { return }
        let allowed = await gate.authorize(
            statements: statements, escalateToDestructive: true, origin: .script, database: schema, actionTitle: "Replace")
        guard allowed else { return }
        guard let (runner, plan) = makeRunner() else { return }
        stage = .running(.apply)
        progress = [:]
        liveReports = []
        runError = nil
        tableTotal = plan.runnableTables.count
        let report = await execute(runner: runner, plan: plan, mode: .apply)
        applyReport = report
        stage = .applied
        if report.tables.contains(where: { $0.committed }) { onApplied() }
    }

    func cancelRun() { runTask?.cancel() }

    private func execute(runner: DatabaseSearchReplace, plan: SearchReplacePlan, mode: SearchReplaceMode) async -> SearchReplaceReport {
        let (stream, continuation) = AsyncStream<SearchReplaceEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task.detached { await runner.run(plan: plan, mode: mode) { continuation.yield($0) } }
        runTask = task
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event) }
        }
        let report = await task.value
        continuation.finish()
        await consumer.value
        runTask = nil
        currentTable = nil
        return report
    }

    private func handle(_ event: SearchReplaceEvent) {
        switch event {
        case .tableStarted(let ref, let index, let total, _):
            currentTable = ref
            tableIndex = index
            tableTotal = total
            progress[ref] = Progress(scanned: 0, changed: 0, isRunning: true)
        case .progress(let ref, let scanned, let changed):
            progress[ref] = Progress(scanned: scanned, changed: changed, isRunning: true)
        case .tableFinished(let report):
            progress[report.table] = Progress(scanned: report.rowsScanned, changed: report.rowsChanged, isRunning: false)
            liveReports.append(report)
        case .finished:
            break
        }
    }

    /// The statements the write gate classifies for the mass update: one UPDATE per table with matches,
    /// filtered by the literal prefilter when the search is literal (so a dry-run count means something).
    func gateStatements() -> [String] {
        guard let report = previewReport else { return [] }
        let d = dialect
        return report.tables.filter { $0.rowsChanged > 0 }.map { table in
            let columns = table.perColumn.map(\.column)
            let set = columns.map { "\(d.quoteIdentifier($0)) = \(d.quoteIdentifier($0))" }.joined(separator: ", ")
            var sql = "UPDATE \(d.qualified(table.table)) SET \(set)"
            if !regex, !wholeWord, !search.isEmpty {
                let pattern = d.literal(.text("%" + d.escapeLikePattern(search) + "%"))
                let op = d.family == .postgres && !caseSensitive ? "ILIKE" : "LIKE"
                sql += " WHERE " + columns.map { "\(d.quoteIdentifier($0)) \(op) \(pattern)" }.joined(separator: " OR ")
            }
            return sql
        }
    }

    // MARK: Helpers for the view

    func tableName(_ ref: TableRef) -> String { ref.name }

    /// Runs the open-in-editor hand-off for an invalid serialized value.
    func openInvalid(_ location: CellLocation) { openInEditor(location) }
}
