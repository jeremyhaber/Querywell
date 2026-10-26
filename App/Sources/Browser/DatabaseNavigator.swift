import AppKit
import QuerywellCore
import SwiftUI

/// The sidebar's database control: a button showing this window's database that opens a popover
/// with a search field, a keyboard-driven list and the create / drop actions.
///
/// What choosing a row does (own window or switch) comes from Settings; ⌥-Return and the row's
/// context menu do the other one.
struct DatabaseNavigator: View {
    @Bindable var workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var presented = false
    @State private var newDatabase: NewDatabaseModel?

    private var current: String? { workspace.boundDatabase }

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cylinder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(current ?? "Choose a database")
                    .font(.system(size: 13))
                    .foregroundStyle(current == nil ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .headerPill()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!workspace.isConnected)
        .help("Choose a database (type to filter)")
        .accessibilityLabel(current.map { "Database: \($0)" } ?? "Database")
        .accessibilityHint("Opens a searchable list of databases")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            DatabaseListPopover(
                workspace: workspace,
                defaultBehaviour: app.settings.general.databaseSelectionBehaviour,
                openElsewhere: { app.isDatabaseOpenElsewhere($0, besides: workspace) },
                choose: { name, behaviour in
                    presented = false
                    choose(name, behaviour)
                },
                drop: { name in
                    presented = false
                    drop(name)
                },
                newDatabase: {
                    presented = false
                    newDatabase = NewDatabaseModel(workspace: workspace)
                })
        }
        .sheet(item: $newDatabase) { model in
            NewDatabaseSheet(model: model) { created in
                newDatabase = nil
                if let created { choose(created, app.settings.general.databaseSelectionBehaviour) }
            }
        }
    }

    private func choose(_ name: String, _ behaviour: DatabaseSelectionBehaviour) {
        Task {
            if let reason = await app.chooseDatabase(name, in: workspace, behaviour: behaviour, using: openWindow) {
                app.alert = AppAlert(title: "Couldn't switch to “\(name)”", message: reason, recovery: nil)
            }
        }
    }

    private func drop(_ name: String) {
        Task {
            switch await workspace.dropDatabase(name) {
            case .done:
                Announce.post("Dropped database \(name)")
            case .declined:
                break
            case .failed(let message):
                Announce.post("Couldn't drop \(name)", important: true)
                app.alert = AppAlert(title: "Couldn't drop “\(name)”", message: message, recovery: nil)
            }
        }
    }
}

/// The popover body. Own view so its search text and highlight start fresh every time it opens.
private struct DatabaseListPopover: View {
    @Bindable var workspace: ConnectionWorkspace
    var defaultBehaviour: DatabaseSelectionBehaviour
    var openElsewhere: (String) -> Bool
    var choose: (String, DatabaseSelectionBehaviour) -> Void
    var drop: (String) -> Void
    var newDatabase: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private var entries: [DatabaseListEntry] {
        DatabaseList.entries(names: workspace.databases, query: query, engine: workspace.profile.engine)
    }

    var body: some View {
        let rows = entries
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search databases", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { activate(rows, behaviour: defaultBehaviour) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    activate(rows, behaviour: defaultBehaviour.inverted)
                    return .handled
                }
                .onKeyPress(.downArrow) { move(rows, by: 1); return .handled }
                .onKeyPress(.upArrow) { move(rows, by: -1); return .handled }
                .onKeyPress(.escape) {
                    if query.isEmpty { return .ignored }
                    query = ""
                    return .handled
                }
                .accessibilityLabel("Search databases")
                .accessibilityHint("Type to filter. Up and down arrows move through the list, Return chooses, Option-Return does the other action, Escape closes.")
            list(rows)
            Divider()
            footer(rows.count)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            highlighted = DatabaseList.reconcile(selected: workspace.boundDatabase, in: rows)
        }
        .task {
            // The popover's window isn't key yet on the first frame.
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            highlighted = DatabaseList.reconcile(selected: highlighted, in: entries)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Databases")
    }

    // MARK: List

    @ViewBuilder
    private func list(_ rows: [DatabaseListEntry]) -> some View {
        if rows.isEmpty {
            Text(workspace.databases.isEmpty ? "No databases" : "No database matches “\(query)”")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            rowView(row).id(row.name)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .onChange(of: highlighted) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
            }
            .accessibilityLabel("Database list")
        }
    }

    private func rowView(_ row: DatabaseListEntry) -> some View {
        let isCurrent = row.name == workspace.boundDatabase
        let isOpen = !isCurrent && openElsewhere(row.name)
        let isHighlighted = row.name == highlighted
        let dropReason = workspace.dropBlockedReason(for: row.name, boundElsewhere: isOpen)
        return Button {
            choose(row.name, defaultBehaviour)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark" : "cylinder")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? Theme.accentText : Theme.textTertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(QuickSwitcherView.highlightedTitle(
                    row.name, match: FuzzyMatch(score: 0, matchedIndices: row.matchedIndices)))
                    .font(.system(size: 13))
                    .foregroundStyle(isHighlighted ? Theme.accentSubtleText : (row.isSystem ? Theme.textSecondary : Theme.text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if isOpen {
                    Text("open").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = row.name } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(row, isCurrent: isCurrent, isOpen: isOpen))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open in its own window") { choose(row.name, .opensOwnWindow) }
        .accessibilityAction(named: "Switch this window here") { choose(row.name, .switchesWindow) }
        .accessibilityAction(named: "Drop database") { if dropReason == nil { drop(row.name) } }
        .contextMenu {
            Button("Open in Its Own Window") { choose(row.name, .opensOwnWindow) }
            Button("Switch This Window Here") { choose(row.name, .switchesWindow) }
                .disabled(isCurrent)
            Divider()
            Button("Drop Database…", role: .destructive) { drop(row.name) }
                .disabled(dropReason != nil)
            if let dropReason { Text(dropReason) }
        }
    }

    static func spokenLabel(_ row: DatabaseListEntry, isCurrent: Bool, isOpen: Bool) -> String {
        var parts = [row.name]
        if isCurrent { parts.append("current database") }
        if isOpen { parts.append("open in another window") }
        if row.isSystem { parts.append("system database") }
        return parts.joined(separator: ", ")
    }

    // MARK: Footer

    private func footer(_ count: Int) -> some View {
        HStack {
            Button {
                newDatabase()
            } label: {
                Label("New Database…", systemImage: "plus")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(workspace.canModifyDatabases ? Theme.accentText : Theme.textTertiary)
            .disabled(!workspace.canModifyDatabases)
            .help(workspace.profile.effectiveReadOnly ? "This connection is read-only" : "Create a database")
            Spacer()
            Text("\(count) of \(workspace.databases.count)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Keyboard

    private func move(_ rows: [DatabaseListEntry], by delta: Int) {
        let index = rows.firstIndex { $0.name == highlighted }
        guard let next = DatabaseList.move(from: index, delta: delta, count: rows.count) else { return }
        highlighted = rows[next].name
        Announce.post(rows[next].name)
    }

    private func activate(_ rows: [DatabaseListEntry], behaviour: DatabaseSelectionBehaviour) {
        guard let name = highlighted ?? rows.first?.name, rows.contains(where: { $0.name == name }) else { return }
        choose(name, behaviour)
    }
}
