import Foundation

/// One row of the database navigator popover.
public struct DatabaseListEntry: Sendable, Hashable, Identifiable {
    public var name: String
    /// Matched characters of `name` for highlighting (empty without a query).
    public var matchedIndices: [String.Index]
    /// Server-internal database (`information_schema`, `template0`, …), listed after the user's own.
    public var isSystem: Bool

    public var id: String { name }

    public init(name: String, matchedIndices: [String.Index] = [], isSystem: Bool = false) {
        self.name = name
        self.matchedIndices = matchedIndices
        self.isSystem = isSystem
    }
}

/// Filtering and keyboard navigation for the database list.
public enum DatabaseList {
    /// Rows for `query`. Without a query: user databases by name, then system ones. With a query:
    /// fuzzy matches, best first; equal scores keep the user-first name order.
    public static func entries(names: [String], query: String, engine: DatabaseEngine) -> [DatabaseListEntry] {
        let base = names
            .map { DatabaseListEntry(name: $0, isSystem: DatabaseSelection.isSystemDatabase($0, engine: engine)) }
            .sorted { a, b in
                if a.isSystem != b.isSystem { return !a.isSystem }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return base }
        return FuzzyMatcher.rank(base, query: trimmed, key: { $0.name }, limit: .max).map { entry, match in
            var copy = entry
            copy.matchedIndices = match.matchedIndices
            return copy
        }
    }

    /// The highlighted row after pressing ↑ (`delta` -1) or ↓ (+1). No wrap-around; with nothing
    /// highlighted ↓ picks the first row and ↑ the last. `nil` when the list is empty.
    public static func move(from index: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta >= 0 ? 0 : count - 1 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Keeps a highlighted row valid after the list changed: the same name when still present, else the first row.
    public static func reconcile(selected: String?, in entries: [DatabaseListEntry]) -> String? {
        if let selected, entries.contains(where: { $0.name == selected }) { return selected }
        return entries.first?.name
    }
}

/// What the window title and header call a connection window.
public enum DatabaseWindowTitle {
    /// "connection · database"; just the connection name while no database is known.
    public static func make(connection: String, database: String?) -> String {
        guard let database, !database.isEmpty else { return connection }
        return "\(connection) · \(database)"
    }
}
