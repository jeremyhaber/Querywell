import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func texts(_ s: String, _ d: SQLDialect = my) -> [String] {
    StatementSplitter.split(s, dialect: d).map(\.text)
}

@Suite("Statement splitter")
struct StatementSplitterTests {
    @Test func basicSplitting() {
        #expect(texts("SELECT 1; SELECT 2;") == ["SELECT 1", "SELECT 2"])
        #expect(texts("SELECT 1;\n\nSELECT 2") == ["SELECT 1", "SELECT 2"])
        #expect(texts("") == [])
        #expect(texts("  \n ;; ; ") == [])
    }

    @Test func semicolonInsideQuotes() {
        #expect(texts("SELECT 'a;b'; SELECT \"c;d\"; SELECT `e;f`") == ["SELECT 'a;b'", "SELECT \"c;d\"", "SELECT `e;f`"])
    }

    @Test func mysqlBackslashEscapes() {
        // \' does not close the string on MySQL
        #expect(texts(#"SELECT 'it\'s; fine'; SELECT 2"#) == [#"SELECT 'it\'s; fine'"#, "SELECT 2"])
        #expect(texts(#"SELECT "a\"b;c"; SELECT 2"#) == [#"SELECT "a\"b;c""#, "SELECT 2"])
        // trailing escaped backslash then quote closes
        #expect(texts(#"SELECT 'a\\'; SELECT 2"#) == [#"SELECT 'a\\'"#, "SELECT 2"])
    }

    @Test func doubledQuoteEscapes() {
        #expect(texts("SELECT 'it''s; fine'; SELECT 2") == ["SELECT 'it''s; fine'", "SELECT 2"])
        #expect(texts("SELECT `a``;b`; SELECT 2") == ["SELECT `a``;b`", "SELECT 2"])
        #expect(texts("SELECT 'it''s; fine'; SELECT 2", pg) == ["SELECT 'it''s; fine'", "SELECT 2"])
    }

    @Test func postgresBackslashIsLiteralInPlainStrings() {
        // On Postgres a backslash does not escape, so the string ends at the second quote.
        #expect(texts(#"SELECT 'a\'; SELECT 2"#, pg) == [#"SELECT 'a\'"#, "SELECT 2"])
        // …but E'' strings do honour it.
        #expect(texts(#"SELECT E'a\'; b'; SELECT 2"#, pg) == [#"SELECT E'a\'; b'"#, "SELECT 2"])
    }

    @Test func postgresDoubleQuotedIdentifier() {
        #expect(texts("SELECT \"a;b\" FROM t; SELECT 2", pg) == ["SELECT \"a;b\" FROM t", "SELECT 2"])
        #expect(texts("SELECT \"a\"\";b\"; SELECT 2", pg) == ["SELECT \"a\"\";b\"", "SELECT 2"])
    }

    @Test func lineComments() {
        #expect(texts("SELECT 1 -- ; not a split\n; SELECT 2") == ["SELECT 1 -- ; not a split", "SELECT 2"])
        #expect(texts("SELECT 1 # ; hidden\n; SELECT 2") == ["SELECT 1 # ; hidden", "SELECT 2"])
        // '#' is not a comment on Postgres (it is an operator)
        #expect(texts("SELECT 1 # 2; SELECT 3", pg) == ["SELECT 1 # 2", "SELECT 3"])
    }

    @Test func mysqlDoubleDashNeedsWhitespace() {
        // `1--1;` is arithmetic, not a comment, on MySQL
        #expect(texts("SELECT 1--1; SELECT 2") == ["SELECT 1--1", "SELECT 2"])
        #expect(texts("SELECT 1--1; SELECT 2", pg) == ["SELECT 1--1; SELECT 2"])  // comment to end of line on Postgres
    }

    @Test func blockComments() {
        #expect(texts("SELECT 1 /* ; */; SELECT 2") == ["SELECT 1 /* ; */", "SELECT 2"])
        #expect(texts("/* a; b */ SELECT 1; SELECT 2") == ["/* a; b */ SELECT 1", "SELECT 2"])
    }

