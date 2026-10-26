import AppKit
import QuerywellCore
import SwiftUI

/// Callbacks from the grid to the table model / tab view.
struct GridActions {
    var onSort: (String, Bool) -> Void = { _, _ in }
    var onSelection: ([Int]) -> Void = { _ in }
    var onInspect: (Int, String?) -> Void = { _, _ in }
    var onFollowForeignKey: (String, Int) -> Void = { _, _ in }
    var onActiveColumn: (String) -> Void = { _ in }
    var onFilterByValue: (String, DatabaseValue) -> Void = { _, _ in }
    var onFilterRequestConsumed: () -> Void = {}
    var onFunnel: (String) -> Void = { _ in }
    var onReturn: () -> Void = {}
    /// "Edit Value…" / double-click on long text: opens the value editor for (row, column).
    var onEditValue: (Int, String) -> Void = { _, _ in }
    /// Editing hooks; nil while the table has not loaded.
    var editing: GridEditing?
    var onEditRequestConsumed: () -> Void = {}
}

/// Everything the grid needs to edit cells in place. Row numbers are displayed-row indexes.
struct GridEditing {
    /// False for read-only connections, tables without a primary key, views and while committing.
    var isEditable: Bool
    var info: (Int, String) -> CellEditInfo
    /// Returns why the text was rejected, nil on success.
    var commitText: (Int, String, String) -> CellInputError?
    var setNull: (Int, String) -> Void
    var setEmpty: (Int, String) -> Void
    var setDefault: (Int, String) -> Void
    var revertCell: (Int, String) -> Void
    var clearCell: (Int, String) -> Void
    var deleteRows: ([Int]) -> Void
    var duplicateRows: ([Int]) -> Void
    var revertRows: ([Int]) -> Void
    var rowHasPending: (Int) -> Bool
    var notice: (String) -> Void
}

/// The data grid: an NSTableView in an NSScrollView. Virtualized (only visible rows have views), cells draw
/// their own text, row/cell views are reused, row height is fixed.
struct DataGridView: NSViewRepresentable {
    var content: GridContent?
    var sort: [SortKey]
    var filteredColumns: Set<String>
    var nullDisplay: String
    var showsColumnTypes: Bool
    var table: TableRef
    var dialect: SQLDialect
    var filterRequest: FilterRequest?
    var filterPopoverContent: (String, @escaping () -> Void) -> AnyView?
    var actions: GridActions
    /// Bump to move keyboard focus into the grid.
    var focusToken: Int
    var editRequest: GridEditRequest?

