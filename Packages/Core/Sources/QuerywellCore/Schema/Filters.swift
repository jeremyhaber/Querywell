import Foundation

// Column funnel / filter-chip model for the data grid. Pure value types; SQL comes from `SQLDialect`.

// MARK: - DatabaseValue persistence

/// `DatabaseValue` is persisted inside saved filters, so it gets a stable, self-describing coding:
/// `{"t":"int","v":5}`, `{"t":"text","v":"x"}`, `{"t":"bytes","v":"<base64>"}`, `{"t":"null"}`.
extension DatabaseValue: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "null": self = .null
        case "int": self = .integer(try c.decode(Int64.self, forKey: .v))
        case "uint": self = .unsignedInteger(try c.decode(UInt64.self, forKey: .v))
        case "double": self = .double(try c.decode(Double.self, forKey: .v))
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "text": self = .text(try c.decode(String.self, forKey: .v))
        case "bytes":
            guard let data = Data(base64Encoded: try c.decode(String.self, forKey: .v)) else {
                throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "Invalid base64")
            }
            self = .bytes(data)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "Unknown value type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try c.encode("null", forKey: .t)
        case .integer(let v): try c.encode("int", forKey: .t); try c.encode(v, forKey: .v)
        case .unsignedInteger(let v): try c.encode("uint", forKey: .t); try c.encode(v, forKey: .v)
        case .double(let v):
            // JSON can't carry NaN/Infinity; keep those as text.
            if v.isFinite {
                try c.encode("double", forKey: .t); try c.encode(v, forKey: .v)
            } else {
                try c.encode("text", forKey: .t); try c.encode(String(v), forKey: .v)
            }
        case .bool(let v): try c.encode("bool", forKey: .t); try c.encode(v, forKey: .v)
        case .text(let v): try c.encode("text", forKey: .t); try c.encode(v, forKey: .v)
        case .bytes(let v): try c.encode("bytes", forKey: .t); try c.encode(v.base64EncodedString(), forKey: .v)
        }
    }
}

// MARK: - Operators

public enum FilterOperator: Hashable, Sendable, Codable {
    case isAnyOf([DatabaseValue])
    case isNoneOf([DatabaseValue])
    case equals(DatabaseValue)
    case notEquals(DatabaseValue)
    case contains(String)
    case notContains(String)
    case startsWith(String)
    case endsWith(String)
    /// NULL or the empty string.
    case isEmpty
    case isNotEmpty
    case isNull
    case isNotNull
    case greaterThan(DatabaseValue)
    case lessThan(DatabaseValue)
    case between(DatabaseValue, DatabaseValue)
    /// `from` inclusive, `to` exclusive; ISO-8601 strings (`2026-09-26`, `2026-09-26 10:00:00`). Either may be nil.
    case dateRange(from: String?, to: String?)
    /// MySQL `REGEXP`, Postgres `~`.
    case regex(String)
}

