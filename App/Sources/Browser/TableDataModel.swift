import Foundation
import Observation
import QuerywellCore

/// One column of the grid, merged from the result's ``ColumnInfo`` and the table structure.
struct GridColumn: Equatable, Identifiable {
    var name: String
    /// "bigint", "varchar", or "→ wp_users" for foreign keys.
    var typeLabel: String
    var presentation: ColumnPresentation
    var isPrimaryKey: Bool
    var foreignKey: ForeignKeyDefinition?
    /// Declared type for inspector hints ("varchar(200)").
    var fullType: String
    var id: String { name }
}

/// How a grid row relates to the pending edits.
enum GridRowMark: Equatable {
    case normal, deleted, inserted
}

/// A cell addressed by its position in the displayed rows.
struct GridCellPosition: Hashable {
    var row: Int
    var column: Int
}

/// An immutable page of rows, rendered by the grid. A new `id` means "reload the table view";
/// the same `id` with a new `revision` means "same page, pending edits changed" (the grid keeps its
/// scroll position and selection).
///
/// Displayed rows are the inserted (not yet saved) rows first, then the loaded rows with pending
/// cell edits substituted in.
final class GridContent {
    let id: UUID
    let revision: Int
    let columns: [GridColumn]
    let rows: [[DatabaseValue]]
    /// 0-based offset of the first *loaded* row in the whole result (for the row-number gutter).
    let offset: Int
    let duration: Duration
    /// Rows at the top that are unsaved inserts.
    let insertedCount: Int
    /// Per displayed row; empty means all `.normal`.
    let rowMarks: [GridRowMark]
    /// Cells with a pending edit (displayed row, column index).
    let editedCells: Set<GridCellPosition>
    /// Cells of inserted rows the server will fill in (default / auto-increment).
    let unsetCells: Set<GridCellPosition>
    /// The grid keeps its scroll offset when it shows this content (reload after commit).
    let preservesViewport: Bool
    /// Rows to select when the grid shows this content (reload after commit keeps the selection).
    let selectionToRestore: [Int]?

    init(columns: [GridColumn], rows: [[DatabaseValue]], offset: Int, duration: Duration,
         id: UUID = UUID(), revision: Int = 0, insertedCount: Int = 0, rowMarks: [GridRowMark] = [],
         editedCells: Set<GridCellPosition> = [], unsetCells: Set<GridCellPosition> = [], preservesViewport: Bool = false,
         selectionToRestore: [Int]? = nil) {
        self.id = id
        self.revision = revision
        self.columns = columns
        self.rows = rows
        self.offset = offset
        self.duration = duration
        self.insertedCount = insertedCount
        self.rowMarks = rowMarks
        self.editedCells = editedCells
        self.unsetCells = unsetCells
        self.preservesViewport = preservesViewport
        self.selectionToRestore = selectionToRestore
    }

    var columnSignature: [String] { columns.map { "\($0.name)|\($0.typeLabel)|\($0.isPrimaryKey)" } }

    func mark(_ row: Int) -> GridRowMark { rowMarks.indices.contains(row) ? rowMarks[row] : .normal }

    func isEdited(row: Int, column: Int) -> Bool { editedCells.contains(GridCellPosition(row: row, column: column)) }

    func isUnset(row: Int, column: Int) -> Bool { unsetCells.contains(GridCellPosition(row: row, column: column)) }

    /// A copy with the same page but different decorations / substituted values.
    func decorated(rows: [[DatabaseValue]], insertedCount: Int, rowMarks: [GridRowMark], editedCells: Set<GridCellPosition>,
                   unsetCells: Set<GridCellPosition>, revision: Int) -> GridContent {
        GridContent(columns: columns, rows: rows, offset: offset, duration: duration, id: id, revision: revision,
                    insertedCount: insertedCount, rowMarks: rowMarks, editedCells: editedCells, unsetCells: unsetCells,
                    preservesViewport: preservesViewport, selectionToRestore: selectionToRestore)
    }
}