    func makeCoordinator() -> GridCoordinator { GridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = ThemeNS.background

        let table = GridTableView()
        table.coordinator = coordinator
        table.style = .plain
        table.rowHeight = GridMetrics.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .regular
        table.backgroundColor = ThemeNS.background
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(GridCoordinator.doubleClicked(_:))
        table.setAccessibilityLabel("Table rows")

        let header = GridHeaderView()
        header.onFunnelClick = { [weak coordinator] column, rect in coordinator?.funnelClicked(columnIndex: column, rect: rect) }
        header.onHoverChange = { [weak coordinator] column in coordinator?.hoverChanged(column) }
        table.headerView = header
        header.frame.size.height = GridMetrics.headerHeight

        scroll.documentView = table
        coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: GridCoordinator?

    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKeyDown(event) == true { return }
        // Return / Enter opens the inspector for the selected row.
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            coordinator?.parent?.actions.onReturn()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        if row >= 0, column >= 0 {
            coordinator?.noteClick(row: row, column: column)
            if event.clickCount == 1, coordinator?.handleLinkClick(row: row, column: column, point: point, event: event) == true {
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return coordinator?.contextMenu(row: row, column: column)
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection(format: .tsv, includeHeader: false)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    var parent: DataGridView?
    private weak var tableView: GridTableView?
    private weak var scroll: NSScrollView?

    private var content: GridContent?
    private var lastContentID: UUID?
    private var columnSignature: [String] = []
    private var hoveredColumn: Int?
    private var popover: NSPopover?
    private var lastRequestID: UUID?
    private var lastFocusToken = 0
    /// Widths the user chose, by column name, kept across page loads and sorts.
    private var userWidths: [String: CGFloat] = [:]
    private var isRebuilding = false
    /// The column keyboard editing targets (last clicked / arrowed to).
    private var activeColumnID: String?
    private var editor: CellEditorField?
    private var isFinishingEdit = false
    private var errorPopover: NSPopover?
    private var lastEditRequestID: UUID?

    var isEditable: Bool { parent?.actions.editing?.isEditable == true }

    func attach(table: GridTableView, scroll: NSScrollView) {
        tableView = table
        self.scroll = scroll
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnResized(_:)), name: NSTableView.columnDidResizeNotification, object: table)
    }

    // MARK: Updating

    func update(with new: DataGridView) {
        let previous = parent
        parent = new
        guard let table = tableView else { return }

        if content?.id != new.content?.id {
            endEditing(commit: false)
            let savedOrigin = scroll?.contentView.bounds.origin
            content = new.content
            let signature = new.content?.columnSignature ?? []
            if signature != columnSignature || previous?.showsColumnTypes != new.showsColumnTypes {
                columnSignature = signature
                rebuildColumns()
            }
            table.reloadData()
            let keepViewport = new.content?.preservesViewport == true
            if new.content?.id != lastContentID {
                lastContentID = new.content?.id
                if let clip = scroll?.contentView {
                    let y = keepViewport ? (savedOrigin?.y ?? -clip.contentInsets.top) : -clip.contentInsets.top
                    let maxY = max(table.bounds.height - clip.bounds.height, -clip.contentInsets.top)
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(y, maxY)))
                    scroll?.reflectScrolledClipView(clip)
                }
            }
            if let restore = new.content?.selectionToRestore, !restore.isEmpty {
                let valid = restore.filter { $0 < table.numberOfRows }
                if !valid.isEmpty { table.selectRowIndexes(IndexSet(valid), byExtendingSelection: false) }
            }
            reportSelection()
        } else if content?.revision != new.content?.revision {
            // Same page, different pending edits: keep scroll and selection (shifted by inserted rows).
            let shift = (new.content?.insertedCount ?? 0) - (content?.insertedCount ?? 0)
            let selected = table.selectedRowIndexes
            content = new.content
            table.reloadData()
            let restored = selected.map { $0 + shift }.filter { $0 >= 0 && $0 < table.numberOfRows }
            if !restored.isEmpty { table.selectRowIndexes(IndexSet(restored), byExtendingSelection: false) }
            reportSelection()
        } else if previous?.nullDisplay != new.nullDisplay {
            table.reloadData()
        }
        refreshHeaders()

