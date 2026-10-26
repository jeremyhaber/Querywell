import QuerywellCore
import SwiftUI

/// Saved-filters menu, filter chips, "+ Add filter", "Show as SQL" and "Save filter…" (design: Filters.dc.html).
struct FilterBar: View {
    @Bindable var model: TableDataModel
    @State private var saving = false
    @State private var saveName = ""
    @State private var managing = false

    var body: some View {
        HStack(spacing: 8) {
            savedMenu
            Rectangle().fill(Theme.separator).frame(width: 1, height: 20).accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.filters.filters) { filter in
                        chip(filter)
                    }
                    addFilterMenu
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.showSQL ? "Hide SQL" : "Show as SQL") { model.showSQL.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 6)
                .accessibilityLabel(model.showSQL ? "Hide generated SQL" : "Show generated SQL")
            Button("Save filter…") {
                saveName = model.appliedSavedName ?? ""
                saving = true
            }
            .font(.system(size: 12))
            .controlSize(.regular)
            .disabled(!model.isFiltered)
            .help(model.isFiltered ? "Save the current filters under a name" : "Add a filter first")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .alert("Save filter", isPresented: $saving) {
            TextField("Name", text: $saveName)
            Button("Save") {
                let name = saveName
                Task { await model.saveCurrentFilter(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved filters are kept per connection and table. Reusing a name replaces that filter.")
        }
        .sheet(isPresented: $managing) { SavedFiltersManager(model: model) }
    }

    // MARK: Saved menu

    private var savedMenu: some View {
        Menu {
            if model.savedFilters.isEmpty {
                Text("No saved filters")
            } else {
                ForEach(model.savedFilters) { saved in
                    Button {
                        model.apply(saved: saved)
                    } label: {
                        if saved.id == model.appliedSavedID {
                            Label(saved.name, systemImage: "checkmark")
                        } else {
                            Text(saved.name)
                        }
                    }
                }
            }
            Divider()
            Button("Save filter…") {
                saveName = model.appliedSavedName ?? ""
                saving = true
            }
            .disabled(!model.isFiltered)
            if !model.savedFilters.isEmpty {
                Menu("Delete") {
                    ForEach(model.savedFilters) { saved in
                        Button(saved.name, role: .destructive) { Task { await model.deleteSavedFilter(id: saved.id) } }
                    }
                }
                Button("Manage…") { managing = true }
            }
            if model.isFiltered {
                Divider()
                Button("Clear All Filters") { model.clearFilters() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark").font(.system(size: 12))
                Text(model.appliedSavedName.map { "Saved: \($0)" } ?? "Saved filters")
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.text)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Saved filters for this table")
        .accessibilityLabel("Saved filters")
    }

    // MARK: Chips

    private func chip(_ filter: ColumnFilter) -> some View {
        let parts = Self.parts(of: filter)
        return HStack(spacing: 6) {
            Button {
                model.requestFilter(column: filter.column)
            } label: {
                HStack(spacing: 5) {
                    Text(filter.column).font(.system(size: 12, weight: .semibold))
                    Text(parts.op).font(.system(size: 12))
                    if !parts.value.isEmpty {
                        Text(parts.value).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .foregroundStyle(Theme.accentSubtleText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this filter")
            Button {
                model.removeFilter(id: filter.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accentSubtleText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.chipRemoveBackground))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove filter \(filter.chipLabel)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.accentSubtleBackground))
        .accessibilityElement(children: .contain)
    }

    /// Splits `chipLabel` (after the column name) into the operator words and the value.
    static func parts(of filter: ColumnFilter) -> (op: String, value: String) {
        var rest = String(filter.chipLabel.dropFirst(filter.column.count)).trimmingCharacters(in: .whitespaces)
        let prefixes = [
            "is any of", "is none of", "is not NULL", "is NULL", "is not empty", "is empty", "is not", "is", "does not contain", "contains",
            "starts with", "ends with", "between", "matches", "≥", "any date", "<", ">",
        ]
        for prefix in prefixes where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            var op = prefix
            if prefix == "≥" { op = "≥" }
            return (op, rest)
        }
        return (rest, "")
    }

    private var addFilterMenu: some View {
        Menu {
            ForEach(model.columnDefinitions) { column in
                Button(column.name) { model.requestFilter(column: column.name) }
            }
        } label: {
            Text("+ Add filter")
                .font(.system(size: 12))
                .foregroundStyle(Theme.chipText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Theme.separatorStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.columnDefinitions.isEmpty)
        .help("Filter by a column (⌘⌥F for the selected column)")
        .accessibilityLabel("Add filter")
    }
}

/// Rename and delete saved filters.
struct SavedFiltersManager: View {
    @Bindable var model: TableDataModel
    @Environment(\.dismiss) private var dismiss
    @State private var names: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved filters for \(model.table.name)").font(.headline)
            if model.savedFilters.isEmpty {
                Text("Nothing saved yet.").foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(model.savedFilters) { saved in
                    HStack(spacing: 8) {
                        TextField("Name", text: Binding(
                            get: { names[saved.id] ?? saved.name },
                            set: { names[saved.id] = $0 }))
                            .onSubmit { Task { await model.renameSavedFilter(id: saved.id, to: names[saved.id] ?? saved.name) } }
                        Text("\(saved.group.filters.count) filter\(saved.group.filters.count == 1 ? "" : "s")\(saved.rawWhere == nil ? "" : " + WHERE")")
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Button(role: .destructive) {
                            Task { await model.deleteSavedFilter(id: saved.id) }
                        } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete \(saved.name)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") {
                    Task {
                        for (id, name) in names { await model.renameSavedFilter(id: id, to: name) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
