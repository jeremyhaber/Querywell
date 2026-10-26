import AppKit
import Foundation
import Observation
import QuerywellCore

/// Everything one connection window owns: the live connection, its lifecycle state, the tabs and
/// the database list. Closing the window closes the workspace, which closes the connection (and
/// any ssh process behind it).
@MainActor @Observable
final class ConnectionWorkspace: Identifiable {
    enum State: Equatable {
        /// Not connected: before the first attempt, or after Disconnect.
        case idle
        case connecting(ConnectionStage)
        case connected(ServerInfo, latency: Duration?)
        case failed(ConnectionOpenError)
    }

    let id = UUID()
    let openedAt = Date()
    private(set) var profile: ConnectionProfile
    private(set) var state: State = .idle
    var tabs = WorkspaceTabs()
    private(set) var databases: [String] = []
    var selectedDatabase: String?
    /// Sidebar state: schemas, cached table lists, filter and multi-selection.
    let browser = SchemaBrowserModel()
    /// Bumped on every successful (re)connect; table tabs reload when it changes.
    private(set) var connectionEpoch = 0
    /// Every write in this window goes through here (inline edits, truncate/drop, batch operations).
    let gate = WriteGate()
    /// Safety settings, kept current by the window (`AppSettings.safety`).
    var safety = AppSettings.Safety()
    /// A tab with unsaved edits is being closed: asks Review / Discard / Cancel.
    var closePrompt: TabClosePrompt?
    /// The open "Table Operations" sheet, if any.
    var batchOperations: BatchOperationsModel?
    /// Console, terminal, export and import state (Phase 7).
    let tools = WorkspaceTools()
    /// Database ▸ Search & Replace… (kept between openings so the last search/replace pair is still there).
    var searchReplace: SearchReplaceModel?
    var searchReplacePresented = false

    @ObservationIgnored private(set) var live: LiveConnection?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let opener: ConnectionOpener
    @ObservationIgnored private let keepaliveInterval: Duration
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var tableModels: [WorkspaceTab.ID: TableDataModel] = [:]
    @ObservationIgnored private var queryModels: [WorkspaceTab.ID: QueryTabModel] = [:]
    @ObservationIgnored var savedFiltersStore: SavedFiltersStore?
    /// History, saved queries and snippets (shared by every window).
    @ObservationIgnored let queryServices: QueryServices
    /// The History / Saved / Snippets sidebar of query tabs.
    let queryLibrary: QueryLibraryModel

    init(profile: ConnectionProfile, opener: ConnectionOpener, keepaliveInterval: Duration = .seconds(60),
         queryServices: QueryServices? = nil) {
        self.profile = profile
        self.opener = opener
        self.keepaliveInterval = keepaliveInterval
        let services = queryServices ?? QueryServices()
        self.queryServices = services
        self.queryLibrary = QueryLibraryModel(connectionID: profile.id, services: services)
        gate.contextProvider = { [weak self] database in
            guard let self else { return nil }
            return GuardContext(profile: self.profile, currentDatabase: database ?? self.browser.selectedSchema ?? self.selectedDatabase)
        }
        gate.settingsProvider = { [weak self] in self?.safety ?? AppSettings.Safety() }
        gate.sessionProvider = { [weak self] in self?.live?.session }
        gate.windowProvider = { [weak self] in self?.window }
        queryLibrary.onSavedChanged = { [weak self] q in self?.savedQueryChanged(q) }
        queryLibrary.onSavedDeleted = { [weak self] id in self?.savedQueryDeleted(id) }
    }

    // MARK: Derived

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var serverInfo: ServerInfo? {
        if case .connected(let info, _) = state { return info }
        return nil
    }

    var latency: Duration? {
        if case .connected(_, let latency) = state { return latency }
        return nil
    }

    var summary: ConnectionSummary { ConnectionSummary(profile: profile, serverInfo: serverInfo) }

    /// Window title text: name and, once connected, nothing else (the toolbar shows the rest).
    var title: String { profile.name }

    // MARK: Lifecycle

    /// Replaces the profile used for the next (re)connect. A live connection is not touched.
    func updateProfile(_ new: ConnectionProfile) {
        profile = new
        for model in queryModels.values { model.profile = new }
    }

