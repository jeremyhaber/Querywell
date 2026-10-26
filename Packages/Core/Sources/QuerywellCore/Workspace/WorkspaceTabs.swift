import Foundation

/// Colour role of a tab's leading dot in the design.
public enum TabAccent: Sendable, Hashable {
    /// Table tabs: the accent blue.
    case table
    /// Query tabs: purple.
    case query
    /// Console and terminal tabs: the primary text colour.
    case console
}

/// A user-chosen colour for one tab (tab context menu > Color). The app maps each case to theme tokens.
public enum TabColor: String, Codable, Sendable, Hashable, CaseIterable {
    case red, orange, yellow, green, blue, purple

    /// Menu title.
    public var displayName: String { rawValue.capitalized }
}

/// What a single click on a table in the sidebar does (Settings > General).
public enum TableClickBehaviour: String, Codable, Sendable, Hashable, CaseIterable {
    /// Opens in the window's one preview tab, replacing the table shown there.
    case preview
    /// Always opens a new tab.
    case newTab
    /// Focuses the table's existing tab, else opens a new one.
    case reuseExisting
}

/// One tab in a connection window.
public struct WorkspaceTab: Identifiable, Hashable, Sendable, Codable {
    /// What the tab shows.
    public enum Kind: Hashable, Sendable, Codable {
        case table(database: String, name: String)
        case query(number: Int)
        case console
        case terminal

        /// Dot colour role for this kind.
        public var accent: TabAccent {
            switch self {
            case .table: .table
            case .query: .query
            case .console, .terminal: .console
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// Has unsaved content (shown as a dot / used for close confirmation).
    public var isDirty: Bool
    /// Query tabs: the editor text, kept so it survives a window restore. Nil for other kinds.
    public var queryText: String?
    /// Query tabs opened from (or saved as) a saved query.
    public var savedQueryID: UUID?
    /// A preview tab (italic title) that the next single-click on a table replaces. Table tabs only.
    public var isPreview: Bool
    /// The user's colour for this tab, if any.
    public var color: TabColor?

    public init(id: UUID = UUID(), kind: Kind, title: String, isDirty: Bool = false,
                queryText: String? = nil, savedQueryID: UUID? = nil, isPreview: Bool = false, color: TabColor? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isDirty = isDirty
        self.queryText = queryText
        self.savedQueryID = savedQueryID
        self.isPreview = isPreview
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, isDirty, queryText, savedQueryID, isPreview, color
    }

    /// Tolerant: `isPreview` and `color` are absent in older data, and an unknown colour is dropped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        queryText = try c.decodeIfPresent(String.self, forKey: .queryText)
        savedQueryID = try c.decodeIfPresent(UUID.self, forKey: .savedQueryID)
        let preview = try c.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
        if case .table = kind { isPreview = preview } else { isPreview = false }
        color = (try? c.decodeIfPresent(TabColor.self, forKey: .color)) ?? nil
    }

    /// Dot colour role for this tab.
    public var accent: TabAccent { kind.accent }
}

/// The ordered tabs of one connection window, and which is selected. A plain value type so
/// a window can persist and restore it (`Codable`).
public struct WorkspaceTabs: Hashable, Sendable, Codable {
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var selectedID: WorkspaceTab.ID?
    /// Next "Query N" number; only ever increases, so numbers are never reused after closing.
    public private(set) var nextQueryNumber: Int

    public init() {
        tabs = []
        selectedID = nil
        nextQueryNumber = 1
    }

    /// Titles in tab order.
    public var titles: [String] { tabs.map(\.title) }

    /// The selected tab, if any.
    public var selectedTab: WorkspaceTab? { selectedID.flatMap(tab(id:)) }

    /// The tab with this id.
    public func tab(id: WorkspaceTab.ID) -> WorkspaceTab? { tabs.first { $0.id == id } }

    // MARK: Opening

    /// What opening a table did: the tab to show, and the preview tab it replaced (so the caller can
    /// drop that tab's data model).
    public struct OpenResult: Equatable, Sendable {
        public var id: WorkspaceTab.ID
        public var replacedID: WorkspaceTab.ID?
    }

