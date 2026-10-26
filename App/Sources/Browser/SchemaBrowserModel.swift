import Foundation
import Observation
import QuerywellCore

/// What the sidebar shows for one schema (MySQL database / Postgres schema).
struct SchemaContents: Equatable {
    var tables: [TableInfo]
    var views: [TableInfo]
    var routines: [RoutineInfo]

    /// "2 views · 1 procedure", the design's summary line.
    var summary: String {
        func part(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let procedures = routines.filter { $0.kind == .procedure }.count
        let parts = [part(views.count, "view"), part(procedures, "procedure"), part(routines.count - procedures, "function")]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? "No views or routines" : joined
    }
}

/// Sidebar state for one connection window: schema list, per-schema table lists (cached), the filter
/// field and the multi-selection. Invalidated on refresh and reconnect.
///
/// Selection is `selectedTables` (names inside ``selectedSchema``); the batch engine / collation sheet
/// reads it.
@MainActor @Observable
final class SchemaBrowserModel {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private(set) var schemas: [String] = []
    private(set) var schemasPhase: Phase = .idle
    var selectedSchema: String? {
        didSet {
            guard selectedSchema != oldValue else { return }
            selectedTables = []
            anchor = nil
            if let selectedSchema { loadContentsIfNeeded(schema: selectedSchema) }
        }
    }
    private(set) var contents: [String: SchemaContents] = [:]
    private(set) var contentsPhase: [String: Phase] = [:]
    var filterText = ""
    /// Table/view names selected in the sidebar (⌘/⇧-click). The batch tools act on this set.
    var selectedTables: Set<String> = []
    /// Last plain/⌘-clicked name, the origin of ⇧-click ranges.
    private(set) var anchor: String?
    var routinesExpanded = false

    @ObservationIgnored private(set) var inspector: (any SchemaInspector)?
    @ObservationIgnored private var engine: DatabaseEngine = .mysql
    @ObservationIgnored private var preferredSchema: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var schemasTask: Task<Void, Never>?

    // MARK: Derived

    var current: SchemaContents? { selectedSchema.flatMap { contents[$0] } }

    var currentPhase: Phase {
        guard let selectedSchema else { return schemasPhase }
        return contentsPhase[selectedSchema] ?? (schemasPhase == .loading ? .loading : .idle)
    }

    /// Caption for the picker: databases on MySQL, schemas on Postgres.
    var schemaNoun: String { engine == .postgresql ? "Schema" : "Database" }

    /// Tables matching the filter field, best fuzzy match first (name order when the field is empty).
    var filteredTables: [TableInfo] { filtered(current?.tables ?? []) }
    var filteredViews: [TableInfo] { filtered(current?.views ?? []) }

