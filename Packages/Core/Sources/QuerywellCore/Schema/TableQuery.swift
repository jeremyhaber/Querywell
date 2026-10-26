import Foundation

public struct SortKey: Hashable, Sendable, Codable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// The data-grid query: one page of a table under the current chips, raw WHERE and sort.
public struct TableQuery: Hashable, Sendable {
    public var table: TableRef
    /// Columns to select; nil (or empty) selects `*`.
    public var columns: [String]?
    public var filter: FilterGroup?
    /// The WHERE bar text. **Intentionally not escaped or validated**: it is the user's own SQL, ANDed
    /// with the chips inside parentheses. Anything that must protect against writes (read-only mode, the
    /// PROD guard) has to look at the statement itself; a `SELECT … WHERE` can't write, but a raw clause
    /// like `1=1) OR (SELECT …` is still the user's responsibility.
    public var rawWhere: String?
    public var sort: [SortKey]
    public var limit: Int
    public var offset: Int
    /// Primary-key columns in key order. Appended to the ORDER BY (after the user's sort keys) so paging
    /// is deterministic; leave empty for tables without a primary key.
    public var primaryKey: [String]

    public init(
        table: TableRef, columns: [String]? = nil, filter: FilterGroup? = nil, rawWhere: String? = nil,
        sort: [SortKey] = [], limit: Int = 1000, offset: Int = 0, primaryKey: [String] = []
    ) {
        self.table = table
        self.columns = columns
        self.filter = filter
        self.rawWhere = rawWhere
        self.sort = sort
        self.limit = limit
        self.offset = offset
        self.primaryKey = primaryKey
    }

    /// `SELECT … FROM … [WHERE …] [ORDER BY …] LIMIT n [OFFSET m]`.
    public func sql(dialect: SQLDialect) -> String {
        let select: String
        if let columns, !columns.isEmpty {
            select = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
        } else {
            select = "*"
        }
        var out = "SELECT \(select) FROM \(dialect.qualified(table))"
        if let condition = whereSQL(dialect: dialect) { out += " WHERE \(condition)" }
        let order = orderBy(dialect: dialect)
        if !order.isEmpty { out += " ORDER BY \(order.joined(separator: ", "))" }
        out += dialect.limitClause(limit: max(limit, 0), offset: max(offset, 0))
        return out
    }

    /// `SELECT COUNT(*) FROM … [WHERE …]` with the same conditions.
    public func countSQL(dialect: SQLDialect) -> String {
        var out = "SELECT COUNT(*) FROM \(dialect.qualified(table))"
        if let condition = whereSQL(dialect: dialect) { out += " WHERE \(condition)" }
        return out
    }

    /// Chips AND (raw), or nil when neither contributes.
    func whereSQL(dialect: SQLDialect) -> String? {
        var parts: [String] = []
        if let chips = filter?.sql(dialect: dialect) { parts.append(chips) }
        if let raw = Self.cleanedRawWhere(rawWhere) {
            // The newline keeps a trailing `-- comment` in the raw text from swallowing the ")".
            parts.append("(\(raw)\n)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    private func orderBy(dialect: SQLDialect) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for key in sort where seen.insert(key.column.lowercased()).inserted {
            out.append(dialect.quoteIdentifier(key.column) + (key.ascending ? " ASC" : " DESC"))
        }
        for column in primaryKey where seen.insert(column.lowercased()).inserted {
            out.append(dialect.quoteIdentifier(column) + " ASC")
        }
        return out
    }

    /// Trims, drops a leading `WHERE` keyword and a trailing `;`; nil when nothing is left.
    static func cleanedRawWhere(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.range(of: #"^where\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}
