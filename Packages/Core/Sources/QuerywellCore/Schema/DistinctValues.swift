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
    /// Non-nil when the exact query ran out of time and the counts come from roughly this many rows
    /// ("Based on a sample of 100k rows").
    public var sampledRows: Int?

    public init(values: [DistinctValue], isTruncated: Bool, sampledRows: Int? = nil) {
        self.values = values
        self.isTruncated = isTruncated
        self.sampledRows = sampledRows
    }
}

/// How the funnel popover bounds a distinct-values query on big tables.
public struct DistinctValuesPolicy: Hashable, Sendable {
    /// The exact GROUP BY is aborted by the server after this long.
    public var timeout: Duration
    /// Size of the fallback sample.
    public var sampleRows: Int
    /// Table size estimate (for Postgres' `TABLESAMPLE SYSTEM` percentage); nil samples with a LIMIT subquery.
    public var estimatedRows: Int64?

    public init(timeout: Duration = .milliseconds(1500), sampleRows: Int = 100_000, estimatedRows: Int64? = nil) {
        self.timeout = timeout
        self.sampleRows = sampleRows
        self.estimatedRows = estimatedRows
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

    enum Source: Equatable {
        case table
        /// The first N rows (after the filters), counted instead of the whole table.
        case limitSample(Int)
        /// Postgres `TABLESAMPLE SYSTEM (percent)`, filters applied to the sampled blocks.
        case tableSample(percent: Double)
    }

    /// Fetches `limit + 1` groups so truncation can be detected; ordered by count desc, then value (NULL last).
    public func sql(dialect: SQLDialect) -> String { sql(dialect: dialect, source: .table) }

    func sql(dialect: SQLDialect, source: Source) -> String {
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
        let where_ = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        var out: String
        switch source {
        case .table:
            out = "SELECT \(col) AS qw_value, COUNT(*) AS qw_count FROM \(dialect.qualified(table))" + where_
        case .limitSample(let rows):
            // The WHERE (and search) belong inside the sample so it holds matching rows only.
            out = "SELECT qw_value, COUNT(*) AS qw_count FROM (SELECT \(col) AS qw_value FROM \(dialect.qualified(table))"
                + where_ + " LIMIT \(max(rows, 1))) AS qw_sample"
        case .tableSample(let percent):
            let p = String(format: "%.4f", min(max(percent, 0.0001), 100))
            out = "SELECT \(col) AS qw_value, COUNT(*) AS qw_count FROM \(dialect.qualified(table)) TABLESAMPLE SYSTEM (\(p))" + where_
        }
        var groupColumn = col
        if case .limitSample = source { groupColumn = "qw_value" }
        // NULL sorts last among equal counts on both engines (MySQL would put it first, Postgres last).
        out += " GROUP BY \(groupColumn) ORDER BY qw_count DESC, (\(groupColumn) IS NULL) ASC, \(groupColumn) ASC"
        out += dialect.limitClause(limit: max(limit, 1) + 1, offset: 0)
        return out
    }

    public func run(on session: any DatabaseSession) async throws -> DistinctValuesResult {
        let result = try await session.execute(sql(dialect: SQLDialect(session.engine)))
        return Self.result(from: result, limit: limit, sampledRows: nil)
    }

    /// Runs the exact query under a server-side time limit; when it is exceeded, counts a sample instead
    /// (`sampledRows` is then set). **`session` must not be shared**: Postgres' limit is a `SET LOCAL`
    /// inside a transaction, so another statement interleaved on the same connection would inherit it.
    /// MySQL uses the `MAX_EXECUTION_TIME` hint, MariaDB `SET STATEMENT max_statement_time`.
    public func run(on session: any DatabaseSession, policy: DistinctValuesPolicy) async throws -> DistinctValuesResult {
        let dialect = SQLDialect(session.engine)
        let seconds = Double(policy.timeout.components.seconds) + Double(policy.timeout.components.attoseconds) / 1e18
        do {
            let exact = try await Self.executeLimited(sql(dialect: dialect), seconds: seconds, session: session)
            return Self.result(from: exact, limit: limit, sampledRows: nil)
        } catch let error as DatabaseError where error.isTimeout {
            let source: Source
            if dialect.family == .postgres, let estimate = policy.estimatedRows, estimate > Int64(policy.sampleRows) {
                source = .tableSample(percent: Double(policy.sampleRows) / Double(estimate) * 100)
            } else {
                source = .limitSample(policy.sampleRows)
            }
            let sampled = try await Self.executeLimited(sql(dialect: dialect, source: source), seconds: max(seconds * 4, 5), session: session)
            return Self.result(from: sampled, limit: limit, sampledRows: policy.sampleRows)
        }
    }

    private static func executeLimited(_ sql: String, seconds: Double, session: any DatabaseSession) async throws -> QueryResult {
        let millis = max(Int(seconds * 1000), 1)
        switch session.engine {
        case .mysql:
            let hinted = sql.replacingOccurrences(of: "SELECT ", with: "SELECT /*+ MAX_EXECUTION_TIME(\(millis)) */ ", options: [.anchored])
            return try await session.execute(hinted, interruptible: true)
        case .mariadb:
            return try await session.execute("SET STATEMENT max_statement_time=\(String(format: "%.3f", seconds)) FOR \(sql)", interruptible: true)
        case .postgresql:
            _ = try await session.execute("BEGIN")
            do {
                _ = try await session.execute("SET LOCAL statement_timeout = \(millis)")
                let result = try await session.execute(sql, interruptible: true)
                _ = try await session.execute("COMMIT")
                return result
            } catch {
                _ = try? await session.execute("ROLLBACK")
                throw error
            }
        }
    }

    private static func result(from result: QueryResult, limit: Int, sampledRows: Int?) -> DistinctValuesResult {
        let cap = max(limit, 1)
        var values: [DistinctValue] = []
        for row in result.rows where row.count >= 2 {
            values.append(DistinctValue(value: row[0], count: Record.int(from: row[1]) ?? 0))
        }
        let truncated = values.count > cap
        return DistinctValuesResult(values: Array(values.prefix(cap)), isTruncated: truncated, sampledRows: sampledRows)
    }
}
