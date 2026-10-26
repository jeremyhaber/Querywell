import AppKit
import QuerywellCore
import SwiftUI

/// A table tab: segmented control, WHERE bar, filter chips, grid, footer and inspector (Main.dc.html).
struct TableTabView: View {
    @Bindable var model: TableDataModel
    let workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var app

    @State private var whereFocus = 0
    @State private var gridFocus = 0

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            switch model.mode {
            case .data: dataPane
            case .structure: StructureTableView(model: model)
            case .indexes: IndexesTableView(model: model)
            case .relations:
                RelationsView(model: model) { workspace.openTable($0) }
            case .operations: TableOperationsView(model: model, workspace: workspace)
            case .triggers: TableTriggersView(model: model, workspace: workspace)
            }
            if model.mode != .data { simpleFooter }
        }
        .background(Theme.background)
        .background { shortcuts }
        .sheet(isPresented: $model.reviewPresented) {
            ReviewChangesSheet(model: model) { model.reviewPresented = false }
        }
        .sheet(item: $model.valueEditor) { editor in
            ValueEditorView(model: editor)
        }
        .task(id: workspace.connectionEpoch) {
            configure()
            model.loadIfNeeded(epoch: workspace.connectionEpoch)
        }
        .onChange(of: app.settings.dataGrid.pageSize) { _, _ in configure() }
        .onChange(of: app.settings.dataGrid.nullDisplay) { _, _ in configure() }
    }

    private func configure() {
        model.nullDisplay = app.settings.dataGrid.nullDisplay
        model.savedFiltersStore = app.savedFiltersStore
        model.connectionID = workspace.profile.id
        model.pageSizeChanged(app.settings.dataGrid.pageSize)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            TableModeControl(selection: $model.mode)
            if model.mode == .data {
                WhereBar(model: model, focusToken: whereFocus)
            } else {
                Text(model.table.description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if model.hasPendingChanges {
                PendingEditsPill(count: model.pendingEditCount) { model.reviewPresented = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    // MARK: Data

    private var dataPane: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
            if let block = model.editBlock, model.structure != nil { EditBlockBanner(block: block) }
            HSplitView {
                gridPane
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if model.inspectorVisible {
                    RowInspectorView(
                        title: model.inspectorTitle,
                        subtitle: model.selectedRows.count > 1 ? "\(model.selectedRows.count) rows selected · showing the first" : nil,
                        columns: model.content?.columns ?? [],
                        values: model.selectedValues.first,
                        focusColumn: model.inspectorFocusColumn,
                        nullDisplay: model.nullDisplay,
                        onClose: { model.inspectorVisible = false },
                        editing: inspectorEditing,
                        onOpenEditor: { column in
                            if let row = model.selectedRows.first { model.openValueEditor(displayRow: row, column: column) }
                        })
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                }
            }
            if model.showSQL { sqlStrip }
            dataFooter
        }
    }

    private var gridPane: some View {
        ZStack(alignment: .top) {
            DataGridView(
                content: model.content,
                sort: model.sort,
                filteredColumns: model.filteredColumnNames,
                nullDisplay: model.nullDisplay,
                showsColumnTypes: app.settings.dataGrid.showColumnTypes,
                table: model.table,
                dialect: model.dialect ?? SQLDialect(workspace.profile.engine),
                filterRequest: model.filterRequest,
                filterPopoverContent: { column, dismiss in popoverContent(column: column, dismiss: dismiss) },
                actions: gridActions,
                focusToken: gridFocus,
                editRequest: model.editRequest)
                .opacity(model.isLoading && model.content != nil ? 0.55 : 1)
                .accessibilityLabel("Rows of \(model.table.name)")

            if let failure = model.failure {
                FailureBanner(failure: failure, hasContent: model.content != nil) { model.reload() }
            } else if model.content == nil {
                VStack(spacing: 10) {
                    if let message = model.structureFailure {
                        ContentMessage(symbol: "exclamationmark.triangle", title: "Couldn't read \(model.table.name)", detail: message)
                    } else {
                        ProgressView()
                        Text("Loading \(model.table.name)…").foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.content?.rows.isEmpty == true, !model.isLoading {
                ContentMessage(
                    symbol: model.isFiltered ? "line.3.horizontal.decrease.circle" : "tray",
                    title: model.isFiltered ? "No rows match" : "This table is empty",
                    detail: model.isFiltered ? "Adjust or clear the filters to see more." : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.isLoading, model.content != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Button("Stop") { model.stopLoading() }
                        .controlSize(.small)
                        .help("Cancel the running query on the server and keep the current result")
                        .accessibilityLabel("Stop loading")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator))
                .padding(.top, 44)
                .accessibilityLabel("Loading rows")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .motionAnimation(.easeOut(duration: 0.18), value: model.toast)
    }

    private var gridActions: GridActions {
        GridActions(
            onSort: { column, additive in model.toggleSort(column: column, additive: additive) },
            onSelection: { model.setSelection($0) },
            onInspect: { row, column in
                model.setSelection([row])
                model.inspectorFocusColumn = column
                model.inspectorVisible = true
            },
            onFollowForeignKey: { column, row in model.followForeignKey(column: column, row: row) },
            onActiveColumn: { model.activeColumn = $0 },
            onFilterByValue: { column, value in
                model.upsertFilter(ColumnFilter(column: column, op: value.isNull ? .isNull : .equals(value)))
            },
            onFilterRequestConsumed: { model.filterRequest = nil },
            onFunnel: { model.requestFilter(column: $0) },
            onReturn: {
                if !model.selectedRows.isEmpty {
                    model.inspectorFocusColumn = model.activeColumn
                    model.inspectorVisible = true
                }
            },
            onEditValue: { row, column in model.openValueEditor(displayRow: row, column: column) },
            editing: gridEditing,
            onEditRequestConsumed: { model.editRequest = nil })
    }

    private var gridEditing: GridEditing? { model.makeGridEditing() }

    /// Inspector editing for the first selected row; nil when the table can't be edited.
    private var inspectorEditing: InspectorEditing? {
        guard model.canEdit, let row = model.selectedRows.first else { return nil }
        return InspectorEditing(
            info: { model.editInfo(displayRow: row, column: $0) },
            commitText: { model.applyText(displayRow: row, column: $0, text: $1) },
            setNull: { model.setNull(displayRow: row, column: $0) },
            revertCell: { model.revertCell(displayRow: row, column: $0) },
            pendingSQL: model.pendingSQL(forDisplayRow: row),
            pendingCount: model.pendingEditCount,
            isCommitting: model.isCommitting,
            onDiscard: { model.revertRows([row]) },
            onCommit: {
                // One row's SQL is on screen already; with other changes pending, show them all first.
                if (model.editSession?.changeCount ?? 0) > 1 {
                    model.reviewPresented = true
                } else {
                    Task { await model.commit() }
                }
            })
    }

    private func popoverContent(column: String, dismiss: @escaping () -> Void) -> AnyView? {
        guard let editor = model.makeFilterEditor(column: column) else { return nil }
        editor.onFinish = { filter in
            if let filter {
                model.upsertFilter(filter)
            } else {
                model.removeFilter(column: column)
            }
            dismiss()
        }
        return AnyView(FilterPopoverView(model: editor))
    }

    // MARK: Footers

    private var sqlStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.whereSQLPreview ?? "No WHERE clause: every row is shown")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(model.whereSQLPreview == nil ? Theme.textTertiary : Theme.text)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Generated SQL")
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.whereSQLPreview ?? "", forType: .string)
            }
            .controlSize(.small)
            .disabled(model.whereSQLPreview == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    private var dataFooter: some View {
        let info = model.pageInfo
        return HStack(spacing: 16) {
            Text(info.label)
                .help("The total comes from a COUNT(*); until it arrives (or for very large tables) the server's estimate is shown")
            if case .estimate = model.count, !model.isCountingExactly {
                Button("Count exactly") { model.countExactly() }
                    .buttonStyle(.link).controlSize(.small)
                    .help("Run COUNT(*) on a separate connection; large tables only show the server's estimate until you ask")
            } else if model.isCountingExactly {
                ProgressView().controlSize(.mini).accessibilityLabel("Counting rows")
            }
            if let duration = model.content?.duration {
                Text("Query \(LatencyFormatter.string(for: duration))")
            }
            if let notice = model.deepPagingNotice {
                Label("Slow deep page", systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.warningText).help(notice)
            }
            if workspace.profile.isProduction {
                Label("Writes need confirmation on PROD", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Writes need confirmation on production")
            }
            rowButtons
            Spacer(minLength: 8)
            FooterButton(title: "Export…") { workspace.presentTableExport(model) }
                .help("Export this table, with its current filters and sort, to CSV, JSON or SQL INSERT")
            HStack(spacing: 4) {
                FooterButton(systemImage: "backward.end.fill", label: "First page") { model.firstPage() }
                    .disabled(!info.hasPrevious)
                FooterButton(title: "‹ Prev") { model.previousPage() }.disabled(!info.hasPrevious)
                FooterButton(title: "Next ›") { model.nextPage() }.disabled(!info.hasNext)
                FooterButton(systemImage: "forward.end.fill", label: "Last page") { model.lastPage() }
                    .disabled(info.lastPageOffset == nil || !info.hasNext)
            }
            Button {
                model.inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(model.inspectorVisible ? Theme.accentText : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Toggle row inspector (⌥⌘I)")
            .accessibilityLabel("Toggle row inspector")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    private var rowButtons: some View {
        HStack(spacing: 4) {
            FooterButton(systemImage: "plus", label: "Add row") { model.addRow() }
                .disabled(!model.canEdit)
                .help("Add row (⌥⌘N)")
            FooterButton(systemImage: "minus", label: "Delete selected rows") { model.deleteRows(model.selectedRows) }
                .disabled(!model.canEdit || model.selectedRows.isEmpty)
                .help("Delete selected rows (⌘⌫)")
            FooterButton(systemImage: "plus.square.on.square", label: "Duplicate selected rows") { model.duplicateRows(model.selectedRows) }
                .disabled(!model.canEdit || model.selectedRows.isEmpty)
                .help("Duplicate selected rows (⌘D)")
        }
        .opacity(model.editBlock == nil || model.structure == nil ? 1 : 0.7)
    }

    private var simpleFooter: some View {
        HStack(spacing: 16) {
            if let info = model.structure?.info, let rows = info.estimatedRows {
                Text("~\(CompactCount.grouped(rows)) rows (estimated)")
            }
            if workspace.profile.isProduction {
                Label("Writes need confirmation on PROD", systemImage: "lock.fill")
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    // MARK: Keyboard shortcuts

    /// Invisible buttons that carry the table-tab shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("Focus WHERE bar") {
                model.mode = .data
                whereFocus += 1
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("Toggle row inspector") { model.inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Filter selected column") {
                if let column = model.activeColumn ?? model.content?.columns.first?.name {
                    model.mode = .data
                    model.requestFilter(column: column)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Focus grid") { gridFocus += 1 }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Add row") { if model.canEdit { model.mode = .data; model.addRow() } }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Review changes") { if model.hasPendingChanges { model.reviewPresented = true } }
                .keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Pieces

struct TableModeControl: View {
    @Binding var selection: TableViewMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TableViewMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: selection == mode ? .medium : .regular))
                        .foregroundStyle(selection == mode ? Theme.text : Theme.chipText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selection == mode {
                                RoundedRectangle(cornerRadius: Theme.smallRadius)
                                    .fill(Theme.elevated)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table view")
    }
}

struct FooterButton: View {
    var title: String?
    var systemImage: String?
    var label: String?
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    init(systemImage: String, label: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).padding(.horizontal, 10).padding(.vertical, 4)
                } else if let systemImage {
                    // Fixed square so plus, minus and duplicate match whatever the symbol's own width is.
                    Image(systemName: systemImage).font(.system(size: 9)).frame(width: 26, height: 22)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.separator))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title ?? "")
    }
}

struct FailureBanner: View {
    var failure: TableDataModel.LoadFailure
    var hasContent: Bool
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.dangerText).accessibilityHidden(true)
                Text("Query failed").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Retry", action: retry).controlSize(.small)
            }
            Text(failure.message).font(.system(size: 12)).textSelection(.enabled)
            if let sql = failure.sql {
                Text(sql).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).lineLimit(5)
            }
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.dangerText.opacity(0.4)))
        .padding(.top, hasContent ? 44 : 60)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}
