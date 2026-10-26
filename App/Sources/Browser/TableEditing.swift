import Foundation
import QuerywellCore

// Inline editing for a table tab: the pending `EditSession`, the displayed rows (loaded rows with
// edits applied, inserted rows on top), cell-level actions, review and commit. The session itself is
// pure Core; this file wires it to the grid, the inspector and the write gate.

/// Why a table can't be edited, with the wording of the banner above the grid.
enum EditBlock: Equatable {
    case readOnlyConnection, noPrimaryKey, view

    var message: String {
        switch self {
        case .readOnlyConnection: "Read-only connection — editing is disabled."
        case .noPrimaryKey: "No primary key — rows can't be edited safely."
        case .view: "Views are read-only."
        }
    }

    var symbol: String {
        switch self {
        case .readOnlyConnection: "lock.fill"
        case .noPrimaryKey: "key.slash"
        case .view: "eye"
        }
    }
}

/// A displayed row is either an unsaved insert or a row loaded from the server.
enum DisplayRowRef: Equatable {
    case inserted(InsertedRowID)
    case loaded(Int)
}

/// What the grid / inspector needs to know about one cell to offer editing actions.
struct CellEditInfo {
    var canEdit = false
    var isEdited = false
    var isNullable = true
    var usesPicker = false
    var choices: [String] = []
    var canSetEmpty = false
    var canSetDefault = false
    var prefersInspector = false
    var initialText = ""
    var currentIsNull = false
    var isPrimaryKey = false
}

/// Select `row`; start editing `column` when given.
struct GridEditRequest: Equatable, Identifiable {
    let id = UUID()
    var row: Int
    var column: String?
}

struct ModelToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var isError = false
}

extension TableDataModel {
    // MARK: State

    var editBlock: EditBlock? {
        if isReadOnlyProvider() { return .readOnlyConnection }
        guard let structure else { return nil }
        if structure.info.kind != .table { return .view }
        if structure.primaryKey.isEmpty { return .noPrimaryKey }
        return nil
    }

    var canEdit: Bool {
        editBlock == nil && editSession != nil && loadedContent != nil && !isCommitting
    }

    var hasPendingChanges: Bool { editSession?.hasChanges == true }

    /// "N unsaved edits": edited cells plus inserted and deleted rows.
    var pendingEditCount: Int {
        guard let s = editSession else { return 0 }
        return s.editedCellCount + s.insertedRowCount + s.deletedRowCount
    }

    var pendingSummary: String {
        let n = pendingEditCount
        return "\(n) unsaved edit\(n == 1 ? "" : "s")"
    }

    var reviewChanges: [ReviewChange] {
        guard let s = editSession, let d = dialect else { return [] }
        return EditReview.changes(of: s, dialect: d)
    }

    var reviewScript: String {
        guard let s = editSession, let d = dialect else { return "" }
        return EditReview.script(of: s, dialect: d)
    }

    var reviewWarnings: [String] { editSession.map(EditReview.warnings(of:)) ?? [] }

    // MARK: Session lifecycle

    /// Creates the session when the structure is known and nothing is pending (a reload keeps edits).
    func prepareEditSession() {
        guard let structure else { editSession = nil; return }
        if let session = editSession, session.hasChanges { return }
        editSession = try? EditSession(structure: structure)
    }

    func ref(forDisplayRow row: Int) -> DisplayRowRef? {
        guard let loadedContent, row >= 0 else { return nil }
        if row < insertedOrder.count { return .inserted(insertedOrder[row]) }
        let index = row - insertedOrder.count
        return index < loadedContent.rows.count ? .loaded(index) : nil
    }

    /// The primary-key value of a loaded row.
    func rowKey(forLoadedRow index: Int) -> RowKey? {
        guard let loaded = loadedContent, let session = editSession, loaded.rows.indices.contains(index) else { return nil }
        var values: [DatabaseValue] = []
        for name in session.primaryKey {
            guard let c = loaded.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            values.append(loaded.rows[index][c])
        }
        return RowKey(values)
    }

    // MARK: Display

