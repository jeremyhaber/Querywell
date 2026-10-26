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
    @State private var showConnectionPopover = false
    /// Drives header density so toolbar items always fit (otherwise macOS shows its overflow
    /// button, which sat behind the identity pill as a stray glass circle).
    @State private var windowWidth: CGFloat = 0  // start compact; grows once measured (toolbar items shrink less reliably than they grow)

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
            .modifier(RemoveToolbarTitle())  // identity lives in the toolbar; `title` stays set for the Window menu / VoiceOver
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
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
                        unsavedEdits: { [workspace] in workspace.unsavedEditsDescription },
                        reviewUnsaved: { [workspace] in workspace.reviewFirstUnsaved() },
                        discardUnsaved: { [workspace] in workspace.discardAllUnsavedEdits() },
                        didClose: { [workspace, model] in
                            Task { await model.closeWorkspace(id: workspace.id) }
                        })
                })
            .focusedSceneValue(\.windowActions, windowActions)
            .task { await workspace.startIfNeeded() }
            .onAppear { workspace.safety = model.settings.safety }
            .onChange(of: model.settings.safety) { _, new in workspace.safety = new }
            .confirmationDialog(
                workspace.closePrompt.map { "“\($0.title)” has unsaved edits" } ?? "Unsaved edits",
                isPresented: Binding(get: { workspace.closePrompt != nil }, set: { if !$0 { workspace.closePrompt = nil } }),
                titleVisibility: .visible, presenting: workspace.closePrompt
            ) { _ in
                Button("Review Changes") { workspace.resolveClosePrompt(.review) }
                Button("Discard Edits", role: .destructive) { workspace.resolveClosePrompt(.discard) }
                Button("Cancel", role: .cancel) { workspace.resolveClosePrompt(.cancel) }
            } message: { prompt in
                Text("\(prompt.summary) will be lost if you close this tab.")
            }
            .sheet(isPresented: Binding(get: { workspace.batchOperations != nil }, set: { if !$0 { workspace.batchOperations = nil } })) {
                if let ops = workspace.batchOperations {
                    BatchOperationsSheet(model: ops) { workspace.batchOperations = nil }
                }
            }
            .sheet(isPresented: $workspace.searchReplacePresented) {
                if let sr = workspace.searchReplace {
                    SearchReplaceSheet(model: sr) { workspace.searchReplacePresented = false }
                        .interactiveDismissDisabled(sr.isRunning)
                }
            }
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
            quickOpen: { showSwitcher.toggle() },
            searchReplace: workspace.isConnected ? { workspace.presentSearchReplace() } : nil)
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
        // One cohesive leading item (identity + status). On macOS 26 the system would otherwise
        // wrap it in its own Liquid Glass capsule on top of the pill we draw ourselves.
        if #available(macOS 26.0, *) {
            // `.navigation` items get a capped width on macOS 26; a wider cluster there is clipped
            // and AppKit shows its overflow button behind it. `.automatic` + a flexible spacer
            // keeps the identity leading and the actions trailing.
            ToolbarItem(placement: .automatic) { identityCluster }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) { trailingCluster }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { identityCluster }
            ToolbarItem(placement: .primaryAction) { trailingCluster }
        }
    }

    private var identityCluster: some View {
        HStack(spacing: 12) {
            connectionButton
            statusView
        }
    }

    /// Header density for the current window width. Thresholds leave room for the traffic
    /// lights and both clusters at the window's minimum width (820pt).
    private var showsEngineLabel: Bool { windowWidth >= 1040 }
    private var showsQuickOpenText: Bool { windowWidth >= 960 }

    private var trailingCluster: some View {
        HStack(spacing: 10) {
            quickOpenButton
            newQueryButton
        }
    }

    private var quickOpenButton: some View {
        Button {
            showSwitcher = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                if showsQuickOpenText {
                    Text("Jump to table, query…")
                    Spacer(minLength: 8)
                }
                KeyCap("⌘K")
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: showsQuickOpenText ? 220 : nil, minHeight: 28)
            .headerPill()
        }
        .buttonStyle(.plain)
        .help("Quick open (⌘K)")
        .accessibilityLabel("Jump to table or query")
        .accessibilityHint("Opens the quick switcher")
    }

    private var newQueryButton: some View {
        Button {
            workspace.newQuery()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("New query").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .opacity(workspace.isConnected ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        }
        .buttonStyle(.plain)
        .disabled(!workspace.isConnected)
        .help("New query (⌘T)")
        .accessibilityLabel("New query")
    }

    private var connectionButton: some View {
        Button {
            showConnectionPopover.toggle()
        } label: {
            HStack(spacing: 10) {
                if profile.isProduction {
                    ProdBadge()
                } else if let tag = profile.colorTag {
                    ColorTagSwatch(tag: tag)
                }
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: profile.name.count <= 28, vertical: false)
                if showsEngineLabel {
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .headerPill()
        }
        .buttonStyle(.plain)
        .help("Connection actions")
        .accessibilityLabel(
            "\(profile.name), \(profile.isProduction ? "production connection, " : "")\(workspace.summary.engineLabel). Connection menu")
        .popover(isPresented: $showConnectionPopover, arrowEdge: .bottom) { connectionPopover }
    }

    private var connectionPopover: some View {
        let summary = workspace.summary
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Engine", summary.engineLabel)
                detailRow("Endpoint", summary.endpointLabel)
                detailRow("Access", summary.accessLabel)
                detailRow("TLS", tlsLabel)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                popoverAction("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await workspace.reconnect() }
                }
                popoverAction("Disconnect", systemImage: "bolt.slash", enabled: workspace.state != .idle) {
                    Task { await workspace.disconnect() }
                }
                popoverAction("Edit Connection…", systemImage: "pencil") { openEditor() }
                popoverAction("Copy Connection Details", systemImage: "doc.on.doc") { copyDetails() }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func popoverAction(
        _ title: String, systemImage: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button {
            showConnectionPopover = false
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var tlsLabel: String {
        switch profile.tls.mode {
        case .disabled: "Off"
        case .preferred: "On when available"
        case .required: "On"
        case .verifyCA: "On, verifies CA"
        case .verifyIdentity: "On, verifies identity"
        }
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
                    Text(workspace.latency.map { "Connected · \(LatencyFormatter.string(for: $0))" } ?? "Connected")
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
        .fixedSize()
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
        return tabs + workspace.browser.switcherItems + connections + QuickAction.allCases.map(QuickSwitcherItem.action)
    }

    private func perform(_ item: QuickSwitcherItem) {
        switch item {
        case .connection(let id, _, _): model.openConnection(id, using: openWindow)
        case .openTab(let id, _): workspace.tabs.select(id: id)
        case .table(let database, let name): workspace.openTable(TableRef(schema: database, name: name))
        case .action(.newQuery): workspace.newQuery()
        case .action(.newConsole): workspace.openConsole()
        case .action(.openConnections): openWindow(id: "launcher")
        case .action(.settings): openSettings()
        }
    }
}

extension View {
    /// The design's header control: rounded 8, 1pt separator border, control background.
    func headerPill() -> some View {
        background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
    }
}
