import AppKit
import QuerywellCore
import SwiftUI

/// Left column (design: Main.dc.html `aside`): schema picker, table filter, tables, views and routines.
struct WorkspaceSidebar: View {
    @Bindable var workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var app
    @State private var filterFocusToken = 0
    @FocusState private var filterFocused: Bool
    @FocusState private var listFocused: Bool

    private var browser: SchemaBrowserModel { workspace.browser }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            schemaPicker
            filterField
            HStack {
                CaptionLabel("Tables")
                if browser.currentPhase == .loading {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading tables")
                }
            }
            .padding(.top, 4)
            tableList
            Spacer(minLength: 0).frame(maxHeight: 0)
            routinesSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .background { shortcuts }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tables sidebar")
    }

    // MARK: Header

    private var schemaPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CaptionLabel(browser.schemaNoun)
                Spacer()
                Button {
                    workspace.refreshSchema()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh tables (⌘R)")
                .accessibilityLabel("Refresh tables")
            }
            Picker(browser.schemaNoun, selection: Binding(
                get: { browser.selectedSchema },
                set: { browser.selectedSchema = $0 }
            )) {
                if browser.schemas.isEmpty { Text("No \(browser.schemaNoun.lowercased())s").tag(String?.none) }
                ForEach(browser.schemas, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .disabled(browser.schemas.isEmpty)
            .accessibilityLabel(browser.schemaNoun)
        }
    }

    private var filterField: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionLabel("Filter tables")
            TextField("Filter…", text: Binding(get: { browser.filterText }, set: { browser.filterText = $0 }))
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .onSubmit {
                    if let first = browser.filteredTables.first ?? browser.filteredViews.first { open(first.ref.name) }
                }
                .onKeyPress(.downArrow) { listFocused = true; return .handled }
                .onKeyPress(.escape) {
                    if browser.filterText.isEmpty { return .ignored }
                    browser.filterText = ""
                    return .handled
                }
                .accessibilityLabel("Filter tables")
        }
    }

    // MARK: Tables

    @ViewBuilder
    private var tableList: some View {
        switch browser.currentPhase {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load tables", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dangerText)
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                Button("Retry") { workspace.refreshSchema() }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            if browser.current == nil {
                Text(browser.currentPhase == .loading ? "Loading tables…" : "No \(browser.schemaNoun.lowercased()) selected")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                list
            }
        }
    }

    private var list: some View {
        let tables = browser.filteredTables
        let views = browser.filteredViews
        let visible = (tables + views).map(\.ref.name)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(tables) { info in row(info, visible: visible) }
                    if !views.isEmpty {
                        CaptionLabel("Views").padding(.top, 10).padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(views) { info in row(info, visible: visible) }
                    }
                    if tables.isEmpty, views.isEmpty {
                        Text(browser.filterText.isEmpty ? "No tables" : "No tables match “\(browser.filterText)”")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress(.return) {
                if let name = visible.first(where: { browser.selectedTables.contains($0) }) { open(name) }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
                guard press.modifiers == .command else { return .ignored }
                browser.selectAllMatching()
                return .handled
            }
            .accessibilityLabel("Tables")
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ info: TableInfo, visible: [String]) -> some View {
        let name = info.ref.name
        let selected = browser.selectedTables.contains(name)
        let isView = info.kind != .table
        let estimate = info.estimatedRows
        return Button {
            let flags = NSEvent.modifierFlags
            let command = flags.contains(.command)
            let shift = flags.contains(.shift)
            browser.select(name, command: command, shift: shift, visible: visible)
            listFocused = true
            if !command && !shift { open(name) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isView ? "eye" : "tablecells")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.accentSubtleText : Theme.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let estimate, !isView {
                    Text(CompactCount.string(estimate))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(selected ? Theme.accentSubtleText.opacity(0.8) : Theme.textTertiary)
                        .help("~\(CompactCount.grouped(estimate)) rows (estimated)")
                }
            }
            .foregroundStyle(selected ? Theme.accentSubtleText : Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(name)
        .contextMenu { contextMenu(for: info) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: info))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func accessibilityLabel(for info: TableInfo) -> String {
        var label = info.ref.name + (info.kind == .table ? "" : ", view")
        if let rows = info.estimatedRows, info.kind == .table { label += ", about \(CompactCount.grouped(rows)) rows" }
        return label
    }

    /// The tables an action applies to: the selection when the clicked row is part of it, else just that row.
    private func targets(for info: TableInfo) -> [TableInfo] {
        guard browser.selectedTables.contains(info.ref.name), browser.selectedTables.count > 1 else { return [info] }
        return (browser.current.map { $0.tables + $0.views } ?? []).filter { browser.selectedTables.contains($0.ref.name) }
    }

    @ViewBuilder
    private func contextMenu(for info: TableInfo) -> some View {
        let name = info.ref.name
        let targets = targets(for: info)
        let readOnly = workspace.profile.effectiveReadOnly
        let realTables = targets.filter { $0.kind == .table }
        let unsupported = BatchOperationsModel.unsupportedReason(for: workspace.profile.engine)
        Button("Open in New Tab") { open(name) }
        Button("Show Structure") {
            open(name)
            workspace.tableModel(forTable: info.ref)?.mode = .structure
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
        Divider()
        Button(targets.count > 1 ? "Table Operations… (\(targets.count) tables)" : "Table Operations…") {
            workspace.presentTableOperations(for: targets)
        }
        .disabled(unsupported != nil || readOnly)
        .help(unsupported ?? (readOnly ? "This connection is read-only." : "Change storage engine or character set"))
        Button("Search & Replace…") {
            workspace.presentSearchReplace(preselect: Set(realTables.map(\.ref.name)))
        }
        .disabled(realTables.isEmpty || !workspace.isConnected)
        .help("Find and replace text in these tables, keeping serialized data valid")
        Divider()
        Button(targets.count > 1 ? "Empty \(realTables.count) Tables…" : "Truncate…") {
            run(targets: realTables, destructive: .truncate)
        }
        .disabled(readOnly || realTables.isEmpty)
        .help(readOnly ? "This connection is read-only." : "Delete every row, keep the table")
        Button(targets.count > 1 ? "Drop \(targets.count) Objects…" : "Drop…") {
            run(targets: targets, destructive: .drop)
        }
        .disabled(readOnly)
        .help(readOnly ? "This connection is read-only." : "Delete the table or view")
    }

    private enum Destructive { case truncate, drop }

    private func run(targets: [TableInfo], destructive: Destructive) {
        Task {
            let outcome = destructive == .truncate ? await workspace.truncate(targets) : await workspace.drop(targets)
            guard let failure = outcome.failure else { return }
            let verb = destructive == .truncate ? "empty" : "drop"
            app.alert = AppAlert(
                title: "Couldn't \(verb) the table",
                message: failure.message,
                recovery: outcome.completed > 0
                    ? "\(outcome.completed) earlier statement\(outcome.completed == 1 ? "" : "s") already ran. Failed: \(failure.statement)"
                    : "Nothing was changed. Statement: \(failure.statement)")
        }
    }

    private func open(_ name: String) {
        guard let schema = browser.selectedSchema else { return }
        workspace.openTable(TableRef(schema: schema, name: name))
    }

    private func move(_ delta: Int, visible: [String], proxy: ScrollViewProxy) {
        guard !visible.isEmpty else { return }
        let current = visible.lastIndex { browser.selectedTables.contains($0) }
        let next = min(max((current ?? (delta > 0 ? -1 : visible.count)) + delta, 0), visible.count - 1)
        let flags = NSEvent.modifierFlags
        browser.select(visible[next], command: false, shift: flags.contains(.shift), visible: visible)
        proxy.scrollTo(visible[next])
    }

    // MARK: Routines

    private var routinesSection: some View {
        let contents = browser.current
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                browser.routinesExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: browser.routinesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    CaptionLabel("Views · Routines")
                    Spacer()
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Views and routines, \(browser.routinesExpanded ? "expanded" : "collapsed")")

            if browser.routinesExpanded, let contents {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(contents.routines) { routine in
                            HStack(spacing: 8) {
                                Image(systemName: routine.kind == .procedure ? "gearshape" : "function")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                                    .accessibilityHidden(true)
                                Text(routine.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text(routine.kind.rawValue).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                        }
                        if contents.routines.isEmpty {
                            Text("No routines").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
            Text(contents?.summary ?? "—")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 14)
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Button("Filter tables") { filterFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The selected tab's content.
struct TabContentView: View {
    let workspace: ConnectionWorkspace

    var body: some View {
        Group {
            if let tab = workspace.tabs.selectedTab {
                content(for: tab)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder
    private func content(for tab: WorkspaceTab) -> some View {
        if case .table = tab.kind, let model = workspace.tableModel(forTab: tab) {
            TableTabView(model: model, workspace: workspace)
                .id(tab.id)
        } else {
            placeholder(for: tab)
        }
    }

    private func placeholder(for tab: WorkspaceTab) -> some View {
        let (symbol, text): (String, String) = switch tab.kind {
        case .table: ("tablecells", "Table browser")
        case .query: ("chevron.left.forwardslash.chevron.right", "Query editor — Phase 5")
        case .console: ("terminal", "Console — Phase 7")
        case .terminal: ("apple.terminal", "Terminal — Phase 7")
        }
        return VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(Theme.color(for: tab.accent))
                .accessibilityHidden(true)
            Text(tab.title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text("No tabs open").font(.title3.weight(.semibold))
            Text("Pick a table in the sidebar, start a query or open a console. Press ⌘K to jump to anything.")
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Button {
                    workspace.newQuery()
                } label: {
                    Label("New Query", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button("Open Console") { workspace.openConsole() }
            }
            .controlSize(.large)
        }
    }
}