public struct ColumnFilter: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var column: String
    public var op: FilterOperator
    public var isEnabled: Bool

    public init(id: UUID = UUID(), column: String, op: FilterOperator, isEnabled: Bool = true) {
        self.id = id
        self.column = column
        self.op = op
        self.isEnabled = isEnabled
    }

    /// The SQL predicate for this filter alone, or nil when it constrains nothing
    /// (a `dateRange` with neither bound). Ignores `isEnabled`; ``FilterGroup`` applies that.
    ///
    /// Semantics worth knowing:
    /// - "negative" operators (`notEquals`, `isNoneOf`, `notContains`) are NULL-safe: rows whose column is
    ///   NULL are *included*, which matches what a person means by "is not X".
    /// - `contains`/`startsWith`/`endsWith` escape `%`, `_` and `\` and add `ESCAPE '\\'`. Postgres uses
    ///   `ILIKE` on `col::text` (case-insensitive); MySQL uses `LIKE`, whose case sensitivity follows the
    ///   column's collation (the default `_ci` collations are case-insensitive).
    /// - `isEmpty`/`isNotEmpty` compare the column *as text*, so `0` in an integer column isn't "empty"
    ///   (MySQL would otherwise coerce `0 = ''` to true).
    public func sql(dialect: SQLDialect) -> String? {
        let col = dialect.quoteIdentifier(column)
        let isPG = dialect.family == .postgres
        let text = isPG ? "\(col)::text" : "CAST(\(col) AS CHAR)"
        func lit(_ v: DatabaseValue) -> String { dialect.literal(v) }

        func like(_ pattern: String, negate: Bool) -> String {
            let escaped = dialect.quoteString(pattern)
            let escapeClause = isPG ? "ESCAPE E'\\\\'" : "ESCAPE '\\\\'"
            let operatorSQL = (isPG ? "ILIKE" : "LIKE")
            let core = "\(isPG ? text : col) \(negate ? "NOT " : "")\(operatorSQL) \(escaped) \(escapeClause)"
            return negate ? "(\(col) IS NULL OR \(core))" : core
        }

        switch op {
        case .isAnyOf(let values):
            let nonNull = values.filter { !$0.isNull }
            let hasNull = nonNull.count != values.count
            if values.isEmpty { return "1 = 0" }
            if nonNull.isEmpty { return "\(col) IS NULL" }
            let list = "\(col) IN (\(nonNull.map(lit).joined(separator: ", ")))"
            return hasNull ? "(\(list) OR \(col) IS NULL)" : list
        case .isNoneOf(let values):
            let nonNull = values.filter { !$0.isNull }
            let hasNull = nonNull.count != values.count
            if values.isEmpty { return "1 = 1" }
            if nonNull.isEmpty { return "\(col) IS NOT NULL" }
            let list = "\(col) NOT IN (\(nonNull.map(lit).joined(separator: ", ")))"
            return hasNull ? "(\(list) AND \(col) IS NOT NULL)" : "(\(list) OR \(col) IS NULL)"
        case .equals(let v):
            return v.isNull ? "\(col) IS NULL" : "\(col) = \(lit(v))"
        case .notEquals(let v):
            if v.isNull { return "\(col) IS NOT NULL" }
            return isPG ? "\(col) IS DISTINCT FROM \(lit(v))" : "NOT (\(col) <=> \(lit(v)))"
        case .contains(let s): return like("%" + dialect.escapeLikePattern(s) + "%", negate: false)
        case .notContains(let s): return like("%" + dialect.escapeLikePattern(s) + "%", negate: true)
        case .startsWith(let s): return like(dialect.escapeLikePattern(s) + "%", negate: false)
        case .endsWith(let s): return like("%" + dialect.escapeLikePattern(s), negate: false)
        case .isEmpty: return "(\(col) IS NULL OR \(text) = '')"
        case .isNotEmpty: return "(\(col) IS NOT NULL AND \(text) <> '')"
        case .isNull: return "\(col) IS NULL"
        case .isNotNull: return "\(col) IS NOT NULL"
        case .greaterThan(let v): return "\(col) > \(lit(v))"
        case .lessThan(let v): return "\(col) < \(lit(v))"
        case .between(let a, let b): return "\(col) BETWEEN \(lit(a)) AND \(lit(b))"
        case .dateRange(let from, let to):
            var parts: [String] = []
            if let from { parts.append("\(col) >= \(dialect.quoteString(from))") }
            if let to { parts.append("\(col) < \(dialect.quoteString(to))") }
            switch parts.count {
            case 0: return nil
            case 1: return parts[0]
            default: return "(\(parts.joined(separator: " AND ")))"
            }
        case .regex(let pattern):
            return isPG ? "\(text) ~ \(dialect.quoteString(pattern))" : "\(col) REGEXP \(dialect.quoteString(pattern))"
        }
    }

    /// Short text for the filter chip, e.g. `post_status is publish`, `post_modified ≥ 2026-09-26`.
    public var chipLabel: String {
        func v(_ value: DatabaseValue) -> String {
            switch value {
            case .null: "NULL"
            case .text(let s): s.isEmpty ? "\"\"" : s
            default: value.displayString
            }
        }
        func list(_ values: [DatabaseValue]) -> String {
            let shown = values.prefix(3).map(v).joined(separator: ", ")
            return values.count > 3 ? "\(shown) +\(values.count - 3) more" : shown
        }
        switch op {
        case .isAnyOf(let values):
            return values.count == 1 ? "\(column) is \(v(values[0]))" : "\(column) is any of \(list(values))"
        case .isNoneOf(let values):
            return values.count == 1 ? "\(column) is not \(v(values[0]))" : "\(column) is none of \(list(values))"
        case .equals(let x): return "\(column) is \(v(x))"
        case .notEquals(let x): return "\(column) is not \(v(x))"
        case .contains(let s): return "\(column) contains \(s)"
        case .notContains(let s): return "\(column) does not contain \(s)"
        case .startsWith(let s): return "\(column) starts with \(s)"
        case .endsWith(let s): return "\(column) ends with \(s)"
        case .isEmpty: return "\(column) is empty"
        case .isNotEmpty: return "\(column) is not empty"
        case .isNull: return "\(column) is NULL"
        case .isNotNull: return "\(column) is not NULL"
        case .greaterThan(let x): return "\(column) > \(v(x))"
        case .lessThan(let x): return "\(column) < \(v(x))"
        case .between(let a, let b): return "\(column) between \(v(a)) and \(v(b))"
        case .dateRange(let from, let to):
            switch (from, to) {
            case (let f?, let t?): return "\(column) ≥ \(f) and < \(t)"
            case (let f?, nil): return "\(column) ≥ \(f)"
            case (nil, let t?): return "\(column) < \(t)"
            case (nil, nil): return "\(column) any date"
            }
        case .regex(let p): return "\(column) matches /\(p)/"
        }
    }
}

