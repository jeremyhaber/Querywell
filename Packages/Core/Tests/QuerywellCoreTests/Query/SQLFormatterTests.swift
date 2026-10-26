import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func fmt(_ sql: String, _ d: SQLDialect = my, upper: Bool = true) -> String {
    SQLFormatter.format(sql, dialect: d, options: SQLFormatOptions(uppercaseKeywords: upper))
}

/// The non-whitespace token stream, with word case folded when `foldCase`.
private func stream(_ sql: String, _ d: SQLDialect, foldCase: Bool) -> [String] {
    SQLLexer(d).tokenize(sql).filter { $0.kind != .whitespace }.map {
        let kind: String
        switch $0.kind {
        case .word: kind = "w"
        case .string: kind = "s"
        case .quotedIdentifier: kind = "q"
        case .number: kind = "n"
        case .lineComment: kind = "lc"
        case .blockComment: kind = "bc"
        case .versionedComment: kind = "vc"
        case .dollarString: kind = "d"
        case .symbol: kind = "y"
        case .whitespace: kind = "_"
        }
        return kind + ":" + (foldCase && $0.kind == .word ? $0.text.lowercased() : $0.text)
    }
}

/// A corpus covering what real scripts contain: WordPress queries, DDL, CTEs, strings with SQL
/// inside, comments in awkward places, dollar quoting, executable comments, JSON operators, odd spacing.
private let corpus: [(name: String, sql: String, dialect: SQLDialect)] = [
    ("simple", "select * from wp_posts where ID=1", my),
    ("wp join", "SELECT p.ID,p.post_title,pm.meta_value FROM wp_posts p INNER JOIN wp_postmeta pm ON pm.post_id=p.ID AND pm.meta_key='_thumbnail_id' WHERE p.post_status='publish' AND p.post_type IN ('post','page') ORDER BY p.post_date DESC LIMIT 10 OFFSET 20", my),
    ("left join chain", "select a.x from a left outer join b on a.id=b.id natural join c cross join d right join e using (id) where 1", my),
    ("subquery", "SELECT * FROM (SELECT id, COUNT(*) AS n FROM t GROUP BY id HAVING n > 1) x WHERE x.id IN (SELECT id FROM u WHERE u.a = 1 OR u.b = 2)", my),
    ("exists", "select 1 where exists (select 1 from t where t.a = 1 and t.b = 2)", my),
    ("between", "SELECT * FROM t WHERE a BETWEEN 1 AND 10 AND b = 2 OR c BETWEEN 'a' AND 'z'", my),
    ("case", "SELECT CASE WHEN a = 1 AND b = 2 THEN 'x' WHEN a = 3 THEN 'y' ELSE 'z' END AS c, d FROM t WHERE e = 1 AND f = 2", my),
    ("union", "select a from t1 union all select a from t2 union select a from t3 order by 1", my),
    ("insert", "INSERT INTO wp_options (option_name,option_value,autoload) VALUES ('a','b','yes'),('c','d','no') ON DUPLICATE KEY UPDATE option_value=VALUES(option_value), autoload='no'", my),
    ("insert select", "insert into t (a,b) select a,b from u where c = 1", my),
    ("update", "UPDATE wp_posts SET post_status='draft', post_modified=NOW() WHERE ID IN (1,2,3) AND post_type='post'", my),
    ("delete", "delete from wp_postmeta where meta_key = '_edit_lock' and post_id > 100", my),
    ("multi statement", "SELECT 1; SELECT 2;\n\n\nUPDATE t SET a = 1 WHERE b = 2;DELETE FROM t WHERE x=1", my),
    ("strings with sql inside", "SELECT 'SELECT * FROM t WHERE a = 1; -- not a comment' AS s, \"double 'quoted' ; string\" AS d FROM t", my),
    ("escapes", "SELECT 'it''s', 'back\\'slash', \"say \\\"hi\\\"\" FROM t WHERE a = 'x\\\\'", my),
    ("backticks", "select `select`, `from`.`where`, `a``b` from `my table` `t` where `t`.`id` = 1", my),
    ("line comments", "SELECT a, -- first\n b -- second\nFROM t -- third\nWHERE x = 1 -- end", my),
    ("hash comment", "SELECT a # why\nFROM t", my),
    ("block comments", "/* header */ SELECT /* inline */ a /* more */ FROM /* x */ t /* trailing */", my),
    ("optimizer hint", "SELECT /*+ NO_RANGE_OPTIMIZATION(t PRIMARY) */ a FROM t USE INDEX (idx) WHERE a = 1", my),
    ("versioned comments", "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\nSELECT /*!50100 SQL_NO_CACHE */ 1 FROM t;", my),
    ("mysql dash comment", "SELECT 1 --x\n, 2 -- real comment\nFROM t", my),
    ("variables", "SET @a = 1, @b := 'x'; SELECT @a + @b, @@session.sql_mode, @`odd name` FROM t", my),
    ("session set", "SET NAMES utf8mb4; SET SESSION sql_mode = 'STRICT_ALL_TABLES'; SET FOREIGN_KEY_CHECKS=0", my),
    ("operators", "SELECT a<=>b, a<>b, a!=b, a>=b, a<=b, a||b, a&&b, -a, - -a, a- -b, ~a, a<<2, a%3, a DIV 2 FROM t", my),
    ("numbers", "SELECT 1, 1.5, .5, 1e10, 1E-3, 0x1F, 1.e2, 5.field FROM t WHERE a=-1 AND b=+2", my),
    ("functions", "SELECT COUNT (*), COUNT(DISTINCT a), IFNULL(a,0), CONCAT(a,' ',b), LEFT(a,2), REPLACE(a,'x','y'), GROUP_CONCAT(a ORDER BY b SEPARATOR ',') FROM t GROUP BY c", my),
    ("window", "SELECT id, ROW_NUMBER() OVER (PARTITION BY a ORDER BY b DESC), SUM(x) OVER w FROM t WINDOW w AS (PARTITION BY a)", my),
    ("create table", "CREATE TABLE `t` (`id` int NOT NULL AUTO_INCREMENT, `name` varchar(50) DEFAULT 'x', PRIMARY KEY (`id`), KEY `n` (`name`(10))) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='a;b'", my),
    ("alter", "alter table t add column c int not null default 0 after b, drop index i, add constraint fk foreign key (c) references u (id) on delete cascade", my),
    ("create view", "create or replace view v as select a, b from t where c = 1", my),
    ("procedure body", "CREATE PROCEDURE p() BEGIN SELECT 1; UPDATE t SET a = 1 WHERE b = 2; END", my),
    ("cte", "WITH recent AS (SELECT * FROM wp_posts WHERE post_date > '2024-01-01'), counts AS (SELECT post_author, COUNT(*) c FROM recent GROUP BY post_author) SELECT * FROM counts WHERE c > 5", my),
    ("select into", "SELECT a, b INTO @x, @y FROM t LIMIT 1", my),
    ("for update", "SELECT * FROM t WHERE id = 1 FOR UPDATE", my),
    ("tabs and blank lines", "SELECT\ta,\n\n\n\tb\n\nFROM\t\tt\n\n\n\nWHERE   a   =   1", my),
    ("trailing newline", "SELECT 1\n", my),
    ("unicode", "SELECT 'héllo 😀', ünïcode_col FROM `tàble` WHERE x = 'ß'", my),
    ("unterminated string", "SELECT 'abc", my),
    ("unterminated comment", "SELECT 1 /* never closed", my),
    ("only comments", "-- just a comment\n/* and another */", my),
    // PostgreSQL
    ("pg basic", "select p.id, p.title::text, now()::date from posts p join users u on u.id = p.user_id where p.status = 'published' and p.created_at > now() - interval '7 days' order by 1 desc limit 5", pg),
    ("pg returning", "INSERT INTO t (a, b) VALUES ($1, $2) ON CONFLICT (a) DO UPDATE SET b = EXCLUDED.b RETURNING id, b", pg),
    ("pg update returning", "update t set a = 1, b = 2 where c = 3 returning *", pg),
    ("pg dollar quote", "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $body$ SELECT 1; -- not a split $$ $body$; SELECT 2", pg),
    ("pg dollar plain", "DO $$ BEGIN PERFORM 1; END $$; SELECT $$a;b$$", pg),
    ("pg json", "SELECT data->'a'->>'b', data#>>'{c,d}', data @> '{\"x\":1}', arr[1], tags && ARRAY['a'] FROM docs WHERE data ? 'k'", pg),
    ("pg E string", "SELECT E'line\\nbreak', E'it\\'s', 'plain \\ backslash' FROM t", pg),
    ("pg quoted idents", "SELECT \"Order\".\"Id\", \"a\"\"b\" FROM \"Order\" WHERE \"Id\" = 1", pg),
    ("pg nested comment", "SELECT 1 /* outer /* inner */ still outer */ + 2", pg),
    ("pg distinct on", "SELECT DISTINCT ON (a) a, b FROM t ORDER BY a, b DESC", pg),
    ("pg is distinct from", "SELECT * FROM t WHERE a IS DISTINCT FROM b AND c IS NOT NULL", pg),
    ("pg lateral", "select * from t cross join lateral (select * from u where u.t_id = t.id limit 1) x", pg),
    ("pg copy", "COPY t (a, b) FROM STDIN", pg),
    ("pg dash comment", "SELECT 1 --x\n, 2", pg),
]

