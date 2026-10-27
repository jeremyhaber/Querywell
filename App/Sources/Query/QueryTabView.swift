import AppKit
import QuerywellCore
import SwiftUI

/// A query tab (design: Query.dc.html `main`): toolbar, editor, result tabs, grid, footer; the AI panel docks at the right.
struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    let workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var app
    @State private var promptFocused = false

    var body: some View {
        HStack(spacing: 0) {
            VSplitView {
                editorPane
                    .frame(minHeight: 110, idealHeight: 250, maxHeight: .infinity)
                resultsPane
                    .frame(minHeight: 150, maxHeight: .infinity)
            }
            // Wide enough for the folded toolbar and a readable editor beside the assistant.
            .frame(minWidth: 380)
            if model.showsAssistant {
                Divider()
                AIAssistantPanel(model: model.assistant, onClose: { model.showsAssistant = false }, promptFocused: $promptFocused)
                    .frame(width: 320)
            }
        }
        .background(Theme.background)
        .background { shortcuts }
        .task(id: workspace.connectionEpoch) { model.invalidateCatalog() }
        .task { await workspace.queryLibrary.refreshAllSaved(); await model.refreshTables() }
        .onAppear { wireAssistant(); refreshAssistantConfig() }
        .onChange(of: app.settings.ai) { _, _ in refreshAssistantConfig() }
        .onChange(of: model.showsAssistant) { _, on in if on { refreshAssistantConfig() } }
        .sheet(item: $model.saveSheet) { request in
            SavedQueryForm(
                title: "Save query", name: request.defaultName, isGlobal: request.isGlobal,
                onCancel: { model.saveSheet = nil },
                onSave: { name, notes, tags, global in
                    model.saveSheet = nil
                    Task { _ = await model.saveAs(name: name, notes: notes, tags: tags, global: global) }
                })
        }
        .sheet(item: $model.snippetSheet) { request in
            SnippetForm(existing: nil, sql: request.sql, onCancel: { model.snippetSheet = nil }) { name, sql, tags, global in
                model.snippetSheet = nil
                Task {
                    _ = await workspace.queryLibrary.saveSnippet(existing: nil, name: name, sql: sql, tags: tags, global: global)
                    model.show(toast: "Saved snippet “\(name)”", isError: false)
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        ZStack {
            Button("Run statement") { model.startRun(.currentStatement) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Explain") { Task { await model.explain() } }
                .keyboardShortcut("e", modifiers: .command)
            Button("Format") { model.format() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Save query") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Toggle assistant") { model.showsAssistant.toggle(); if model.showsAssistant { promptFocused = true } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Editor pane

    private var editorPane: some View {
        VStack(spacing: 0) {
            toolbar
            SQLTextView(
                controller: model.editor, initialText: model.text,
                settings: SQLEditorSettings(
                    fontSize: app.settings.editor.fontSize, showsLineNumbers: app.settings.editor.showLineNumbers,
                    dialect: model.dialect))
                .overlay(alignment: .bottom) {
                    if let toast = model.toast {
                        ToastView(toast: toast).padding(.bottom, 12).transition(.opacity)
                    }
                }
                .motionAnimation(.easeOut(duration: 0.18), value: model.toast)
                .clipped()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button { model.cancel() } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Stop").font(.system(size: 13, weight: .medium))
                    }
                }
                .buttonStyle(AccentFillButtonStyle(tint: Theme.dangerFill))
                .help("Stop: cancels the running statement on the server and skips the rest")
                .fixedSize()
            } else {
                runButton.fixedSize()
            }
            // Narrow tabs (assistant open, small window): secondary actions fold into a menu instead of squashing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Button("Run selection") { model.startRun(.selection) }
                        .disabled(model.isRunning || !model.hasSelection)
                        .help("Runs only the selected SQL")
                    Button("Explain") { Task { await model.explain() } }
                        .disabled(model.isRunning || !model.hasText)
                        .help("Show the query plan for the statement at the cursor (⌘E)")
                    Button("Format") { model.format() }
                        .disabled(!model.hasText)
                        .help("Tidy the SQL (⌥⌘F)")
                    quickQueriesMenu(compact: false)
                }
                .fixedSize()
                HStack(spacing: 8) {
                    moreActionsMenu
                    quickQueriesMenu(compact: true)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            Menu {
                Button("Save Query…") { Task { await model.save() } }.keyboardShortcut("s", modifiers: .command)
                Button("Save Query As…") {
                    model.saveSheet = SaveQuerySheetRequest(sql: model.text, defaultName: SavedQueryNaming.suggestedName(for: model.text), isGlobal: false)
                }
                Divider()
                Button("Save as Snippet…") { model.snippetSheet = SnippetSheetRequest(snippet: nil, sql: model.selectedTextOrAll) }
            } label: {
                Text(model.linkedQuery == nil ? "Save as…" : "Save")
            }
            .menuStyle(.button)
            .buttonStyle(OutlineButtonStyle())
            .fixedSize()
            .disabled(!model.hasText)
            Button {
                model.showsAssistant.toggle()
                if model.showsAssistant { promptFocused = true }
            } label: {
                Image(systemName: "sparkles")
                    .foregroundStyle(model.showsAssistant ? Theme.accentSubtleText : Theme.tabQuery)
                    .padding(.horizontal, 2)
            }
            .help("AI assistant (⌘⇧A)")
            .accessibilityLabel("AI assistant")
            .accessibilityValue(model.showsAssistant ? "shown" : "hidden")
        }
        .buttonStyle(OutlineButtonStyle())
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 8)
        // An opaque bar above the editor: nothing from the editor or its gutter shows through.
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .zIndex(1)
    }

    // MARK: Quick queries

    private var moreActionsMenu: some View {
        Menu {
            Button("Run Selection") { model.startRun(.selection) }
                .disabled(model.isRunning || !model.hasSelection)
            Button("Explain") { Task { await model.explain() } }
                .disabled(model.isRunning || !model.hasText)
            Button("Format") { model.format() }
                .disabled(!model.hasText)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(OutlineButtonStyle())
        .fixedSize()
        .help("Run selection, Explain, Format")
        .accessibilityLabel("More actions")
    }

    private func quickQueriesMenu(compact: Bool) -> some View {
        let snippets = workspace.queryLibrary.allSnippets
        let target = model.quickTable.map(\.name) ?? "at cursor"
        return Menu {
            Section("Table: \(target)") {
                ForEach(QuickQueryKind.tableLevel) { kind in
                    Button(kind.title) { Task { await model.insertQuickQuery(kind) } }
                }
            }
            Section("This database") {
                ForEach(QuickQueryKind.databaseLevel) { kind in
                    Button(kind.title) { Task { await model.insertQuickQuery(kind) } }
                }
            }
            Divider()
            Menu("Choose table") {
                Button { model.quickTable = nil } label: {
                    Text(model.quickTable == nil ? "✓ Table at cursor" : "Table at cursor")
                }
                Divider()
                ForEach(model.knownTables.prefix(400)) { info in
                    Button { model.quickTable = info.ref } label: {
                        Text(model.quickTable == info.ref ? "✓ \(info.ref.name)" : info.ref.name)
                    }
                }
            }
            if !snippets.isEmpty {
                Menu("Snippets") {
                    ForEach(snippets) { snippet in
                        Button(snippet.name) { model.insertSnippet(snippet.sql); model.editor.focus() }
                    }
                }
            }
        } label: {
            if compact { Image(systemName: "bolt") } else { Text("Quick queries") }
        }
        .menuStyle(.button)
        .buttonStyle(OutlineButtonStyle())
        .fixedSize()
        .help("Insert a common query for a table: SELECT, COUNT, INSERT, UPDATE, structure, sizes …")
        .accessibilityLabel("Quick queries")
    }

    private var runButton: some View {
        let button = Button { model.startRun(.auto) } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10))
                Text("Run").font(.system(size: 13, weight: .medium))
                Text("⌘↵").font(.system(size: 11)).opacity(0.85)
            }
        }
        .buttonStyle(AccentFillButtonStyle())
        .disabled(!model.hasText)
        .help(model.hasSelection ? "Run the selection (⌘↵)" : "Run all statements (⌘↵) · ⇧⌘↵ runs the statement at the cursor")
        .accessibilityLabel("Run")
        // The assistant's prompt field owns ⌘↵ while it has focus.
        return Group {
            if promptFocused { button } else { button.keyboardShortcut(.return, modifiers: .command) }
        }
    }

    // MARK: Results pane

    private var resultsPane: some View {
        VStack(spacing: 0) {
            resultTabs
            Divider()
            resultContent
            footer
        }
        .background(Theme.background)
        .sheet(isPresented: Binding(
            get: { model.selectedItem?.editModel?.reviewPresented == true },
            set: { if !$0 { model.selectedItem?.editModel?.reviewPresented = false } })) {
            if let edit = model.selectedItem?.editModel {
                ReviewChangesSheet(model: edit) { edit.reviewPresented = false }
            }
        }
    }

    private var resultTabs: some View {
        HStack(spacing: 4) {
            ForEach(model.results) { item in
                tabButton(item.title, selected: model.selected == .result(item.id)) { model.selected = .result(item.id) }
            }
            tabButton(model.lastRun?.hasErrors == true ? "Messages ●" : "Messages", selected: model.selected == .messages,
                      tint: model.lastRun?.hasErrors == true ? Theme.dangerText : nil) { model.selected = .messages }
            if model.explainState != .idle { tabButton("Plan", selected: model.selected == .plan) { model.selected = .plan } }
            Spacer(minLength: 8)
            trailingHint
        }
        .padding(.horizontal, 14).padding(.top, 6)
        .frame(minHeight: 34, alignment: .bottom)
    }

    private func tabButton(_ title: String, selected: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(tint ?? (selected ? Theme.text : Theme.textSecondary))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? Theme.accent : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var trailingHint: some View {
        if let item = model.selectedItem {
            if let edit = item.editModel, edit.hasPendingChanges {
                PendingEditsPill(count: edit.pendingEditCount) { edit.reviewPresented = true }
            } else if let verdict = item.verdict {
                switch verdict {
                case .editable:
                    Label("Editable · single table with key", systemImage: "pencil")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .help("Double-click a cell to edit it. Changes are reviewed before they are saved.")
                case .notEditable(let reason):
                    Label("Read-only result", systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .help("Not editable: \(reason)")
                        .accessibilityHint(reason)
                }
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.selected {
        case .result(let id):
            if let item = model.results.first(where: { $0.id == id }) { resultView(item) } else { idleNote }
        case .messages:
            MessagesView(model: model)
        case .plan:
            ExplainPlanView(model: model)
        case nil:
            if model.isRunning {
                VStack(spacing: 8) { ProgressView(); Text("Running…").foregroundStyle(Theme.textSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { idleNote }
        }
    }

    private var idleNote: some View {
        ContentMessage(symbol: "play.rectangle", title: "No results yet",
                       detail: "Press ⌘↵ to run the script, or select part of it first. ⇧⌘↵ runs the statement at the cursor.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultView(_ item: QueryResultItem) -> some View {
        switch item.payload {
        case .affected(let rows, let lastID):
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(Theme.connectedDot).accessibilityHidden(true)
                Text(rows == 1 ? "1 row affected" : "\(rows) rows affected").font(.system(size: 14, weight: .semibold))
                if let lastID, lastID > 0 { Text("Last insert ID \(lastID)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                Text(QueryRunner.format(item.duration)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rows(let result, let truncated, let total):
            VStack(spacing: 0) {
                if truncated {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
                        Text("Showing first \(result.rows.count.formatted(.number.grouping(.automatic))) rows of \(total.formatted(.number.grouping(.automatic))). Add a LIMIT or filter to see the rest.")
                            .font(.system(size: 12)).foregroundStyle(Theme.pendingPillText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6).background(Theme.pendingPillBackground)
                }
                ResultGridView(item: item, dialect: model.dialect, nullDisplay: app.settings.dataGrid.nullDisplay,
                               showsColumnTypes: app.settings.dataGrid.showColumnTypes, schema: workspace.browser.selectedSchema ?? "")
                    .id(item.id)
                if result.rows.isEmpty {
                    Text("The query returned no rows.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(10)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            if let summary = model.footerSummary { Text(summary).lineLimit(1).fixedSize() }
            if let hint = model.guardHint.text {
                Label(hint, systemImage: guardSymbol)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                    .foregroundStyle(model.guardHint == .readOnlyQuery ? Theme.textSecondary : Theme.pendingPillText)
            }
            Spacer(minLength: 8)
            Menu("Export") {
                Button("CSV…") { exportSelected(.csv) }
                Button("JSON…") { exportSelected(.json) }
                Button("SQL INSERT…") { exportSelected(.sql) }
            }
            .menuStyle(.button).buttonStyle(OutlineButtonStyle()).fixedSize()
            .disabled(model.selectedItem?.result == nil)
            .help("Export the selected result set to a file")
            Button("Copy as CSV") {
                if let csv = model.csvOfSelectedResult() {
                    copyToPasteboard(csv)
                    model.show(toast: "Copied \(model.selectedItem?.rowCount ?? 0) rows as CSV", isError: false)
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(model.selectedItem?.result == nil)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private func exportSelected(_ kind: ResultExportModel.Kind) {
        guard let item = model.selectedItem, let result = item.result else { return }
        let rows = model.selectedItem?.editModel?.content?.rows ?? result.rows
        var exported = result
        exported.rows = rows
        workspace.presentResultExport(exported, name: "Result \(item.statementIndex + 1)", kind: kind)
    }

    private var guardSymbol: String {
        switch model.guardHint {
        case .readOnlyQuery: "checkmark.shield"
        default: "exclamationmark.shield"
        }
    }

    // MARK: AI wiring

    private func refreshAssistantConfig() {
        let a = model.assistant
        a.providerID = app.settings.ai.provider
        a.modelOverride = app.settings.ai.model
        a.hasKey = app.settings.ai.provider.map { AIKeyStore(store: app.secretStore).hasKey(for: $0) } ?? false
    }

    private func wireAssistant() {
        let a = model.assistant
        let workspace = workspace
        let app = app
        let tab = model
        a.makeProvider = {
            if let override = tab.assistantProviderOverride { return try override() }
            guard let id = app.settings.ai.provider else { throw AIError.missingAPIKey(.anthropic) }
            return try AIKeyStore(store: app.secretStore).provider(for: id)
        }
        a.loadContext = { prompt, allowSamples in
            guard let session = workspace.live?.session, let inspector = workspace.browser.inspector,
                  let schema = workspace.browser.selectedSchema ?? workspace.selectedDatabase else {
                throw AIError.invalidResponse("Connect to a database first.")
            }
            let cache = tab.assistantSchemaCache
            var samples: [TableRef: SampleRows]?
            if allowSamples {
                let tables = (try? await cache.tables(schema: schema, using: inspector)) ?? []
                samples = await AISampleRows.load(session: session, tables: tables, focus: prompt, dialect: SQLDialect(session.engine))
            }
            return try await AssistantContext.load(
                from: inspector, engine: session.engine, serverVersion: session.serverInfo.versionString, schema: schema,
                prompt: prompt, allowSampleRows: allowSamples, sampleRows: samples, cache: cache)
        }
        a.allowSampleRows = { app.settings.ai.includesSampleRows(for: workspace.profile.id) }
        a.setAllowSampleRows = { on in app.updateSettings { $0.ai.setIncludesSampleRows(on, for: workspace.profile.id) } }
        a.wordPress = { WordPressDetector.detect(tableNames: workspace.browser.current?.tables.map(\.ref.name) ?? []) }
        a.currentSQL = { tab.assistantSQL }
        a.lastError = { tab.lastError.map { ($0.statement.text, $0.message) } }
        a.optimizeInput = { await tab.planForOptimize() }
        a.insertIntoEditor = { sql in tab.insertIntoEditor(sql); tab.editor.focus() }
        a.replaceEditor = { sql in tab.setEditorText(sql); tab.editor.focus() }
        a.dialect = { tab.dialect }
    }
}

// MARK: - Result grid

/// The grid for one result: editable (a table edit model) or read-only with client-side sorting.
struct ResultGridView: View {
    let item: QueryResultItem
    let dialect: SQLDialect
    let nullDisplay: String
    let showsColumnTypes: Bool
    let schema: String
    @State private var focus = 0

    var body: some View {
        if let edit = item.editModel {
            EditableResultGrid(model: edit, dialect: dialect, nullDisplay: nullDisplay, showsColumnTypes: showsColumnTypes)
        } else if let grid = item.grid {
            ReadOnlyResultGrid(grid: grid, dialect: dialect, nullDisplay: nullDisplay, showsColumnTypes: showsColumnTypes, schema: schema)
        }
    }
}

private struct ReadOnlyResultGrid: View {
    let grid: ResultGridModel
    let dialect: SQLDialect
    let nullDisplay: String
    let showsColumnTypes: Bool
    let schema: String

    var body: some View {
        DataGridView(
            content: grid.content, sort: grid.sort, filteredColumns: [], nullDisplay: nullDisplay, showsColumnTypes: showsColumnTypes,
            table: TableRef(schema: schema, name: "result"), dialect: dialect, filterRequest: nil,
            filterPopoverContent: { _, _ in nil },
            actions: GridActions(onSort: { column, additive in grid.toggleSort(column: column, additive: additive) }),
            focusToken: 0, editRequest: nil)
            .accessibilityLabel("Query result")
    }
}

private struct EditableResultGrid: View {
    @Bindable var model: TableDataModel
    let dialect: SQLDialect
    let nullDisplay: String
    let showsColumnTypes: Bool

    var body: some View {
        DataGridView(
            content: model.content, sort: [], filteredColumns: [], nullDisplay: nullDisplay, showsColumnTypes: showsColumnTypes,
            table: model.table, dialect: dialect, filterRequest: nil, filterPopoverContent: { _, _ in nil },
            actions: GridActions(
                onSelection: { model.setSelection($0) },
                onActiveColumn: { model.activeColumn = $0 },
                editing: model.makeGridEditing(),
                onEditRequestConsumed: { model.editRequest = nil }),
            focusToken: 0, editRequest: model.editRequest)
            .overlay(alignment: .bottom) {
                if let toast = model.toast { ToastView(toast: toast).padding(.bottom, 10) }
            }
            .accessibilityLabel("Editable query result")
    }
}

// MARK: - Messages

/// The Messages tab: per-statement log lines and errors; rows with a statement jump to it in the editor.
struct MessagesView: View {
    let model: QueryTabModel

    var body: some View {
        if model.lastRun == nil {
            ContentMessage(symbol: "text.bubble", title: "No messages yet", detail: "Row counts, timings and errors from the last run appear here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, message in row(message) }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func row(_ message: QueryMessage) -> some View {
        let excerpt = message.statementIndex.flatMap { i in
            model.lastRun?.results[safe: i].map { Self.excerpt($0.statement.text) }
        }
        return Button {
            if let i = message.statementIndex { model.jumpToStatement(i) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol(message.level)).font(.system(size: 11)).foregroundStyle(tint(message.level)).frame(width: 14)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.text).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(message.level == .error ? Theme.dangerText : Theme.text)
                        .textSelection(.enabled)
                    if message.level == .error, let excerpt {
                        Text(excerpt).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(message.statementIndex == nil)
        .help(message.statementIndex == nil ? "" : "Jump to the statement")
    }

    static func excerpt(_ sql: String) -> String {
        let one = sql.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 90 ? String(one.prefix(90)) + "…" : one
    }

    private func symbol(_ l: QueryMessage.Level) -> String {
        switch l {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func tint(_ l: QueryMessage.Level) -> Color {
        switch l {
        case .info: Theme.textSecondary
        case .warning: Theme.pendingEditBar
        case .error: Theme.dangerText
        }
    }
}
