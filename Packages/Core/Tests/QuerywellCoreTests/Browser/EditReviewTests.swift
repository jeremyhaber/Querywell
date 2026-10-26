import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let cols = [
    ColumnDefinition(name: "ID", ordinal: 1, dataType: "bigint", fullType: "bigint", isNullable: false, isPrimaryKey: true, isAutoIncrement: true),
    ColumnDefinition(name: "title", ordinal: 2, dataType: "varchar", fullType: "varchar(50)", isNullable: true),
    ColumnDefinition(name: "status", ordinal: 3, dataType: "varchar", fullType: "varchar(20)", isNullable: false),
]
private func makeSession() throws -> EditSession {
    try EditSession(table: TableRef(schema: "app", name: "posts"), primaryKey: ["ID"], columns: cols)
}
private func key(_ id: Int64) -> RowKey { RowKey([.integer(id)]) }

@Suite("Edit review and commit reports")
struct EditReviewTests {
    @Test func changesFollowCommitOrderWithBeforeAndAfter() throws {
        var s = try makeSession()
        try s.setCell(row: key(1042), column: "title", original: .text("Services"), new: .text("Our services"))
        try s.setCell(row: key(1042), column: "status", original: .text("draft"), new: .text("publish"))
        try s.markDeleted(key(7))
        try s.insertRow(["title": .text("Hello"), "status": .text("draft")])
        let changes = EditReview.changes(of: s, dialect: my)
        #expect(changes.map(\.kind) == [.delete, .update, .insert])
        #expect(changes[0].title == "Delete row ID 7")
        #expect(changes[1].title == "Row ID 1042")
        #expect(changes[1].cells.map(\.column) == ["title", "status"])
        #expect(changes[1].cells[0].before == .text("Services"))
        #expect(changes[1].cells[0].after == .text("Our services"))
        #expect(changes[2].title == "New row 1")
        #expect(changes[2].cells.map(\.column) == ["title", "status"])
        #expect(changes[2].cells[0].before == nil)
        #expect(changes[1].sql.hasPrefix("UPDATE `app`.`posts` SET"))
        #expect(EditReview.script(of: s, dialect: my).split(separator: "\n").count == 3)
        #expect(EditReview.script(of: s, dialect: my).hasSuffix(";"))
    }

    @Test func warningsNameTheColumn() throws {
        var s = try makeSession()
        try s.insertRow(["title": .text("x")])
        let w = EditReview.warnings(of: s)
        #expect(w.count == 1)
        #expect(w[0].contains("status"))
    }

    @Test func sessionExposesPendingCells() throws {
        var s = try makeSession()
        try s.setCell(row: key(1), column: "title", original: .text("a"), new: .text("b"))
        #expect(s.updatedRowKeys == [key(1)])
        #expect(s.originalValue(key(1), column: "title") == .text("a"))
        #expect(s.cellChanges(for: key(1)).first?.new == .text("b"))
        #expect(s.rowLabel(key(1)) == "ID 1")
        try s.markDeleted(key(2))
        #expect(s.deletedRowKeys == [key(2)])
    }

    @Test func rebasingUpdatesTheOriginalOrDropsMatchingEdits() throws {
        var s = try makeSession()
        try s.setCell(row: key(1), column: "title", original: .text("old"), new: .text("mine"))
        try s.setCell(row: key(2), column: "title", original: .text("a"), new: .text("same"))
        s.rebaseOriginal(row: key(1), column: "title", original: .text("theirs"))
        #expect(s.originalValue(key(1), column: "title") == .text("theirs"))
        #expect(s.plannedStatements(dialect: my)[0].sql.contains("`title` = 'theirs'"))
        s.rebaseOriginal(row: key(2), column: "title", original: .text("same"))
        #expect(s.updatedRowKeys == [key(1)])
    }

    @Test func reportsSuccessConflictAndFailure() throws {
        var s = try makeSession()
        try s.setCell(row: key(1042), column: "title", original: .text("a"), new: .text("b"))
        let stmt = s.plannedStatements(dialect: my)
        let ok = EditSession.CommitResult(status: .committed, statements: stmt, outcomes: [.applied(rowsAffected: 1)], duration: .zero)
        let okReport = CommitReport.make(result: ok, session: s, editCount: 3)
        #expect(okReport.isSuccess)
        #expect(okReport.headline == "Committed 3 changes")
        let one = CommitReport.make(result: ok, session: s, editCount: 1)
        #expect(one.headline == "Committed 1 change")

        let conflict = EditSession.CommitResult(status: .rolledBack(.conflict(statementIndex: 0)), statements: stmt, outcomes: [.conflict], duration: .zero)
        let c = CommitReport.make(result: conflict, session: s, editCount: 1)
        #expect(c.status == .conflict)
        #expect(c.headline == "Row ID 1042 was changed by someone else since you loaded it — nothing was saved.")
        #expect(c.statement == stmt[0].sql)
        #expect(c.detail?.contains("pending edits are still here") == true)

        let failed = EditSession.CommitResult(status: .rolledBack(.error(statementIndex: 0, message: "Data too long")), statements: stmt, outcomes: [.failed("Data too long")], duration: .zero)
        let f = CommitReport.make(result: failed, session: s, editCount: 1, engine: "MyISAM")
        #expect(f.status == .failed)
        #expect(f.headline.contains("saving row ID 1042"))
        #expect(f.serverError == "Data too long")
        #expect(f.detail?.contains("MyISAM") == true)
        #expect(CommitReport.make(result: failed, session: s, editCount: 1, engine: "InnoDB").detail?.contains("roll back") == false)
    }

    @Test func tableOperationsQuoteAndMatchKind() {
        let t = TableInfo(ref: TableRef(schema: "my`db", name: "t"), kind: .table)
        let v = TableInfo(ref: TableRef(schema: "my`db", name: "v"), kind: .view)
        #expect(TableOperations.truncate([t, v], dialect: my) == ["TRUNCATE TABLE `my``db`.`t`"])
        #expect(TableOperations.drop([t, v], dialect: my) == ["DROP TABLE `my``db`.`t`", "DROP VIEW `my``db`.`v`"])
        let m = TableInfo(ref: TableRef(schema: "public", name: "mv"), kind: .materializedView)
        #expect(TableOperations.drop([m], dialect: SQLDialect(.postgresql)) == ["DROP MATERIALIZED VIEW \"public\".\"mv\""])
    }
}
