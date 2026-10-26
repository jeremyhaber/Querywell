import AppKit
import QuerywellCore
import SwiftUI

/// The sidebar's Schema segment for query tabs: the current database's tables, each expandable to its columns
/// (type, key / index / foreign-key markers, nullability), so you can see what exists while writing a query.
/// Data comes from the editor's own completion catalog (`QueryTabModel.knownTables` / `structure(of:)`);
/// columns load per table, the first time it is expanded.
struct QuerySchemaList: View {
    let workspace: ConnectionWorkspace
    @State private var filter = ""
    @State private var expanded: Set<TableRef> = []
    @State private var columns: [TableRef: [SchemaOutlineColumn]] = [:]
    @State private var selectedTable: TableRef?

    var body: some View {
        if let model = workspace.currentQueryModel {
            content(model)
        } else {
            note("Open a query tab to see the tables.")
        }
    }

    private func content(_ model: QueryTabModel) -> some View {
        let tables = SchemaOutline.filter(model.knownTables, query: filter)
        return VStack(alignment: .leading, spacing: 8) {
            filterField
            if !model.tablesLoaded {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading tables…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    .padding(.top, 8).padding(.horizontal, 4)
            } else if model.knownTables.isEmpty {
                note("This database has no tables.")
            } else if tables.isEmpty {
                note("No matching tables.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(tables) { info in
                            tableRow(info, model: model)
                            if expanded.contains(info.ref) { columnRows(info.ref, model: model) }
                        }
                    }
                }
                .accessibilityLabel("Tables")
            }
        }
        .task(id: loadKey(model)) {
            columns = [:]
            await model.refreshTables()
            for ref in expanded { await loadColumns(ref, model: model) }
        }
    }

    private func loadKey(_ model: QueryTabModel) -> String {
        "\(ObjectIdentifier(model).hashValue)|\(model.catalogVersion)|\(workspace.browser.selectedSchema ?? workspace.selectedDatabase ?? "")"
    }

    // MARK: Filter

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            TextField("Filter tables", text: $filter)
                .textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel("Filter tables")
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
    }

    // MARK: Table row

    private func tableRow(_ info: TableInfo, model: QueryTabModel) -> some View {
        let ref = info.ref
        let isOpen = expanded.contains(ref)
        return HStack(spacing: 4) {
            Button { toggle(ref, model: model) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide columns of \(ref.name)" : "Show columns of \(ref.name)")
            Image(systemName: info.kind == .table ? "tablecells" : "eye").font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            Text(ref.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.trailing, 6)
        .background(selectedTable == ref ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(ref, model: model, asSelect: NSEvent.modifierFlags.contains(.option)) }
        .onTapGesture { selectedTable = ref }
        .onDrag { NSItemProvider(object: model.dialect.quoteIdentifier(ref.name) as NSString) }
        .contextMenu {
            Button("Insert Name") { model.insertIdentifier(ref.name) }
            Button("Insert SELECT … FROM \(ref.name)") { activate(ref, model: model, asSelect: true) }
            Menu("Quick Queries") {
                ForEach(QuickQueryKind.tableLevel) { kind in
                    Button(kind.title) { Task { await model.insertQuickQuery(kind, table: ref) } }
                }
            }
            Divider()
            Button(isOpen ? "Hide Columns" : "Show Columns") { toggle(ref, model: model) }
            Button("Copy Name") { copyToPasteboard(ref.name) }
        }
        .help("Double-click to insert the name · ⌥-double-click for SELECT … FROM · drag into the editor")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.kind == .table ? "Table" : "View") \(ref.name)")
        .accessibilityHint(isOpen ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Insert name") { model.insertIdentifier(ref.name) }
        .accessibilityAction(named: "Insert SELECT") { activate(ref, model: model, asSelect: true) }
        .accessibilityAction(named: isOpen ? "Hide columns" : "Show columns") { toggle(ref, model: model) }
    }

    private func activate(_ ref: TableRef, model: QueryTabModel, asSelect: Bool) {
        if asSelect {
            Task { await model.insertQuickQuery(.selectColumns, table: ref) }
        } else {
            model.insertIdentifier(ref.name)
        }
    }

    private func toggle(_ ref: TableRef, model: QueryTabModel) {
        if expanded.contains(ref) {
            expanded.remove(ref)
        } else {
            expanded.insert(ref)
            Task { await loadColumns(ref, model: model) }
        }
    }

    private func loadColumns(_ ref: TableRef, model: QueryTabModel) async {
        guard columns[ref] == nil else { return }
        let loaded = await model.structure(of: ref).map(SchemaOutline.columns(of:)) ?? []
        columns[ref] = loaded
    }

    // MARK: Column rows

    @ViewBuilder
    private func columnRows(_ ref: TableRef, model: QueryTabModel) -> some View {
        if let list = columns[ref] {
            if list.isEmpty {
                Text("Couldn't read the columns.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).padding(.leading, 36).padding(.vertical, 3)
            }
            ForEach(list) { column in columnRow(column, model: model) }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading columns…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary) }
                .padding(.leading, 36).padding(.vertical, 3)
        }
    }

    private func columnRow(_ column: SchemaOutlineColumn, model: QueryTabModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(column.name).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                if column.isPrimaryKey { badge("PK", help: "Primary key") }
                if column.isUnique { badge("UQ", help: "Unique index") } else if column.isIndexed { badge("IX", help: "Indexed") }
                if let fk = column.foreignKey { badge("FK", help: "References \(fk)") }
            }
            Text("\(column.type) · \(column.isNullable ? "nullable" : "not null")")
                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, 36).padding(.vertical, 2).padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.insertIdentifier(column.name) }
        .onDrag { NSItemProvider(object: model.dialect.quoteIdentifier(column.name) as NSString) }
        .contextMenu {
            Button("Insert Name") { model.insertIdentifier(column.name) }
            Button("Copy Name") { copyToPasteboard(column.name) }
        }
        .help(column.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.summary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Insert name") { model.insertIdentifier(column.name) }
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.chipText)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
            .help(help)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.horizontal, 4)
    }
}