/// The funnel popover is asked for through this (Add filter, chip click, ⌘⌥F, header funnel).
struct FilterRequest: Equatable, Identifiable {
    let id = UUID()
    var column: String
}

enum TableViewMode: String, CaseIterable, Identifiable {
    case data = "Data", structure = "Structure", indexes = "Indexes", relations = "Relations"
    var id: String { rawValue }
}

/// State and loading for one table tab: structure, query (sort / chips / WHERE / page), the current page
/// of rows and its count. Sessions serialize statements, so a newer request simply supersedes an older
/// one: the older result is dropped when it arrives (`generation`).
@MainActor @Observable
final class TableDataModel {
    struct LoadFailure: Equatable {
        var message: String
        var sql: String?
    }

    enum CountState: Equatable {
        case unknown
        case estimate(Int64)
        case exact(Int64)
    }

    let table: TableRef

    /// A query result (query editor) edited in place instead of a paged table: the SQL is re-run on
    /// reload, columns are named as the base table's, and no count / paging is involved.
    struct FixedQuery {
        var sql: String
        /// Result column i shows base-table column `columnMap[i]`.
        var columnMap: [String]
        /// The rows the editor already has; used for the first load so the query isn't run twice.
        var seed: QueryResult?
    }
    @ObservationIgnored var fixedQuery: FixedQuery?

    // Environment, injected by the owner.
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var inspectorProvider: @MainActor () -> (any SchemaInspector)? = { nil }
    @ObservationIgnored var savedFiltersStore: SavedFiltersStore?
    @ObservationIgnored var connectionID = UUID()
    /// Opens another table tab, optionally filtered (FK navigation).
    @ObservationIgnored var openTable: @MainActor (TableRef, ColumnFilter?) -> Void = { _, _ in }
    @ObservationIgnored var reportNotice: @MainActor (String) -> Void = { _ in }
    /// Opens another short-lived session to the same server (exact counts and funnel value lists run there so
    /// they never queue behind the page requests on the main session). nil/absent: they use the main session.
    @ObservationIgnored var auxSessionOpener: (@MainActor () async throws -> (any DatabaseSession)?)?

    var pageSize = 500
    var nullDisplay = "NULL"

    var mode: TableViewMode = .data
    private(set) var structure: TableStructure?
    private(set) var structureFailure: String?
    private(set) var isLoadingStructure = false

    // Query state.
    private(set) var sort: [SortKey] = []
    private(set) var filters = FilterGroup()
    /// What the WHERE field currently contains (not applied until Return).
    var whereDraft = ""
    private(set) var appliedWhere = ""
    private(set) var offset = 0
    /// Where the current page starts in key order (keyset paging); `.first` for OFFSET paging and page one.
    private(set) var pageCursor: PageCursor = .first
    /// Shown in the footer when paging with a deep OFFSET (slow); nil otherwise.
    private(set) var deepPagingNotice: String?
    private(set) var isCountingExactly = false

    enum PageCursor: Equatable {
        case first
        /// The page after the row with these order-column values.
        case after([DatabaseValue])
        /// The page before the row with these values; `fromOffset` is the offset of the page we came from.
        case before([DatabaseValue], fromOffset: Int)
        /// The final rows of the result.
        case last
    }

    /// Pages deeper than this many rows without keyset paging get the "slow" notice.
    nonisolated static let deepOffsetThreshold = 100_000

    // Results. `content` is what the grid shows (loaded rows with pending edits applied); `loadedContent`
    // is the page exactly as the server returned it.
    var content: GridContent?
    var loadedContent: GridContent?
    private(set) var isLoading = false
    private(set) var failure: LoadFailure?
    private(set) var count: CountState = .unknown
    private(set) var lastSQL: String?
    private(set) var hasLoaded = false

    // Selection / inspector.
    private(set) var selectedRows: [Int] = []
    var inspectorVisible = false
    /// The value editor sheet (JSON / PHP serialized / text) opened on a cell of this table.
    var valueEditor: ValueEditorModel?
    var inspectorFocusColumn: String?
    /// Last clicked column, the target of ⌘⌥F.
    var activeColumn: String?