@Suite("SQL formatter")
struct SQLFormatterTests {
    // MARK: Never changes semantics

    @Test(arguments: corpus.map { $0.name })
    func tokenStreamIsPreserved(name: String) throws {
        let entry = try #require(corpus.first { $0.name == name })
        for upper in [true, false] {
            let result = SQLFormatter.formatDetailed(entry.sql, dialect: entry.dialect, options: SQLFormatOptions(uppercaseKeywords: upper))
            #expect(result.didFormat, "\(name): formatter backed out (verification failed or construct refused)")
            let before = stream(entry.sql, entry.dialect, foldCase: upper)
            let after = stream(result.text, entry.dialect, foldCase: upper)
            #expect(before == after, "\(name) (upper=\(upper)):\n\(result.text)")
        }
    }

    @Test(arguments: corpus.map { $0.name })
    func isIdempotent(name: String) throws {
        let entry = try #require(corpus.first { $0.name == name })
        let once = fmt(entry.sql, entry.dialect)
        let twice = fmt(once, entry.dialect)
        #expect(once == twice, "\(name):\n--- once\n\(once)\n--- twice\n\(twice)")
    }

    @Test func withoutUppercaseTheTextOfEveryWordIsUnchanged() {
        let out = fmt("select Post_Title, count(*) from WP_Posts where ID = 1", upper: false)
        #expect(out.contains("Post_Title") && out.contains("WP_Posts") && out.contains("count(*)"))
        #expect(out.contains("select") && out.contains("from") && out.contains("where"))
    }

