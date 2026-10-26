import Foundation
import Observation
import QuerywellCore

/// State of the "Export database" sheet (design: Export.dc.html): what to dump and where it runs, the exact
/// command that will run, and the progress of the run. All command construction is Core's `ExportPlanner`;
/// this model only turns the form into `ExportOptions`, regenerates the plan whenever it changes, and
/// drives `ExportRunner`.
@MainActor @Observable
final class ExportSheetModel {
    enum CollationChoice: String, CaseIterable, Identifiable {
        case keep, mysql57, legacy, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keep: "Keep original"
            case .mysql57: "MySQL 5.7 & MariaDB compatible"
            case .legacy: "Legacy utf8mb4_unicode_ci"
            case .custom: "Custom…"
            }
        }
    }

    struct Failure: Equatable {
        var message: String
        /// The last lines the dump tool / ssh printed, when the process failed.
        var stderrTail: String?
    }

    enum RunState: Equatable {
        case idle
        case running
        case finished(ExportSummary)
        case failed(Failure)
        case cancelled
    }

    struct Progress: Equatable {
        var currentTable: String?
        var tableIndex = 0
        var tableTotal: Int?
        var bytes: Int64 = 0
    }

    // MARK: Fixed context

    let profile: ConnectionProfile
    let database: String
    let serverInfo: ServerInfo
    /// Tables and views of the database, with the sizes the sidebar already has.
    let allTables: [TableInfo]
    @ObservationIgnored let secretStore: any SecretStore
    @ObservationIgnored var tunnelLocalPort: Int?
    /// Finds the local dump tools (tests inject fixed ones).
    @ObservationIgnored var toolLocator: @Sendable () async -> [ToolInfo] = { await DumpToolLocator().locate() }
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    /// How ssh is invoked (tests point it at a throw-away known_hosts).
    @ObservationIgnored var sshOptions = SSHClientOptions()
    @ObservationIgnored var downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
    @ObservationIgnored private let dbPassword: String?
    @ObservationIgnored private let hasSSHSecret: Bool
    @ObservationIgnored private var runTask: Task<ExportSummary, any Error>?

    // MARK: Options (every change regenerates the plan)

    var location: ExportLocation { didSet { regenerate() } }
    var scope: ExportScope = .structureAndData { didSet { regenerate() } }
    var singleTransaction = true { didSet { regenerate() } }
    var addDropTable = true { didSet { regenerate() } }
    var gzip = true { didSet { regenerate() } }
    var includeRoutines = false { didSet { regenerate() } }
    var includeTriggers = true { didSet { regenerate() } }
    var includeEvents = false { didSet { regenerate() } }
    var skipTransients = false { didSet { regenerate() } }
    var collationChoice: CollationChoice = .keep { didSet { regenerate() } }
    var customCharset = "utf8mb4" { didSet { regenerate() } }
    var customCollation = "utf8mb4_unicode_ci" { didSet { regenerate() } }
    /// Rules (remembered per connection) and the explicit per-table choices; ``tableModes`` is what they resolve to.
    private(set) var config = ExportSelectionConfig() { didSet { tableModes = config.resolve(tableNames: allTableNames); regenerate() } }
    private(set) var tableModes: [String: TableExportMode] = [:]
    /// Rows selected in the list (⇧/⌘-click), for Space / the context menu.
    var selection: Set<String> = []
    /// Substring or glob (`wp_wf*`) narrowing the list; bulk actions apply to what it shows.
    var filterText = ""
    var sortBySize = false
    private(set) var prefix: String?
    private(set) var groups: [TableGroup] = []
    @ObservationIgnored var rulesStore: ExportRulesStore?

    // MARK: Derived state

    private(set) var tools: [ToolInfo] = []
    private(set) var toolsLoaded = false
    private(set) var toolSelection: ToolSelection?
    private(set) var plan: ExportPlan?
    private(set) var planError: String?
    /// WordPress options tables found in the database (`wp_options`, …); empty when it isn't WordPress.
    private(set) var optionsTables: [String] = []
    private(set) var collations: [CollationInfo] = []
    var destination: URL
    @ObservationIgnored private var destinationChosen = false

    private(set) var runState: RunState = .idle
    private(set) var progress = Progress()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var logLines: [String] = []

    init(profile: ConnectionProfile, database: String, serverInfo: ServerInfo, tables: [TableInfo],
         secretStore: any SecretStore, tunnelLocalPort: Int? = nil) {
        self.profile = profile
        self.database = database
        self.serverInfo = serverInfo
        self.allTables = tables
        self.secretStore = secretStore
        self.tunnelLocalPort = tunnelLocalPort
        location = profile.ssh != nil ? .remoteOverSSH : .localThroughTunnel
        let clustered = ExportTableCatalog.cluster(tables.map(\.ref.name))
        prefix = clustered.prefix
        groups = clustered.groups
        let owner = profile.id.uuidString
        dbPassword = (try? secretStore.read(SecretKey(ownerID: owner, kind: .databasePassword))) ?? nil
        switch profile.ssh?.auth {
        case .password: hasSSHSecret = ((try? secretStore.read(SecretKey(ownerID: owner, kind: .sshPassword))) ?? nil) != nil
        case .keyFile: hasSSHSecret = ((try? secretStore.read(SecretKey(ownerID: owner, kind: .sshKeyPassphrase))) ?? nil) != nil
        default: hasSSHSecret = false
        }
        destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        regenerate()
    }

    // MARK: Loading

    /// Finds the local tools, the server's collations and WordPress options tables. Safe to call again.
    func load(inspector: (any SchemaInspector)?) async {
        if let rulesStore, let stored = try? await rulesStore.config(for: profile.id) { config = stored }
        tools = await toolLocator()
        toolsLoaded = true
        regenerate()
        guard let inspector else { return }
        if let found = try? await inspector.availableCollations(), !found.isEmpty { collations = found }
        await detectWordPress(inspector: inspector)
    }

    func detectWordPress(inspector: any SchemaInspector) async {
        guard profile.engine != .postgresql else { return }
        var found: [String] = []
        for table in allTables where table.kind == .table && (table.ref.name == "options" || table.ref.name.hasSuffix("_options")) {
            guard let structure = try? await inspector.structure(of: table.ref) else { continue }
            let names = Set(structure.columns.map { $0.name.lowercased() })
            if names.contains("option_name"), names.contains("option_value") { found.append(table.ref.name) }
        }
        optionsTables = found
        if found.isEmpty, skipTransients { skipTransients = false } else { regenerate() }
    }

    // MARK: Derived

    var engine: DatabaseEngine { profile.engine }
    var isWordPress: Bool { !optionsTables.isEmpty }
    var supportsTransients: Bool { isWordPress && engine != .postgresql }
    var supportsCollation: Bool { engine != .postgresql }
    var supportsRoutinesEventsTriggers: Bool { engine != .postgresql }
    var canExportOnServer: Bool { profile.ssh != nil }
    var allTableNames: [String] { allTables.map(\.ref.name) }
    func mode(of table: String) -> TableExportMode { tableModes[table] ?? .both }

    /// Tables that are part of the dump (anything but skipped).
    var selectedTables: Set<String> {
        get { Set(allTableNames.filter { mode(of: $0) != .skip }) }
        set { setMode(.skip, for: allTableNames.filter { !newValue.contains($0) }); setMode(.both, for: allTableNames.filter { newValue.contains($0) && mode(of: $0) == .skip }) }
    }
    var allSelected: Bool { selectedCount == allTables.count }
    var selectedCount: Int { allTables.count - tableModes.values.filter { $0 == .skip }.count }
    var structureOnlyCount: Int { tableModes.values.filter { $0 == .structureOnly }.count }

    var selectedTableInfos: [TableInfo] { allTables.filter { mode(of: $0.ref.name) != .skip } }

    /// Data + index bytes of the tables whose rows are exported (the server's estimate).
    var estimatedBytes: Int64 {
        allTables.filter { [.both, .dataOnly].contains(mode(of: $0.ref.name)) }.reduce(0) { $0 + ($1.dataBytes ?? 0) + ($1.indexBytes ?? 0) }
    }

    /// "Exporting 42 of 48 tables · structure only for 6 · ≈ 37 MB"
    var selectionSummary: String {
        var parts = ["Exporting \(selectedCount) of \(allTables.count) tables"]
        if structureOnlyCount > 0 { parts.append("structure only for \(structureOnlyCount)") }
        if estimatedBytes > 0 { parts.append("≈ " + Self.byteString(estimatedBytes)) }
        return parts.joined(separator: " · ")
    }

    var subtitle: String {
        let estimatedBytes = allTables.reduce(Int64(0)) { $0 + ($1.dataBytes ?? 0) + ($1.indexBytes ?? 0) }
        let tablesText = "\(allTables.count) table\(allTables.count == 1 ? "" : "s")"
        var parts = [profile.name, serverInfo.shortDescription, tablesText]
        if estimatedBytes > 0 { parts.append("about " + Self.byteString(estimatedBytes)) }
        return parts.joined(separator: " · ")
    }

    static func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    var tablesSummary: String {
        if allSelected { return "All \(allTables.count) tables" }
        return "\(selectedCount) of \(allTables.count) tables"
    }

    var exportOptions: ExportOptions {
        ExportOptions(
            scope: scope, singleTransaction: singleTransaction, addDropTable: addDropTable, gzip: gzip,
            tables: explicitTableList,
            skipWordPressTransients: skipTransients && supportsTransients, optionsTables: optionsTables,
            includeRoutines: includeRoutines, includeTriggers: includeTriggers, includeEvents: includeEvents,
            collation: collationMapping, location: location, tableModes: tableModes)
    }

    /// With few skipped tables the dump uses `--ignore-table`; with many, an explicit list reads better.
    private var explicitTableList: [String]? {
        let skipped = tableModes.values.filter { $0 == .skip }.count
        guard skipped > 0, skipped > allTables.count - skipped else { return nil }
        return allTableNames.filter { mode(of: $0) != .skip }
    }

    var collationMapping: CollationMapping? {
        switch collationChoice {
        case .keep: nil
        case .mysql57: .mysql57MariaDBCompatible
        case .legacy: .legacyUnicodeCI
        case .custom: .custom(charset: customCharset, collation: customCollation)
        }
    }

    var charsets: [String] { Array(Set(collations.map(\.characterSet))).sorted() }
    func collations(forCharset charset: String) -> [String] { collations.filter { $0.characterSet == charset }.map(\.name).sorted() }

    /// The text of the command preview (secrets already replaced by ****).
    var commandPreview: String { plan?.displayCommand ?? "" }

    /// Issues with the local tool that matter for the chosen location.
    var toolIssues: [ToolIssue] {
        guard location == .localThroughTunnel, toolsLoaded else { return [] }
        return toolSelection?.issues ?? []
    }

    /// `brew install …` for the missing client tools, or nil when a tool is available.
    var installHint: String? {
        guard location == .localThroughTunnel, toolsLoaded, toolSelection?.tool == nil else { return nil }
        return engine == .postgresql ? "brew install libpq" : "brew install mysql-client"
    }

    /// "Uses mysqldump from Homebrew (found: 8.4.2). Slower on large tables." / "Runs mysqldump on web01, …".
    var locationDetail: (server: String, local: String) {
        let host = profile.ssh?.host ?? "the server"
        let tool = engine == .postgresql ? "pg_dump" : "mysqldump"
        let server = "Runs \(tool) on \(host)" + (gzip ? ", gzips it there, then downloads one compressed file." : " and downloads the result.")
        guard toolsLoaded else { return (server, "Looking for \(tool) on this Mac…") }
        guard let found = toolSelection?.tool else { return (server, "No \(tool) found on this Mac.") }
        let source = Self.isHomebrew(found.path) ? " from Homebrew" : ""
        return (server, "Uses \(found.name)\(source) (found: \(found.version)). Slower on large tables.")
    }

    static func isHomebrew(_ path: String) -> Bool {
        path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local/opt") || path.hasPrefix("/usr/local/Cellar") || path.contains("/homebrew/")
    }

    var isRunning: Bool { runState == .running }
    var canStart: Bool { plan != nil && !isRunning && selectedCount > 0 }

    var progressFraction: Double {
        switch runState {
        case .finished: return 1
        default:
            let total = progress.tableTotal ?? selectedCount
            guard total > 0 else { return 0 }
            return min(1, Double(progress.tableIndex) / Double(total))
        }
    }

    // MARK: Plan

    func regenerate() {
        toolSelection = toolsLoaded || !tools.isEmpty ? DumpToolSelector.select(for: serverInfo, from: tools) : nil
        guard selectedCount > 0 else {
            plan = nil
            planError = "Choose at least one table to export."
            return
        }
        let target = ExportTarget(profile: profile, database: database, password: dbPassword, tunnelLocalPort: tunnelLocalPort)
        do {
            // Local exports need the tool selection even before discovery finished: show the plan error instead.
            let selection: ToolSelection? = location == .localThroughTunnel ? (toolSelection ?? DumpToolSelector.select(for: serverInfo, from: [])) : nil
            let p = try ExportPlanner.plan(target: target, options: exportOptions, tool: selection, sshOptions: sshOptions, sshHasSecret: hasSSHSecret, now: now())
            plan = p
            planError = nil
            if !destinationChosen {
                destination = downloadsDirectory.appendingPathComponent(p.outputFilename)
            }
        } catch {
            plan = nil
            planError = error.localizedDescription
        }
    }

    func chooseDestination(_ url: URL) {
        destination = url
        destinationChosen = true
    }

    /// `~/Downloads/wp_sunset-20261026-0930.sql.gz`
    var destinationDisplay: String {
        (destination.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Table modes

    /// Sets a mode as an explicit choice (it beats the rules, and is remembered for the next export).
    func setMode(_ mode: TableExportMode, for tables: [String]) {
        var c = config
        for t in tables {
            let byRules = ExportSelectionConfig(rules: c.rules).resolve(tableNames: [t])[t] ?? .both
            if mode == byRules { c.overrides[t] = nil } else { c.overrides[t] = mode }
        }
        if c != config { config = c }
    }

    /// Row click: Both → Structure only → Skip → Both.
    func cycleMode(of tables: [String]) {
        for t in tables {
            let next: TableExportMode = switch mode(of: t) {
            case .both: .structureOnly
            case .structureOnly: .skip
            case .skip, .dataOnly: .both
            }
            setMode(next, for: [t])
        }
    }

    /// Structure / Data toggles of a row, group or column header.
    func setStructure(_ on: Bool, for tables: [String]) {
        for t in tables { setMode(Self.mode(structure: on, data: includesData(t)), for: [t]) }
    }

    func setData(_ on: Bool, for tables: [String]) {
        for t in tables { setMode(Self.mode(structure: includesStructure(t), data: on), for: [t]) }
    }

    func includesStructure(_ t: String) -> Bool { [.both, .structureOnly].contains(mode(of: t)) }
    func includesData(_ t: String) -> Bool { [.both, .dataOnly].contains(mode(of: t)) }

    static func mode(structure: Bool, data: Bool) -> TableExportMode {
        switch (structure, data) {
        case (true, true): .both
        case (true, false): .structureOnly
        case (false, true): .dataOnly
        case (false, false): .skip
        }
    }

    func apply(preset: ExportTablePreset) {
        let modes = preset.modes(for: groups)
        var c = config
        c.overrides = [:]
        for t in allTableNames { c.overrides[t] = modes[t] ?? .both }
        config = c
    }

    func selectAllTables() { apply(preset: .allTables) }
    func selectNoTables() { setMode(.skip, for: allTableNames) }

    // MARK: Suggestions

    func suggestion(for table: String) -> TableSuggestion? {
        let isCore = groups.first { $0.kind == .core }?.tables.contains(table) ?? false
        return ExportTableCatalog.suggestion(for: table, prefix: prefix, isCore: isCore)
    }

    /// Suggested tables that aren't already at the suggested mode.
    var pendingSuggestions: [String] {
        allTableNames.filter { t in suggestion(for: t).map { mode(of: t) != $0.mode } ?? false }
    }

    func applySuggestions() {
        for t in pendingSuggestions { if let s = suggestion(for: t) { setMode(s.mode, for: [t]) } }
    }

    // MARK: Filter

    var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    func matchesFilter(_ table: String) -> Bool {
        !isFiltering || GlobPattern.matches(filterText.trimmingCharacters(in: .whitespaces), table, substringIfPlain: true)
    }

    var visibleTables: [String] { allTableNames.filter(matchesFilter) }

    /// "Skip matching" / "Structure only" / "Include matching".
    func setModeForVisible(_ mode: TableExportMode) { setMode(mode, for: visibleTables) }

    /// "Remember as rule": the filter text becomes a rule with `mode`, applied to the matches now and to future tables.
    func rememberFilterAsRule(_ mode: TableExportMode) {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let pattern = trimmed.contains("*") || trimmed.contains("?") ? trimmed : "*\(trimmed)*"
        var c = config
        c.rules.removeAll { $0.pattern.lowercased() == pattern.lowercased() }
        c.rules.append(ExportRule(pattern: pattern, mode: mode))
        // Explicit choices for the matched tables would hide the new rule.
        for t in allTableNames where GlobPattern.matches(pattern, t) { c.overrides[t] = nil }
        config = c
        persistRules()
    }

    func removeRule(_ id: UUID) {
        var c = config
        c.rules.removeAll { $0.id == id }
        config = c
        persistRules()
    }

    var rules: [ExportRule] { config.rules }

    private func persistRules() {
        guard let rulesStore else { return }
        let snapshot = config
        let id = profile.id
        Task { try? await rulesStore.save(snapshot, for: id) }
    }

    /// Tables in a group, in the chosen sort order and narrowed by the filter.
    func tables(in group: TableGroup) -> [TableInfo] {
        let infos = group.tables.compactMap { name in allTables.first { $0.ref.name == name } }.filter { matchesFilter($0.ref.name) }
        guard sortBySize else { return infos }
        func size(_ t: TableInfo) -> Int64 { (t.dataBytes ?? 0) + (t.indexBytes ?? 0) }
        return infos.sorted { size($0) > size($1) }
    }

    // MARK: Run

    /// Runs the export to ``destination``. Returns when it finished, failed or was cancelled.
    func run() async {
        guard let plan, canStart else { return }
        if let rulesStore {
            let snapshot = config
            let id = profile.id
            try? await rulesStore.save(snapshot, for: id)
        }
        runState = .running
        progress = Progress(tableTotal: plan.tables?.count ?? selectedCount)
        logLines = []
        startedAt = Date()
        finishedAt = nil
        let runner = ExportRunner(secretStore: secretStore)
        let destination = destination
        let (stream, continuation) = AsyncStream.makeStream(of: ExportEvent.self)
        let task = Task { try await runner.run(plan: plan, to: destination) { continuation.yield($0) } }
        runTask = task
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.apply(event) }
        }
        do {
            let summary = try await task.value
            continuation.finish()
            await consumer.value
            finishedAt = Date()
            runState = .finished(summary)
        } catch is CancellationError {
            continuation.finish()
            await consumer.value
            finishedAt = Date()
            runState = .cancelled
        } catch let error as ExportError {
            continuation.finish()
            await consumer.value
            finishedAt = Date()
            if case .processFailed(_, let tail) = error {
                runState = .failed(Failure(message: error.errorDescription ?? "The export failed.", stderrTail: tail.isEmpty ? nil : tail))
            } else {
                runState = .failed(Failure(message: error.errorDescription ?? "The export failed.", stderrTail: nil))
            }
        } catch {
            continuation.finish()
            await consumer.value
            finishedAt = Date()
            runState = .failed(Failure(message: error.localizedDescription, stderrTail: nil))
        }
        runTask = nil
    }

    /// Stops the export; the partial file is deleted by the runner.
    func cancel() { runTask?.cancel() }

    /// Shows a run in progress without running anything (snapshots).
    func previewRunning(_ progress: Progress, startedAgo: TimeInterval = 12) {
        runState = .running
        self.progress = progress
        startedAt = Date().addingTimeInterval(-startedAgo)
    }

    func endPreview() { runState = .idle }

    func resetAfterRun() {
        if !isRunning { runState = .idle }
    }

    private func apply(_ event: ExportEvent) {
        switch event {
        case .started: break
        case .table(let name, let index, let total):
            progress.currentTable = name
            progress.tableIndex = index
            if let total { progress.tableTotal = total }
        case .bytes(let n): progress.bytes = n
        case .log(let line):
            logLines.append(line)
            if logLines.count > 30 { logLines.removeFirst(logLines.count - 30) }
        }
    }

    /// Elapsed run time at `date`, frozen once the run ended.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? date).timeIntervalSince(startedAt)
    }
}