    // Filters UI.
    var filterRequest: FilterRequest?
    var showSQL = false
    private(set) var savedFilters: [SavedFilter] = []
    private(set) var appliedSavedID: UUID?

    // Editing (logic in TableEditing.swift).
    var editSession: EditSession?
    var editRevision = 0
    /// Unsaved inserted rows in display order (newest first).
    var insertedOrder: [InsertedRowID] = []
    var isCommitting = false
    var reviewPresented = false
    /// The last failed commit, shown in the Review sheet until the user acts.
    var commitReport: CommitReport?
    var toast: ModelToast?
    /// Asks the grid to select a row and optionally start editing a cell (Add Row, Duplicate).
    var editRequest: GridEditRequest?
    @ObservationIgnored var gate: WriteGate?
    @ObservationIgnored var isReadOnlyProvider: @MainActor () -> Bool = { false }
    @ObservationIgnored var onDirtyChange: @MainActor (Bool) -> Void = { _ in }
    /// The user changed sort or filters; the workspace turns a preview tab into a normal one.
    @ObservationIgnored var onUserModified: @MainActor () -> Void = {}
    @ObservationIgnored var lastReportedDirty = false
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var rebaseOnNextLoad = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var loadedEpoch: Int?
    @ObservationIgnored private var countKey: String?

    init(table: TableRef) {
        self.table = table
    }

    // MARK: Derived

    var dialect: SQLDialect? { sessionProvider().map { SQLDialect($0.engine) } }

    var columnDefinitions: [ColumnDefinition] { structure?.columns ?? [] }

    func definition(of column: String) -> ColumnDefinition? {
        structure?.columns.first { $0.name.caseInsensitiveCompare(column) == .orderedSame }
    }

    var pageInfo: PageInfo {
        let rows = loadedContent?.rows.count ?? 0
        switch count {
        case .unknown: return PageInfo(offset: offset, rowCount: rows, pageSize: pageSize)
        case .estimate(let n): return PageInfo(offset: offset, rowCount: rows, pageSize: pageSize, total: n, totalIsExact: false)
        case .exact(let n): return PageInfo(offset: offset, rowCount: rows, pageSize: pageSize, total: n, totalIsExact: true)
        }
    }

    /// The keyset order when this table/sort can page with seeks instead of OFFSET.
    var keysetOrder: [SortKey]? {
        guard fixedQuery == nil else { return nil }
        return structure?.keysetOrder(for: sort)
    }

    /// The query for the page being shown: seeks from `pageCursor` when keyset paging applies.
    func pageQuery() -> TableQuery {
        var query = currentQuery()
        guard let order = keysetOrder else { return query }
        switch pageCursor {
        case .first: query.keyset = KeysetPage(order: order)
        case .after(let boundary): query.keyset = KeysetPage(order: order, direction: .forward, boundary: boundary)
        case .before(let boundary, _): query.keyset = KeysetPage(order: order, direction: .backward, boundary: boundary)
        case .last: query.keyset = KeysetPage(order: order, direction: .backward)
        }
        return query
    }

    func currentQuery(offset: Int? = nil) -> TableQuery {
        TableQuery(
            table: table, filter: filters.isEmpty ? nil : filters, rawWhere: appliedWhere,
            sort: sort, limit: pageSize, offset: offset ?? self.offset, primaryKey: structure?.primaryKey ?? [])
    }

    /// The generated `WHERE …` for "Show as SQL", or nil when nothing filters.
    var whereSQLPreview: String? {
        guard let dialect else { return nil }
        return currentQuery().whereSQL(dialect: dialect).map { "WHERE " + $0 }
    }

    var isFiltered: Bool { !filters.activeFilters.isEmpty || !appliedWhere.trimmingCharacters(in: .whitespaces).isEmpty }

