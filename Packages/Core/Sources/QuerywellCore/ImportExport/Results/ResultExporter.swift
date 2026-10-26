import Foundation

// Export of query results / whole tables to CSV, JSON (array or JSON Lines) and SQL INSERT statements.

// MARK: - Sinks

/// Destination for exported bytes.
public protocol ByteSink: AnyObject {
    func write(_ data: Data) throws
    func close() throws
}

/// Writes to a `FileHandle` (a file, or a pipe).
public final class FileHandleSink: ByteSink {
    private let handle: FileHandle
    private let closesHandle: Bool

    public init(handle: FileHandle, closesHandle: Bool = false) {
        self.handle = handle
        self.closesHandle = closesHandle
    }

    /// Creates (truncating) the file at `url`.
    public convenience init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.init(handle: try FileHandle(forWritingTo: url), closesHandle: true)
    }

    public func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    public func close() throws { if closesHandle { try handle.close() } }
}

/// Collects output in memory (tests, small exports, clipboard).
public final class DataSink: ByteSink {
    public private(set) var data = Data()
    public init() {}
    public func write(_ data: Data) throws { self.data.append(data) }
    public func close() throws {}
    public var string: String { String(decoding: data, as: UTF8.self) }
}

// MARK: - Options

public enum BytesEncoding: Sendable, Equatable {
    /// `0x` followed by upper-case hex digits.
    case hex
    case base64
}

public struct CSVOptions: Sendable, Equatable {
    public enum NullRepresentation: Sendable, Equatable {
        /// NULL is an empty field. Empty strings are then written as `""` so they stay distinguishable.
        case empty
        /// MySQL's `\N` (what `LOAD DATA` and `SELECT … INTO OUTFILE` use).
        case backslashN
        case custom(String)
    }
    public enum LineEnding: Sendable, Equatable { case crlf, lf }

    public var delimiter: String
    public var includeHeader: Bool
    public var nullRepresentation: NullRepresentation
    public var bytesEncoding: BytesEncoding
    /// A UTF-8 byte-order mark so Excel opens the file as UTF-8.
    public var utf8BOM: Bool
    public var lineEnding: LineEnding
    /// `nil` = automatic: quote empty strings only when NULL is also written as an empty field.
    public var quoteEmptyStrings: Bool?
    public var quoteAllFields: Bool

    public init(delimiter: String = ",", includeHeader: Bool = true, nullRepresentation: NullRepresentation = .empty,
                bytesEncoding: BytesEncoding = .hex, utf8BOM: Bool = false, lineEnding: LineEnding = .crlf,
                quoteEmptyStrings: Bool? = nil, quoteAllFields: Bool = false) {
        self.delimiter = delimiter
        self.includeHeader = includeHeader
        self.nullRepresentation = nullRepresentation
        self.bytesEncoding = bytesEncoding
        self.utf8BOM = utf8BOM
        self.lineEnding = lineEnding
        self.quoteEmptyStrings = quoteEmptyStrings
        self.quoteAllFields = quoteAllFields
    }
}

public struct JSONExportOptions: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// `[` + one object per line + `]`
        case array
        /// One object per line, no brackets (JSON Lines / NDJSON).
        case lines
    }

    public var layout: Layout
    public var bytesEncoding: BytesEncoding
    /// Integers beyond ±2^53 are written as strings so JavaScript consumers don't silently round them.
    public var bigIntegersAsStrings: Bool
    /// JSON / JSONB columns are embedded as JSON values instead of strings (when the text parses).
    public var embedJSONColumns: Bool

    public init(layout: Layout = .array, bytesEncoding: BytesEncoding = .base64, bigIntegersAsStrings: Bool = true,
                embedJSONColumns: Bool = true) {
        self.layout = layout
        self.bytesEncoding = bytesEncoding
        self.bigIntegersAsStrings = bigIntegersAsStrings
        self.embedJSONColumns = embedJSONColumns
    }
}

public struct SQLInsertOptions: Sendable, Equatable {
    public var table: TableRef
    public var rowsPerStatement: Int
    public var includeColumnList: Bool