        if let request = new.filterRequest, request.id != lastRequestID {
            lastRequestID = request.id
            DispatchQueue.main.async { [weak self] in
                self?.presentFilter(column: request.column)
                self?.parent?.actions.onFilterRequestConsumed()
            }
        }
        if let request = new.editRequest, request.id != lastEditRequestID {
            lastEditRequestID = request.id
            DispatchQueue.main.async { [weak self] in self?.perform(request) }
        }
        if new.focusToken != lastFocusToken {
            lastFocusToken = new.focusToken
            DispatchQueue.main.async { table.window?.makeFirstResponder(table) }
        }
    }

    // MARK: Columns

    private func rebuildColumns() {
        guard let table = tableView, let content else {
            tableViewClear()
            return
        }
        isRebuilding = true
        defer { isRebuilding = false }
        tableViewClear()

        let gutter = NSTableColumn(identifier: GridMetrics.gutterIdentifier)
        gutter.width = GridMetrics.gutterWidth
        gutter.minWidth = GridMetrics.gutterWidth
        gutter.maxWidth = GridMetrics.gutterWidth
        gutter.resizingMask = []
        let gutterHeader = GridHeaderCell(textCell: "#")
        gutterHeader.info = GridHeaderInfo(name: "#", showsType: false)
        gutter.headerCell = gutterHeader
        table.addTableColumn(gutter)

        let sample = content.rows.prefix(60)
        for (index, column) in content.columns.enumerated() {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
            tc.minWidth = GridMetrics.minColumnWidth
            tc.maxWidth = 2000
            tc.resizingMask = .userResizingMask
            let header = GridHeaderCell(textCell: column.name)
            tc.headerCell = header
            tc.width = userWidths[column.name] ?? idealWidth(for: column, index: index, sample: sample)
            table.addTableColumn(tc)
        }
        refreshHeaders()
    }

    private func tableViewClear() {
        guard let table = tableView else { return }
        for column in table.tableColumns { table.removeTableColumn(column) }
    }

    private func idealWidth(for column: GridColumn, index: Int, sample: ArraySlice<[DatabaseValue]>) -> CGFloat {
        let font = GridFonts.cell(mono: column.presentation.usesMonospace)
        var widest: CGFloat = 0
        let nullText = parent?.nullDisplay ?? "NULL"
        for row in sample where index < row.count {
            let text = CellDisplay.text(row[index], nullDisplay: nullText)
            let measured = (String(text.prefix(80)) as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, measured)
        }
        if column.presentation.usesPill { widest += 16 }
        if column.foreignKey != nil { widest += 18 }
        let name = (column.name as NSString).size(withAttributes: [.font: GridFonts.headerName]).width
        let type = parent?.showsColumnTypes == false ? 0 : (column.typeLabel as NSString).size(withAttributes: [.font: GridFonts.headerType]).width + 6
        let header = name + type + (column.isPrimaryKey ? 16 : 0) + 56
        let wanted = max(widest + GridMetrics.cellInset * 2 + 4, header)
        return min(max(wanted, 84), GridMetrics.maxColumnWidth)
    }

    @objc private func columnResized(_ note: Notification) {
        guard !isRebuilding, let column = note.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier != GridMetrics.gutterIdentifier else { return }
        userWidths[column.identifier.rawValue] = column.width
    }

    func refreshHeaders() {
        guard let table = tableView, let parent, let content else { return }
        for (tableIndex, tc) in table.tableColumns.enumerated() {
            guard let header = tc.headerCell as? GridHeaderCell, tc.identifier != GridMetrics.gutterIdentifier,
                  let column = content.columns.first(where: { $0.name == tc.identifier.rawValue }) else { continue }
            let indicator = SortCycle.indicator(for: column.name, in: parent.sort)
            header.info = GridHeaderInfo(
                name: column.name, typeLabel: column.typeLabel, isPrimaryKey: column.isPrimaryKey,
                showsType: parent.showsColumnTypes, sortAscending: indicator?.ascending, sortPriority: indicator?.priority,
                isFiltered: parent.filteredColumns.contains(column.name.lowercased()), isHovered: hoveredColumn == tableIndex)
        }
        table.headerView?.needsDisplay = true
    }

    func hoverChanged(_ column: Int?) {
        hoveredColumn = column
        refreshHeaders()
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { content?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("qw.row")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView) ?? {
            let v = GridRowView()
            v.identifier = id
            return v
        }()
        view.mark = content?.mark(row) ?? .normal
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let content, let tableColumn, row < content.rows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("qw.cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCellView) ?? {
            let c = GridCellView()
            c.identifier = id
            return c
        }()
        let mark = content.mark(row)
        if tableColumn.identifier == GridMetrics.gutterIdentifier {
            if mark == .inserted {
                cell.configure(value: .null, string: "new", style: .gutterNew, font: GridFonts.gutter, accessibilityText: "New row, not saved yet")
                return cell
            }
            let number = String(content.offset + row - content.insertedCount + 1)
            cell.configure(value: .null, string: number, style: .gutter, font: GridFonts.gutter,
                           accessibilityText: "Row \(number)\(mark == .deleted ? ", marked for deletion" : "")")
            return cell
        }
        guard let columnIndex = content.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }),
              columnIndex < content.rows[row].count else { return nil }
        let column = content.columns[columnIndex]
        let value = content.rows[row][columnIndex]
        let nullText = parent?.nullDisplay ?? "NULL"
        let text = CellDisplay.text(value, nullDisplay: nullText)
        let edited = content.isEdited(row: row, column: columnIndex)
        let unset = content.isUnset(row: row, column: columnIndex)
        let a11y = "\(column.name): \(value.isNull ? "null" : text)\(edited ? ", edited" : "")\(mark == .deleted ? ", row marked for deletion" : "")"
        let font = GridFonts.cell(mono: column.presentation.usesMonospace)
        let isActive = isEditable && column.name == activeColumnID && tableView.selectedRowIndexes == [row]
        let decoration = GridCellDecoration(
            edited: edited, placeholder: unset ? "DEFAULT" : nil, struck: mark == .deleted, active: isActive)
        let style: GridCellView.Style
        if value.isNull {
            style = .null
        } else if column.foreignKey != nil {
            style = .link
        } else if column.presentation.usesPill, !text.isEmpty {
            style = .pill(positive: ColumnPresentation.pillTone(for: text) == .positive)
        } else {
            style = .plain
        }
        cell.configure(value: value, string: text, style: style, font: font, accessibilityText: a11y, decoration: decoration)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reportSelection()
        refreshActiveCells()
    }

    private var lastHighlightedRows = IndexSet()

    func lastHighlightedRowsReset() {
        lastHighlightedRows = []
        refreshActiveCells()
    }

    /// Redraws the cells that show (or stop showing) the active-cell outline.
    private func refreshActiveCells() {
        guard let table = tableView, isEditable else { return }
        let rows = table.selectedRowIndexes.union(lastHighlightedRows).filteredIndexSet(includeInteger: { $0 < table.numberOfRows })
        lastHighlightedRows = table.selectedRowIndexes
        guard !rows.isEmpty, rows.count <= 8 else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    private func reportSelection() {
        guard let table = tableView else { return }
        parent?.actions.onSelection(Array(table.selectedRowIndexes))
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex > 0 && newColumnIndex > 0  // the row-number gutter stays first
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard tableColumn.identifier != GridMetrics.gutterIdentifier else { return }
        let additive = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        parent?.actions.onSort(tableColumn.identifier.rawValue, additive)
    }

    func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }

    // MARK: Clicks

    func noteClick(row: Int, column: Int) {
        guard let table = tableView, column < table.tableColumns.count else { return }
        let id = table.tableColumns[column].identifier
        if id != GridMetrics.gutterIdentifier {
            if activeColumnID != id.rawValue {
                activeColumnID = id.rawValue
                DispatchQueue.main.async { [weak self] in self?.refreshActiveCells() }
            }
            parent?.actions.onActiveColumn(id.rawValue)
        }
    }

    /// A click on a foreign-key link follows it (and does not change the selection).
    func handleLinkClick(row: Int, column: Int, point: NSPoint, event: NSEvent) -> Bool {
        guard let table = tableView, column < table.tableColumns.count,
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? GridCellView
        else { return false }
        let local = cell.convert(point, from: table)
        guard cell.linkRect != .zero, cell.linkRect.contains(local) else { return false }
        parent?.actions.onFollowForeignKey(table.tableColumns[column].identifier.rawValue, row)
        return true
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let table = tableView, table.clickedRow >= 0 else { return }
        var name: String?
        if table.clickedColumn >= 0, table.clickedColumn < table.tableColumns.count {
            let id = table.tableColumns[table.clickedColumn].identifier
            if id != GridMetrics.gutterIdentifier { name = id.rawValue }
        }
        if isEditable, let name {
            beginEdit(row: table.clickedRow, columnID: name)
        } else {
            parent?.actions.onInspect(table.clickedRow, name)
        }
    }

    // MARK: Funnel popover

    func funnelClicked(columnIndex: Int, rect: NSRect) {
        guard let table = tableView, columnIndex < table.tableColumns.count else { return }
        parent?.actions.onFunnel(table.tableColumns[columnIndex].identifier.rawValue)
    }

    private func presentFilter(column name: String) {
        guard let table = tableView, let header = table.headerView,
              let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        popover?.close()
        table.scrollColumnToVisible(index)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = header.window?.effectiveAppearance
        guard let root = parent?.filterPopoverContent(name, { [weak popover] in popover?.close() }) else { return }
        popover.contentViewController = NSHostingController(rootView: root)
        self.popover = popover
        let frame = header.headerRect(ofColumn: index)
        popover.show(relativeTo: GridHeaderCell.funnelRect(in: frame), of: header, preferredEdge: .maxY)
    }

    // MARK: Copy & context menu

    func selectedRowValues() -> [[DatabaseValue]] {
        guard let table = tableView, let content else { return [] }
        return table.selectedRowIndexes.filter { content.rows.indices.contains($0) }.map { content.rows[$0] }
    }

    func copySelection(format: CopyFormat, includeHeader: Bool) {
        guard let parent, let content else { return }
        let rows = selectedRowValues()
        guard !rows.isEmpty else { return }
        let text = RowCopy.text(
            format: format, columns: content.columns.map(\.name), rows: rows, table: parent.table,
            dialect: parent.dialect, includeHeader: includeHeader, nullText: format == .tsv || format == .csv ? "NULL" : "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func contextMenu(row: Int, column: Int) -> NSMenu {
        let menu = NSMenu()
        let count = tableView?.selectedRowIndexes.count ?? 1
        menu.addItem(item("Copy", #selector(menuCopy(_:)), key: "c", represented: nil))
        let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for format in CopyFormat.allCases {
            sub.addItem(item(format.title + (count > 1 ? " (\(count) rows)" : ""), #selector(menuCopyAs(_:)), represented: format.rawValue))
        }
        copyAs.submenu = sub
        menu.addItem(copyAs)

        var columnName: String?
        if let table = tableView, column >= 0, column < table.tableColumns.count,
           table.tableColumns[column].identifier != GridMetrics.gutterIdentifier {
            columnName = table.tableColumns[column].identifier.rawValue
        }
        if let columnName, let content, let index = content.columns.firstIndex(where: { $0.name == columnName }),
           content.rows.indices.contains(row) {
            menu.addItem(.separator())
            menu.addItem(item("Copy Cell Value", #selector(menuCopyCell(_:)), represented: CellCoordinate(row: row, column: columnName)))
            menu.addItem(item("Filter by This Value", #selector(menuFilterByValue(_:)), represented: CellCoordinate(row: row, column: columnName)))
            if content.columns[index].foreignKey != nil, !content.rows[row][index].isNull {
                menu.addItem(item("Open Referenced Row ↗", #selector(menuFollow(_:)), represented: CellCoordinate(row: row, column: columnName)))
            }
            if TableDataModel.supportsValueEditor(content.columns[index].presentation.kind) {
                let canEdit = parent?.actions.editing?.info(row, columnName).canEdit == true
                menu.addItem(item(canEdit ? "Edit Value…" : "View Value…", #selector(menuEditValue(_:)), represented: CellCoordinate(row: row, column: columnName)))
            }
        }
        addEditingItems(to: menu, row: row, columnName: columnName)
        menu.addItem(.separator())
        menu.addItem(item("Open in Inspector", #selector(menuInspect(_:)), represented: CellCoordinate(row: row, column: columnName ?? "")))
        return menu
    }

    fileprivate func item(_ title: String, _ action: Selector, key: String = "", represented: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    fileprivate final class CellCoordinate: NSObject {
        let row: Int
        let column: String
        init(row: Int, column: String) { self.row = row; self.column = column }
    }

    @objc private func menuCopy(_ sender: NSMenuItem) { copySelection(format: .tsv, includeHeader: false) }

    @objc private func menuCopyAs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = CopyFormat(rawValue: raw) else { return }
        copySelection(format: format, includeHeader: true)
    }

    @objc private func menuCopyCell(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate, let content,
              let index = content.columns.firstIndex(where: { $0.name == c.column }), content.rows.indices.contains(c.row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CellDisplay.copyText(content.rows[c.row][index]), forType: .string)
    }

    @objc private func menuFilterByValue(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate, let content,
              let index = content.columns.firstIndex(where: { $0.name == c.column }), content.rows.indices.contains(c.row) else { return }
        parent?.actions.onFilterByValue(c.column, content.rows[c.row][index])
    }

    @objc private func menuFollow(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.onFollowForeignKey(c.column, c.row)
    }

    @objc private func menuInspect(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.onInspect(c.row, c.column.isEmpty ? nil : c.column)
    }
}


// MARK: - In-place editing

/// The text field that edits one cell. It lives inside the table view, over the cell.
final class CellEditorField: NSTextField {
    var row = 0
    var columnID = ""
    var initialText = ""

    override class var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set {}
    }
}

/// A single-line cell that insets its text like a grid cell and centres it vertically.
final class PaddedTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect.insetBy(dx: GridMetrics.cellInset - 2, dy: 0))
        let height = cellSize(forBounds: rect).height
        r.origin.y = rect.minY + (rect.height - height) / 2
        r.size.height = height
        return r
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: start, length: length)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

extension GridCoordinator: NSTextFieldDelegate {
    private var dataColumnIDs: [String] {
        (tableView?.tableColumns ?? []).map(\.identifier).filter { $0 != GridMetrics.gutterIdentifier }.map(\.rawValue)
    }

    // MARK: Keyboard

    /// Returns true when the grid consumed the key (editing shortcuts); false lets the table handle it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let table = tableView, isEditable, let editing = parent?.actions.editing else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let selected = Array(table.selectedRowIndexes)
        guard !selected.isEmpty else { return false }
        let column = activeColumnID ?? dataColumnIDs.first
        let key = event.keyCode

        switch key {
        case 36, 76:  // Return / Enter edits the active cell
            guard flags.isDisjoint(with: [.command, .option, .control]), let column else { return false }
            beginEdit(row: table.selectedRow >= 0 ? table.selectedRow : selected[0], columnID: column)
            return true
        case 123, 124:  // ← → move the active cell sideways
            guard flags.isEmpty else { return false }
            moveActiveColumn(by: key == 123 ? -1 : 1)
            return true
        case 51, 117:  // ⌫ clears the cell, ⌘⌫ deletes the rows
            if flags == [.command] {
                editing.deleteRows(selected)
                return true
            }
            guard flags.isEmpty, let column else { return false }
            for row in selected where editing.info(row, column).canEdit { editing.clearCell(row, column) }
            return true
        case 2 where flags == [.command]:  // ⌘D duplicates
            editing.duplicateRows(selected)
            return true
        default:
            break
        }
        guard flags.isSubset(of: [.shift]), let column, let chars = event.characters, let scalar = chars.unicodeScalars.first,
              chars.count == 1, scalar != " ", (0x20...0x7E).contains(scalar.value) || (scalar.value > 0xA0 && scalar.value < 0xF700)
        else { return false }
        beginEdit(row: table.selectedRow >= 0 ? table.selectedRow : selected[0], columnID: column, typed: chars)
        return true
    }

    private func moveActiveColumn(by delta: Int) {
        let ids = dataColumnIDs
        guard !ids.isEmpty else { return }
        let current = activeColumnID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + delta, 0), ids.count - 1)
        activeColumnID = ids[next]
        parent?.actions.onActiveColumn(ids[next])
        if let table = tableView, let tableIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == ids[next] }) {
            table.scrollColumnToVisible(tableIndex)
        }
        lastHighlightedRowsReset()
    }

    // MARK: Beginning and ending an edit

    func beginEdit(row: Int, columnID: String, typed: String? = nil) {
        guard let table = tableView, let content, let editing = parent?.actions.editing, editing.isEditable,
              row >= 0, row < table.numberOfRows,
              let tableIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnID }),
              let column = content.columns.first(where: { $0.name == columnID })
        else { return }
        let info = editing.info(row, columnID)
        guard info.canEdit else {
            NSSound.beep()
            return
        }
        guard finishEditing(commit: true, keepOpenOnError: true) else { return }
        if !table.selectedRowIndexes.contains(row) || table.selectedRowIndexes.count > 1 {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        activeColumnID = columnID
        parent?.actions.onActiveColumn(columnID)
        table.scrollRowToVisible(row)
        table.scrollColumnToVisible(tableIndex)

        if info.prefersInspector {
            parent?.actions.onEditValue(row, columnID)
            return
        }
        let frame = table.frameOfCell(atColumn: tableIndex, row: row)
        if info.usesPicker {
            showPicker(info: info, row: row, columnID: columnID, frame: frame)
            return
        }
        let field = CellEditorField(frame: frame)
        field.row = row
        field.columnID = columnID
        field.initialText = info.initialText
        field.font = GridFonts.cell(mono: column.presentation.usesMonospace)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = ThemeNS.elevated
        field.textColor = ThemeNS.text
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.wantsLayer = true
        field.layer?.borderWidth = 2
        field.layer?.borderColor = ThemeNS.accent.cgColor
        field.stringValue = typed ?? info.initialText
        field.delegate = self
        field.setAccessibilityLabel("Edit \(columnID)")
        table.addSubview(field)
        editor = field
        table.window?.makeFirstResponder(field)
        if let textView = field.currentEditor() {
            if typed != nil {
                textView.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            } else {
                textView.selectAll(nil)
            }
        }
    }

    func endEditing(commit: Bool) { _ = finishEditing(commit: commit, keepOpenOnError: false) }

    /// Commits (or cancels) the open editor. Returns false only when `keepOpenOnError` and the text was rejected.
    @discardableResult
    func finishEditing(commit: Bool, keepOpenOnError: Bool) -> Bool {
        guard let field = editor, !isFinishingEdit else { return true }
        isFinishingEdit = true
        defer { isFinishingEdit = false }
        if commit, field.stringValue != field.initialText, let editing = parent?.actions.editing {
            if let error = editing.commitText(field.row, field.columnID, field.stringValue) {
                if keepOpenOnError {
                    showError(error.message, near: field)
                    return false
                }
                editing.notice(error.message)
            }
        }
        errorPopover?.close()
        errorPopover = nil
        editor = nil
        field.removeFromSuperview()
        tableView?.window?.makeFirstResponder(tableView)
        return true
    }

    private func showError(_ message: String, near field: NSView) {
        errorPopover?.close()
        field.layer?.borderColor = ThemeNS.dangerText.cgColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 280
        label.textColor = ThemeNS.dangerText
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: max(label.fittingSize.height + 20, 36)))
        label.frame = NSRect(x: 12, y: 10, width: 280, height: content.frame.height - 20)
        content.addSubview(label)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.appearance = field.window?.effectiveAppearance
        popover.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
        errorPopover = popover
        NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [.announcement: message])
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? CellEditorField, field === editor, errorPopover != nil {
            errorPopover?.close()
            errorPopover = nil
            field.layer?.borderColor = ThemeNS.accent.cgColor
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere commits; Return / Tab / Esc were handled in doCommandBy and cleared `editor` already.
        guard let field = obj.object as? CellEditorField, field === editor else { return }
        finishEditing(commit: true, keepOpenOnError: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? CellEditorField, field === editor else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true, keepOpenOnError: true)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let backwards = commandSelector == #selector(NSResponder.insertBacktab(_:))
            let (row, column) = (field.row, field.columnID)
            guard finishEditing(commit: true, keepOpenOnError: true) else { return true }
            if let next = nextEditableCell(after: row, columnID: column, backwards: backwards) {
                beginEdit(row: next.row, columnID: next.column)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false, keepOpenOnError: false)
            return true
        default:
            return false
        }
    }

    /// The next cell (Tab) or previous one (⇧Tab) that can be edited in place, wrapping across rows.
    private func nextEditableCell(after row: Int, columnID: String, backwards: Bool) -> (row: Int, column: String)? {
        guard let table = tableView, let editing = parent?.actions.editing else { return nil }
        let ids = dataColumnIDs
        guard var c = ids.firstIndex(of: columnID) else { return nil }
        var r = row
        for _ in 0..<(ids.count * max(table.numberOfRows, 1)) {
            c += backwards ? -1 : 1
            if c >= ids.count { c = 0; r += 1 } else if c < 0 { c = ids.count - 1; r -= 1 }
            guard r >= 0, r < table.numberOfRows else { return nil }
            let info = editing.info(r, ids[c])
            if info.canEdit, !info.prefersInspector { return (r, ids[c]) }
        }
        return nil
    }

    // MARK: Pickers

    private func showPicker(info: CellEditInfo, row: Int, columnID: String, frame: NSRect) {
        guard let table = tableView else { return }
        let menu = NSMenu()
        for choice in info.choices {
            let item = NSMenuItem(title: choice, action: #selector(pickerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PickerChoice(row: row, column: columnID, value: choice)
            if choice.caseInsensitiveCompare(info.initialText) == .orderedSame { item.state = .on }
            menu.addItem(item)
        }
        if info.isNullable {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "NULL", action: #selector(pickerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PickerChoice(row: row, column: columnID, value: nil)
            if info.currentIsNull { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.maxY), in: table)
    }

    private final class PickerChoice: NSObject {
        let row: Int
        let column: String
        let value: String?
        init(row: Int, column: String, value: String?) { self.row = row; self.column = column; self.value = value }
    }

    @objc private func pickerChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PickerChoice, let editing = parent?.actions.editing else { return }
        if let value = choice.value {
            if let error = editing.commitText(choice.row, choice.column, value) { editing.notice(error.message) }
        } else {
            editing.setNull(choice.row, choice.column)
        }
    }

    // MARK: Edit requests (Add Row, Duplicate)

    func perform(_ request: GridEditRequest) {
        guard let table = tableView, request.row < table.numberOfRows else {
            parent?.actions.onEditRequestConsumed()
            return
        }
        table.selectRowIndexes([request.row], byExtendingSelection: false)
        table.scrollRowToVisible(request.row)
        if let column = request.column {
            beginEdit(row: request.row, columnID: column)
        } else {
            table.window?.makeFirstResponder(table)
        }
        parent?.actions.onEditRequestConsumed()
    }

    // MARK: Context menu

    func addEditingItems(to menu: NSMenu, row: Int, columnName: String?) {
        guard let table = tableView, let editing = parent?.actions.editing, editing.isEditable else { return }
        let rows = Array(table.selectedRowIndexes)
        menu.addItem(.separator())
        if let columnName {
            let info = editing.info(row, columnName)
            let target = CellCoordinate(row: row, column: columnName)
            if info.canEdit {
                menu.addItem(item("Edit Cell", #selector(menuEditCell(_:)), represented: target))
                let null = item("Set to NULL", #selector(menuSetNull(_:)), represented: target)
                null.isEnabled = info.isNullable && !info.currentIsNull
                menu.addItem(null)
                if info.canSetEmpty { menu.addItem(item("Set to Empty String", #selector(menuSetEmpty(_:)), represented: target)) }
                if info.canSetDefault { menu.addItem(item("Set to Default", #selector(menuSetDefault(_:)), represented: target)) }
                if info.isEdited { menu.addItem(item("Revert Cell", #selector(menuRevertCell(_:)), represented: target)) }
                menu.addItem(.separator())
            }
        }
        let allDeleted = !rows.isEmpty && rows.allSatisfy { content?.mark($0) == .deleted }
        let n = rows.count
        let deleteTitle = allDeleted ? (n == 1 ? "Restore Row" : "Restore \(n) Rows") : (n == 1 ? "Delete Row" : "Delete \(n) Rows")
        let delete = item(deleteTitle, #selector(menuDeleteRows(_:)), represented: nil)
        menu.addItem(delete)
        menu.addItem(item(n == 1 ? "Duplicate Row" : "Duplicate \(n) Rows", #selector(menuDuplicateRows(_:)), represented: nil))
        if rows.contains(where: editing.rowHasPending) {
            menu.addItem(item(n == 1 ? "Revert Row Changes" : "Revert Changes in \(n) Rows", #selector(menuRevertRows(_:)), represented: nil))
        }
    }

    @objc private func menuEditValue(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.onEditValue(c.row, c.column)
    }
    @objc private func menuEditCell(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        beginEdit(row: c.row, columnID: c.column)
    }
    @objc private func menuSetNull(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.editing?.setNull(c.row, c.column)
    }
    @objc private func menuSetEmpty(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.editing?.setEmpty(c.row, c.column)
    }
    @objc private func menuSetDefault(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.editing?.setDefault(c.row, c.column)
    }
    @objc private func menuRevertCell(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? CellCoordinate else { return }
        parent?.actions.editing?.revertCell(c.row, c.column)
    }
    @objc private func menuDeleteRows(_ sender: NSMenuItem) {
        parent?.actions.editing?.deleteRows(Array(tableView?.selectedRowIndexes ?? []))
    }
    @objc private func menuDuplicateRows(_ sender: NSMenuItem) {
        parent?.actions.editing?.duplicateRows(Array(tableView?.selectedRowIndexes ?? []))
    }
    @objc private func menuRevertRows(_ sender: NSMenuItem) {
        parent?.actions.editing?.revertRows(Array(tableView?.selectedRowIndexes ?? []))
    }
}
