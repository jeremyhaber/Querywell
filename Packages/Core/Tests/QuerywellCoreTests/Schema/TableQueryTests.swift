import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)
private let posts = TableRef(schema: "wp", name: "wp_posts")

@Suite("TableQuery")
struct TableQueryTests {
    @Test func plainSelect() {
        let q = TableQuery(table: posts, limit: 100)
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` LIMIT 100")
        #expect(q.sql(dialect: pg) == "SELECT * FROM \"wp\".\"wp_posts\" LIMIT 100")
        #expect(q.countSQL(dialect: my) == "SELECT COUNT(*) FROM `wp`.`wp_posts`")
    }

    @Test func columnsOffsetAndEmptyColumnList() {
        let q = TableQuery(table: posts, columns: ["ID", "post`title"], limit: 50, offset: 100)
        #expect(q.sql(dialect: my) == "SELECT `ID`, `post``title` FROM `wp`.`wp_posts` LIMIT 50 OFFSET 100")
        #expect(TableQuery(table: posts, columns: [], limit: 1).sql(dialect: my).hasPrefix("SELECT * FROM"))
    }

    @Test func primaryKeyBecomesTiebreaker() {
        let q = TableQuery(
            table: posts, sort: [SortKey(column: "post_date", ascending: false)], limit: 10, primaryKey: ["ID"])
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` ORDER BY `post_date` DESC, `ID` ASC LIMIT 10")
    }

    @Test func unsortedPagingStillOrdersByPrimaryKey() {
        let q = TableQuery(table: posts, limit: 10, offset: 20, primaryKey: ["a", "b"])
        #expect(q.sql(dialect: pg) == "SELECT * FROM \"wp\".\"wp_posts\" ORDER BY \"a\" ASC, \"b\" ASC LIMIT 10 OFFSET 20")
    }

    @Test func primaryKeyColumnsAlreadySortedAreNotRepeated() {
        let q = TableQuery(
            table: posts,
            sort: [SortKey(column: "b", ascending: false), SortKey(column: "B"), SortKey(column: "x")],
            limit: 5, primaryKey: ["a", "B"])
        // `B` (duplicate sort key) and PK column `B` are already covered by the first key.
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` ORDER BY `b` DESC, `x` ASC, `a` ASC LIMIT 5")
    }

    @Test func noPrimaryKeyNoTiebreaker() {
        let q = TableQuery(table: posts, sort: [SortKey(column: "x")], limit: 5)
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` ORDER BY `x` ASC LIMIT 5")
        #expect(!TableQuery(table: posts, limit: 5).sql(dialect: my).contains("ORDER BY"))
    }

    @Test func chipsAndRawWhereAreAnded() {
        let group = FilterGroup(filters: [
            ColumnFilter(column: "post_status", op: .equals(.text("publish"))),
        ])
        let q = TableQuery(table: posts, filter: group, rawWhere: "ID > 5 OR ID < 2", limit: 10, primaryKey: ["ID"])
        #expect(q.sql(dialect: my)
            == "SELECT * FROM `wp`.`wp_posts` WHERE `post_status` = 'publish' AND (ID > 5 OR ID < 2\n) ORDER BY `ID` ASC LIMIT 10")
        #expect(q.countSQL(dialect: my)
            == "SELECT COUNT(*) FROM `wp`.`wp_posts` WHERE `post_status` = 'publish' AND (ID > 5 OR ID < 2\n)")
    }

    @Test func orGroupIsParenthesisedBeforeAnding() {
        let group = FilterGroup(filters: [
            ColumnFilter(column: "a", op: .isNull), ColumnFilter(column: "b", op: .isNotNull),
        ], combinator: .or)
        let q = TableQuery(table: posts, filter: group, rawWhere: "c = 1", limit: 1)
        #expect(q.sql(dialect: my).contains("WHERE ((`a` IS NULL) OR (`b` IS NOT NULL)) AND (c = 1\n)"))
    }

    @Test func rawWhereIsCleanedButNotEscaped() {
        func whereClause(_ raw: String?) -> String {
            let sql = TableQuery(table: posts, rawWhere: raw, limit: 1).sql(dialect: my)
            return sql.contains(" WHERE ") ? String(sql[sql.range(of: " WHERE ")!.upperBound...]) : ""
        }
        #expect(whereClause(nil) == "")
        #expect(whereClause("   \n ") == "")
        #expect(whereClause("WHERE ID = 1;") == "(ID = 1\n) LIMIT 1")
        #expect(whereClause("where\nID = 1 ; ;") == "(ID = 1\n) LIMIT 1")
        #expect(whereClause("WHERE") == "")
        #expect(whereClause("wherever = 1") == "(wherever = 1\n) LIMIT 1")
        // Quotes and backticks pass through verbatim — it is the user's SQL.
        #expect(whereClause("post_title = 'it''s' AND `x` = \"y\"") == "(post_title = 'it''s' AND `x` = \"y\"\n) LIMIT 1")
        // A trailing line comment can't swallow the closing parenthesis.
        #expect(whereClause("ID = 1 -- note") == "(ID = 1 -- note\n) LIMIT 1")
    }

    @Test func disabledAndEmptyFiltersContributeNothing() {
        let group = FilterGroup(filters: [
            ColumnFilter(column: "a", op: .isNull, isEnabled: false),
            ColumnFilter(column: "d", op: .dateRange(from: nil, to: nil)),
        ])
        let q = TableQuery(table: posts, filter: group, limit: 5)
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` LIMIT 5")
        #expect(q.countSQL(dialect: my) == "SELECT COUNT(*) FROM `wp`.`wp_posts`")
    }

    @Test func hostileNamesAreQuoted() {
        let q = TableQuery(
            table: TableRef(schema: "a`b", name: "c`; DROP TABLE x; --"), columns: ["x`y"],
            sort: [SortKey(column: "o`k")], limit: 1)
        #expect(q.sql(dialect: my)
            == "SELECT `x``y` FROM `a``b`.`c``; DROP TABLE x; --` ORDER BY `o``k` ASC LIMIT 1")
    }

    @Test func negativeLimitAndOffsetAreClamped() {
        let q = TableQuery(table: posts, limit: -5, offset: -9)
        #expect(q.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` LIMIT 0")
    }
}
