import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func col(_ name: String, _ type: String = "varchar") -> ColumnInfo { ColumnInfo(name: name, typeName: type) }

@Suite("Console input analysis")
struct ConsoleInputTests {
    @Test func semicolonCompletesAStatement() {
        #expect(ConsoleInput.analyze("SELECT 1;", dialect: my) == .run([ConsoleStatement(sql: "SELECT 1")], remainder: ""))
    }

    @Test func noTerminatorKeepsReading() {
        #expect(ConsoleInput.analyze("SELECT 1", dialect: my) == .incomplete(.statement))
        #expect(ConsoleInput.analyze("SELECT *\nFROM t", dialect: my) == .incomplete(.statement))
    }

    @Test func semicolonInsideQuotesAndCommentsDoesNotEnd() {
        #expect(ConsoleInput.analyze("SELECT 'a;b'", dialect: my) == .incomplete(.statement))
        #expect(ConsoleInput.analyze("SELECT 'a;b", dialect: my) == .incomplete(.singleQuote))
        #expect(ConsoleInput.analyze("SELECT \"a;b", dialect: my) == .incomplete(.doubleQuote))
        #expect(ConsoleInput.analyze("SELECT `a;b", dialect: my) == .incomplete(.backtick))
        #expect(ConsoleInput.analyze("SELECT 1 /* ;", dialect: my) == .incomplete(.blockComment))
        #expect(ConsoleInput.analyze("SELECT 1 -- ;", dialect: my) == .incomplete(.statement))
        #expect(ConsoleInput.analyze("SELECT $$a;b", dialect: pg) == .incomplete(.dollarQuote))
    }

    @Test func backslashGEndsAStatementVertically() {
        #expect(ConsoleInput.analyze("SELECT * FROM t\\G", dialect: my) == .run([ConsoleStatement(sql: "SELECT * FROM t", vertical: true)], remainder: ""))
        #expect(ConsoleInput.analyze("SELECT 1 \\g", dialect: my) == .run([ConsoleStatement(sql: "SELECT 1", vertical: false)], remainder: ""))
        // Inside a string it is just text.
        #expect(ConsoleInput.analyze("SELECT '\\G'", dialect: my) == .incomplete(.statement))
    }

    @Test func severalStatementsAndARemainder() {
        let r = ConsoleInput.analyze("SELECT 1; SELECT 2;\nSELECT 3", dialect: my)
        #expect(r == .run([ConsoleStatement(sql: "SELECT 1"), ConsoleStatement(sql: "SELECT 2")], remainder: "SELECT 3"))
    }

    @Test func blankAndCommentOnlyInputIsEmpty() {
        #expect(ConsoleInput.analyze("   \n", dialect: my) == .empty)
        #expect(ConsoleInput.analyze("-- nothing\n", dialect: my) == .empty)
        #expect(ConsoleInput.analyze(";", dialect: my) == .empty)
    }

    @Test func clientCommands() {
        #expect(ConsoleInput.analyze("quit", dialect: my) == .command(.quit))
        #expect(ConsoleInput.analyze("EXIT;", dialect: my) == .command(.quit))
        #expect(ConsoleInput.analyze("\\q", dialect: my) == .command(.quit))
        #expect(ConsoleInput.analyze("clear", dialect: my) == .command(.clear))
        #expect(ConsoleInput.analyze("\\c", dialect: my) == .command(.clear))
        #expect(ConsoleInput.analyze("help", dialect: my) == .command(.help))
        #expect(ConsoleInput.analyze("\\h", dialect: my) == .command(.help))
        #expect(ConsoleInput.analyze("use wp_site", dialect: my) == .command(.use("wp_site")))
        #expect(ConsoleInput.analyze("USE `my db`;", dialect: my) == .command(.use("my db")))
        #expect(ConsoleInput.analyze("SELECT 1\n\\c", dialect: my) == .command(.cancelInput))
        // `use` inside a longer statement is not a command.
        #expect(ConsoleInput.analyze("SELECT 1 FROM t USE INDEX (i);", dialect: my) == .run([ConsoleStatement(sql: "SELECT 1 FROM t USE INDEX (i)")], remainder: ""))
    }
}