    /// Rebuilds ``content`` from the loaded page and the pending edits.
    func rebuildDisplay() {
        guard let loaded = loadedContent else {
            content = nil
            insertedOrder = []
            return
        }
        guard let session = editSession, session.hasChanges else {
            insertedOrder = []
            content = loaded
            return
        }
        insertedOrder = Array(session.insertedRowIDs.reversed())
        var rows: [[DatabaseValue]] = []
        var marks: [GridRowMark] = []
        var edited = Set<GridCellPosition>()
        var unset = Set<GridCellPosition>()
        rows.reserveCapacity(insertedOrder.count + loaded.rows.count)

        for (r, id) in insertedOrder.enumerated() {
            let values = session.insertedValues(id) ?? [:]
            var row: [DatabaseValue] = []
            for (c, column) in loaded.columns.enumerated() {
                if let v = values[column.name] {
                    row.append(v)
                } else {
                    row.append(.null)
                    unset.insert(GridCellPosition(row: r, column: c))
                }
            }
            rows.append(row)
            marks.append(.inserted)
        }

        let hasRowEdits = !session.updatedRowKeys.isEmpty || !session.deletedRowKeys.isEmpty
        for i in loaded.rows.indices {
            var row = loaded.rows[i]
            var mark = GridRowMark.normal
            if hasRowEdits, let key = rowKey(forLoadedRow: i), session.hasPendingChanges(for: key) {
                if session.isRowDeleted(key) {
                    mark = .deleted
                } else {
                    for (c, column) in loaded.columns.enumerated() {
                        if let v = session.editedValue(key, column: column.name) {
                            row[c] = v
                            edited.insert(GridCellPosition(row: insertedOrder.count + i, column: c))
                        }
                    }
                }
            }
            rows.append(row)
            marks.append(mark)
        }
        content = loaded.decorated(
            rows: rows, insertedCount: insertedOrder.count, rowMarks: marks, editedCells: edited, unsetCells: unset,
            revision: editRevision)
    }

    private func didChangeEdits() {
        editRevision += 1
        rebuildDisplay()
        let dirty = hasPendingChanges
        if dirty != lastReportedDirty {
            lastReportedDirty = dirty
            onDirtyChange(dirty)
        }
        if !dirty { reviewPresented = false }
    }

    // MARK: Cell info

    func editInfo(displayRow: Int, column: String) -> CellEditInfo {
        var info = CellEditInfo()
        guard let def = definition(of: column), let content, content.rows.indices.contains(displayRow),
              let c = content.columns.firstIndex(where: { $0.name == def.name }), let dialect, let ref = ref(forDisplayRow: displayRow)
        else { return info }
        let parser = CellValueParser(column: def, dialect: dialect)
        let value = content.rows[displayRow][c]
        let unset = content.isUnset(row: displayRow, column: c)
        let deleted = content.mark(displayRow) == .deleted
        info.canEdit = canEdit && !deleted
        if case .inserted = ref {
            info.isEdited = !unset
        } else {
            info.isEdited = content.isEdited(row: displayRow, column: c)
        }
        info.isNullable = def.isNullable
        info.usesPicker = parser.usesPicker
        info.choices = parser.pickerChoices
        info.canSetEmpty = parser.emptyValue != nil
        if case .inserted = ref {
            info.canSetDefault = def.defaultExpression != nil || def.isAutoIncrement
        } else {
            info.canSetDefault = parser.defaultValue() != nil
        }
        info.currentIsNull = value.isNull && !unset
        info.initialText = unset ? "" : CellValueParser.editingText(for: value)
        info.isPrimaryKey = def.isPrimaryKey
        var long = false
        if case .text(let s) = value { long = s.contains("\n") || s.count > 200 }
        info.prefersInspector = parser.prefersInspector || long
        return info
    }

    // MARK: Cell edits

    /// Parses `text` for the column and records it. Returns the reason when the text isn't valid.
    @discardableResult
    func applyText(displayRow: Int, column: String, text: String) -> CellInputError? {
        guard let def = definition(of: column), let dialect else { return CellInputError("This column can't be edited.") }
        switch CellValueParser(column: def, dialect: dialect).parse(text) {
        case .success(let value):
            return setValue(displayRow: displayRow, column: column, value: value) ? nil : CellInputError("This cell can't be edited.")
        case .failure(let error):
            return error
        }
    }

    @discardableResult
    func setValue(displayRow: Int, column: String, value: DatabaseValue) -> Bool {
        guard canEdit, var session = editSession, let def = definition(of: column), let ref = ref(forDisplayRow: displayRow) else { return false }
        switch ref {
        case .inserted(let id):
            do { try session.setInsertedCell(id, column: def.name, value: value) } catch { return false }
        case .loaded(let i):
            guard let loaded = loadedContent, let c = loaded.columns.firstIndex(where: { $0.name == def.name }),
                  let key = rowKey(forLoadedRow: i), !session.isRowDeleted(key) else { return false }
            let original = loaded.rows[i][c]
            let new = CellValueParser.equivalent(original, value) ? original : value
            do { try session.setCell(row: key, column: def.name, original: original, new: new) } catch { return false }
        }
        editSession = session
        didChangeEdits()
        return true
    }