    var filteredColumnNames: Set<String> { Set(filters.activeFilters.map { $0.column.lowercased() }) }

    func foreignKey(for column: String) -> ForeignKeyDefinition? {
        structure?.foreignKeys.first { $0.columns.count == 1 && $0.columns[0].caseInsensitiveCompare(column) == .orderedSame }
    }

    // MARK: Loading

    /// Loads on first display and again after a reconnect (`epoch` changes).
    func loadIfNeeded(epoch: Int) {
        if loadedEpoch == epoch, hasLoaded || isLoading { return }
        if loadedEpoch != nil, loadedEpoch != epoch { structure = nil }
        loadedEpoch = epoch
        Task { await loadSavedFilters() }
        reload()
    }

    /// Re-reads the structure on the next load (⌘R in the sidebar).
    func invalidateStructure() {
        structure = nil
        structureFailure = nil
    }

    func reload(keepCount: Bool = false, preserveViewport: Bool = false, restoreSelection: [Int]? = nil) {
        if !keepCount { countKey = nil }
        guard let session = sessionProvider() else {
            failure = LoadFailure(message: "Not connected.", sql: nil)
            return
        }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        countTask?.cancel()
        isCountingExactly = false
        isLoading = true
        loadTask = Task { [weak self] in
            await self?.performLoad(generation: gen, session: session, preserveViewport: preserveViewport, restoreSelection: restoreSelection)
        }
    }

    private func performLoad(generation gen: Int, session: any DatabaseSession, preserveViewport: Bool = false,
                             restoreSelection: [Int]? = nil) async {
        if structure == nil {
            isLoadingStructure = true
            do {
                let inspector = inspectorProvider() ?? SchemaInspectorFactory.inspector(for: session)
                let loaded = try await inspector.structure(of: table)
                guard gen == generation else { return }
                structure = loaded
                structureFailure = nil
            } catch {
                guard gen == generation else { return }
                structureFailure = SchemaBrowserModel.message(error)
            }
            isLoadingStructure = false
        }
        guard gen == generation, !Task.isCancelled else { return }

        let dialect = SQLDialect(session.engine)
        let query = pageQuery()
        let sql = fixedQuery?.sql ?? query.sql(dialect: dialect)
        lastSQL = sql
        do {
            let fetched: QueryResult
            if var fixed = fixedQuery, let seed = fixed.seed {
                fetched = seed
                fixed.seed = nil
                fixedQuery = fixed
            } else {
                fetched = try await session.execute(sql, interruptible: true)
            }
            guard gen == generation else { return }
            var result = fetched
            if query.keyset?.direction == .backward { result.rows.reverse() }
            applyOffset(for: result.rows.count)
            loadedContent = GridContent(
                columns: mergedColumns(result.columns), rows: result.rows, offset: offset, duration: result.duration,
                preservesViewport: preserveViewport, selectionToRestore: preserveViewport ? restoreSelection : nil)
            prepareEditSession()
            if rebaseOnNextLoad {
                rebaseOnNextLoad = false
                rebasePendingOriginals()
            }
            rebuildDisplay()
            failure = nil
            selectedRows = preserveViewport ? (restoreSelection ?? []).filter { $0 < (content?.rows.count ?? 0) } : []
            hasLoaded = true
            isLoading = false
            committed = QueryState(sort: sort, filters: filters, appliedWhere: appliedWhere, offset: offset, cursor: pageCursor)
            updateDeepPagingNotice()
            if fixedQuery != nil {
                count = .exact(Int64(result.rows.count))
            } else {
                startCount(generation: gen, session: session, dialect: dialect, query: query, rowsOnPage: result.rows.count)
            }
        } catch is CancellationError {
            guard gen == generation else { return }
            isLoading = false
            hasLoaded = true
        } catch {
            guard gen == generation else { return }
            failure = LoadFailure(message: SchemaBrowserModel.message(error), sql: sql)
            hasLoaded = true
            isLoading = false
        }
    }

