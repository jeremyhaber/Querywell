import Foundation

// What the Review sheet shows and what a finished commit says, derived from an `EditSession`.
// Pure so the wording and ordering are unit-tested.

/// One planned statement together with the cell-level changes behind it.
public struct ReviewChange: Identifiable, Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        public var column: String
        /// nil for inserts, and for edits whose original wasn't recorded.
        public var before: DatabaseValue?
        public var after: DatabaseValue
    }

    /// Position in the commit order (also the statement index).
    public var id: Int
    public var kind: EditSession.ChangeKind
    /// "Row ID 1042", "New row", "Delete row ID 7".
    public var title: String
    public var cells: [Cell]
    public var sql: String
}

public enum EditReview {
    /// Changes in commit order (deletes, updates, inserts).
    public static func changes(of session: EditSession, dialect: SQLDialect) -> [ReviewChange] {
        let planned = session.plannedStatements(dialect: dialect)
        var out: [ReviewChange] = []
        var newRowNumber = 0
        for (i, stmt) in planned.enumerated() {
            switch stmt.kind {
            case .delete:
                let label = stmt.row.map { session.rowLabel($0) } ?? "row"
                out.append(ReviewChange(id: i, kind: .delete, title: "Delete row \(label)", cells: [], sql: stmt.sql))
            case .update:
                let key = stmt.row
                let cells = key.map { session.cellChanges(for: $0) } ?? []
                out.append(ReviewChange(
                    id: i, kind: .update, title: "Row \(key.map { session.rowLabel($0) } ?? "")",
                    cells: cells.map { .init(column: $0.column, before: $0.original, after: $0.new) }, sql: stmt.sql))
            case .insert:
                newRowNumber += 1
                let values = stmt.insertedRow.flatMap { session.insertedValues($0) } ?? [:]
                let cells = session.columns.compactMap { c in values[c.name].map { ReviewChange.Cell(column: c.name, before: nil, after: $0) } }
                out.append(ReviewChange(id: i, kind: .insert, title: "New row \(newRowNumber)", cells: cells, sql: stmt.sql))
            }
        }
        return out
    }

    /// The statements as one script, each terminated with `;` (what Copy puts on the clipboard).
    public static func script(of session: EditSession, dialect: SQLDialect) -> String {
        session.statements(dialect: dialect).map { $0 + ";" }.joined(separator: "\n")
    }

    /// Issues worth showing before committing (NOT NULL columns left empty).
    public static func warnings(of session: EditSession) -> [String] {
        session.validationIssues.map { issue in
            switch issue.kind {
            case .missingRequiredColumn(let c):
                return "A new row has no value for \(c), which is NOT NULL and has no default."
            case .nullInNotNullColumn(let c):
                return "\(c) is NOT NULL but is set to NULL."
            }
        }
    }
}

/// The user-facing result of a commit attempt.
public struct CommitReport: Sendable, Hashable {
    public enum Status: Sendable, Hashable { case committed, conflict, failed }

    public var status: Status
    /// One line, e.g. "Committed 3 changes" or "Row ID 1042 was changed by someone else since you loaded it — nothing was saved."
    public var headline: String
    /// Extra explanation (what to do next, storage-engine caveat).
    public var detail: String?
    /// The statement that conflicted or failed.
    public var statement: String?
    /// The server's own message for failures.
    public var serverError: String?

    public var isSuccess: Bool { status == .committed }

    public init(status: Status, headline: String, detail: String? = nil, statement: String? = nil, serverError: String? = nil) {
        self.status = status
        self.headline = headline
        self.detail = detail
        self.statement = statement
        self.serverError = serverError
    }

    /// - Parameters:
    ///   - editCount: edits the user made (cells + inserted + deleted rows), for the success line.
    ///   - engine: the table's storage engine; non-transactional ones get a caveat on failure.
    public static func make(result: EditSession.CommitResult, session: EditSession, editCount: Int, engine: String? = nil) -> CommitReport {
        switch result.status {
        case .committed:
            let n = max(editCount, result.statements.count)
            return CommitReport(status: .committed, headline: "Committed \(n) change\(n == 1 ? "" : "s")")
        case .rolledBack(let reason):
            let caveat = nonTransactionalNote(engine)
            switch reason {
            case .conflict(let index):
                let stmt = result.statements.indices.contains(index) ? result.statements[index] : nil
                let label = stmt?.row.map { "Row \(session.rowLabel($0))" } ?? "A row"
                let verb = stmt?.kind == .delete ? "was changed or removed by someone else" : "was changed by someone else"
                return CommitReport(
                    status: .conflict,
                    headline: "\(label) \(verb) since you loaded it — nothing was saved.",
                    detail: "Reload the table to see the current values, or discard your edits. Your pending edits are still here." + (caveat.map { " " + $0 } ?? ""),
                    statement: stmt?.sql, serverError: nil)
            case .error(let index, let message):
                let stmt = index.flatMap { result.statements.indices.contains($0) ? result.statements[$0] : nil }
                let what: String
                if let row = stmt?.row {
                    what = stmt?.kind == .delete ? "deleting row \(session.rowLabel(row))" : "saving row \(session.rowLabel(row))"
                } else if stmt?.kind == .insert {
                    what = "adding a new row"
                } else {
                    what = "finishing the commit"
                }
                return CommitReport(
                    status: .failed,
                    headline: "The server rejected \(what) — nothing was saved.",
                    detail: "Fix the value or discard your edits; your pending edits are still here." + (caveat.map { " " + $0 } ?? ""),
                    statement: stmt?.sql, serverError: message)
            }
        }
    }

    private static func nonTransactionalNote(_ engine: String?) -> String? {
        guard let engine, !engine.isEmpty, engine.caseInsensitiveCompare("InnoDB") != .orderedSame else { return nil }
        return "This table uses \(engine), which can't roll back: statements that ran before the problem were kept."
    }
}