    func setNull(displayRow: Int, column: String) {
        guard definition(of: column)?.isNullable == true else {
            show(toast: "\(column) is NOT NULL, so it can't be set to NULL.", isError: true)
            return
        }
        setValue(displayRow: displayRow, column: column, value: .null)
    }

    func setEmpty(displayRow: Int, column: String) {
        guard let def = definition(of: column), let dialect, let empty = CellValueParser(column: def, dialect: dialect).emptyValue else { return }
        setValue(displayRow: displayRow, column: column, value: empty)
    }

    func setDefault(displayRow: Int, column: String) {
        guard let def = definition(of: column), let dialect, let ref = ref(forDisplayRow: displayRow) else { return }
        if case .inserted(let id) = ref, var session = editSession {
            // The server fills in the default itself, whatever it is.
            try? session.setInsertedCell(id, column: def.name, value: nil)
            editSession = session
            didChangeEdits()
            return
        }
        if let value = CellValueParser(column: def, dialect: dialect).defaultValue() {
            setValue(displayRow: displayRow, column: column, value: value)
        }
    }

    func revertCell(displayRow: Int, column: String) {
        guard var session = editSession, let def = definition(of: column), let ref = ref(forDisplayRow: displayRow) else { return }
        switch ref {
        case .inserted(let id): try? session.setInsertedCell(id, column: def.name, value: nil)
        case .loaded(let i):
            guard let key = rowKey(forLoadedRow: i) else { return }
            session.revertCell(row: key, column: def.name)
        }
        editSession = session
        didChangeEdits()
    }

    /// Clears cells: empty string for text columns, NULL otherwise (⌫ in the grid).
    func clearCell(displayRow: Int, column: String) {
        guard let def = definition(of: column), let dialect else { return }
        let parser = CellValueParser(column: def, dialect: dialect)
        if let empty = parser.emptyValue, parser.kind != .binary {
            setValue(displayRow: displayRow, column: column, value: empty)
        } else {
            setNull(displayRow: displayRow, column: column)
        }
    }

    // MARK: Row actions

    func addRow() {
        guard canEdit, var session = editSession else { return }
        guard (try? session.insertRow()) != nil else { return }
        editSession = session
        didChangeEdits()
        setSelection([0])
        let first = content?.columns.first { c in
            guard let def = definition(of: c.name) else { return false }
            return !def.isAutoIncrement
        }
        editRequest = GridEditRequest(row: 0, column: first?.name)
    }

    func duplicateRows(_ displayRows: [Int]) {
        guard canEdit, var session = editSession, let content else { return }
        var added = 0
        for row in displayRows.sorted() where content.rows.indices.contains(row) && content.mark(row) != .deleted {
            var values: [String: DatabaseValue] = [:]
            for (c, column) in content.columns.enumerated() {
                guard let def = definition(of: column.name), !def.isAutoIncrement, !content.isUnset(row: row, column: c) else { continue }
                values[def.name] = content.rows[row][c]
            }
            if (try? session.insertRow(values)) != nil { added += 1 }
        }
        guard added > 0 else { return }
        editSession = session
        didChangeEdits()
        setSelection(Array(0..<added))
        editRequest = GridEditRequest(row: 0, column: nil)
    }

    /// Marks rows deleted; if every given row is already marked, restores them instead.
    func deleteRows(_ displayRows: [Int]) {
        guard canEdit, var session = editSession else { return }
        let refs = displayRows.compactMap(ref(forDisplayRow:))
        let loadedKeys = refs.compactMap { ref -> RowKey? in
            if case .loaded(let i) = ref { return rowKey(forLoadedRow: i) }
            return nil
        }
        let allDeleted = !loadedKeys.isEmpty && loadedKeys.allSatisfy { session.isRowDeleted($0) } && refs.count == loadedKeys.count
        for ref in refs {
            switch ref {
            case .inserted(let id): session.removeInsertedRow(id)
            case .loaded(let i):
                guard let key = rowKey(forLoadedRow: i) else { continue }
                if allDeleted { session.unmarkDeleted(key) } else { try? session.markDeleted(key) }
            }
        }
        editSession = session
        didChangeEdits()
        setSelection(allDeleted ? displayRows : [])
    }

