import Foundation

/// Keyset ("seek") paging for the table grid: instead of `OFFSET n` (which walks and discards n rows) the
/// next page is `WHERE (sort cols, pk) > (last row's values) ORDER BY … LIMIT n`, served straight from an
/// index. Previous and "last page" run the same query in reverse order and flip the rows afterwards.
public struct KeysetPage: Hashable, Sendable {
    public enum Direction: Sendable, Hashable { case forward, backward }

    /// The total order of the page: the user's sort keys followed by the remaining primary-key columns,
    /// all in the same direction.
    public var order: [SortKey]
    public var direction: Direction
    /// Values of `order` in the row to continue from (the last row of the previous page for `.forward`,
    /// the first row of the current page for `.backward`); nil = start at the very beginning / end.
    public var boundary: [DatabaseValue]?

    public init(order: [SortKey], direction: Direction = .forward, boundary: [DatabaseValue]? = nil) {
        self.order = order
        self.direction = direction
        self.boundary = boundary
    }

    /// `ORDER BY` terms as run on the server (reversed for `.backward`).
    func orderTerms(dialect: SQLDialect) -> [String] {
        order.map { key in
            let ascending = (direction == .forward) == key.ascending
            return dialect.quoteIdentifier(key.column) + (ascending ? " ASC" : " DESC")
        }
    }

    /// The seek predicate, written out as `(a > x OR (a = x AND b > y))` so every engine can use the index.
    /// nil without a boundary or when the boundary doesn't match the order.
    func condition(dialect: SQLDialect) -> String? {
        guard let boundary, boundary.count == order.count, !order.isEmpty else { return nil }
        var terms: [String] = []
        for i in order.indices {
            var parts: [String] = []
            for j in 0..<i {
                parts.append("\(dialect.quoteIdentifier(order[j].column)) = \(dialect.literal(boundary[j]))")
            }
            let greater = (direction == .forward) == order[i].ascending
            parts.append("\(dialect.quoteIdentifier(order[i].column)) \(greater ? ">" : "<") \(dialect.literal(boundary[i]))")
            terms.append("(" + parts.joined(separator: " AND ") + ")")
        }
        return "(" + terms.joined(separator: " OR ") + ")"
    }
}

extension TableStructure {
    /// The keyset order for `sort`, or nil when the grid must page with `OFFSET`.
    ///
    /// Eligible when the table has a primary key and the sort (possibly empty) is index-served and
    /// unambiguous: one direction throughout, the sort columns are a prefix of the columns of some index (so
    /// the server doesn't sort 1M rows), every key column is NOT NULL and has a type whose `>` agrees with
    /// its `ORDER BY` (integers, decimals, dates/times, short text — not enums, floats, JSON, blobs, which
    /// compare differently from how they sort or can't be written back as a literal).
    public func keysetOrder(for sort: [SortKey]) -> [SortKey]? {
        let pk = primaryKey
        guard !pk.isEmpty else { return nil }
        let direction = sort.first?.ascending ?? true
        guard sort.allSatisfy({ $0.ascending == direction }) else { return nil }

        func column(_ name: String) -> ColumnDefinition? { columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        func usable(_ definition: ColumnDefinition) -> Bool {
            guard !definition.isNullable || definition.isPrimaryKey else { return false }
            let type = definition.dataType.lowercased()
            if ["float", "double", "real", "float4", "float8", "double precision", "bit", "money"].contains(where: { type.hasPrefix($0) }) { return false }
            switch ColumnKind.classify(dataType: type) {
            case .integer, .decimal, .date, .time, .dateTime, .text, .uuid: return true
            default: return false
            }
        }

        var seen = Set<String>()
        var order: [SortKey] = []
        for key in sort where seen.insert(key.column.lowercased()).inserted {
            guard let definition = column(key.column), usable(definition) else { return nil }
            order.append(SortKey(column: definition.name, ascending: direction))
        }
        // The sort columns, in order, must lead some index (the primary key counts).
        if !order.isEmpty {
            let wanted = order.map { $0.column.lowercased() }
            let served = indexes.contains { index in
                (index.method ?? "").uppercased() != "FULLTEXT" && (index.method ?? "").uppercased() != "SPATIAL"
                    && index.predicate == nil && index.columns.count >= wanted.count
                    && Array(index.columns.prefix(wanted.count)).map({ $0.lowercased() }) == wanted
            }
            guard served else { return nil }
        }
        for name in pk where seen.insert(name.lowercased()).inserted {
            guard let definition = column(name), usable(definition) else { return nil }
            order.append(SortKey(column: definition.name, ascending: direction))
        }
        return order
    }
}
