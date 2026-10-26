import Foundation
import Observation
import QuerywellCore

/// State of the small "Export results" sheet: CSV / JSON / SQL INSERT options for a table view (re-read page by
/// page from the server, filters and sort included) or for an in-memory query result.
@MainActor @Observable
final class ResultExportModel {
    enum Source {
        /// The table as the grid shows it now (filters, sort); exported page by page.
        case table(TableQuery)
        case result(QueryResult)
    }

    enum Kind: String, CaseIterable, Identifiable {
        case csv, json, sql
        var id: String { rawValue }
        var title: String {
            switch self {
            case .csv: "CSV"
            case .json: "JSON"
            case .sql: "SQL INSERT"
            }
        }
    }

    enum Delimiter: String, CaseIterable, Identifiable {
        case comma, semicolon, tab, pipe
        var id: String { rawValue }
        var title: String {
            switch self {
            case .comma: "Comma"
            case .semicolon: "Semicolon"
            case .tab: "Tab"
            case .pipe: "Pipe"
            }
        }
        var character: String {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            case .pipe: "|"
            }
        }
    }

    enum NullStyle: String, CaseIterable, Identifiable {
        case empty, backslashN, literal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .empty: "Empty field"
            case .backslashN: "\\N (MySQL)"
            case .literal: "NULL"
            }
        }
    }

    enum JSONLayout: String, CaseIterable, Identifiable {
        case array, lines
        var id: String { rawValue }
        var title: String { self == .array ? "JSON array" : "JSON Lines (one object per line)" }
    }

    enum State: Equatable {
        case idle
        case running(rows: Int)
        case finished(URL, rows: Int, bytes: Int64)
        case failed(String)
        case cancelled
    }

    let source: Source
    /// "wp_posts" / "Result 1": the base of the suggested file name.
    let name: String
    let engine: DatabaseEngine
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored private var runTask: Task<(rows: Int, bytes: Int64), any Error>?

    var kind: Kind = .csv
    var delimiter: Delimiter = .comma
    var includeHeader = true
    var utf8BOM = false
    var nullStyle: NullStyle = .empty
    var jsonLayout: JSONLayout = .array
    /// SQL INSERT target; `schema.table` or just `table` (then ``schema`` is used).
    var insertTable: String
    var rowsPerStatement = 100
    private let schema: String

    private(set) var state: State = .idle {
        didSet {
            switch state {
            case .finished(_, let rows, _): Announce.post("Export finished. \(rows) rows written.")
            case .failed(let message): Announce.post("Export failed. \(message)", important: true)
            case .cancelled: Announce.post("Export cancelled.")
            case .running where oldValue == .idle: Announce.post("Exporting.")
            default: break
            }
        }
    }

    init(source: Source, name: String, engine: DatabaseEngine, schema: String, tableName: String) {
        self.source = source
        self.name = name
        self.engine = engine
        self.schema = schema
        insertTable = tableName
    }

    var dialect: SQLDialect { SQLDialect(engine) }
    var isRunning: Bool { if case .running = state { true } else { false } }

    var tableRef: TableRef {
        let trimmed = insertTable.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\"", with: "")
        if let dot = trimmed.firstIndex(of: ".") {
            return TableRef(schema: String(trimmed[..<dot]), name: String(trimmed[trimmed.index(after: dot)...]))
        }
        return TableRef(schema: schema, name: trimmed.isEmpty ? "exported_table" : trimmed)
    }

    var format: ResultFormat {
        switch kind {
        case .csv:
            let nulls: CSVOptions.NullRepresentation = switch nullStyle {
            case .empty: .empty
            case .backslashN: .backslashN
            case .literal: .custom("NULL")
            }
            return .csv(CSVOptions(delimiter: delimiter.character, includeHeader: includeHeader, nullRepresentation: nulls, utf8BOM: utf8BOM))
        case .json:
            return .json(JSONExportOptions(layout: jsonLayout == .array ? .array : .lines))
        case .sql:
            return .sqlInserts(SQLInsertOptions(table: tableRef, rowsPerStatement: max(1, rowsPerStatement)))
        }
    }

    var suggestedFileName: String {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return base + "." + format.fileExtension
    }

    var rowCountHint: String? {
        if case .result(let r) = source { return "\(r.rows.count.formatted()) row\(r.rows.count == 1 ? "" : "s") in this result" }
        return "Every row matching the current filters, read from the server in pages"
    }

    /// Writes the file. Returns when it finished, failed or was cancelled; a failed or cancelled run deletes the partial file.
    func run(to url: URL) async {
        guard !isRunning else { return }
        state = .running(rows: 0)
        let format = format
        let dialect = dialect
        let source = source
        let session = sessionProvider()
        let task = Task.detached { () -> (rows: Int, bytes: Int64) in
            let sink = try FileHandleSink(url: url)
            do {
                let rows: Int
                switch source {
                case .result(let result):
                    rows = try ResultExporter.export(result, format: format, to: sink, dialect: dialect)
                case .table(let query):
                    guard let session else { throw DatabaseError.sessionClosed }
                    rows = try await ResultExporter.exportTable(query, session: session, format: format, to: sink) { count in
                        Task { @MainActor [weak self] in self?.noteProgress(count) }
                    }
                }
                try sink.close()
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                return (rows, size)
            } catch {
                try? sink.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        runTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            state = .finished(url, rows: result.rows, bytes: result.bytes)
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = Task.isCancelled || (runTask?.isCancelled ?? false) ? .cancelled : .failed((error as? DatabaseError).map(QueryRunner.describe) ?? error.localizedDescription)
        }
        runTask = nil
    }

    private func noteProgress(_ rows: Int) {
        if isRunning { state = .running(rows: rows) }
    }

    func cancel() { runTask?.cancel() }
}