    /// Drops the pending changes of the given rows (edits, deletion mark, or the unsaved insert).
    func revertRows(_ displayRows: [Int]) {
        guard var session = editSession else { return }
        for ref in displayRows.compactMap(ref(forDisplayRow:)) {
            switch ref {
            case .inserted(let id): session.removeInsertedRow(id)
            case .loaded(let i): if let key = rowKey(forLoadedRow: i) { session.discard(row: key) }
            }
        }
        editSession = session
        didChangeEdits()
    }

    func rowHasPendingChanges(_ displayRow: Int) -> Bool {
        guard let session = editSession, let ref = ref(forDisplayRow: displayRow) else { return false }
        switch ref {
        case .inserted: return true
        case .loaded(let i): return rowKey(forLoadedRow: i).map(session.hasPendingChanges(for:)) ?? false
        }
    }

    func discardAll() {
        guard var session = editSession else { return }
        session.discardAll()
        editSession = session
        commitReport = nil
        didChangeEdits()
        reviewPresented = false
    }

    /// The pending SQL for one displayed row (inspector "PENDING SQL").
    func pendingSQL(forDisplayRow row: Int) -> String? {
        guard let session = editSession, let dialect, let ref = ref(forDisplayRow: row) else { return nil }
        let planned = session.plannedStatements(dialect: dialect)
        let mine: [EditSession.PlannedStatement]
        switch ref {
        case .inserted(let id): mine = planned.filter { $0.insertedRow == id }
        case .loaded(let i):
            guard let key = rowKey(forLoadedRow: i) else { return nil }
            mine = planned.filter { $0.row == key }
        }
        return mine.isEmpty ? nil : mine.map { $0.sql + ";" }.joined(separator: "\n")
    }

    // MARK: Commit

    /// Authorizes through the write gate and commits in one transaction. On success the page reloads
    /// (scroll and selection kept); on conflict or error the edits stay and ``commitReport`` explains.
    @discardableResult
    func commit() async -> CommitReport? {
        guard let session = editSession, session.hasChanges, !isCommitting, let live = sessionProvider(), let dialect else { return nil }
        guard let gate else { return nil }
        let allowed = await gate.authorize(
            statements: session.statements(dialect: dialect), origin: .gridEdit, database: table.schema, actionTitle: "Commit")
        guard allowed else { return nil }
        isCommitting = true
        commitReport = nil
        let count = pendingEditCount
        let engine = structure?.info.engine
        let report: CommitReport
        do {
            let result = try await session.commit(on: live)
            report = CommitReport.make(result: result, session: session, editCount: count, engine: engine)
        } catch {
            report = CommitReport(
                status: .failed, headline: "Couldn't start the commit — nothing was saved.",
                detail: "Your pending edits are still here.", statement: nil, serverError: SchemaBrowserModel.message(error))
        }
        isCommitting = false
        if report.isSuccess {
            let keep = selectedRows.filter { $0 >= insertedOrder.count }.map { $0 - insertedOrder.count }
            var cleared = session
            cleared.discardAll()
            editSession = cleared
            commitReport = nil
            didChangeEdits()
            setSelection(keep)
            reload(keepCount: false, preserveViewport: true, restoreSelection: keep)
            show(toast: report.headline, isError: false)
            reviewPresented = false
        } else {
            commitReport = report
        }
        return report
    }

    // MARK: Conflicts

    /// After a conflict: reloads the table and keeps the edits, comparing them with today's values.
    func reloadKeepingEdits() {
        commitReport = nil
        rebaseOnNextLoad = true
        reload(preserveViewport: true, restoreSelection: selectedRows)
    }

    /// Points every pending edit on the loaded page at the values the server has now.
    func rebasePendingOriginals() {
        guard var session = editSession, let loaded = loadedContent else { return }
        var rowIndex: [RowKey: Int] = [:]
        for i in loaded.rows.indices { if let key = rowKey(forLoadedRow: i) { rowIndex[key] = i } }
        for key in session.updatedRowKeys {
            guard let i = rowIndex[key] else { continue }
            for change in session.cellChanges(for: key) {
                guard let c = loaded.columns.firstIndex(where: { $0.name == change.column }) else { continue }
                session.rebaseOriginal(row: key, column: change.column, original: loaded.rows[i][c])
            }
        }
        editSession = session
        didChangeEdits()
    }

    // MARK: Toast

    func show(toast message: String, isError: Bool) {
        let t = ModelToast(message: message, isError: isError)
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 6 : 3.5))
            guard !Task.isCancelled, let self, self.toast?.id == t.id else { return }
            self.toast = nil
        }
    }
}