    /// Connects the first time the window appears; later appearances don't undo a Disconnect.
    func startIfNeeded() async {
        guard !hasStarted else { return }
        await connect()
    }

    func connect() async {
        guard !isClosed else { return }
        switch state {
        case .connecting, .connected: return
        case .idle, .failed: break
        }
        hasStarted = true
        state = .connecting(.validating)
        do {
            let live = try await opener.open(profile) { [weak self] stage in
                Task { @MainActor in self?.report(stage) }
            }
            guard !isClosed else {
                await live.close()
                return
            }
            self.live = live
            let latency = await measureLatency(live)
            // The window may have been closed (or the user disconnected) while we pinged.
            guard !isClosed, self.live === live else { return }
            connectionEpoch += 1
            state = .connected(live.session.serverInfo, latency: latency)
            startKeepalive(live)
            await loadDatabases(live)
            guard !isClosed, self.live === live else { return }
            browser.attach(
                inspector: SchemaInspectorFactory.inspector(for: live.session), engine: profile.engine,
                preferred: profile.engine == .postgresql ? nil : selectedDatabase)
        } catch let error as ConnectionOpenError {
            if !isClosed { state = .failed(error) }
        } catch {
            if !isClosed { state = .failed(.database(.connectionFailed(error.localizedDescription))) }
        }
    }

    private func report(_ stage: ConnectionStage) {
        if case .connecting = state { state = .connecting(stage) }
    }

    func reconnect() async {
        await teardown()
        state = .idle
        await connect()
    }

    /// Closes the connection but keeps the window and tabs.
    func disconnect() async {
        await teardown()
        state = .idle
    }

    /// Final: the window is going away.
    func close() async {
        isClosed = true
        tools.shutdown()
        await teardown()
        state = .idle
    }