    private func mergedColumns(_ result: [ColumnInfo]) -> [GridColumn] {
        result.enumerated().map { index, info in
            let name = fixedQuery.flatMap { $0.columnMap.indices.contains(index) ? $0.columnMap[index] : nil } ?? info.name
            let def = definition(of: name)
            let fk = foreignKey(for: name)
            let base = def?.dataType ?? info.typeName
            let full = def?.fullType ?? info.typeName
            return GridColumn(
                name: name,
                typeLabel: fk.map { "→ \($0.referenced.name)" } ?? base,
                presentation: ColumnPresentation(name: name, dataType: base, fullType: full),
                isPrimaryKey: def?.isPrimaryKey ?? false,
                foreignKey: fk,
                fullType: full)
        }
    }

    /// Row count: exact when the page proves it, the server estimate for big unfiltered tables, otherwise
    /// a `COUNT(*)` that arrives after the page ("…" until then). Counts run on a second short-lived session
    /// when the connection can open one, so a slow COUNT never delays the next page request.
    private func startCount(generation gen: Int, session: any DatabaseSession, dialect: SQLDialect, query: TableQuery, rowsOnPage: Int) {
        if rowsOnPage < pageSize {
            switch pageCursor {
            case .first, .after, .last:
                count = .exact(Int64(offset + rowsOnPage))
                countKey = nil
                return
            case .before: break  // fewer rows only means the start was reached
            }
        }
        var countQuery = query
        countQuery.keyset = nil
        let sql = countQuery.countSQL(dialect: dialect)
        // Paging within the same result keeps the exact total we already have.
        if case .exact = count, countKey == sql { return }
        countKey = sql
        let estimate = structure?.info.estimatedRows
        if !isFiltered, let estimate {
            count = .estimate(estimate)
            if estimate > Self.exactCountCeiling { return }  // large: keep the estimate until "Count exactly"
        } else {
            count = .unknown
        }
        runCount(sql: sql, generation: gen, session: session)
    }

    /// "Count exactly" in the footer: the `COUNT(*)` for tables above the automatic ceiling.
    func countExactly() {
        guard let session = sessionProvider(), let dialect else { return }
        var query = currentQuery()
        query.keyset = nil
        let sql = query.countSQL(dialect: dialect)
        countKey = sql
        countTask?.cancel()
        runCount(sql: sql, generation: generation, session: session)
    }

    private func runCount(sql: String, generation gen: Int, session: any DatabaseSession) {
        countTask?.cancel()
        isCountingExactly = true
        let opener = auxSessionOpener
        countTask = Task { [weak self] in
            var aux: (any DatabaseSession)?
            if let opener { aux = try? await opener() }
            let runner = aux ?? session
            var total: Int64?
            do {
                let result = try await runner.execute(sql, interruptible: true)
                if let first = result.rows.first?.first { total = Self.int(first) }
            } catch {
                // A failed or cancelled count only costs the footer its total.
            }
            await aux?.close()
            guard let self, self.generation == gen else { return }
            self.isCountingExactly = false
            if let total, !Task.isCancelled { self.count = .exact(total) }
        }
    }

    /// Above this many (estimated) rows an unfiltered table is only counted when asked ("Count exactly").
    nonisolated static let exactCountCeiling: Int64 = 2_000_000

    nonisolated static func int(_ value: DatabaseValue) -> Int64? {
        switch value {
        case .integer(let i): i
        case .unsignedInteger(let u): Int64(exactly: u)
        case .double(let d): Int64(exactly: d)
        case .text(let s): Int64(s)
        default: nil
        }
    }

    // MARK: Query changes

    func toggleSort(column: String, additive: Bool) {
        sort = SortCycle.next(current: sort, column: column, additive: additive)
        onUserModified()
        resetPaging()
        reload()
    }

    func applyWhere() {
        let trimmed = whereDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != appliedWhere || failure != nil else { return }
        appliedWhere = trimmed
        appliedSavedID = nil
        onUserModified()
        resetPaging()
        reload()
    }