@Suite("Console prompts")
struct ConsolePromptTests {
    @Test func mysqlPrompts() {
        #expect(ConsolePrompt.primary(engine: .mysql, database: "wp") == "mysql> ")
        #expect(ConsolePrompt.continuation(.statement, engine: .mariadb, database: "wp") == "    -> ")
        #expect(ConsolePrompt.continuation(.singleQuote, engine: .mysql, database: nil) == "    '> ")
        #expect(ConsolePrompt.continuation(.blockComment, engine: .mysql, database: nil) == "   /*> ")
    }

    @Test func postgresPromptsCarryTheDatabase() {
        #expect(ConsolePrompt.primary(engine: .postgresql, database: "shop") == "shop=# ")
        #expect(ConsolePrompt.continuation(.statement, engine: .postgresql, database: "shop") == "shop-# ")
        #expect(ConsolePrompt.continuation(.singleQuote, engine: .postgresql, database: "shop") == "shop'# ")
    }
}

@Suite("Console formatting")
struct ConsoleFormatterTests {
    @Test func tableMatchesTheMysqlClient() {
        let lines = ConsoleFormatter.table(
            columns: [col("Name"), col("Engine"), col("Rows", "bigint")],
            rows: [[.text("wp_postmeta"), .text("InnoDB"), .integer(38214)], [.text("wp_options"), .text("InnoDB"), .integer(684)]])
        #expect(lines.map(\.text) == [
            "+-------------+--------+-------+",
            "| Name        | Engine | Rows  |",
            "+-------------+--------+-------+",
            "| wp_postmeta | InnoDB | 38214 |",
            "| wp_options  | InnoDB |   684 |",
            "+-------------+--------+-------+",
        ])
        #expect(lines.map(\.kind) == [.border, .header, .border, .row, .row, .border])
    }

    @Test func nullsAndNumbers() {
        let lines = ConsoleFormatter.table(columns: [col("COUNT(*)", "bigint"), col("note")], rows: [[.integer(412), .null]])
        #expect(lines.map(\.text) == [
            "+----------+------+",
            "| COUNT(*) | note |",
            "+----------+------+",
            "|      412 | NULL |",
            "+----------+------+",
        ])
    }

    @Test func wideCellsAreTruncatedWithAnEllipsis() {
        let long = String(repeating: "x", count: 40)
        let lines = ConsoleFormatter.table(columns: [col("v")], rows: [[.text(long)]], options: ConsoleFormatOptions(maxCellWidth: 10))
        #expect(lines[3].text == "| xxxxxxxxx… |")
        let unlimited = ConsoleFormatter.table(columns: [col("v")], rows: [[.text(long)]], options: ConsoleFormatOptions(maxCellWidth: nil))
        #expect(unlimited[3].text == "| \(long) |")
    }

    @Test func newlinesAndTabsAreEscapedSoBordersStayStraight() {
        let lines = ConsoleFormatter.table(columns: [col("v")], rows: [[.text("a\nb\tc")]])
        #expect(lines[3].text == "| a\\nb\\tc |")
    }

    @Test func wideCharactersCountTwoColumns() {
        #expect(ConsoleFormatter.displayWidth("日本") == 4)
        #expect(ConsoleFormatter.displayWidth("é") == 1)
        let lines = ConsoleFormatter.table(columns: [col("n")], rows: [[.text("日本")], [.text("ab")]])
        #expect(lines.map(\.text).filter { $0.hasPrefix("|") } == ["| n    |", "| 日本 |", "| ab   |"])
    }

    @Test func emptyResultHasNoTable() {
        #expect(ConsoleFormatter.table(columns: [col("a")], rows: []).isEmpty)
        #expect(ConsoleFormatter.footer(rowCount: 0, duration: .zero) == "Empty set (0.00 sec)")
    }

    @Test func footersAndAffectedLines() {
        #expect(ConsoleFormatter.footer(rowCount: 1, duration: .milliseconds(10)) == "1 row in set (0.01 sec)")
        #expect(ConsoleFormatter.footer(rowCount: 2, duration: .milliseconds(24)) == "2 rows in set (0.02 sec)")
        #expect(ConsoleFormatter.affected(sql: "DELETE FROM t", rows: 1, duration: .milliseconds(5), engine: .mysql) == "Query OK, 1 row affected (0.01 sec)")
        #expect(ConsoleFormatter.affected(sql: "UPDATE t SET a=1", rows: 3, duration: .zero, engine: .mariadb) == "Query OK, 3 rows affected (0.00 sec)")
        #expect(ConsoleFormatter.affected(sql: "UPDATE t SET a=1", rows: 3, duration: .zero, engine: .postgresql) == "UPDATE 3 (0.00 sec)")
        #expect(ConsoleFormatter.postgresCommandTag(sql: "insert into t values (1)", rows: 1) == "INSERT 0 1")
        #expect(ConsoleFormatter.postgresCommandTag(sql: "CREATE UNIQUE INDEX i ON t(a)", rows: 0) == "CREATE INDEX")
        #expect(ConsoleFormatter.postgresCommandTag(sql: "CREATE TABLE t(a int)", rows: 0) == "CREATE TABLE")
    }

    @Test func verticalOutput() {
        let lines = ConsoleFormatter.vertical(columns: [col("ID", "bigint"), col("post_title")], rows: [[.integer(1), .text("Hello")]])
        #expect(lines.map(\.text) == [
            "*************************** 1. row ***************************",
            "        ID: 1",
            "post_title: Hello",
        ])
    }

    @Test func errorsLookLikeTheClient() {
        let e = DatabaseError.query(message: "Unknown column 'x' in 'field list'", code: "1054")
        #expect(ConsoleFormatter.error(e, engine: .mysql) == "ERROR 1054 (42S22): Unknown column 'x' in 'field list'")
        #expect(ConsoleFormatter.error(.query(message: "weird", code: "9999"), engine: .mysql) == "ERROR 9999 (HY000): weird")
        #expect(ConsoleFormatter.error(.query(message: "column \"x\" does not exist", code: "42703"), engine: .postgresql)
            == "ERROR:  column \"x\" does not exist (SQLSTATE 42703)")
        #expect(ConsoleFormatter.error(.sessionClosed, engine: .mysql).hasPrefix("ERROR 2006"))
    }
}