    private func teardown() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        databases = []
        selectedDatabase = nil
        browser.detach()
        let live = self.live
        self.live = nil
        await live?.close()
    }

    // MARK: Health

    private func measureLatency(_ live: LiveConnection) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await live.session.execute("SELECT 1")
            return start.duration(to: clock.now)
        } catch {
            return nil
        }
    }

    private func startKeepalive(_ live: LiveConnection) {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.ping(live)
            }
        }
    }

    private func ping(_ live: LiveConnection) async {
        guard self.live === live, case .connected(let info, _) = state else { return }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await live.session.execute("SELECT 1")
            guard self.live === live, case .connected = state else { return }
            state = .connected(info, latency: start.duration(to: clock.now))
        } catch {
            guard self.live === live else { return }
            let detail: String
            if let db = error as? DatabaseError {
                detail = ConnectionOpenError.database(db).message
            } else {
                detail = error.localizedDescription
            }
            keepaliveTask?.cancel()
            keepaliveTask = nil
            self.live = nil
            state = .failed(.database(.connectionFailed("The connection was lost. \(detail)")))
            await live.close()
        }
    }

    private func loadDatabases(_ live: LiveConnection) async {
        do {
            let names = try await live.session.listDatabases()
            guard self.live === live else { return }
            databases = names
            let current = (try? await live.session.currentDatabase()) ?? nil
            selectedDatabase = DatabaseSelection.preferred(
                among: names, defaultDatabase: profile.defaultDatabase, current: current, engine: profile.engine)
        } catch {
            databases = []
        }
    }

    // MARK: Tabs

    func newQuery() { tabs.newQuery() }
    func openConsole() { tabs.openConsole() }
    func openTerminal() { tabs.openTerminal() }

    /// Closes the selected tab; returns `false` when there was none.
    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let id = tabs.selectedID else { return false }
        requestClose(tab: id)
        return true
    }

    // MARK: Unsaved edits

    /// Table models with pending edits, in tab order.
    var modelsWithUnsavedEdits: [(tab: WorkspaceTab, model: TableDataModel)] {
        tabs.tabs.flatMap { tab in pendingModels(for: tab.id).map { (tab, $0) } }
    }

    /// Edit models of a tab that hold unsaved edits: a table tab's own, or a query tab's editable results.
    func pendingModels(for id: WorkspaceTab.ID) -> [TableDataModel] {
        if let model = tableModels[id] { return model.hasPendingChanges ? [model] : [] }
        return queryModels[id]?.pendingEditModels ?? []
    }

    var hasUnsavedEdits: Bool { !modelsWithUnsavedEdits.isEmpty }

    /// "3 unsaved edits in wp_posts and 1 other table" for close / quit prompts.
    var unsavedEditsDescription: String? {
        let dirty = modelsWithUnsavedEdits
        guard let first = dirty.first else { return nil }
        let total = dirty.reduce(0) { $0 + $1.model.pendingEditCount }
        let others = dirty.count - 1
        let where_ = others == 0 ? "“\(first.tab.title)”" : "“\(first.tab.title)” and \(others) other table\(others == 1 ? "" : "s")"
        return "\(total) unsaved edit\(total == 1 ? "" : "s") in \(where_)"
    }

    /// Closes a tab, first asking what to do with its unsaved edits.
    func requestClose(tab id: WorkspaceTab.ID) {
        guard let tab = tabs.tab(id: id) else { return }
        let pending = pendingModels(for: id)
        if !pending.isEmpty {
            tabs.select(id: id)
            let total = pending.reduce(0) { $0 + $1.pendingEditCount }
            closePrompt = TabClosePrompt(tabID: id, title: tab.title, summary: "\(total) unsaved edit\(total == 1 ? "" : "s")")
            return
        }
        tabs.close(id: id)
    }

    /// Resolves the close prompt.
    func resolveClosePrompt(_ choice: TabClosePrompt.Choice) {
        guard let prompt = closePrompt else { return }
        closePrompt = nil
        switch choice {
        case .review:
            tabs.select(id: prompt.tabID)
            pendingModels(for: prompt.tabID).first?.reviewPresented = true
        case .discard:
            for model in pendingModels(for: prompt.tabID) { model.discardAll() }
            tabs.close(id: prompt.tabID)
        case .cancel:
            break
        }
    }

    /// Selects the first tab with unsaved edits and opens its Review sheet.
    func reviewFirstUnsaved() {
        guard let first = modelsWithUnsavedEdits.first else { return }
        tabs.select(id: first.tab.id)
        first.model.reviewPresented = true
    }

    func discardAllUnsavedEdits() {
        for entry in modelsWithUnsavedEdits { entry.model.discardAll() }
    }

    // MARK: Destructive table actions

    struct DestructiveOutcome: Equatable {
        /// Statements that ran.
        var completed = 0
        /// The statement that failed and the server's message; later statements were not run.
        var failure: (statement: String, message: String)?
        var declined = false

        static func == (a: Self, b: Self) -> Bool {
            a.completed == b.completed && a.declined == b.declined && a.failure?.statement == b.failure?.statement
                && a.failure?.message == b.failure?.message
        }
    }

    /// `TRUNCATE` for each table, through the write gate (typed database name on production).
    func truncate(_ tables: [TableInfo]) async -> DestructiveOutcome {
        guard let dialect = live.map({ SQLDialect($0.session.engine) }) else { return DestructiveOutcome(declined: true) }
        let statements = TableOperations.truncate(tables, dialect: dialect)
        let outcome = await runDestructive(statements, schema: tables.first?.ref.schema, title: "Empty")
        let real = tables.filter { $0.kind == .table }
        for info in real.prefix(outcome.completed) {
            if let model = tableModel(forTable: info.ref) {
                model.discardAll()
                model.reload()
            }
        }
        browser.reloadCurrent()
        return outcome
    }

    /// `DROP` for each table or view; their tabs close and the sidebar refreshes.
    func drop(_ tables: [TableInfo]) async -> DestructiveOutcome {
        guard let dialect = live.map({ SQLDialect($0.session.engine) }) else { return DestructiveOutcome(declined: true) }
        let statements = TableOperations.drop(tables, dialect: dialect)
        let outcome = await runDestructive(statements, schema: tables.first?.ref.schema, title: "Drop")
        for info in tables.prefix(outcome.completed) {
            for tab in tabs.tabs where tab.kind == .table(database: info.ref.schema, name: info.ref.name) {
                tableModels[tab.id]?.discardAll()
                tabs.close(id: tab.id)
            }
        }
        browser.selectedTables = []
        browser.reloadCurrent()
        return outcome
    }

    private func runDestructive(_ statements: [String], schema: String?, title: String) async -> DestructiveOutcome {
        guard !statements.isEmpty, let session = live?.session else { return DestructiveOutcome(declined: true) }
        let noun = statements.count == 1 ? "" : " \(statements.count) objects"
        guard await gate.authorize(statements: statements, escalateToDestructive: true, database: schema, actionTitle: title + noun) else {
            return DestructiveOutcome(declined: true)
        }
        var outcome = DestructiveOutcome()
        for sql in statements {
            do {
                _ = try await session.execute(sql)
                outcome.completed += 1
            } catch {
                outcome.failure = (sql, SchemaBrowserModel.message(error))
                break
            }
        }
        return outcome
    }

    // MARK: Table operations sheet

    /// Opens the batch engine / charset sheet for `tables` (MySQL / MariaDB only).
    func presentTableOperations(for tables: [TableInfo]) {
        guard let schema = browser.selectedSchema, let server = serverInfo, let live,
              BatchOperationsModel.unsupportedReason(for: profile.engine) == nil, !tables.isEmpty else { return }
        let model = BatchOperationsModel(
            schema: schema, tables: tables, server: server, inspector: browser.inspector, session: live.session, gate: gate)
        model.onFinished = { [weak self] in
            guard let self else { return }
            self.refreshSchema()
        }
        batchOperations = model
    }

    /// ⌘1…⌘9: selects the tab at `index` (0-based) if it exists.
    func selectTab(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        tabs.select(id: tabs.tabs[index].id)
    }

    // MARK: Query tabs

    /// The model behind a query tab, created on first use from the tab's persisted text.
    func queryModel(forTab tab: WorkspaceTab) -> QueryTabModel? {
        guard case .query = tab.kind else { return nil }
        if let existing = queryModels[tab.id] { return existing }
        let open = Set(tabs.tabs.map(\.id))
        queryModels = queryModels.filter { open.contains($0.key) }
        let model = QueryTabModel(profile: profile, text: tab.queryText ?? "")
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.inspectorProvider = { [weak self] in self?.browser.inspector }
        model.schemaProvider = { [weak self] in self?.browser.selectedSchema ?? self?.selectedDatabase }
        model.gate = gate
        model.history = queryServices.history(for: profile.id)
        model.savedQueries = queryServices.savedQueries
        let tabID = tab.id
        model.onHistoryChanged = { [weak self] in
            guard let self else { return }
            Task { await self.queryLibrary.reload() }
        }
        model.onDirtyChange = { [weak self] dirty in self?.tabs.setDirty(id: tabID, dirty) }
        model.onTextPersist = { [weak self] text in self?.tabs.setQueryText(id: tabID, text) }
        model.onLinked = { [weak self] q in
            self?.tabs.link(id: tabID, savedQueryID: q.id, title: q.name)
            Task { await self?.queryLibrary.reload() }
        }
        if let savedID = tab.savedQueryID {
            Task { [weak model, store = queryServices.savedQueries] in
                if let q = try? await store.query(id: savedID) { model?.attach(saved: q) }
            }
        }
        queryModels[tab.id] = model
        return model
    }

    /// The model of the selected tab when it is a query tab.
    var currentQueryModel: QueryTabModel? {
        tabs.selectedTab.flatMap { queryModel(forTab: $0) }
    }

    /// Opens a new query tab holding `text`.
    @discardableResult
    func newQuery(text: String) -> QueryTabModel? {
        let id = tabs.newQuery(text: text)
        return tabs.tab(id: id).flatMap { queryModel(forTab: $0) }
    }

    /// History click: into the current editor, or a new tab with ⌥ (or when no query tab is selected).
    func openHistory(_ entry: HistoryEntry, inNewTab: Bool) {
        if inNewTab || currentQueryModel == nil {
            newQuery(text: entry.editorText)
        } else {
            currentQueryModel?.setEditorText(entry.editorText)
        }
    }

    /// "Run Again": loads the SQL and runs it through the runner and the write guard. Truncated entries can only be opened.
    func runHistory(_ entry: HistoryEntry) {
        guard let sql = entry.rerunScript else {
            openHistory(entry, inNewTab: false)
            return
        }
        let model = currentQueryModel ?? newQuery(text: sql)
        Task { await model?.loadAndRun(sql) }
    }

    func openSaved(_ query: SavedQuery) {
        let id = tabs.openSavedQuery(id: query.id, name: query.name, sql: query.sql)
        if let tab = tabs.tab(id: id) { queryModel(forTab: tab)?.attach(saved: query) }
    }

    func runSaved(_ query: SavedQuery) {
        openSaved(query)
        guard let model = currentQueryModel else { return }
        Task { await model.run(.all) }
    }

    func insertSnippet(_ snippet: Snippet) {
        let model = currentQueryModel ?? newQuery(text: "")
        model?.insertSnippet(snippet.sql)
        model?.editor.focus()
    }

    private func savedQueryChanged(_ query: SavedQuery) {
        for tab in tabs.tabs where tab.savedQueryID == query.id { tabs.rename(id: tab.id, to: query.name) }
        for model in queryModels.values { model.savedQueryUpdated(query) }
    }

    private func savedQueryDeleted(_ id: UUID) {
        for tab in tabs.tabs where tab.savedQueryID == id {
            tabs.link(id: tab.id, savedQueryID: nil)
            queryModels[tab.id]?.detachSaved()
        }
    }

    // MARK: Table tabs

    /// Opens (or focuses) a table's tab; `filter` replaces the tab's chips (foreign-key navigation).
    func openTable(_ ref: TableRef, filter: ColumnFilter? = nil) {
        let id = tabs.openTable(database: ref.schema, name: ref.name)
        guard let tab = tabs.tab(id: id), let model = tableModel(forTab: tab) else { return }
        if let filter { model.replaceFilters(with: filter) }
    }

    /// The model behind a table tab, created on first use. Models of closed tabs are dropped here.
    func tableModel(forTab tab: WorkspaceTab) -> TableDataModel? {
        guard case .table(let database, let name) = tab.kind else { return nil }
        if let existing = tableModels[tab.id] { return existing }
        let open = Set(tabs.tabs.map(\.id))
        tableModels = tableModels.filter { open.contains($0.key) }
        let model = TableDataModel(table: TableRef(schema: database, name: name))
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.inspectorProvider = { [weak self] in self?.browser.inspector }
        model.auxSessionOpener = { [weak self] in
            guard let live = self?.live, live.canOpenAuxiliarySession else { return nil }
            return try await live.openAuxiliarySession()
        }
        model.savedFiltersStore = savedFiltersStore
        model.connectionID = profile.id
        model.openTable = { [weak self] ref, filter in self?.openTable(ref, filter: filter) }
        model.gate = gate
        model.isReadOnlyProvider = { [weak self] in self?.profile.effectiveReadOnly ?? false }
        let tabID = tab.id
        model.onDirtyChange = { [weak self] dirty in self?.tabs.setDirty(id: tabID, dirty) }
        tableModels[tab.id] = model
        return model
    }

    /// The model of the open tab for `ref`, if any.
    func tableModel(forTable ref: TableRef) -> TableDataModel? {
        tabs.tabs.first { $0.kind == .table(database: ref.schema, name: ref.name) }.flatMap { tableModel(forTab: $0) }
    }

    /// A table was renamed or moved: its open tab now shows `new`, and the sidebar re-reads.
    func tableRelocated(from old: TableRef, to new: TableRef) {
        for tab in tabs.tabs where tab.kind == .table(database: old.schema, name: old.name) {
            tabs.retargetTable(id: tab.id, database: new.schema, name: new.name)
            tableModels[tab.id]?.retarget(to: new)
        }
        refreshSchema()
    }

    /// ⌘R: re-read schemas and tables, and the structure of open tables.
    func refreshSchema() {
        browser.refresh()
        for model in queryModels.values { model.invalidateCatalog() }
        for model in tableModels.values { model.invalidateStructure() }
        if let tab = tabs.selectedTab, let model = tableModel(forTab: tab), model.hasLoaded { model.reload() }
    }

    // MARK: Window

    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}


/// "Close the tab with unsaved edits?" state.
struct TabClosePrompt: Identifiable, Equatable {
    enum Choice { case review, discard, cancel }
    var tabID: UUID
    var title: String
    var summary: String
    var id: UUID { tabID }
}
