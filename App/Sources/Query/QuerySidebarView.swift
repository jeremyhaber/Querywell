import AppKit
import QuerywellCore
import SwiftUI

/// Left column of query tabs (design: Query.dc.html `aside`): Schema | History | Saved | Snippets.
struct QuerySidebarView: View {
    @Bindable var workspace: ConnectionWorkspace
    @Bindable var library: QueryLibraryModel
    @State private var confirmClear = false
    @State private var pendingDelete: SavedQuery?

    private var editorText: String { workspace.currentQueryModel?.text ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedPills(selection: $library.segment)
            if library.segment != .schema { searchField }
            list
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .task { await library.reload() }
        .sheet(item: $library.savedSheet) { request in
            SavedQueryForm(
                title: "Edit details", actionTitle: "Save", name: request.query.name, notes: request.query.notes ?? "",
                tags: request.query.tags, isGlobal: request.query.connectionID == nil,
                onCancel: { library.savedSheet = nil },
                onSave: { name, notes, tags, global in
                    library.savedSheet = nil
                    Task { await library.updateSaved(request.query.id, name: name, notes: notes, tags: tags, global: global) }
                })
        }
        .sheet(item: $library.snippetSheet) { request in
            SnippetForm(existing: request.snippet, sql: request.sql, onCancel: { library.snippetSheet = nil }) { name, sql, tags, global in
                library.snippetSheet = nil
                Task { _ = await library.saveSnippet(existing: request.snippet, name: name, sql: sql, tags: tags, global: global) }
            }
        }
        .confirmationDialog("Clear history for this connection?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { Task { await library.clearHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every statement run on this connection is forgotten. Saved queries are not affected.")
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete saved query?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { query in
            Button("Delete", role: .destructive) { Task { await library.delete(query) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The saved query is removed. Open tabs keep their text.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            TextField("Search \(library.segment.rawValue.lowercased())", text: $library.search)
                .textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel("Search \(library.segment.rawValue.lowercased())")
            if !library.search.isEmpty {
                Button { library.search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
    }

    @ViewBuilder
    private var list: some View {
        switch library.segment {
        case .schema: QuerySchemaList(workspace: workspace)
        case .history: historyList
        case .saved: savedList
        case .snippets: snippetList
        }
    }

    // MARK: History

    private var historyList: some View {
        Group {
            if library.history.isEmpty {
                emptyNote(library.search.isEmpty ? "Statements you run appear here." : "No matching statements.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.history) { entry in historyRow(entry) }
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let active = !editorText.isEmpty && editorText.contains(entry.sql.prefix(400))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(HistoryRowFormat.title(entry.sql))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if entry.runCount > 1 {
                    Text("×\(entry.runCount)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.chipText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.chipBackground, in: Capsule())
                        .accessibilityLabel("run \(entry.runCount) times")
                }
            }
            Text(entry.isTruncated ? "Too long to re-run · open only" : HistoryRowFormat.meta(entry))
                .font(.system(size: 11)).foregroundStyle(entry.failed ? Theme.dangerText : Theme.textSecondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.runHistory(entry) }
        .onTapGesture { workspace.openHistory(entry, inNewTab: NSEvent.modifierFlags.contains(.option)) }
        .contextMenu {
            Button("Open in Editor") { workspace.openHistory(entry, inNewTab: false) }
            Button("Open in New Tab") { workspace.openHistory(entry, inNewTab: true) }
            Button("Run Again") { workspace.runHistory(entry) }.disabled(entry.rerunScript == nil)
            Divider()
            Button("Copy SQL") { copyToPasteboard(entry.sql) }
            Button("Delete", role: .destructive) { Task { await library.deleteHistory(entry) } }
        }
        .help(entry.isTruncated ? "This statement was too long to keep in full, so it can only be opened." : "Click to load · double-click to run again · ⌥-click for a new tab")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Run Again") { workspace.runHistory(entry) }
    }

    // MARK: Saved

    private var savedList: some View {
        Group {
            if library.saved.isEmpty {
                emptyNote(library.search.isEmpty ? "Save a query with ⌘S to find it here." : "No matching saved queries.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !library.connectionSaved.isEmpty {
                            sectionHeader("This connection")
                            ForEach(library.connectionSaved) { savedRow($0) }
                        }
                        if !library.globalSaved.isEmpty {
                            sectionHeader("All connections")
                            ForEach(library.globalSaved) { savedRow($0) }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        CaptionLabel(text).padding(.top, 6).padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func savedRow(_ query: SavedQuery) -> some View {
        let open = workspace.tabs.selectedTab?.savedQueryID == query.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(query.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(savedSubtitle(query)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(open ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.runSaved(query) }
        .onTapGesture { workspace.openSaved(query) }
        .contextMenu {
            Button("Open") { workspace.openSaved(query) }
            Button("Run") { workspace.runSaved(query) }
            Divider()
            Button("Edit Details…") { library.savedSheet = SavedQueryDetailsRequest(query: query) }
            Button("Duplicate") { Task { await library.duplicate(query) } }
            Toggle("Available to All Connections", isOn: Binding(
                get: { query.connectionID == nil }, set: { on in Task { await library.setGlobal(query, on) } }))
            Divider()
            Button("Copy SQL") { copyToPasteboard(query.sql) }
            Button("Delete…", role: .destructive) { pendingDelete = query }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func savedSubtitle(_ q: SavedQuery) -> String {
        var parts: [String] = []
        if let notes = q.notes, !notes.isEmpty { parts.append(notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? notes) }
        if !q.tags.isEmpty { parts.append(q.tags.map { "#\($0)" }.joined(separator: " ")) }
        if parts.isEmpty { parts.append(HistoryRowFormat.title(q.sql)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Snippets

    private var snippetList: some View {
        Group {
            if library.snippets.isEmpty {
                emptyNote(library.search.isEmpty ? "Snippets insert reusable SQL with tab stops." : "No matching snippets.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.snippets) { snippetRow($0) }
                    }
                }
            }
        }
    }

    private func snippetRow(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(HistoryRowFormat.title(s.sql)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { workspace.insertSnippet(s) }
        .contextMenu {
            Button("Insert at Cursor") { workspace.insertSnippet(s) }
            Button("Edit…") { library.snippetSheet = SnippetSheetRequest(snippet: s, sql: s.sql) }
            Divider()
            Button("Delete", role: .destructive) { Task { await library.delete(s) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch library.segment {
        case .history:
            if !library.history.isEmpty || !library.search.isEmpty {
                Button("Clear History…") { confirmClear = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        case .snippets:
            Button { library.snippetSheet = SnippetSheetRequest(snippet: nil, sql: "") } label: {
                Label("New Snippet", systemImage: "plus").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accentText)
        case .saved, .schema:
            EmptyView()
        }
        if let error = library.error {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.dangerText)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.horizontal, 4)
    }
}

/// The design's segmented control: tinted track, white selected pill with a hairline shadow.
struct SegmentedPills: View {
    @Binding var selection: QueryLibraryModel.Segment

    var body: some View {
        HStack(spacing: 0) {
            ForEach(QueryLibraryModel.Segment.allCases) { segment in
                Button { selection = segment } label: {
                    Text(segment.rawValue)
                        .font(.system(size: 12, weight: selection == segment ? .medium : .regular))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(selection == segment ? Theme.text : Theme.chipText)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background {
                            if selection == segment {
                                RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.elevated)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == segment ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar view")
    }
}