    private func filtered(_ items: [TableInfo]) -> [TableInfo] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return items }
        return FuzzyMatcher.rank(items, query: query, key: { $0.ref.name }, limit: .max).map(\.0)
    }

    /// Tables of the current schema as ⌘K items.
    var switcherItems: [QuickSwitcherItem] {
        guard let schema = selectedSchema, let current else { return [] }
        return (current.tables + current.views).map { .table(database: schema, name: $0.ref.name) }
    }

    func info(for name: String) -> TableInfo? {
        guard let current else { return nil }
        return current.tables.first { $0.ref.name == name } ?? current.views.first { $0.ref.name == name }
    }

    // MARK: Lifecycle

    /// Starts browsing a freshly opened session. `preferred` is the workspace's initial database.
    func attach(inspector: any SchemaInspector, engine: DatabaseEngine, preferred: String?) {
        detach()
        self.inspector = inspector
        self.engine = engine
        self.preferredSchema = preferred
        loadSchemas()
    }

    /// Drops everything (disconnect / reconnect). The selected schema is remembered as the preference.
    func detach() {
        generation += 1
        schemasTask?.cancel()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        if let selectedSchema { preferredSchema = selectedSchema }
        inspector = nil
        schemas = []
        contents = [:]
        contentsPhase = [:]
        schemasPhase = .idle
        selectedTables = []
        anchor = nil
        selectedSchema = nil
    }

    /// Re-reads the schema list and the current schema (⌘R).
    func refresh() {
        guard inspector != nil else { return }
        let keep = selectedSchema ?? preferredSchema
        preferredSchema = keep
        contents = [:]
        contentsPhase = [:]
        loadSchemas()
    }

    private func loadSchemas() {
        guard let inspector else { return }
        generation += 1
        let gen = generation
        schemasTask?.cancel()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        schemasPhase = .loading
        schemasTask = Task { [weak self] in
            do {
                let names = try await inspector.listSchemas()
                guard let self, self.generation == gen else { return }
                self.schemas = names
                self.schemasPhase = .idle
                let pick = Self.pick(names, preferred: self.preferredSchema, engine: self.engine)
                if self.selectedSchema == pick {
                    if let pick { self.loadContentsIfNeeded(schema: pick) }
                } else {
                    self.selectedSchema = pick  // didSet loads it
                }
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.schemasPhase = .failed(Self.message(error))
            }
        }
    }

    /// Preferred schema if present; on Postgres `public`; otherwise the first non-system one.
    static func pick(_ names: [String], preferred: String?, engine: DatabaseEngine) -> String? {
        if let preferred, names.contains(preferred) { return preferred }
        if engine == .postgresql, names.contains("public") { return "public" }
        return DatabaseSelection.preferred(among: names, defaultDatabase: nil, current: nil, engine: engine)
    }

    func loadContentsIfNeeded(schema: String) {
        if contents[schema] != nil || contentsPhase[schema] == .loading { return }
        loadContents(schema: schema)
    }

    func reloadCurrent() {
        guard let selectedSchema else { return }
        loadContents(schema: selectedSchema)
    }

    private func loadContents(schema: String) {
        guard let inspector else { return }
        let gen = generation
        loadTasks[schema]?.cancel()
        contentsPhase[schema] = .loading
        loadTasks[schema] = Task { [weak self] in
            do {
                let all = try await inspector.listTables(schema: schema)
                // Routines are optional: a user without privileges still gets the tables.
                let routines = (try? await inspector.listRoutines(schema: schema)) ?? []
                guard let self, self.generation == gen else { return }
                self.contents[schema] = SchemaContents(
                    tables: all.filter { $0.kind == .table }.sorted(by: Self.byName),
                    views: all.filter { $0.kind != .table }.sorted(by: Self.byName),
                    routines: routines)
                self.contentsPhase[schema] = .idle
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.contentsPhase[schema] = .failed(Self.message(error))
            }
        }
    }

    private static func byName(_ a: TableInfo, _ b: TableInfo) -> Bool {
        a.ref.name.localizedCaseInsensitiveCompare(b.ref.name) == .orderedAscending
    }

    static func message(_ error: any Error) -> String {
        if let db = error as? DatabaseError {
            switch db {
            case .query(let message, _), .connectionFailed(let message), .authenticationFailed(let message),
                .tlsFailed(let message), .unsupported(let message):
                return message
            case .timeout: return "The server took too long to respond."
            case .sessionClosed: return "The connection was closed."
            }
        }
        return error.localizedDescription
    }

    // MARK: Selection

    /// Plain click selects only `name`; ⌘ toggles it; ⇧ extends from the anchor across `visible`.
    func select(_ name: String, command: Bool, shift: Bool, visible: [String]) {
        if shift, let anchor, let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: name) {
            let range = visible[min(a, b)...max(a, b)]
            selectedTables = command ? selectedTables.union(range) : Set(range)
        } else if command {
            if selectedTables.contains(name) { selectedTables.remove(name) } else { selectedTables.insert(name) }
            anchor = name
        } else {
            selectedTables = [name]
            anchor = name
        }
    }

    func selectAllMatching() {
        selectedTables = Set(filteredTables.map(\.ref.name))
    }
}
