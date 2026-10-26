import AppKit
import Foundation
import QuerywellCore
import UniformTypeIdentifiers

// Console, terminal, export, import and result export for a connection window.

extension ConnectionWorkspace {
    // MARK: Console and terminal tabs

    /// The model behind the console tab, created on first use.
    func consoleModel(forTab tab: WorkspaceTab) -> ConsoleTabModel? {
        guard case .console = tab.kind else { return nil }
        if let existing = tools.consoleModels[tab.id] { return existing }
        let model = ConsoleTabModel(profile: profile)
        let tabID = tab.id
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.inspectorProvider = { [weak self] in self?.browser.inspector }
        model.initialDatabaseProvider = { [weak self] in self?.browser.selectedSchema ?? self?.selectedDatabase }
        model.gate = gate
        model.history = queryServices.history(for: profile.id)
        model.formatOptions = { [weak self] in
            let s = self?.tools.consoleSettings ?? AppSettings.Console()
            return ConsoleFormatOptions(maxCellWidth: s.showFullCells ? nil : s.maxCellWidth)
        }
        model.onHistoryChanged = { [weak self] in
            guard let self else { return }
            Task { await self.queryLibrary.reload() }
        }
        model.onQuit = { [weak self] in self?.tabs.close(id: tabID) }
        model.onOpenInGrid = { [weak self] sql in self?.openInGrid(sql: sql) }
        model.onDatabaseChanged = { [weak self] database in
            if self?.browser.schemas.contains(database) == true { self?.browser.selectedSchema = database }
        }
        tools.consoleModels[tab.id] = model
        return model
    }

    func terminalModel(forTab tab: WorkspaceTab) -> TerminalTabModel? {
        guard case .terminal = tab.kind else { return nil }
        if let existing = tools.terminalModels[tab.id] { return existing }
        let model = TerminalTabModel(profile: profile)
        let owner = profile.id.uuidString
        let kind: SecretKind? = switch profile.ssh?.auth {
        case .password: .sshPassword
        case .keyFile: .sshKeyPassphrase
        default: nil
        }
        model.secretProvider = { [weak self] in
            guard let kind, let store = self?.tools.secretStore else { return nil }
            return (try? store.read(SecretKey(ownerID: owner, kind: kind))) ?? nil
        }
        tools.terminalModels[tab.id] = model
        return model
    }

    /// "Open in grid": a new query tab holding `sql`, run there (through the same guard as any query).
    func openInGrid(sql: String) {
        guard let model = newQuery(text: sql) else { return }
        Task { await model.run(.all) }
    }

    // MARK: Export

    /// The database the Export sheet is about: the sidebar's schema (MySQL) or the connected database (PostgreSQL).
    var exportDatabase: String? {
        profile.engine == .postgresql ? (selectedDatabase ?? profile.defaultDatabase) : (browser.selectedSchema ?? selectedDatabase)
    }

    /// File ▸ Export Database…, sidebar "Export…". `only` preselects those tables.
    func presentExport(only: Set<String>? = nil) async {
        guard isConnected, let server = serverInfo, let database = exportDatabase, tools.exportSheet == nil else { return }
        let schema = profile.engine == .postgresql ? (browser.selectedSchema ?? "public") : database
        var listed = browser.contents[schema].map { $0.tables + $0.views }
        if listed == nil, let inspector = browser.inspector { listed = try? await inspector.listTables(schema: schema) }
        let model = ExportSheetModel(
            profile: profile, database: database, serverInfo: server, tables: listed ?? [],
            secretStore: tools.secretStore ?? InMemorySecretStore(), tunnelLocalPort: live?.tunnel?.localPort)
        if let only, !only.isEmpty { model.selectedTables = only.intersection(Set((listed ?? []).map(\.ref.name))) }
        tools.exportSheet = model
        await model.load(inspector: browser.inspector)
    }

    // MARK: Import

    /// File ▸ Import SQL… (asks for a file) or a dropped file.
    func presentImport(file: URL?) {
        guard isConnected, tools.importSheet == nil else { return }
        guard let file = file ?? Self.askForImportFile() else { return }
        let model = ImportSheetModel(file: file, profile: profile, schemas: browser.schemas, currentSchema: browser.selectedSchema ?? selectedDatabase)
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.inspectorProvider = { [weak self] in self?.browser.inspector }
        model.gate = gate
        model.onFinished = { [weak self] target in
            guard let self else { return }
            self.refreshSchema()
            if let target, self.browser.selectedSchema != target, self.profile.engine != .postgresql { self.browser.selectedSchema = target }
        }
        tools.importSheet = model
    }

    private static func askForImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import SQL"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .gzip]
        if let sql = UTType(filenameExtension: "sql") { types.insert(sql, at: 0) }
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Whether a dropped file looks like a dump (`.sql`, `.sql.gz`, `.gz`).
    nonisolated static func isImportable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".sql") || name.hasSuffix(".sql.gz") || name.hasSuffix(".gz")
    }

    // MARK: Result export

    /// The table footer's "Export…": the table with its current filters and sort.
    func presentTableExport(_ model: TableDataModel) {
        guard isConnected, tools.resultExport == nil else { return }
        let table = model.table
        let export = ResultExportModel(
            source: .table(model.currentQuery()), name: table.name, engine: profile.engine, schema: table.schema, tableName: table.name)
        export.sessionProvider = { [weak self] in self?.live?.session }
        tools.resultExport = export
    }

    /// The query results strip's "Export ▸ …": the selected result set.
    func presentResultExport(_ result: QueryResult, name: String, kind: ResultExportModel.Kind) {
        guard tools.resultExport == nil else { return }
        let table = result.columns.compactMap(\.table).first ?? "exported_table"
        let export = ResultExportModel(
            source: .result(result), name: name, engine: profile.engine,
            schema: browser.selectedSchema ?? selectedDatabase ?? "", tableName: table)
        export.kind = kind
        export.sessionProvider = { [weak self] in self?.live?.session }
        tools.resultExport = export
    }
}