    /// Opens a table. `forceNewTab` (command-click, "Open in New Tab") always appends a kept tab, even
    /// when the table is already open. Otherwise `behaviour` decides: preview reuses the table's tab if
    /// open, else replaces the (clean) preview tab in place, else appends a new preview tab; reuse
    /// focuses the table's tab or appends a kept one; newTab always appends a kept tab.
    @discardableResult
    public mutating func openTable(
        database: String, name: String, behaviour: TableClickBehaviour = .reuseExisting, forceNewTab: Bool = false
    ) -> OpenResult {
        let kind = WorkspaceTab.Kind.table(database: database, name: name)
        if forceNewTab || behaviour == .newTab {
            return OpenResult(id: append(WorkspaceTab(kind: kind, title: name)), replacedID: nil)
        }
        if let existing = tabs.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            return OpenResult(id: existing.id, replacedID: nil)
        }
        guard behaviour == .preview else { return OpenResult(id: append(WorkspaceTab(kind: kind, title: name)), replacedID: nil) }
        let fresh = WorkspaceTab(kind: kind, title: name, isPreview: true)
        if let i = tabs.firstIndex(where: { $0.isPreview && !$0.isDirty }) {
            let old = tabs[i].id
            tabs[i] = fresh
            selectedID = fresh.id
            return OpenResult(id: fresh.id, replacedID: old)
        }
        return OpenResult(id: append(fresh), replacedID: nil)
    }

    private mutating func append(_ tab: WorkspaceTab) -> WorkspaceTab.ID {
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    /// Turns a preview tab into a normal one (double-click, edit, filter or sort change).
    public mutating func keep(id: WorkspaceTab.ID) {
        if let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].isPreview { tabs[i].isPreview = false }
    }

    /// Tabs showing this table, in tab order (several are allowed).
    public func tabs(database: String, name: String) -> [WorkspaceTab] {
        tabs.filter { $0.kind == .table(database: database, name: name) }
    }

    /// Appends and selects "Query N"; N is one higher than every query number used so far.
    @discardableResult
    public mutating func newQuery() -> WorkspaceTab.ID {
        let number = nextQueryNumber
        nextQueryNumber += 1
        return open(kind: .query(number: number), title: "Query \(number)", reuseExisting: false)
    }

