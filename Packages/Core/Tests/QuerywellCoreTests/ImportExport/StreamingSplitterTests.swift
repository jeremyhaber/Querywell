import Foundation
import Testing

@testable import QuerywellCore

private func splitAll(_ script: String, family: SQLDialect.Family, chunk: Int? = nil) throws -> [SplitStatement] {
    let s = StreamingStatementSplitter(family: family)
    let bytes = Array(script.utf8)
    var out: [SplitStatement] = []
    if let chunk {
        var i = 0
        while i < bytes.count {
            let n = min(chunk, bytes.count - i)
            out += try s.feed(Data(bytes[i..<(i + n)]))
            i += n
        }
    } else {
        out += try s.feed(Data(bytes))
    }
    out += try s.finish()
    return out
}

private let mysqlScript = """
-- header comment; with a semicolon
/*M!999999\\- enable the sandbox mode */
/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
DROP TABLE IF EXISTS `a;b`;
CREATE TABLE `t` (id int, s varchar(10) DEFAULT 'a;b\\'c') ;
INSERT INTO t VALUES (1,'it''s; ok'),(2,"dq;\\"x"),(3,'\\\\');
# hash comment ; here
/* block ; comment */ SELECT 1;
-- a lone comment statement;
DELIMITER ;;
CREATE TRIGGER x BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; SET NEW.b = 2; END ;;
DELIMITER ;
SELECT 2;
  delimiter $$
SELECT 3 $$
delimiter ;
SELECT 'no trailing delimiter'
"""

@Suite("Streaming statement splitter")
struct StreamingSplitterTests {
    @Test(arguments: [nil, 1, 2, 3, 5, 7, 64, 1000])
    func mysqlScriptSplitsIdenticallyAtAnyChunkSize(chunk: Int?) throws {
        let statements = try splitAll(mysqlScript, family: .mysql, chunk: chunk)
        let texts = statements.map(\.text)
        #expect(texts.count == 9, "\(texts)")
        #expect(texts[1] == "DROP TABLE IF EXISTS `a;b`")
        #expect(texts[2] == "CREATE TABLE `t` (id int, s varchar(10) DEFAULT 'a;b\\'c')")
        #expect(texts[3] == "INSERT INTO t VALUES (1,'it''s; ok'),(2,\"dq;\\\"x\"),(3,'\\\\')")
        #expect(texts[4].hasSuffix("SELECT 1"))
        #expect(texts[5].hasPrefix("-- a lone comment statement;\nCREATE TRIGGER") || texts[5].hasPrefix("CREATE TRIGGER"))
        #expect(texts[5].contains("SET NEW.a = 1; SET NEW.b = 2; END"))
        #expect(texts[6] == "SELECT 2")
        #expect(texts[7] == "SELECT 3")
        #expect(texts[8] == "SELECT 'no trailing delimiter'")
        #expect(statements.map(\.index) == Array(0..<9))
        #expect(texts[0].contains("/*!40101 SET @OLD_CHARACTER_SET_CLIENT"))
    }

    @Test func chunkingNeverChangesTheResult() throws {
        let whole = try splitAll(mysqlScript, family: .mysql).map(\.text)
        for chunk in 1...40 {
            #expect(try splitAll(mysqlScript, family: .mysql, chunk: chunk).map(\.text) == whole, "chunk \(chunk)")
        }
    }

    @Test func agreesWithTheInMemorySplitterOnMySQL() throws {
        let script = """
        CREATE TABLE a (x int);
        INSERT INTO a VALUES (1), (2);
        INSERT INTO a VALUES ('semi;colon');
        DELIMITER //
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END//
        DELIMITER ;
        SELECT `weird;name` FROM a
        """
        let streaming = try splitAll(script, family: .mysql).map(\.text)
        let reference = StatementSplitter.split(script, dialect: SQLDialect(.mysql)).map(\.text)
        #expect(streaming.count == reference.count)
        for (s, r) in zip(streaming, reference) {
            #expect(s.trimmingCharacters(in: .whitespacesAndNewlines) == r.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func commentOnlyInputYieldsNothing() throws {
        #expect(try splitAll("-- nothing\n# also nothing\n/* and nothing */\n  \n", family: .mysql).isEmpty)
        #expect(try splitAll("-- nothing\n/* and\n /* nested */ nothing */\n", family: .postgres).isEmpty)
        #expect(try splitAll("", family: .mysql).isEmpty)
    }

    @Test func dashesAreOperatorsUnlessFollowedBySpaceOnMySQL() throws {
        let t = try splitAll("SELECT 1--1;\nSELECT 2 -- real comment ; \n;\nSELECT 5-3;", family: .mysql).map(\.text)
        #expect(t == ["SELECT 1--1", "SELECT 2 -- real comment ;", "SELECT 5-3"])
    }

    @Test func positionsAreReported() throws {
        let s = try splitAll("SELECT 1;\n\n  SELECT 2;\n-- c\nSELECT 3;", family: .mysql)
        #expect(s.map(\.startLine) == [1, 3, 4])  // a leading comment belongs to the statement
        #expect(s[1].startOffset == 13)
    }

    @Test func oversizedStatementsAreRejected() {
        let splitter = StreamingStatementSplitter(family: .mysql, maxStatementBytes: 100)
        #expect(throws: StreamingSplitterError.self) {
            _ = try splitter.feed(Data(("INSERT INTO t VALUES ('" + String(repeating: "x", count: 500) + "');").utf8))
        }
    }

