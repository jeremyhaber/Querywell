import AppKit
import QuerywellCore
import SwiftUI

/// Root of a connection window: resolves the workspace by id, or closes itself when the
/// workspace is gone (for instance a window restored from a previous launch).
struct ConnectionWindowView: View {
    let workspaceID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let id = workspaceID, let workspace = model.workspaces[id] {
            ConnectionWindowContent(workspace: workspace)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

/// The connection window (design: Main.dc.html header, tab strip and body frame).
struct ConnectionWindowContent: View {
    @Bindable var workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var showSwitcher = false
    @State private var editor: EditorItem?

    private var profile: ConnectionProfile { workspace.profile }

    var body: some View {
        content
            .background(Theme.background)
            .overlay(alignment: .top) {
                if profile.isProduction {
                    Theme.tagProduction.frame(height: 2).accessibilityHidden(true)
                }
            }
            .navigationTitle(workspace.title)
            .navigationSubtitle(profile.isProduction ? "PRODUCTION" : "")
            .toolbar { toolbarContent }
            .overlay {
                if showSwitcher {
                    QuickSwitcherView(
                        items: switcherItems,
                        tabs: workspace.tabs,
                        profiles: model.library.profiles,
                        onSelect: perform,
                        onDismiss: { showSwitcher = false })
                }
            }
            .sheet(item: $editor) { item in
                ConnectionEditorView(draft: item.draft, isNew: false)
            }
            .background(
                WindowAccessor { window in
                    workspace.window = window
                    WindowCloseGuard.install(
                        on: window,
                        confirmation: { [workspace, model] in
                            guard model.settings.general.confirmBeforeClosingConnectionWindow, workspace.isConnected
                            else { return nil }
                            return (
                                "Close the connection to “\(workspace.title)”?",
                                "The database connection\(workspace.profile.ssh != nil ? " and its SSH tunnel" : "") will be closed. Unsaved work in this window is lost."
                            )
                        },
                        didClose: { [workspace, model] in
                            Task { await model.closeWorkspace(id: workspace.id) }
                        })
                })
            .focusedSceneValue(\.windowActions, windowActions)
            .task { await workspace.startIfNeeded() }
            .appAlert()
    }

    private var windowActions: WindowActions {
        let newQuery: (() -> Void)? = workspace.isConnected ? { workspace.newQuery() } : nil
        return WindowActions(
            kind: .connection,
            newQuery: newQuery,
            closeTab: {
                if !workspace.closeSelectedTab() { NSApp.keyWindow?.performClose(nil) }
            },
            closeLabel: workspace.tabs.selectedID == nil ? "Close Window" : "Close Tab",
            selectTab: { workspace.selectTab(at: $0) },
            nextTab: { workspace.tabs.selectNext() },
            previousTab: { workspace.tabs.selectPrevious() },
            quickOpen: { showSwitcher.toggle() })
    }

    // MARK: Body by state

    @ViewBuilder
    private var content: some View {
        switch workspace.state {
        case .connected:
            VStack(spacing: 0) {
                TabStripView(workspace: workspace)
                HSplitView {
                    WorkspaceSidebar(workspace: workspace)
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    TabContentView(workspace: workspace)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .connecting(let stage):
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Connecting to \(profile.name)")
                    .font(.title3.weight(.semibold))
                Text(stage.title + "…")
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let error):
            failedPanel(error)
        case .idle:
            VStack(spacing: 14) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
                Text("Disconnected").font(.title3.weight(.semibold))
                Text("Your tabs are kept. Reconnect to continue.")
                    .foregroundStyle(Theme.textSecondary)
                Button("Reconnect") { Task { await workspace.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failedPanel(_ error: ConnectionOpenError) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.dangerText)
                .accessibilityHidden(true)
            Text("Couldn't connect to \(profile.name)")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion).foregroundStyle(Theme.textSecondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(14)
            .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            HStack {
                Button("Reconnect") { Task { await workspace.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Edit Connection…") { openEditor() }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            connectionMenu
            statusView
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showSwitcher = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Jump to table, query…")
                    Spacer(minLength: 8)
                    KeyCap("⌘K")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(width: 240, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick open (⌘K)")
            .accessibilityLabel("Jump to table or query")
            .accessibilityHint("Opens the quick switcher")

            Button {
                workspace.newQuery()
            } label: {
                Label("New query", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!workspace.isConnected)
            .help("New query (⌘T)")
        }
    }

    private var connectionMenu: some View {
        Menu {
            Button("Reconnect") { Task { await workspace.reconnect() } }
            Button("Disconnect") { Task { await workspace.disconnect() } }
                .disabled(workspace.state == .idle)
            Divider()
            Button("Edit Connection…") { openEditor() }
            Button("Copy Connection Details") { copyDetails() }
        } label: {
            HStack(spacing: 8) {
                if profile.isProduction { ProdBadge() }
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .menuIndicator(.visible)
        .help("Connection actions")
        .accessibilityLabel("\(profile.name), \(profile.isProduction ? "production, " : "")\(headerSubtitle). Connection menu")
    }

    private var headerSubtitle: String {
        workspace.summary.engineLabel + (profile.ssh != nil ? " · via SSH" : "")
    }

    @ViewBuilder
    private var statusView: some View {
        Group {
            switch workspace.state {
            case .connected:
                HStack(spacing: 6) {
                    StatusDot(color: Theme.connectedDot)
                    Text(workspace.latencyMilliseconds.map { "Connected · \($0) ms" } ?? "Connected")
                        .foregroundStyle(Theme.connectedText)
                }
            case .connecting(let stage):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting… \(stage.title)").foregroundStyle(Theme.textSecondary)
                }
            case .failed:
                HStack(spacing: 6) {
                    StatusDot(color: Theme.dangerText)
                    Text("Connection lost").foregroundStyle(Theme.dangerText)
                }
            case .idle:
                HStack(spacing: 6) {
                    StatusDot(color: Theme.textTertiary)
                    Text("Disconnected").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func openEditor() {
        let current = model.profile(id: profile.id) ?? profile
        guard let draft = model.draft(for: current) else { return }
        editor = EditorItem(draft: draft, isNew: false)
    }

    private func copyDetails() {
        var lines = [
            "Name: \(profile.name)",
            "Engine: \(workspace.summary.engineLabel)",
            "Endpoint: \(workspace.summary.endpointLabel)",
            "User: \(profile.user)",
        ]
        if let db = profile.defaultDatabase { lines.append("Database: \(db)") }
        if let ssh = profile.ssh { lines.append("SSH: \(ssh.user)@\(ssh.host):\(ssh.port)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Quick switcher

    private var switcherItems: [QuickSwitcherItem] {
        let tabs = workspace.tabs.tabs.map { QuickSwitcherItem.openTab($0.id, title: $0.title) }
        let connections = model.library.profiles
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .map { QuickSwitcherItem.connection($0.id, name: $0.name, tag: $0.colorTag) }
        return tabs + connections + QuickAction.allCases.map(QuickSwitcherItem.action)
    }

    private func perform(_ item: QuickSwitcherItem) {
        switch item {
        case .connection(let id, _, _): model.openConnection(id, using: openWindow)
        case .openTab(let id, _): workspace.tabs.select(id: id)
        case .table(let database, let name): workspace.tabs.openTable(database: database, name: name)
        case .action(.newQuery): workspace.newQuery()
        case .action(.newConsole): workspace.openConsole()
        case .action(.openConnections): openWindow(id: "launcher")
        case .action(.settings): openSettings()
        }
    }
}

/// Left column: database picker and table filter (the table list arrives with the table browser).
struct WorkspaceSidebar: View {
    @Bindable var workspace: ConnectionWorkspace
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Database")
                Picker("Database", selection: $workspace.selectedDatabase) {
                    if workspace.databases.isEmpty {
                        Text("No databases").tag(String?.none)
                    }
                    ForEach(workspace.databases, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .disabled(workspace.databases.isEmpty)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Filter tables")
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter tables")
            }
            CaptionLabel("Tables")
            Text("Tables load in the table browser (Phase 4)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    }
}

/// The selected tab's content. Real editors arrive in later phases.
struct TabContentView: View {
    let workspace: ConnectionWorkspace

    var body: some View {
        Group {
            if let tab = workspace.tabs.selectedTab {
                placeholder(for: tab)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func placeholder(for tab: WorkspaceTab) -> some View {
        let (symbol, text): (String, String) = switch tab.kind {
        case .table: ("tablecells", "Table browser — Phase 4")
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
            Text("Start a query or open a console. Press ⌘K to jump to anything.")
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