    func upsertFilter(_ filter: ColumnFilter) {
        if let index = filters.filters.firstIndex(where: { $0.id == filter.id || $0.column.caseInsensitiveCompare(filter.column) == .orderedSame }) {
            filters.filters[index] = filter
        } else {
            filters.filters.append(filter)
        }
        filtersChanged()
    }

    func removeFilter(id: UUID) {
        filters.filters.removeAll { $0.id == id }
        filtersChanged()
    }

    func removeFilter(column: String) {
        filters.filters.removeAll { $0.column.caseInsensitiveCompare(column) == .orderedSame }
        filtersChanged()
    }

    func clearFilters() {
        filters.filters = []
        appliedWhere = ""
        whereDraft = ""
        filtersChanged()
    }

    /// Replaces all chips with one (FK navigation into an already-open tab).
    func replaceFilters(with filter: ColumnFilter) {
        filters.filters = [filter]
        appliedWhere = ""
        whereDraft = ""
        filtersChanged(userInitiated: false)
    }

    private func filtersChanged(userInitiated: Bool = true) {
        if userInitiated { onUserModified() }
        appliedSavedID = nil
        resetPaging()
        reload()
    }

    func filter(forColumn column: String) -> ColumnFilter? {
        filters.filters.first { $0.column.caseInsensitiveCompare(column) == .orderedSame }
    }

    // MARK: Paging

    func resetPaging() {
        offset = 0
        pageCursor = .first
    }

    /// Values of the keyset order columns in a loaded row, nil when a column isn't in the result.
    private func boundary(of row: [DatabaseValue], order: [SortKey]) -> [DatabaseValue]? {
        guard let columns = loadedContent?.columns else { return nil }
        var values: [DatabaseValue] = []
        for key in order {
            guard let index = columns.firstIndex(where: { $0.name.caseInsensitiveCompare(key.column) == .orderedSame }),
                  row.indices.contains(index), !row[index].isNull else { return nil }
            values.append(row[index])
        }
        return values
    }

    func nextPage() {
        if let order = keysetOrder, let last = loadedContent?.rows.last, let key = boundary(of: last, order: order) {
            offset += loadedContent?.rows.count ?? pageSize
            pageCursor = .after(key)
            reload(keepCount: true)
        } else {
            goTo(offset: offset + pageSize)
        }
    }

    func previousPage() {
        if let order = keysetOrder, let first = loadedContent?.rows.first, let key = boundary(of: first, order: order) {
            pageCursor = .before(key, fromOffset: offset)
            offset = max(offset - pageSize, 0)
            reload(keepCount: true)
        } else {
            goTo(offset: max(offset - pageSize, 0))
        }
    }

    func firstPage() {
        if keysetOrder != nil {
            guard offset != 0 || pageCursor != .first else { return }
            resetPaging()
            reload(keepCount: true)
        } else {
            goTo(offset: 0)
        }
    }

    /// With keyset paging the last page is the final `pageSize` rows read backwards from the end of the index;
    /// otherwise an aligned OFFSET page.
    func lastPage() {
        guard pageInfo.lastPageOffset != nil else { return }
        if keysetOrder != nil {
            // The page's row numbers come from the total, so an estimate is replaced by an exact count first.
            if case .exact = count {
                pageCursor = .last
                reload(keepCount: true)
            } else {
                Task { [weak self] in
                    guard let self, let session = self.sessionProvider(), let dialect = self.dialect else { return }
                    var query = self.currentQuery()
                    query.keyset = nil
                    let sql = query.countSQL(dialect: dialect)
                    self.isCountingExactly = true
                    var aux: (any DatabaseSession)?
                    if let opener = self.auxSessionOpener { aux = try? await opener() }
                    let result = try? await (aux ?? session).execute(sql, interruptible: true)
                    await aux?.close()
                    self.isCountingExactly = false
                    if let first = result?.rows.first?.first, let n = Self.int(first) {
                        self.count = .exact(n)
                        self.countKey = sql
                    }
                    self.pageCursor = .last
                    self.reload(keepCount: true)
                }
            }
        } else if let last = pageInfo.lastPageOffset {
            goTo(offset: last)
        }
    }