@Suite("Console editing")
struct ConsoleEditorTests {
    @Test func insertAndDelete() {
        var e = ConsoleLineEditor()
        e.insert("SELECT")
        e.insert(" 1")
        #expect(e.text == "SELECT 1")
        e.moveLeft(); e.moveLeft()
        e.backspace()
        #expect(e.text == "SELEC 1")
        e.deleteForward()
        #expect(e.text == "SELEC1")
    }

    @Test func multilineEditing() {
        var e = ConsoleLineEditor()
        e.insert("SELECT 1")
        e.newline()
        e.insert("FROM t")
        #expect(e.lines == ["SELECT 1", "FROM t"])
        #expect(e.moveUp() == true)
        #expect(e.moveUp() == false)
        #expect(e.line == 0)
        e.moveToLineEnd()
        e.deleteForward()
        #expect(e.lines == ["SELECT 1FROM t"])
        e.moveTo(line: 0, column: 8)
        e.newline()
        #expect(e.lines == ["SELECT 1", "FROM t"])
        e.backspace()
        #expect(e.lines == ["SELECT 1FROM t"])
        #expect(e.column == 8)
    }

    @Test func pasteSplitsLines() {
        var e = ConsoleLineEditor()
        e.insert("a\r\nb\nc")
        #expect(e.lines == ["a", "b", "c"])
        #expect(e.line == 2 && e.column == 1)
        #expect(e.caretUTF16Offset == 5)
    }

