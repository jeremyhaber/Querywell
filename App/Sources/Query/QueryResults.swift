import Foundation
import Observation
import QuerywellCore

/// A read-only result set in the grid: columns made unique, client-side sort on header clicks.
@MainActor @Observable
final class ResultGridModel {
    let columnNames: [String]
    let columns: [GridColumn]
    private let baseRows: [[DatabaseValue]]
    private let duration: Duration
    private(set) var sort: [SortKey] = []
    private(set) var content: GridContent
    private(set) var rows: [[DatabaseValue]]

    init(result: QueryResult) {
        // Joins often return the same name twice (`ID`, `ID`); the grid addresses columns by name.
        var seen: [String: Int] = [:]
        var names: [String] = []
        for c in result.columns {
            let key = c.name.lowercased()
            let n = seen[key, default: 0] + 1
            seen[key] = n
            names.append(n == 1 ? c.name : "\(c.name) (\(n))")
        }
        columnNames = names
        columns = zip(result.columns, names).map { info, name in
            GridColumn(
                name: name, typeLabel: info.typeName,
                presentation: ColumnPresentation(name: name, dataType: info.typeName, fullType: info.typeName),
                isPrimaryKey: false, foreignKey: nil, fullType: info.typeName)
        }
        baseRows = result.rows
        duration = result.duration
        rows = result.rows
        content = GridContent(columns: columns, rows: result.rows, offset: 0, duration: result.duration)
    }

    func toggleSort(column: String, additive: Bool) {
        sort = SortCycle.next(current: sort, column: column, additive: additive)
        rows = Self.sorted(baseRows, by: sort, names: columnNames)
        content = GridContent(columns: columns, rows: rows, offset: 0, duration: duration, preservesViewport: false)
    }

    static func sorted(_ rows: [[DatabaseValue]], by sort: [SortKey], names: [String]) -> [[DatabaseValue]] {
        guard !sort.isEmpty else { return rows }
        let keys = sort.compactMap { key -> (Int, Bool)? in
            names.firstIndex { $0.caseInsensitiveCompare(key.column) == .orderedSame }.map { ($0, key.ascending) }
        }
        return rows.enumerated().sorted { a, b in
            for (index, ascending) in keys {
                let c = compare(a.element[safe: index], b.element[safe: index])
                if c != .orderedSame { return ascending ? c == .orderedAscending : c == .orderedDescending }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// NULL first, numbers numerically, everything else by natural string order.
    static func compare(_ a: DatabaseValue?, _ b: DatabaseValue?) -> ComparisonResult {
        let a = a ?? .null, b = b ?? .null
        if a.isNull || b.isNull { return a.isNull == b.isNull ? .orderedSame : (a.isNull ? .orderedAscending : .orderedDescending) }
        if let x = number(a), let y = number(b) { return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        return a.displayString.localizedStandardCompare(b.displayString)
    }

    private static func number(_ v: DatabaseValue) -> Double? {
        switch v {
        case .integer(let i): Double(i)
        case .unsignedInteger(let u): Double(u)
        case .double(let d): d
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One entry in the results strip of a query tab.
struct QueryResultItem: Identifiable {
    enum Payload {
        case rows(QueryResult, truncated: Bool, total: Int)
        case affected(rows: UInt64, lastInsertID: UInt64?)
    }

    let id = UUID()
    /// 0-based position of the statement in the run.
    var statementIndex: Int
    var statement: ClassifiedStatement
    var payload: Payload
    var duration: Duration
    /// Set once the editability analysis finished (nil while pending, or for non-reads).
    var verdict: EditableResultVerdict?
    var grid: ResultGridModel?
    var editModel: TableDataModel?

    var isRowSet: Bool { if case .rows = payload { true } else { false } }

    var result: QueryResult? { if case .rows(let r, _, _) = payload { r } else { nil } }

    var rowCount: Int {
        switch payload {
        case .rows(let r, _, _): r.rows.count
        case .affected(let n, _): Int(clamping: n)
        }
    }

    var isTruncated: Bool { if case .rows(_, let t, _) = payload { t } else { false } }

    var totalRows: Int { if case .rows(_, _, let total) = payload { total } else { rowCount } }

    /// "Result 1 · 24 rows", "Result 2 · 1 row", "Result 3 · 3 rows affected".
    var title: String {
        let n = statementIndex + 1
        switch payload {
        case .rows(let r, _, _):
            return "Result \(n) · \(r.rows.count == 1 ? "1 row" : "\(Self.grouped(r.rows.count)) rows")"
        case .affected(let rows, _):
            return "Result \(n) · \(rows == 1 ? "1 row" : "\(rows) rows") affected"
        }
    }

    private static func grouped(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
}

/// A plan from the Explain button.
struct ExplainOutcome: Equatable {
    var plan: ExplainPlan
    /// The EXPLAIN statement that was sent.
    var sql: String
    /// The statement that was explained.
    var explained: String
    var note: String?
}

enum QueryResultSelection: Equatable {
    case result(UUID)
    case messages
    case plan
}

/// The guard hint in the footer.
enum GuardHint: Equatable {
    case none
    case readOnlyQuery
    case needsConfirmation(production: Bool)
    case writesNoConfirmation
    case blocked

    var text: String? {
        switch self {
        case .none: nil
        case .readOnlyQuery: "Read-only query — no confirmation needed"
        case .needsConfirmation(let prod): prod ? "Writes need confirmation on PROD" : "Asks for confirmation before running"
        case .writesNoConfirmation: "Contains writes — runs without confirmation here"
        case .blocked: "Read-only connection — writes are blocked"
        }
    }
}

extension HistoryEntry {
    /// The history record for one executed statement (nil for statements that were skipped).
    static func make(from result: StatementResult, database: String?, at date: Date = Date()) -> HistoryEntry? {
        let ms = Double(result.duration.components.seconds) * 1000 + Double(result.duration.components.attoseconds) / 1e15
        switch result.outcome {
        case .skipped:
            return nil
        case .resultSet(let r):
            return HistoryEntry(sql: result.statement.text, ranAt: date, durationMs: ms, rowCount: result.totalRows ?? r.rows.count,
                                database: database)
        case .affected(let rows, _):
            return HistoryEntry(sql: result.statement.text, ranAt: date, durationMs: ms, affected: Int(clamping: rows), database: database)
        case .error(let e):
            return HistoryEntry(sql: result.statement.text, ranAt: date, durationMs: ms, error: QueryRunner.describe(e), database: database)
        }
    }
}