    private func goTo(offset new: Int) {
        guard new != offset else { return }
        offset = new
        pageCursor = .first
        reload(keepCount: true)
    }

    /// Settles `offset` once the rows of a keyset page are known (backward pages and the last page).
    private func applyOffset(for rowCount: Int) {
        switch pageCursor {
        case .before(_, let from): offset = max(from - rowCount, 0)
        case .last:
            switch count {
            case .exact(let n), .estimate(let n): offset = max(Int(n) - rowCount, 0)
            case .unknown: offset = max(offset, 0)
            }
        case .first, .after: break
        }
    }

    private func updateDeepPagingNotice() {
        guard fixedQuery == nil, keysetOrder == nil, offset >= Self.deepOffsetThreshold else { deepPagingNotice = nil; return }
        let why = (structure?.primaryKey.isEmpty ?? true) ? "this table has no primary key" : "the current sort isn't served by an index"
        deepPagingNotice = "Deep page: \(why), so the server skips \(CompactCount.grouped(Int64(offset))) rows first. Sort by an indexed column or filter to jump faster."
    }

    // MARK: Stop

    /// What the grid is showing, restored when a slow load is stopped.
    struct QueryState {
        var sort: [SortKey]
        var filters: FilterGroup
        var appliedWhere: String
        var offset: Int
        var cursor: PageCursor
    }
    @ObservationIgnored var committed: QueryState?

    /// The Stop button on a running load: aborts the statement on the server (`KILL QUERY` / `pg_cancel_backend`),
    /// ignores whatever arrives late and puts the sort / filters / page back to what the grid shows.
    func stopLoading() {
        guard isLoading else { return }
        generation += 1
        loadTask?.cancel()
        countTask?.cancel()
        isLoading = false
        isCountingExactly = false
        if let state = committed {
            sort = state.sort
            filters = state.filters
            appliedWhere = state.appliedWhere
            whereDraft = state.appliedWhere
            offset = state.offset
            pageCursor = state.cursor
            reportNotice("Stopped. Showing the previous result.")
        } else {
            failure = LoadFailure(message: "Stopped.", sql: lastSQL)
            hasLoaded = true
        }
    }

    /// Page size changed in Settings: restart from the first page.
    func pageSizeChanged(_ size: Int) {
        guard size != pageSize else { return }
        pageSize = size
        if hasLoaded {
            resetPaging()
            reload()
        }
    }

    // MARK: Selection

    func setSelection(_ rows: [Int]) { selectedRows = rows }

    var selectedValues: [[DatabaseValue]] {
        guard let content else { return [] }
        return selectedRows.filter { content.rows.indices.contains($0) }.map { content.rows[$0] }
    }

