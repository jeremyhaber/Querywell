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
            content = new.content
            let signature = new.content?.columnSignature ?? []
            if signature != columnSignature || previous?.showsColumnTypes != new.showsColumnTypes {
                columnSignature = signature
                rebuildColumns()
            }
            table.reloadData()
            if new.content?.id != lastContentID {
                lastContentID = new.content?.id
                if let clip = scroll?.contentView { clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -clip.contentInsets.top)); scroll?.reflectScrolledClipView(clip) }
            }
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
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView { return view }
        let view = GridRowView()
        view.identifier = id
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
        if tableColumn.identifier == GridMetrics.gutterIdentifier {
            let number = String(content.offset + row + 1)
            cell.configure(value: .null, string: number, style: .gutter, font: GridFonts.gutter, accessibilityText: "Row \(number)")
            return cell
        }
        guard let columnIndex = content.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }),
              columnIndex < content.rows[row].count else { return nil }
        let column = content.columns[columnIndex]
        let value = content.rows[row][columnIndex]
        let nullText = parent?.nullDisplay ?? "NULL"
        let text = CellDisplay.text(value, nullDisplay: nullText)
        let a11y = "\(column.name): \(value.isNull ? "null" : text)"
        let font = GridFonts.cell(mono: column.presentation.usesMonospace)
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
        cell.configure(value: value, string: text, style: style, font: font, accessibilityText: a11y)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { reportSelection() }

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
        if id != GridMetrics.gutterIdentifier { parent?.actions.onActiveColumn(id.rawValue) }
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
        parent?.actions.onInspect(table.clickedRow, name)
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
        }
        menu.addItem(.separator())
        menu.addItem(item("Open in Inspector", #selector(menuInspect(_:)), represented: CellCoordinate(row: row, column: columnName ?? "")))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", represented: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    private final class CellCoordinate: NSObject {
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