    @Test func postgresBlockCommentsNest() {
        #expect(texts("SELECT 1 /* a /* b; */ c; */; SELECT 2", pg) == ["SELECT 1 /* a /* b; */ c; */", "SELECT 2"])
        // MySQL comments do not nest: the first */ ends it.
        #expect(texts("SELECT 1 /* a /* b */; SELECT 2") == ["SELECT 1 /* a /* b */", "SELECT 2"])
    }

    @Test func commentOnlyChunksAreDropped() {
        #expect(texts("-- hello\n/* x */\n;") == [])
        #expect(texts("SELECT 1; -- trailing\n-- more\n") == ["SELECT 1"])
    }

    @Test func trailingCommentOnSameLineStaysWithPreviousStatement() {
        let s = StatementSplitter.split("SELECT 1; -- one\nSELECT 2; /* two */\nSELECT 3", dialect: my)
        #expect(s.map(\.text) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test func leadingCommentsAreKept() {
        #expect(texts("-- first\nSELECT 1;\n/* c */ SELECT 2") == ["-- first\nSELECT 1", "/* c */ SELECT 2"])
    }

    @Test func versionedCommentsAreExecutableContent() {
        let dump = """
        /*!40101 SET NAMES utf8mb4 */;
        /*!50503 SET character_set_client = utf8mb4 */;
        CREATE TABLE t (a int) /*!50100 PARTITION BY HASH (a) */;
        """
        let s = texts(dump)
        #expect(s.count == 3)
        #expect(s[0] == "/*!40101 SET NAMES utf8mb4 */")
        #expect(s[2].hasSuffix("*/"))
        // MariaDB flavour
        #expect(texts("/*M!100100 SET @a=1 */; SELECT 1").count == 2)
        // plain block comments only → dropped
        #expect(texts("/* just a comment */;") == [])
        // semicolon inside the versioned comment doesn't split
        #expect(texts("/*!50000 SELECT 1; SELECT 2 */; SELECT 3").count == 2)
    }

    @Test func versionedCommentIsNotSpecialOnPostgres() {
        #expect(texts("/*! x */; SELECT 1", pg) == ["SELECT 1"])
    }

    @Test func dollarQuotedStrings() {
        let fn = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT f()"
        #expect(texts(fn, pg) == ["CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql", "SELECT f()"])
        let tagged = "SELECT $body$ a; $$ b; $body$; SELECT 2"
        #expect(texts(tagged, pg) == ["SELECT $body$ a; $$ b; $body$", "SELECT 2"])
        // positional parameters are not dollar quotes
        #expect(texts("SELECT $1; SELECT $2", pg) == ["SELECT $1", "SELECT $2"])
        // unterminated dollar quote swallows the rest
        #expect(texts("SELECT $$ a; b", pg) == ["SELECT $$ a; b"])
        // identifier containing $ is not a dollar quote
        #expect(texts("SELECT a$b$ FROM t; SELECT 2", pg) == ["SELECT a$b$ FROM t", "SELECT 2"])
    }