    /// Selects the console tab, creating it if there is none (at most one console).
    /// Opens a query tab for a saved query: focuses the tab already showing it, otherwise a new one
    /// titled with the query's name.
    @discardableResult
    public mutating func openSavedQuery(id: UUID, name: String, sql: String) -> WorkspaceTab.ID {
        if let existing = tabs.first(where: { $0.savedQueryID == id }) {
            selectedID = existing.id
            return existing.id
        }
        let number = nextQueryNumber
        nextQueryNumber += 1
        let tab = WorkspaceTab(kind: .query(number: number), title: name, queryText: sql, savedQueryID: id)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    /// Opens a new query tab pre-filled with `text` (history "open in new tab").
    @discardableResult
    public mutating func newQuery(text: String) -> WorkspaceTab.ID {
        let id = newQuery()
        setQueryText(id: id, text)
        return id
    }

    @discardableResult
    public mutating func openConsole() -> WorkspaceTab.ID {
        open(kind: .console, title: "Console", reuseExisting: true)
    }

    /// Appends and selects a new terminal tab (several terminals are allowed).
    @discardableResult
    public mutating func openTerminal() -> WorkspaceTab.ID {
        open(kind: .terminal, title: "Terminal", reuseExisting: false)
    }

    private mutating func open(kind: WorkspaceTab.Kind, title: String, reuseExisting: Bool) -> WorkspaceTab.ID {
        if reuseExisting, let existing = tabs.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            return existing.id
        }
        let tab = WorkspaceTab(kind: kind, title: title)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    // MARK: Closing

    /// Closes a tab. If it was selected, selection moves to its right neighbour, else its
    /// left neighbour, else nothing. Unknown ids are ignored.
    public mutating func close(id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard selectedID == id else { return }
        if index < tabs.count {
            selectedID = tabs[index].id
        } else {
            selectedID = tabs.last?.id
        }
    }

    /// Closes every tab except `id` and selects it. Unknown ids are ignored.
    public mutating func closeOthers(id: WorkspaceTab.ID) {
        guard let keep = tab(id: id) else { return }
        tabs = [keep]
        selectedID = id
    }

    // MARK: Selection

    /// Selects a tab. Unknown ids are ignored.
    public mutating func select(id: WorkspaceTab.ID) {
        if tabs.contains(where: { $0.id == id }) { selectedID = id }
    }

    /// Selects the next tab, wrapping from last to first (⌃Tab). With nothing selected,
    /// selects the first tab.
    public mutating func selectNext() { step(by: 1) }

    /// Selects the previous tab, wrapping from first to last (⌃⇧Tab). With nothing
    /// selected, selects the last tab.
    public mutating func selectPrevious() { step(by: -1) }

    private mutating func step(by delta: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = selectedID.flatMap({ id in tabs.firstIndex { $0.id == id } }) else {
            selectedID = (delta > 0 ? tabs.first : tabs.last)?.id
            return
        }
        selectedID = tabs[(current + delta + tabs.count) % tabs.count].id
    }

    // MARK: Editing

    /// Marks a tab as having (or not having) unsaved content.
    /// A dirty tab is never a preview tab, so it can't be replaced.
    public mutating func setDirty(id: WorkspaceTab.ID, _ dirty: Bool) {
        if let i = tabs.firstIndex(where: { $0.id == id }) {
            tabs[i].isDirty = dirty
            if dirty { tabs[i].isPreview = false }
        }
    }

    /// Sets (or clears) a tab's colour.
    public mutating func setColor(id: WorkspaceTab.ID, _ color: TabColor?) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].color = color }
    }

    /// Ids of every tab except `id`, in tab order.
    public func ids(except id: WorkspaceTab.ID) -> [WorkspaceTab.ID] { tabs.map(\.id).filter { $0 != id } }

    /// Ids of the tabs after `id`, in tab order (empty for an unknown id).
    public func ids(after id: WorkspaceTab.ID) -> [WorkspaceTab.ID] {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        return tabs[(i + 1)...].map(\.id)
    }

    /// Whether a tab can be duplicated (everything but the single console).
    public func canDuplicate(id: WorkspaceTab.ID) -> Bool {
        guard let tab = tab(id: id) else { return false }
        return tab.kind != .console
    }

    /// Inserts a copy right after `id` and selects it: a table tab shows the same table (kept, same
    /// colour), a query tab gets the next "Query N" with the same text, a terminal another terminal.
    /// Returns nil for the console or an unknown id.
    @discardableResult
    public mutating func duplicate(id: WorkspaceTab.ID) -> WorkspaceTab.ID? {
        guard let i = tabs.firstIndex(where: { $0.id == id }), canDuplicate(id: id) else { return nil }
        let source = tabs[i]
        var copy = WorkspaceTab(kind: source.kind, title: source.title, color: source.color)
        if case .query = source.kind {
            let number = nextQueryNumber
            nextQueryNumber += 1
            copy.kind = .query(number: number)
            copy.title = source.savedQueryID == nil ? "Query \(number)" : source.title
            copy.queryText = source.queryText
        }
        tabs.insert(copy, at: i + 1)
        selectedID = copy.id
        return copy.id
    }

    /// Reorders tabs with the same semantics as SwiftUI's `onMove`: `offset` is a position
    /// in the array *before* removal. Selection follows the tab, not the position.
    public mutating func setQueryText(id: WorkspaceTab.ID, _ text: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].queryText != text { tabs[i].queryText = text }
    }

    public mutating func rename(id: WorkspaceTab.ID, to title: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].title = title }
    }

    /// Points a table tab at another table (after a rename or move); the title follows the new name.
    public mutating func retargetTable(id: WorkspaceTab.ID, database: String, name: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), case .table = tabs[i].kind else { return }
        tabs[i].kind = .table(database: database, name: name)
        tabs[i].title = name
    }

    /// Links (or unlinks) a query tab to a saved query; a linked tab takes the saved query's name.
    public mutating func link(id: WorkspaceTab.ID, savedQueryID: UUID?, title: String? = nil) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].savedQueryID = savedQueryID
        if let title { tabs[i].title = title }
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset offset: Int) {
        let valid = source.filter { tabs.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { tabs[$0] }
        let before = valid.filter { $0 < offset }.count
        for i in valid.reversed() { tabs.remove(at: i) }
        let destination = min(max(offset - before, 0), tabs.count)
        tabs.insert(contentsOf: moving, at: destination)
    }

    // MARK: Codable (tolerant)

    private enum CodingKeys: String, CodingKey { case tabs, selectedID, nextQueryNumber }

    /// Tolerant: a stale `selectedID` is dropped, and `nextQueryNumber` is never lower than
    /// the highest restored query number + 1.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([WorkspaceTab].self, forKey: .tabs) ?? []
        tabs = decoded
        let selected = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
        selectedID = decoded.contains { $0.id == selected } ? selected : nil
        let highest = decoded.compactMap { tab -> Int? in
            if case .query(let n) = tab.kind { return n }
            return nil
        }.max() ?? 0
        nextQueryNumber = max(try c.decodeIfPresent(Int.self, forKey: .nextQueryNumber) ?? 1, highest + 1, 1)
    }
}
