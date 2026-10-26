import AppKit
import QuerywellCore
import SwiftUI

struct EditorItem: Identifiable {
    let id = UUID()
    var draft: ConnectionDraft
    var isNew: Bool
}

/// The saved-connections launcher (design: Connections.dc.html).
struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var query = ConnectionLibraryQuery()
    @State private var selection: UUID?
    @State private var editor: EditorItem?
    @State private var deleteTarget: ConnectionProfile?
    @State private var folderSheet: FolderSheet?
    @State private var folderToDelete: ConnectionFolder?
    @State private var showSwitcher = false
    @State private var columns = 2
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    private static let minCardWidth: CGFloat = 320

    private var visible: [ConnectionProfile] { query.apply(to: model.library) }

    var body: some View {
        NavigationSplitView {
            LauncherSidebar(
                query: $query,
                onAddFolder: { folderSheet = .add },
                onRename: { folderSheet = .rename($0) },
                onDelete: { folderToDelete = $0 })
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationTitle("Connections")
        .sheet(item: $editor) { item in
            ConnectionEditorView(draft: item.draft, isNew: item.isNew)
        }
        .sheet(item: $folderSheet) { sheet in
            switch sheet {
            case .add:
                FolderNameSheet(title: "New Folder", confirmTitle: "Add", name: "") { name in
                    Task {
                        if let id = await model.addFolder(named: name) { query.folder = .folder(id) }
                    }
                }
            case .rename(let folder):
                FolderNameSheet(title: "Rename Folder", confirmTitle: "Rename", name: folder.name) { name in
                    Task { await model.renameFolder(folder, to: name) }
                }
            }
        }
        .alert(
            deleteTarget.map { $0.isProduction ? "Delete production connection “\($0.name)”?" : "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { profile in
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(profile)
                    if selection == profile.id { selection = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text(deleteMessage(profile))
        }
        .alert(
            folderToDelete.map { "Delete the folder “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            presenting: folderToDelete
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                Task {
                    await model.deleteFolder(folder)
                    if query.folder == .folder(folder.id) { query.folder = .all }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The connections in it are kept and move to Unfiled.")
        }
        .overlay {
            if showSwitcher {
                QuickSwitcherView(
                    items: switcherItems,
                    tabs: nil,
                    profiles: model.library.profiles,
                    onSelect: perform,
                    onDismiss: { showSwitcher = false })
            }
        }
        .appAlert()
        .focusedSceneValue(\.windowActions, WindowActions(
            kind: .launcher,
            newQuery: nil,
            closeTab: { NSApp.keyWindow?.performClose(nil) },
            closeLabel: "Close Window",
            quickOpen: { showSwitcher.toggle() }))
        .onAppear { consumeNewConnectionRequest() }
        .onChange(of: model.wantsNewConnection) { _, _ in consumeNewConnectionRequest() }
        .task { gridFocused = true }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .background(Theme.background)
    }

    private var title: String {
        switch query.folder {
        case .all: "All connections"
        case .favourites: "Favourites"
        case .unfiled: "Unfiled"
        case .folder(let id): model.folder(id: id)?.name ?? "Folder"
        case .tag(let kind):
            switch kind {
            case .production: "Production"
            case .staging: "Staging"
            case .local: "Local"
            case .custom: "Custom tags"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            searchField
            sortMenu
            Button {
                startNewConnection()
            } label: {
                Label("New connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField("Search connections", text: $query.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search connections")
                .onKeyPress(.downArrow) { moveFromSearch() }
                .onKeyPress(.escape) {
                    if query.searchText.isEmpty { gridFocused = true } else { query.searchText = "" }
                    return .handled
                }
                .onSubmit { connectSelected(newWindow: false) }
            if !query.searchText.isEmpty {
                Button {
                    query.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            // ⌘F focuses the search field.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 240)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(searchFocused ? Theme.accent : Theme.separator))
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $query.sort) {
                Text("Last used").tag(ConnectionSort.lastUsed)
                Text("Name").tag(ConnectionSort.name)
                Text("Date created").tag(ConnectionSort.created)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort connections")
        .accessibilityLabel("Sort connections")
    }

    @ViewBuilder
    private var content: some View {
        let profiles = visible
        if model.library.profiles.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
                Text("No connections yet").font(.title2.weight(.semibold))
                Text("Add a MySQL, MariaDB or PostgreSQL server, directly or through an SSH tunnel.")
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button {
                    startNewConnection()
                } label: {
                    Label("Add your first connection", systemImage: "plus")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if profiles.isEmpty {
            if query.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "No connections here",
                    systemImage: "folder",
                    description: Text("Drag a connection onto this folder, or add a new one."))
            } else {
                ContentUnavailableView.search(text: query.searchText)
            }
        } else {
            grid(profiles)
        }
    }

    private func grid(_ profiles: [ConnectionProfile]) -> some View {
        let now = Date()
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                        alignment: .leading, spacing: 12
                    ) {
                        ForEach(profiles) { profile in
                            card(profile, now: now).id(profile.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 4)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, profiles: profiles) }
                .onChange(of: selection) { _, new in
                    if let new { Motion.animate(.snappy(duration: 0.15)) { proxy.scrollTo(new) } }
                }
            }
            .onChange(of: geo.size.width, initial: true) { _, width in
                columns = max(1, Int((width - 48 + 12) / (Self.minCardWidth + 12)))
            }
        }
    }

    private func card(_ profile: ConnectionProfile, now: Date) -> some View {
        ConnectionCard(
            profile: profile,
            summary: ConnectionSummary(profile: profile),
            isSelected: selection == profile.id,
            now: now,
            onSelect: { selection = profile.id; gridFocused = true },
            onConnect: { newWindow in
                selection = profile.id
                model.openConnection(profile.id, newWindow: newWindow, using: openWindow)
            },
            onEdit: { edit(profile) }
        )
        .draggable(profile.id.uuidString)
        .contextMenu { contextMenu(for: profile) }
    }

    @ViewBuilder
    private func contextMenu(for profile: ConnectionProfile) -> some View {
        Button("Connect") { model.openConnection(profile.id, using: openWindow) }
        Button("Connect in New Window") { model.openConnection(profile.id, newWindow: true, using: openWindow) }
        Divider()
        Button("Edit…") { edit(profile) }
        Button("Duplicate") {
            Task { if let id = await model.duplicate(profile) { selection = id } }
        }
        Button(profile.favourite ? "Remove from Favourites" : "Add to Favourites") {
            Task { await model.toggleFavourite(profile) }
        }
        Menu("Move to Folder") {
            Button("Unfiled") { Task { await model.move(profile, toFolder: nil) } }
                .disabled(profile.folderID == nil)
            Divider()
            ForEach(model.sortedFolders) { folder in
                Button(folder.name) { Task { await model.move(profile, toFolder: folder.id) } }
                    .disabled(profile.folderID == folder.id)
            }
        }
        Button("Copy Host") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(profile.host, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { deleteTarget = profile }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Passwords and SSH keys stored in Keychain")
            Text("Double-click opens each connection in its own window")
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Actions

    private func deleteMessage(_ profile: ConnectionProfile) -> String {
        var text = "This removes the connection and its saved passwords and SSH secrets from the Keychain. This can't be undone."
        if profile.isProduction {
            text = "This is a PRODUCTION connection. " + text
        }
        if model.workspaces.values.contains(where: { $0.profile.id == profile.id }) {
            text += " Its open windows will be closed."
        }
        return text
    }

    private func startNewConnection() {
        editor = EditorItem(draft: model.newDraft(filter: query.folder), isNew: true)
    }

    private func consumeNewConnectionRequest() {
        guard model.wantsNewConnection else { return }
        model.wantsNewConnection = false
        if editor == nil { startNewConnection() }
    }

    private func edit(_ profile: ConnectionProfile) {
        selection = profile.id
        guard let draft = model.draft(for: profile) else { return }
        editor = EditorItem(draft: draft, isNew: false)
    }

    private func connectSelected(newWindow: Bool) {
        guard let id = selection ?? visible.first?.id else { return }
        selection = id
        model.openConnection(id, newWindow: newWindow, using: openWindow)
    }

    private func moveFromSearch() -> KeyPress.Result {
        let profiles = visible
        guard !profiles.isEmpty else { return .ignored }
        if selection == nil || !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id }
        gridFocused = true
        return .handled
    }

    private func handleKey(_ press: KeyPress, profiles: [ConnectionProfile]) -> KeyPress.Result {
        func step(_ delta: Int) -> KeyPress.Result {
            guard !profiles.isEmpty else { return .ignored }
            guard let current = selection.flatMap({ id in profiles.firstIndex { $0.id == id } }) else {
                selection = profiles.first?.id
                return .handled
            }
            selection = profiles[min(max(current + delta, 0), profiles.count - 1)].id
            return .handled
        }
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .leftArrow: return step(-1)
        case .rightArrow: return step(1)
        case .upArrow: return step(-columns)
        case .downArrow: return step(columns)
        case .return:
            guard selection != nil else { return .ignored }
            connectSelected(newWindow: press.modifiers.contains(.option))
            return .handled
        case .delete where command:
            guard let id = selection, let profile = model.profile(id: id) else { return .ignored }
            deleteTarget = profile
            return .handled
        default:
            if command, press.characters == "e", let id = selection, let profile = model.profile(id: id) {
                edit(profile)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: Quick switcher

    private var switcherItems: [QuickSwitcherItem] {
        model.library.profiles
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .map { QuickSwitcherItem.connection($0.id, name: $0.name, tag: $0.colorTag) }
            + [QuickSwitcherItem.action(.openConnections), .action(.settings)]
    }

    private func perform(_ item: QuickSwitcherItem) {
        switch item {
        case .connection(let id, _, _): model.openConnection(id, using: openWindow)
        case .action(.settings): openSettings()
        case .action(.openConnections): NSApp.activate()
        case .action, .openTab, .table, .savedQuery: break
        }
    }
}
