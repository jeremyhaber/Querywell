import Foundation
import QuerywellCore

extension ConnectionWorkspace {
    /// Opens the Search & Replace sheet for the sidebar's current schema. `preselect` names tables to tick
    /// (the sidebar selection); otherwise WordPress tables are ticked when the schema looks like WordPress.
    func presentSearchReplace(preselect: Set<String>? = nil) {
        guard isConnected, let schema = browser.selectedSchema ?? selectedDatabase else { return }
        let model: SearchReplaceModel
        if let existing = searchReplace, existing.isRunning {
            searchReplacePresented = true
            return
        } else if let existing = searchReplace, existing.schema == schema {
            model = existing
        } else {
            model = SearchReplaceModel(
                connectionID: profile.id, schema: schema, engine: profile.engine,
                isReadOnly: profile.effectiveReadOnly, isProduction: profile.isProduction)
        }
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.inspectorProvider = { [weak self] in self?.browser.inspector }
        model.gate = gate
        model.onApplied = { [weak self] in self?.refreshOpenTables(in: schema) }
        model.openInEditor = { [weak self] location in self?.openInvalidSerialized(location) }
        searchReplace = model
        searchReplacePresented = true
        Task { await model.loadTables(preselect: preselect) }
    }

    /// Reloads the open table tabs of `schema` so they show what search & replace wrote.
    func refreshOpenTables(in schema: String) {
        for tab in tabs.tabs {
            guard case .table(let database, _) = tab.kind, database == schema,
                  let model = tableModel(forTab: tab), model.hasLoaded else { continue }
            model.reload(preserveViewport: true, restoreSelection: model.selectedRows)
        }
    }

    /// Search & replace found a serialized value that doesn't parse: close the sheet, open the row's
    /// table filtered to it, and show the value in the editor (where "Try to repair lengths" lives).
    func openInvalidSerialized(_ location: CellLocation) {
        searchReplacePresented = false
        let filter = location.primaryKey.first.map { ColumnFilter(column: $0.column, op: .equals(.text($0.value))) }
        openTable(location.table, filter: filter)
        guard let model = tableModel(forTable: location.table) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))  // let the sheet finish dismissing
            await model.presentValueEditor(forKey: location.primaryKey, column: location.column)
        }
    }
}
