import Foundation
import QuerywellCore

// Connects the value editor to a table tab: builds the editor for one displayed cell and records its
// result as a pending edit (never a direct write).

extension TableDataModel {
    /// Column kinds that get "Edit Value…": text, JSON and binary data.
    static func supportsValueEditor(_ kind: ColumnKind) -> Bool {
        switch kind {
        case .text, .longText, .json, .binary, .other: true
        default: false
        }
    }

    func makeValueEditor(displayRow: Int, column: String) -> ValueEditorModel? {
        guard let content, content.rows.indices.contains(displayRow),
              let c = content.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(column) == .orderedSame }) else { return nil }
        let gridColumn = content.columns[c]
        let value = content.rows[displayRow][c]
        let info = editInfo(displayRow: displayRow, column: gridColumn.name)
        let reason: String? = info.canEdit ? nil : (editBlock?.message ?? "This cell can't be edited right now.")

        let data: Data
        switch value {
        case .null: data = Data()
        case .text(let s): data = Data(s.utf8)
        case .bytes(let d): data = d
        default: data = Data(value.displayString.utf8)
        }
        let storesBytes: Bool = {
            if case .bytes = value { return true }
            return gridColumn.presentation.kind == .binary
        }()

        var subtitle = gridColumn.fullType
        if let pk = editSession?.primaryKey, !pk.isEmpty {
            let parts = pk.compactMap { name -> String? in
                guard let i = content.columns.firstIndex(where: { $0.name == name }) else { return nil }
                return "\(name) \(content.rows[displayRow][i].displayString)"
            }
            if !parts.isEmpty { subtitle = parts.joined(separator: ", ") + " · " + gridColumn.fullType }
        }

        let model = ValueEditorModel(
            title: "\(table.name) · \(gridColumn.name)", subtitle: subtitle, data: data,
            isReadOnly: reason != nil, readOnlyReason: reason, valueWasNull: value.isNull,
            onSave: { [weak self] new in
                guard let self else { return CellInputError("The table is no longer open.") }
                if storesBytes || String(data: new, encoding: .utf8) == nil {
                    return self.setValue(displayRow: displayRow, column: gridColumn.name, value: .bytes(new))
                        ? nil : CellInputError("This cell can't be edited right now.")
                }
                return self.applyText(displayRow: displayRow, column: gridColumn.name, text: String(decoding: new, as: UTF8.self))
            })
        model.onClose = { [weak self] in self?.valueEditor = nil }
        return model
    }

    /// Opens the editor sheet for a displayed cell.
    func openValueEditor(displayRow: Int, column: String) {
        guard let editor = makeValueEditor(displayRow: displayRow, column: column) else { return }
        valueEditor = editor
    }

    /// Waits for the page to load, finds the row with these key values and opens the editor on `column`.
    /// Used by search & replace to hand an invalid serialized value over for repair.
    func presentValueEditor(forKey key: [PrimaryKeyValue], column: String, timeout: Duration = .seconds(15)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let content, !isLoading, !content.rows.isEmpty {
                let match = content.rows.indices.first { r in
                    key.allSatisfy { part in
                        guard let i = content.columns.firstIndex(where: { $0.name == part.column }) else { return false }
                        return content.rows[r][i].displayString == part.value
                    }
                }
                if let match {
                    openValueEditor(displayRow: match, column: column)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