    @Test func killKeys() {
        var e = ConsoleLineEditor(text: "alpha beta gamma")
        e.deleteWordBackward()
        #expect(e.text == "alpha beta ")
        e.moveTo(line: 0, column: 5)
        e.killToEnd()
        #expect(e.text == "alpha")
        e.killToStart()
        #expect(e.text == "")
    }

    @Test func historyNavigationKeepsTheDraft() {
        var h = ConsoleHistoryNavigator(entries: ["one", "two", "three"])
        #expect(h.previous(current: "draft") == "three")
        #expect(h.previous(current: "three") == "two")
        #expect(h.next() == "three")
        #expect(h.next() == "draft")
        #expect(h.next() == nil)
        #expect(h.previous(current: "") == "three")
        _ = h.previous(current: ""); _ = h.previous(current: "")
        #expect(h.previous(current: "") == nil)
        h.record("four")
        h.record("four")
        #expect(h.entries.last == "four" && h.entries.count == 4)
        #expect(h.isBrowsing == false)
    }
}

@Suite("Console completion plan")
struct ConsoleCompletionTests {
    private func result(_ items: [String], range: Range<Int>) -> CompletionResult {
        CompletionResult(range: range, items: items.map { CompletionItem(label: $0, insertText: $0, kind: .table) }, context: .tableName)
    }

    @Test func singleMatchIsInsertedWithATrailingSpace() {
        let plan = ConsoleCompletionPlan.make(for: result(["wp_postmeta"], range: 14..<17), in: "SELECT * FROM wp_")
        #expect(plan.replacement?.text == "wp_postmeta ")
        #expect(plan.replacement?.range == 14..<17)
        #expect(plan.candidates.isEmpty)
    }

    @Test func ambiguousMatchesInsertTheCommonPrefixThenList() {
        let r = result(["wp_posts", "wp_postmeta"], range: 14..<16)
        let first = ConsoleCompletionPlan.make(for: r, in: "SELECT * FROM wp")
        #expect(first.replacement?.text == "wp_post")
        let again = ConsoleCompletionPlan.make(for: result(["wp_posts", "wp_postmeta"], range: 14..<21), in: "SELECT * FROM wp_post")
        #expect(again.replacement == nil)
        #expect(again.candidates == ["wp_posts", "wp_postmeta"])
    }

    @Test func suppressedAndEmptyDoNothing() {
        let none = ConsoleCompletionPlan.make(for: CompletionResult(range: 0..<0, context: .suppressed), in: "")
        #expect(none.replacement == nil && none.candidates.isEmpty)
    }

    @Test func candidatesLayOutInColumns() {
        let rows = ConsoleCompletionPlan.columns(["alpha", "beta", "gamma", "delta"], width: 24)
        #expect(rows == ["alpha  beta   gamma", "delta"])
    }
}

@Suite("Console editor completion helpers")
struct ConsoleEditorReplaceTests {
    @Test func replaceUTF16RangePlacesTheCaretAfterTheReplacement() {
        var e = ConsoleLineEditor(text: "SELECT * FROM wp_\nWHERE 1")
        e.replace(utf16Range: 14..<17, with: "wp_postmeta ")
        #expect(e.lines == ["SELECT * FROM wp_postmeta ", "WHERE 1"])
        #expect(e.line == 0 && e.column == 26)
    }

    @Test func moveToUTF16OffsetCountsSurrogatePairs() {
        var e = ConsoleLineEditor(text: "a😀b\ncd")
        e.moveTo(utf16Offset: 3)
        #expect(e.line == 0 && e.column == 2)
        e.moveTo(utf16Offset: 6)
        #expect(e.line == 1 && e.column == 1)
    }
}
