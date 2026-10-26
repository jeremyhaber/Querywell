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

    public init(id: UUID = UUID(), kind: Kind, title: String, isDirty: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isDirty = isDirty
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

    /// Selects the existing tab for this table, or appends and selects a new one.
    @discardableResult
    public mutating func openTable(database: String, name: String) -> WorkspaceTab.ID {
        open(kind: .table(database: database, name: name), title: name, reuseExisting: true)
    }

    /// Appends and selects "Query N"; N is one higher than every query number used so far.
    @discardableResult
    public mutating func newQuery() -> WorkspaceTab.ID {
        let number = nextQueryNumber
        nextQueryNumber += 1
        return open(kind: .query(number: number), title: "Query \(number)", reuseExisting: false)
    }

    /// Selects the console tab, creating it if there is none (at most one console).
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
    public mutating func setDirty(id: WorkspaceTab.ID, _ dirty: Bool) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].isDirty = dirty }
    }

    /// Reorders tabs with the same semantics as SwiftUI's `onMove`: `offset` is a position
    /// in the array *before* removal. Selection follows the tab, not the position.
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
