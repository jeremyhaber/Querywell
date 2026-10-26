import Foundation

public struct DistinctValue: Hashable, Sendable {
    public var value: DatabaseValue
    public var count: Int64

    public init(value: DatabaseValue, count: Int64) {
        self.value = value
        self.count = count
    }
}

public struct DistinctValuesResult: Hashable, Sendable {
    public var values: [DistinctValue]
    /// True when more distinct values exist than `limit`.
    public var isTruncated: Bool

    public init(values: [DistinctValue], isTruncated: Bool) {
        self.values = values
        self.isTruncated = isTruncated
    }
}

/// The funnel popover's query: top-N distinct values of one column with row counts, under the
/// grid's current filters *except that column's own* (so choosing "publish" doesn't hide "draft").
public struct DistinctValuesQuery: Hashable, Sendable {
    public var table: TableRef
    public var column: String
    public var filter: FilterGroup?
    public var rawWhere: String?
    /// Substring search on the value cast to text (LIKE on MySQL, ILIKE on Postgres).
    public var search: String?
    public var limit: Int

    public init(
        table: TableRef, column: String, filter: FilterGroup? = nil, rawWhere: String? = nil,
        search: String? = nil, limit: Int = 100
    ) {
        self.table = table
        self.column = column
        self.filter = filter
        self.rawWhere = rawWhere
        self.search = search
        self.limit = limit
    }

    /// Fetches `limit + 1` groups so truncation can be detected; ordered by count desc, then value (NULL last).
    public func sql(dialect: SQLDialect) -> String {
        let col = dialect.quoteIdentifier(column)
        let isPG = dialect.family == .postgres
        let base = TableQuery(
            table: table, filter: filter?.excluding(column: column), rawWhere: rawWhere
        )
        var conditions: [String] = []
        if let existing = base.whereSQL(dialect: dialect) { conditions.append(existing) }
        if let search, !search.isEmpty {
            let pattern = dialect.quoteString("%" + dialect.escapeLikePattern(search) + "%")
            conditions.append(
                isPG
                    ? "\(col)::text ILIKE \(pattern) ESCAPE E'\\\\'"
                    : "CAST(\(col) AS CHAR) LIKE \(pattern) ESCAPE '\\\\'"
            )
        }
        var out = "SELECT \(col) AS qw_value, COUNT(*) AS qw_count FROM \(dialect.qualified(table))"
        if !conditions.isEmpty { out += " WHERE " + conditions.joined(separator: " AND ") }
        // NULL sorts last among equal counts on both engines (MySQL would put it first, Postgres last).
        out += " GROUP BY \(col) ORDER BY qw_count DESC, (\(col) IS NULL) ASC, \(col) ASC"
        out += dialect.limitClause(limit: max(limit, 1) + 1, offset: 0)
        return out
    }

    public func run(on session: any DatabaseSession) async throws -> DistinctValuesResult {
        let result = try await session.execute(sql(dialect: SQLDialect(session.engine)))
        let cap = max(limit, 1)
        var values: [DistinctValue] = []
        for row in result.rows where row.count >= 2 {
            values.append(DistinctValue(value: row[0], count: Record.int(from: row[1]) ?? 0))
        }
        let truncated = values.count > cap
        return DistinctValuesResult(values: Array(values.prefix(cap)), isTruncated: truncated)
    }
}