    // MARK: PostgreSQL

    private static let pgScript = """
    \\restrict abc123XYZ
    SET statement_timeout = 0;
    -- comment with 'quote and ; semicolon
    /* block /* nested ; */ still comment ; */ SELECT 1;
    CREATE FUNCTION f(x integer) RETURNS integer LANGUAGE plpgsql AS $fn$
    BEGIN
      RETURN x * 2; -- semicolons; inside 'a body
    END;
    $fn$;
    CREATE FUNCTION g() RETURNS text AS $$ SELECT 'a;b' $$ LANGUAGE sql;
    INSERT INTO t VALUES (E'esc\\'aped; ok', 'std\\', $1, a$b);
    SELECT 'a\\';
    SELECT "ident;with;semis" FROM "t""x";
    COPY public.t (id, name, data) FROM stdin;
    1\tplain\t{"a": 1}
    2\ttab\\there\t\\N
    3\tnew\\nline \\\\ back\t[1, 2]
    \\.
    SELECT 99;
    CREATE FUNCTION h() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT CASE WHEN true THEN 2 ELSE 3 END; END;
    SELECT 100;
    \\unrestrict abc123XYZ
    """

    @Test(arguments: [nil, 1, 3, 11, 100])
    func postgresScript(chunk: Int?) throws {
        let t = try splitAll(Self.pgScript, family: .postgres, chunk: chunk).map(\.text)
        #expect(t.count == 11, "\(t)")
        #expect(t[0] == "SET statement_timeout = 0")
        #expect(t[1].hasSuffix("SELECT 1") && t[1].contains("nested"))
        #expect(t[2].contains("RETURN x * 2; -- semicolons; inside 'a body") && t[2].hasSuffix("$fn$"))
        #expect(t[3].hasSuffix("LANGUAGE sql"))
        #expect(t[4].hasPrefix("INSERT INTO t VALUES (E'esc\\'aped; ok'"))
        #expect(t[5] == "SELECT 'a\\'")  // standard strings: backslash is an ordinary character
        #expect(t[6] == "SELECT \"ident;with;semis\" FROM \"t\"\"x\"")
        #expect(t[7].hasPrefix("INSERT INTO public.t (id, name, data) VALUES ('1', 'plain', '{\"a\": 1}')"))
        #expect(t[7].contains("('2', 'tab\there', NULL)"))
        #expect(t[7].contains("E'new\nline \\\\ back'") || t[7].contains("new\nline"))
        #expect(t[8] == "SELECT 99")
        #expect(t[9].hasSuffix("END"))
        #expect(t[10] == "SELECT 100")
        // meta commands never surface
        #expect(!t.contains { $0.contains("restrict") })
    }

    @Test func copyBlocksAreBatched() throws {
        var script = "COPY s.t (id) FROM stdin;\n"
        for i in 0..<1250 { script += "\(i)\n" }
        script += "\\.\nSELECT 1;\n"
        let t = try splitAll(script, family: .postgres, chunk: 4096)
        #expect(t.map { $0.text.hasPrefix("INSERT INTO s.t (id) VALUES") }.filter { $0 }.count == 3)  // 500 + 500 + 250
        #expect(t.last?.text == "SELECT 1")
    }

    @Test func copyBlockAfterLeadingCommentsIsStillConverted() throws {
        let script = "--\n-- Data for Name: t; Type: TABLE DATA\n--\n\nCOPY public.t (a) FROM stdin;\n1\n2\n\\.\n\nSELECT 1;\n"
        let t = try splitAll(script, family: .postgres).map(\.text)
        #expect(t == ["INSERT INTO public.t (a) VALUES ('1'), ('2')", "SELECT 1"])
    }

    @Test func copyTextEscapes() {
        #expect(String(decoding: StreamingStatementSplitter.unescapeCopy(Array(#"a\tb\\c\nd\x41\101\q"#.utf8)), as: UTF8.self) == "a\tb\\c\ndAAq")
        #expect((try? StreamingStatementSplitter.copyRowLiteral(Array("1\t\\N\tit's".utf8))) == "('1', NULL, 'it''s')")
        #expect(StreamingStatementSplitter.copyTarget("COPY public.\"Weird Name\" (a, b) FROM stdin;") == "public.\"Weird Name\" (a, b)")
    }
}