    public init(table: TableRef, rowsPerStatement: Int = 100, includeColumnList: Bool = true) {
        self.table = table
        self.rowsPerStatement = max(1, rowsPerStatement)
        self.includeColumnList = includeColumnList
    }
}

public enum ResultFormat: Sendable, Equatable {
    case csv(CSVOptions)
    case json(JSONExportOptions)
    case sqlInserts(SQLInsertOptions)

    public var fileExtension: String {
        switch self {
        case .csv(let o): o.delimiter == "\t" ? "tsv" : "csv"
        case .json(let o): o.layout == .lines ? "jsonl" : "json"
        case .sqlInserts: "sql"
        }
    }
}

// MARK: - Writer

/// Incremental writer: `begin` is implied by the first `write`, call `finish` at the end.
public final class ResultWriter {
    public let format: ResultFormat
    public let columns: [ColumnInfo]
    private let sink: any ByteSink
    private let dialect: SQLDialect
    private var buffer = Data()
    private var started = false
    private var finished = false
    private var pendingSQLRows: [String] = []
    public private(set) var rowsWritten = 0
    public private(set) var bytesWritten: Int64 = 0
    private let jsonKeys: [String]

    public init(format: ResultFormat, columns: [ColumnInfo], sink: any ByteSink, dialect: SQLDialect = SQLDialect(.mysql)) {
        self.format = format
        self.columns = columns
        self.sink = sink
        self.dialect = dialect
        var seen: [String: Int] = [:]
        jsonKeys = columns.map { c in
            let n = (seen[c.name] ?? 0) + 1
            seen[c.name] = n
            return n == 1 ? c.name : "\(c.name)_\(n)"
        }
    }

    public func write(rows: [[DatabaseValue]]) throws {
        try beginIfNeeded()
        for row in rows {
            try write(row: row)
            if buffer.count >= 64 * 1024 { try flush() }
        }
    }

    public func finish() throws {
        guard !finished else { return }
        try beginIfNeeded()
        finished = true
        switch format {
        case .csv: break
        case .json(let o):
            if o.layout == .array { append(rowsWritten == 0 ? "]\n" : "\n]\n") }
        case .sqlInserts: flushSQLRows()
        }
        try flush()
        try sink.close()
    }

    // MARK: internals

    private func beginIfNeeded() throws {
        guard !started else { return }
        started = true
        switch format {
        case .csv(let o):
            if o.utf8BOM { buffer.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            if o.includeHeader {
                append(columns.map { csvField($0.name, forceQuote: false, options: o) }.joined(separator: o.delimiter))
                append(o.lineEnding == .crlf ? "\r\n" : "\n")
            }
        case .json(let o):
            if o.layout == .array { append("[") }
        case .sqlInserts: break
        }
    }

    private func write(row: [DatabaseValue]) throws {
        switch format {
        case .csv(let o): writeCSV(row, o)
        case .json(let o): writeJSON(row, o)
        case .sqlInserts(let o): writeSQL(row, o)
        }
        rowsWritten += 1
    }

    private func append(_ s: String) { buffer.append(contentsOf: s.utf8) }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        bytesWritten += Int64(buffer.count)
        let out = buffer
        buffer = Data()
        try sink.write(out)
    }

    // MARK: CSV

    private func writeCSV(_ row: [DatabaseValue], _ o: CSVOptions) {
        var fields: [String] = []
        fields.reserveCapacity(row.count)
        let quoteEmpty = o.quoteEmptyStrings ?? (o.nullRepresentation == .empty)
        let nullToken: String? = {
            switch o.nullRepresentation {
            case .empty: nil
            case .backslashN: "\\N"
            case .custom(let s): s
            }
        }()
        for v in row {
            switch v {
            case .null:
                fields.append(nullToken.map { csvField($0, forceQuote: false, options: o, isNullToken: true) } ?? "")
            case .text(let s):
                let force = (s.isEmpty && quoteEmpty) || (nullToken != nil && s == nullToken)
                fields.append(csvField(s, forceQuote: force, options: o))
            case .bytes(let d):
                fields.append(csvField(encode(d, o.bytesEncoding), forceQuote: false, options: o))
            default:
                fields.append(csvField(v.displayString, forceQuote: false, options: o))
            }
        }
        append(fields.joined(separator: o.delimiter))
        append(o.lineEnding == .crlf ? "\r\n" : "\n")
    }