public enum FilterCombinator: String, Sendable, Codable, Hashable, CaseIterable {
    case and, or

    var sql: String { self == .and ? "AND" : "OR" }
}

public struct FilterGroup: Hashable, Sendable, Codable {
    public var filters: [ColumnFilter]
    public var combinator: FilterCombinator

    public init(filters: [ColumnFilter] = [], combinator: FilterCombinator = .and) {
        self.filters = filters
        self.combinator = combinator
    }

    /// Enabled filters that actually constrain something.
    public var activeFilters: [ColumnFilter] { filters.filter(\.isEnabled) }

    public var isEmpty: Bool { filters.isEmpty }

    /// A predicate safe to AND with other conditions (wrapped in parentheses when it has several
    /// parts), or nil when nothing is active.
    public func sql(dialect: SQLDialect) -> String? {
        let parts = activeFilters.compactMap { $0.sql(dialect: dialect) }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return "(" + parts.map { "(\($0))" }.joined(separator: " \(combinator.sql) ") + ")"
        }
    }

    /// The same group without any filter on `column` (case-insensitive), used by the funnel popover
    /// so a column's own filter doesn't hide the values it could still offer.
    public func excluding(column: String) -> FilterGroup {
        var copy = self
        copy.filters.removeAll { $0.column.caseInsensitiveCompare(column) == .orderedSame }
        return copy
    }
}

// MARK: - Saved filters

public struct SavedFilter: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var table: TableRef
    public var group: FilterGroup
    /// The raw WHERE bar text (user SQL), if any.
    public var rawWhere: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, table: TableRef, group: FilterGroup = FilterGroup(),
        rawWhere: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.table = table
        self.group = group
        self.rawWhere = rawWhere
        self.createdAt = createdAt
    }
}

public enum SavedFiltersError: Error, Equatable, Sendable {
    case corruptFile(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// Saved filters, keyed per connection id and table, stored in one JSON file (`saved-filters.json`,
/// mode 0600, atomic writes). A mutation is applied to a copy and committed in memory only after the
/// write succeeds. An unreadable file is never overwritten.
public actor SavedFiltersStore {
    public static let currentSchemaVersion = 1

    struct Entry: Codable, Equatable {
        var connectionID: UUID
        var filter: SavedFilter
    }

    struct Document: Codable {
        var schemaVersion: Int
        var entries: [Entry]
    }

    private let fileURL: URL
    private var entries: [Entry] = []
    private var isLoaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Saved filters for one table of one connection, oldest first.
    public func filters(connectionID: UUID, table: TableRef) throws -> [SavedFilter] {
        try loadIfNeeded()
        return entries.filter { $0.connectionID == connectionID && $0.filter.table == table }
            .map(\.filter).sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    /// All saved filters of a connection (every table).
    public func filters(connectionID: UUID) throws -> [SavedFilter] {
        try loadIfNeeded()
        return entries.filter { $0.connectionID == connectionID }.map(\.filter)
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    /// Inserts, or replaces the filter with the same id.
    public func save(_ filter: SavedFilter, connectionID: UUID) throws {
        try loadIfNeeded()
        var next = entries
        if let index = next.firstIndex(where: { $0.connectionID == connectionID && $0.filter.id == filter.id }) {
            next[index].filter = filter
        } else {
            next.append(Entry(connectionID: connectionID, filter: filter))
        }
        try commit(next)
    }

    public func delete(id: UUID, connectionID: UUID) throws {
        try loadIfNeeded()
        try commit(entries.filter { !($0.connectionID == connectionID && $0.filter.id == id) })
    }

    /// Drops everything saved for a connection (e.g. when the connection is deleted).
    public func deleteAll(connectionID: UUID) throws {
        try loadIfNeeded()
        try commit(entries.filter { $0.connectionID != connectionID })
    }

    private func commit(_ next: [Entry]) throws {
        let data = try JSONFileStore.makeEncoder().encode(Document(schemaVersion: Self.currentSchemaVersion, entries: next))
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        entries = next
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            isLoaded = true
            return
        }
        let data = try Data(contentsOf: fileURL)
        struct Header: Decodable { var schemaVersion: Int }
        do {
            let decoder = JSONFileStore.makeDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.schemaVersion <= Self.currentSchemaVersion else {
                throw SavedFiltersError.unsupportedSchemaVersion(found: header.schemaVersion, supported: Self.currentSchemaVersion)
            }
            entries = try decoder.decode(Document.self, from: data).entries
            isLoaded = true
        } catch let error as SavedFiltersError {
            throw error
        } catch {
            throw SavedFiltersError.corruptFile(String(describing: error))
        }
    }
}