    @Test func stringsAndCommentsAreByteIdentical() {
        let sql = "SELECT 'a  ;  b', \"x\", `q  r` /* keep   this */ FROM t -- keep   that"
        let out = fmt(sql)
        for part in ["'a  ;  b'", "\"x\"", "`q  r`", "/* keep   this */", "-- keep   that"] {
            #expect(out.contains(part), "\(part) in \(out)")
        }
    }

    @Test func identifiersEqualToKeywordsKeepTheirCase() {
        // Non-reserved words that are also common identifiers are never upper-cased.
        let out = fmt("select status, type, name, date, value, comment, key from events where end_date is null")
        for w in ["status", "type", "name", "date", "value", "comment", "key", "events", "end_date"] {
            #expect(out.contains(w), "\(w) in \(out)")
        }
        #expect(out.contains("SELECT"))
        #expect(out.contains("IS NULL"))
        // qualified names after a dot are identifiers even when they spell a keyword
        #expect(fmt("select t.select, t.from from t").contains("t.select,\n    t.from\nFROM t"))
    }

    @Test func constructsItWontTouchAreReturnedUnchanged() {
        let delim = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;"
        let r = SQLFormatter.formatDetailed(delim, dialect: my)
        #expect(!r.didFormat && r.text == delim)
        let psql = "\\c mydb\nselect 1"
        #expect(SQLFormatter.format(psql, dialect: pg) == psql)
        #expect(SQLFormatter.format("   \n ", dialect: my) == "   \n ")
        // "delimiter" is only special for MySQL
        #expect(SQLFormatter.formatDetailed("select 1 from delimiter x", dialect: pg).didFormat)
    }

    // MARK: Layout