    private func csvField(_ s: String, forceQuote: Bool, options o: CSVOptions, isNullToken: Bool = false) -> String {
        if isNullToken { return s }  // the NULL marker is written bare
        let needs = forceQuote || o.quoteAllFields
            || s.contains(where: { $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            || s.contains(o.delimiter)
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func encode(_ d: Data, _ e: BytesEncoding) -> String {
        switch e {
        case .base64: d.base64EncodedString()
        case .hex: "0x" + d.map { String(format: "%02X", $0) }.joined()
        }
    }

    // MARK: JSON

    private func writeJSON(_ row: [DatabaseValue], _ o: JSONExportOptions) {
        var s = o.layout == .array ? (rowsWritten == 0 ? "\n  " : ",\n  ") : ""
        s += "{"
        for (i, v) in row.enumerated() where i < jsonKeys.count {
            if i > 0 { s += "," }
            s += Self.jsonString(jsonKeys[i]) + ":" + jsonValue(v, column: columns[i], o)
        }
        s += "}"
        if o.layout == .lines { s += "\n" }
        append(s)
    }

    private func jsonValue(_ v: DatabaseValue, column: ColumnInfo, _ o: JSONExportOptions) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i):
            return o.bigIntegersAsStrings && abs(i) > 9_007_199_254_740_992 ? Self.jsonString(String(i)) : String(i)
        case .unsignedInteger(let u):
            return o.bigIntegersAsStrings && u > 9_007_199_254_740_992 ? Self.jsonString(String(u)) : String(u)
        case .double(let d):
            return d.isFinite ? String(d) : Self.jsonString(String(d))
        case .bytes(let d): return Self.jsonString(encode(d, o.bytesEncoding))
        case .text(let s):
            if o.embedJSONColumns, ["json", "jsonb"].contains(column.typeName.lowercased()),
               let doc = try? JSONDocument.parse(s) {
                return doc.minified
            }
            return Self.jsonString(s)
        }
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: SQL

    private func writeSQL(_ row: [DatabaseValue], _ o: SQLInsertOptions) {
        pendingSQLRows.append("(" + row.map(dialect.literal).joined(separator: ", ") + ")")
        if pendingSQLRows.count >= o.rowsPerStatement { flushSQLRows() }
    }

    private func flushSQLRows() {
        guard case .sqlInserts(let o) = format, !pendingSQLRows.isEmpty else { return }
        var s = "INSERT INTO \(dialect.qualified(o.table))"
        if o.includeColumnList { s += " (" + columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ") + ")" }
        s += " VALUES\n" + pendingSQLRows.joined(separator: ",\n") + ";\n"
        append(s)
        pendingSQLRows.removeAll(keepingCapacity: true)
    }
}

// MARK: - Entry points

public enum ResultExporter {
    /// Exports one in-memory result.
    @discardableResult
    public static func export(_ result: QueryResult, format: ResultFormat, to sink: any ByteSink,
                              dialect: SQLDialect = SQLDialect(.mysql)) throws -> Int {
        let writer = ResultWriter(format: format, columns: result.columns, sink: sink, dialect: dialect)
        try writer.write(rows: result.rows)
        try writer.finish()
        return writer.rowsWritten
    }