    /// "Row 1042" (single primary key) or "Row 17" (position in the result).
    var inspectorTitle: String {
        guard let content, let first = selectedRows.first, content.rows.indices.contains(first) else { return "Row" }
        if first < content.insertedCount { return "New row" }
        let pk = structure?.primaryKey ?? []
        if pk.count == 1, let index = content.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(pk[0]) == .orderedSame }) {
            return "Row \(content.rows[first][index].displayString)"
        }
        return "Row \(content.offset + first - content.insertedCount + 1)"
    }

    // MARK: Foreign keys

    /// Opens the referenced table filtered to the key in `row`.
    func followForeignKey(column: String, row: Int) {
        guard let content, content.rows.indices.contains(row), let fk = foreignKey(for: column),
              let index = content.columns.firstIndex(where: { $0.name == column })
        else { return }
        let value = content.rows[row][index]
        guard !value.isNull else { return }
        let target = fk.referencedColumns.first ?? "id"
        openTable(fk.referenced, ColumnFilter(column: target, op: .equals(value)))
    }

    // MARK: Filter editor

    func requestFilter(column: String) {
        filterRequest = FilterRequest(column: column)
    }

    func makeFilterEditor(column: String) -> FilterEditorModel? {
        guard let session = sessionProvider() else { return nil }
        let def = definition(of: column)
        let columnInfo = content?.columns.first { $0.name.caseInsensitiveCompare(column) == .orderedSame }
        let dataType = def?.dataType ?? columnInfo?.presentation.kind.fallbackTypeName ?? "text"
        let name = def?.name ?? columnInfo?.name ?? column
        let existing = filter(forColumn: name)
        let estimate = structure?.info.estimatedRows
        let group = filters
        let raw = appliedWhere
        let table = table
        let editor = FilterEditorModel(
            columnName: name, dataType: dataType, existing: existing,
            fetch: { [opener = auxSessionOpener] search in
                let query = DistinctValuesQuery(
                    table: table, column: name, filter: group.isEmpty ? nil : group, rawWhere: raw,
                    search: search, limit: 100)
                // A dedicated session lets the server enforce a time limit (and fall back to a sample) without
                // the limit leaking into other statements; without one the query runs unbounded.
                if let aux = try await opener?() {
                    do {
                        let result = try await query.run(on: aux, policy: DistinctValuesPolicy(estimatedRows: estimate))
                        await aux.close()
                        return result
                    } catch {
                        await aux.close()
                        throw error
                    }
                }
                return try await query.run(on: session)
            })
        return editor
    }

    // MARK: Saved filters

    func loadSavedFilters() async {
        guard let store = savedFiltersStore else { return }
        do {
            savedFilters = try await store.filters(connectionID: connectionID, table: table)
        } catch {
            reportNotice("Saved filters couldn't be read: \(error)")
        }
    }

    func apply(saved: SavedFilter) {
        filters = saved.group
        appliedWhere = saved.rawWhere ?? ""
        whereDraft = appliedWhere
        resetPaging()
        reload()
        appliedSavedID = saved.id  // after reload(): filtersChanged() would clear it
    }

    func saveCurrentFilter(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = savedFiltersStore, !trimmed.isEmpty else { return }
        var saved = SavedFilter(name: trimmed, table: table, group: filters, rawWhere: appliedWhere.isEmpty ? nil : appliedWhere)
        // Same name on this table overwrites, so "Save filter…" doubles as update.
        if let existing = savedFilters.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            saved.id = existing.id
            saved.createdAt = existing.createdAt
        }
        do {
            try await store.save(saved, connectionID: connectionID)
            await loadSavedFilters()
            appliedSavedID = saved.id
        } catch {
            reportNotice("Couldn't save the filter: \(error)")
        }
    }

    func deleteSavedFilter(id: UUID) async {
        guard let store = savedFiltersStore else { return }
        do {
            try await store.delete(id: id, connectionID: connectionID)
            if appliedSavedID == id { appliedSavedID = nil }
            await loadSavedFilters()
        } catch {
            reportNotice("Couldn't delete the filter: \(error)")
        }
    }

    func renameSavedFilter(id: UUID, to name: String) async {
        guard let store = savedFiltersStore, var saved = savedFilters.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saved.name = trimmed
        do {
            try await store.save(saved, connectionID: connectionID)
            await loadSavedFilters()
        } catch {
            reportNotice("Couldn't rename the filter: \(error)")
        }
    }

    var appliedSavedName: String? { savedFilters.first { $0.id == appliedSavedID }?.name }
}

extension ColumnKind {
    /// A representative base type name, used when a column isn't in the structure (should not happen).
    var fallbackTypeName: String {
        switch self {
        case .integer: "bigint"
        case .decimal: "decimal"
        case .boolean: "boolean"
        case .date: "date"
        case .time: "time"
        case .dateTime: "datetime"
        case .text: "varchar"
        case .longText: "text"
        case .json: "json"
        case .uuid: "uuid"
        case .binary: "blob"
        case .enumeration: "enum"
        case .other: "text"
        }
    }
}