    @Test func postgresBeginAtomicBody() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT CASE WHEN true THEN 1 END; SELECT 2; END; SELECT 3"
        let s = texts(sql, pg)
        #expect(s.count == 2)
        #expect(s[0].hasSuffix("SELECT 2; END"))
        #expect(s[1] == "SELECT 3")
    }

    @Test func delimiterCommand() {
        let script = """
        SELECT 1;
        DELIMITER //
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          SELECT 2;
        END//
        DELIMITER ;
        SELECT 3;
        """
        let s = texts(script)
        #expect(s.count == 3)
        #expect(s[0] == "SELECT 1")
        #expect(s[1].hasPrefix("CREATE PROCEDURE p()"))
        #expect(s[1].hasSuffix("END"))
        #expect(s[1].contains("SELECT 1;\n  SELECT 2;"))
        #expect(s[2] == "SELECT 3")
    }

    @Test func delimiterDollarAndGluedToWord() {
        let script = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;\nSELECT 2;"
        #expect(texts(script) == ["CREATE PROCEDURE p() BEGIN SELECT 1; END", "SELECT 2"])
    }

    @Test func delimiterInsideStringIsIgnored() {
        let script = "DELIMITER //\nSELECT '//' AS a//\nSELECT 2//"
        #expect(texts(script) == ["SELECT '//' AS a", "SELECT 2"])
    }

    @Test func delimiterIsCaseInsensitiveAndNeedsStatementStart() {
        #expect(texts("delimiter ;;\nSELECT 1;;\nSELECT 2;;") == ["SELECT 1", "SELECT 2"])
        // Mid-statement "DELIMITER" is just a word
        #expect(texts("SELECT delimiter FROM t; SELECT 2") == ["SELECT delimiter FROM t", "SELECT 2"])
    }

    @Test func delimiterNotRecognisedOnPostgres() {
        #expect(texts("DELIMITER //\nSELECT 1;", pg) == ["DELIMITER //\nSELECT 1"])
    }

    @Test func rangesPointBackIntoTheSource() {
        let script = "SELECT 1;\n  SELECT 'é😀';\nSELECT 3"
        let s = StatementSplitter.split(script, dialect: my)
        #expect(s.count == 3)
        for st in s { #expect(String(script[st.range]) == st.text) }
        #expect(s[1].startLine == 2)
        #expect(s[2].startLine == 3)
        // UTF-16 offsets agree with NSString
        let ns = script as NSString
        for st in s {
            let r = NSRange(location: st.utf16Range.lowerBound, length: st.utf16Range.count)
            #expect(ns.substring(with: r) == st.text)
        }
        #expect(s.map(\.index) == [0, 1, 2])
    }

    @Test func statementAtOffset() {
        let script = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let s = StatementSplitter.split(script, dialect: my)
        #expect(StatementSplitter.statement(at: 0, in: s)?.text == "SELECT 1")
        #expect(StatementSplitter.statement(at: 12, in: s)?.text == "SELECT 2")
        #expect(StatementSplitter.statement(at: 9, in: s)?.text == "SELECT 1")  // right after the ';'
        #expect(StatementSplitter.statement(at: 500, in: s)?.text == "SELECT 3")
        #expect(StatementSplitter.statement(at: 0, in: []) == nil)
    }

    @Test func unterminatedConstructsRunToEnd() {
        #expect(texts("SELECT 'abc; SELECT 2") == ["SELECT 'abc; SELECT 2"])
        #expect(texts("SELECT 1 /* oops; SELECT 2") == ["SELECT 1 /* oops; SELECT 2"])
    }

    @Test func crlfAndUnicode() {
        #expect(texts("SELECT 'ü';\r\nSELECT '日本語';\r\n") == ["SELECT 'ü'", "SELECT '日本語'"])
        #expect(texts("SELECT 1 AS 名前; SELECT 2") == ["SELECT 1 AS 名前", "SELECT 2"])
    }

    @Test func realisticMySQLDump() {
        let dump = """
        -- MySQL dump 10.13
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        DROP TABLE IF EXISTS `t`;
        CREATE TABLE `t` (
          `id` int NOT NULL, `s` varchar(10) DEFAULT 'a;b'
        ) ENGINE=InnoDB COMMENT='x; y';
        INSERT INTO `t` VALUES (1,'it\\'s;'),(2,'q"uote;');
        """
        let s = texts(dump)
        #expect(s.count == 4)
        #expect(s[3].hasSuffix("'q\"uote;')"))
    }
}

@Suite("SQL lexer")
struct SQLLexerTests {
    @Test func tokenKinds() {
        let lexer = SQLLexer(my)
        let toks = lexer.tokenize("SELECT `a` , 'b', 12.5e-3 -- c\n")
        #expect(toks.map(\.kind).filter { $0 != .whitespace } == [.word, .quotedIdentifier, .symbol, .string, .symbol, .number, .lineComment])
    }

    @Test func identifierValue() {
        let lexer = SQLLexer(my)
        #expect(lexer.tokenize("`a``b`")[0].identifierValue == "a`b")
        #expect(SQLLexer(pg).tokenize("\"a\"\"b\"")[0].identifierValue == "a\"b")
    }

    @Test func tokensTileTheSource() {
        let src = "SELECT /*! x */ 'a\\'b', `c`, $1 -- end"
        for lexer in [SQLLexer(my), SQLLexer(pg)] {
            let toks = lexer.tokenize(src)
            #expect(toks.map(\.text).joined() == src)
        }
    }
}