    /// Exports a sequence of result pages (the columns come from the first page; later pages only contribute rows).
    @discardableResult
    public static func export<Pages: AsyncSequence>(
        pages: Pages, format: ResultFormat, to sink: any ByteSink, dialect: SQLDialect = SQLDialect(.mysql),
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int where Pages.Element == QueryResult {
        var writer: ResultWriter?
        for try await page in pages {
            try Task.checkCancellation()
            if writer == nil { writer = ResultWriter(format: format, columns: page.columns, sink: sink, dialect: dialect) }
            try writer?.write(rows: page.rows)
            onProgress?(writer?.rowsWritten ?? 0)
        }
        // An empty result still gets a header / brackets, using the columns we have (none if no page arrived).
        if writer == nil { writer = ResultWriter(format: format, columns: [], sink: sink, dialect: dialect) }
        try writer?.finish()
        return writer?.rowsWritten ?? 0
    }

    /// Exports a whole table (or the filtered/sorted view described by `query`) page by page, without
    /// holding it in memory. Uses keyset paging on the primary key when the query has no custom sort,
    /// otherwise `LIMIT/OFFSET`.
    @discardableResult
    public static func exportTable(
        _ query: TableQuery, session: any DatabaseSession, format: ResultFormat, to sink: any ByteSink,
        pageSize: Int = 1000, onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        let fmt = format
        let pages = TablePages(query: query, session: session, pageSize: pageSize)
        return try await export(pages: pages, format: fmt, to: sink, dialect: SQLDialect(session.engine), onProgress: onProgress)
    }
}

/// Pages of a table query: keyset paging on the primary key when possible.
public struct TablePages: AsyncSequence {
    public typealias Element = QueryResult

    let query: TableQuery
    let session: any DatabaseSession
    let pageSize: Int

    public init(query: TableQuery, session: any DatabaseSession, pageSize: Int = 1000) {
        self.query = query
        self.session = session
        self.pageSize = Swift.max(1, pageSize)
    }

    public func makeAsyncIterator() -> Iterator { Iterator(query: query, session: session, pageSize: pageSize) }

    public struct Iterator: AsyncIteratorProtocol {
        let query: TableQuery
        let session: any DatabaseSession
        let pageSize: Int
        private var offset = 0
        private var lastKey: [DatabaseValue]?
        private var done = false
        private var emitted = false
        private let dialect: SQLDialect

        init(query: TableQuery, session: any DatabaseSession, pageSize: Int) {
            self.query = query
            self.session = session
            self.pageSize = pageSize
            self.dialect = SQLDialect(session.engine)
        }

        private var usesKeyset: Bool { query.sort.isEmpty && !query.primaryKey.isEmpty }

        public mutating func next() async throws -> QueryResult? {
            guard !done else { return nil }
            try Task.checkCancellation()
            var q = query
            q.limit = pageSize
            q.offset = 0
            var extra = 0
            let pk = query.primaryKey
            if usesKeyset {
                q.sort = []
                // The key columns must be selected to remember where we stopped; extras are dropped again.
                if let cols = query.columns, !cols.isEmpty {
                    let lower = Set(cols.map { $0.lowercased() })
                    let missing = pk.filter { !lower.contains($0.lowercased()) }
                    extra = missing.count
                    q.columns = cols + missing
                }
                if let last = lastKey, let cond = KeysetPagination.condition(primaryKey: pk, after: last, dialect: dialect) {
                    // ANDed via the raw WHERE slot so the chips/raw WHERE of the original query stay intact.
                    q.rawWhere = [query.rawWhere.flatMap { TableQuery.cleanedRawWhere($0) }.map { "(\($0)\n)" }, cond]
                        .compactMap { $0 }.joined(separator: " AND ")
                }
            } else {
                q.offset = offset
            }
            var result = try await session.execute(q.sql(dialect: dialect))
            if result.rows.isEmpty {
                done = true
                // An empty first page still carries the column names (so an empty table gets a header row).
                return emitted ? nil : result
            }
            emitted = true
            if usesKeyset {
                // Locate the key columns in the result.
                let names = result.columns.map { $0.name.lowercased() }
                let indexes = pk.compactMap { names.firstIndex(of: $0.lowercased()) }
                guard indexes.count == pk.count else {
                    throw DatabaseError.unsupported("Can't page \(query.table): primary key columns missing from the result.")
                }
                lastKey = indexes.map { result.rows[result.rows.count - 1][$0] }
                if extra > 0 {
                    result.columns.removeLast(extra)
                    result.rows = result.rows.map { Array($0.dropLast(extra)) }
                }
            } else {
                offset += result.rows.count
            }
            if result.rows.count < pageSize { done = true }
            return result
        }
    }
}