    @Test func selectClausesOnSeparateLines() {
        #expect(fmt("select a, b from t where x = 1 order by a limit 5") == """
        SELECT
            a,
            b
        FROM t
        WHERE x = 1
        ORDER BY a
        LIMIT 5
        """)
    }

    @Test func singleItemSelectStaysOnOneLine() {
        #expect(fmt("select count(*) from wp_posts") == "SELECT count(*)\nFROM wp_posts")
        #expect(fmt("select 1") == "SELECT 1")
    }

    @Test func andOrAreIndentedUnderWhere() {
        #expect(fmt("select a from t where x = 1 and y = 2 or z = 3") == """
        SELECT a
        FROM t
        WHERE x = 1
            AND y = 2
            OR z = 3
        """)
    }

    @Test func betweenAndCaseDoNotBreak() {
        let out = fmt("select * from t where a between 1 and 10 and b = case when c = 1 and d = 2 then 3 else 4 end")
        #expect(out.contains("a BETWEEN 1 AND 10"))
        #expect(out.contains("CASE WHEN c = 1 AND d = 2 THEN 3 ELSE 4 END"))
        #expect(out.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("AND") }.count == 1)
    }

    @Test func joinsStartOnNewLines() {
        let out = fmt("select * from a left outer join b on a.id = b.id and b.x = 1 inner join c on c.id = a.id")
        #expect(out == """
        SELECT *
        FROM a
        LEFT OUTER JOIN b ON a.id = b.id
            AND b.x = 1
        INNER JOIN c ON c.id = a.id
        """)
    }

    @Test func leftAsFunctionIsNotAJoin() {
        let out = fmt("select left(name, 2), right(name, 1) from t")
        #expect(!out.contains("\nLEFT"))
        #expect(out.lowercased().contains("left(name, 2)"))
    }

    @Test func subqueriesAreIndented() {
        let out = fmt("select * from t where id in (select id from u where a = 1) and b = 2")
        #expect(out == """
        SELECT *
        FROM t
        WHERE id IN (
            SELECT id
            FROM u
            WHERE a = 1
        )
            AND b = 2
        """)
    }

    @Test func derivedTableAndNestedSubquery() {
        let out = fmt("select x.a from (select a, count(*) n from (select a from t) y group by a) x")
        let lines = out.components(separatedBy: "\n")
        #expect(lines[0] == "SELECT x.a")
        // each nesting level is indented one level deeper than its opening line
        let selects = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SELECT") }
        let indents = selects.map { $0.prefix { $0 == " " }.count }
        #expect(indents == indents.sorted() && Set(indents).count == 3)
    }

    @Test func functionCallsKeepTheirParenthesesTight() {
        let out = fmt("select concat(a,' ',b), count (*) from t")
        #expect(out.contains("concat(a, ' ', b)"))
        #expect(out.contains("count (*)"))  // spacing around a function's parenthesis is the author's call
    }

    @Test func updateSetItemsOnSeparateLines() {
        #expect(fmt("update t set a = 1, b = 2 where id = 3") == """
        UPDATE t
        SET
            a = 1,
            b = 2
        WHERE id = 3
        """)
        #expect(fmt("update t set a = 1 where id = 3") == "UPDATE t\nSET a = 1\nWHERE id = 3")
    }

    @Test func insertValuesAndUnion() {
        #expect(fmt("insert into t (a,b) values (1,2),(3,4)") == "INSERT INTO t (a, b)\nVALUES (1, 2), (3, 4)")
        #expect(fmt("select a from t union all select b from u") == "SELECT a\nFROM t\nUNION ALL\nSELECT b\nFROM u")
    }

    @Test func multiStatementScriptsAreFormattedPerStatement() {
        let out = fmt("select 1;select a from t where b = 1;  \n\n\n delete from t where x=1")
        #expect(out == """
        SELECT 1;

        SELECT a
        FROM t
        WHERE b = 1;

        DELETE FROM t
        WHERE x = 1
        """)
    }

    @Test func commentsStayWhereTheyWere() {
        let out = fmt("-- header\nselect a, -- first\n b from t -- tail\n;\n-- next\nselect 2")
        let lines = out.components(separatedBy: "\n")
        #expect(lines[0] == "-- header")
        #expect(out.contains("a, -- first"))
        #expect(out.contains("-- tail"))
        #expect(out.contains("-- next\nSELECT 2"))
    }

    @Test func lineCommentNeverSwallowsFollowingCode() {
        let out = fmt("select a -- c\n, b from t")
        let tokens = stream(out, my, foldCase: true)
        #expect(tokens == stream("select a -- c\n, b from t", my, foldCase: true))
    }

    @Test func trailingNewlineIsKept() {
        #expect(fmt("select 1\n").hasSuffix("1\n"))
        #expect(!fmt("select 1").hasSuffix("\n"))
    }

    @Test func indentWidthOption() {
        let out = SQLFormatter.format("select a, b from t", dialect: my, options: SQLFormatOptions(indentWidth: 2))
        #expect(out == "SELECT\n  a,\n  b\nFROM t")
    }

    @Test func randomCorruptionsNeverChangeTheTokenStream() {
        // Fuzz: chop the corpus at arbitrary points (producing unterminated strings, comments, half
        // statements). Whatever the formatter does, the verified result must keep the token stream.
        for entry in corpus {
            let chars = Array(entry.sql)
            for cut in stride(from: 1, to: chars.count, by: max(1, chars.count / 9)) {
                let sql = String(chars[0..<cut])
                let r = SQLFormatter.formatDetailed(sql, dialect: entry.dialect)
                #expect(stream(sql, entry.dialect, foldCase: true) == stream(r.text, entry.dialect, foldCase: true),
                        "\(entry.name) cut at \(cut)")
            }
        }
    }
}
