import Foundation

/// Built-in commands offered by the quick switcher.
public enum QuickAction: String, Sendable, Hashable, CaseIterable {
    case newQuery
    case newConsole
    case openHealth
    case openConnections
    case settings

    /// User-facing title.
    public var title: String {
        switch self {
        case .newQuery: "New Query"
        case .newConsole: "New Console"
        case .openHealth: "Database Health & Doctor"
        case .openConnections: "Open Connections"
        case .settings: "Settings"
        }
    }
}

/// Something the quick switcher (⌘K / ⌘P) can jump to.
public enum QuickSwitcherItem: Hashable, Sendable {
    case connection(UUID, name: String, tag: ColorTag?)
    case openTab(WorkspaceTab.ID, title: String)
    case table(database: String, name: String)
    case action(QuickAction)
    case savedQuery(UUID, name: String)

    /// The text that is fuzzy-matched and shown as the row title.
    public var title: String {
        switch self {
        case .connection(_, let name, _): name
        case .openTab(_, let title): title
        case .table(_, let name): name
        case .action(let action): action.title
        case .savedQuery(_, let name): "Saved: \(name)"
        }
    }

    /// Secondary text: the database for tables, nil otherwise.
    public var subtitle: String? {
        if case .table(let database, _) = self { return database }
        return nil
    }

    /// Display grouping and tie-break order.
    public var category: QuickSwitcherCategory {
        switch self {
        case .openTab: .openTab
        case .table: .table
        case .connection: .connection
        case .action: .action
        case .savedQuery: .savedQuery
        }
    }
}

/// Section of the quick switcher, in display priority order.
public enum QuickSwitcherCategory: Int, Sendable, Hashable, Comparable, CaseIterable {
    case openTab, table, savedQuery, connection, action

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Section heading.
    public var heading: String {
        switch self {
        case .openTab: "Open Tabs"
        case .table: "Tables"
        case .savedQuery: "Saved Queries"
        case .connection: "Connections"
        case .action: "Actions"
        }
    }
}

/// One row of quick switcher output.
public struct QuickSwitcherResult: Sendable, Hashable {
    public var item: QuickSwitcherItem
    /// Match against ``QuickSwitcherItem/title`` (indices index into that string).
    public var match: FuzzyMatch
}

/// Ranking for the quick switcher.
public enum QuickSwitcher {
    /// Scores within the same band of this width count as a tie, so category order decides.
    public static let scoreBand = 12

    /// Fuzzy-filters `items` by title and orders them.
    ///
    /// Order: higher score band first (`score / scoreBand`); within a band by category
    /// (open tabs, tables, connections, actions); then by score; then original order.
    /// An empty query returns everything grouped by category in original order.
    public static func results(query: String, items: [QuickSwitcherItem], limit: Int) -> [QuickSwitcherResult] {
        guard limit > 0 else { return [] }
        var rows: [(offset: Int, result: QuickSwitcherResult)] = []
        for (offset, item) in items.enumerated() {
            if let match = FuzzyMatcher.score(query: query, candidate: item.title) {
                rows.append((offset, QuickSwitcherResult(item: item, match: match)))
            }
        }
        rows.sort { a, b in
            let (ba, bb) = (a.result.match.score / scoreBand, b.result.match.score / scoreBand)
            if ba != bb { return ba > bb }
            let (ca, cb) = (a.result.item.category, b.result.item.category)
            if ca != cb { return ca < cb }
            if a.result.match.score != b.result.match.score { return a.result.match.score > b.result.match.score }
            return a.offset < b.offset
        }
        return rows.prefix(limit).map(\.result)
    }
}
