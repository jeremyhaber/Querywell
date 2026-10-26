import Foundation
import Testing
@testable import QuerywellCore

// MARK: - helpers

private func bytes(_ s: String) -> Data { Data(s.utf8) }
private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

private func rewrite(_ input: String, _ mapping: CollationMapping, chunk: Int? = nil, maxBuffered: Int = 8 * 1024 * 1024) -> String {
    let r = CollationRewriter(mapping: mapping, maxBufferedStatementBytes: maxBuffered)
    return text(run(r, Data(input.utf8), chunk: chunk))
}

private func run(_ r: CollationRewriter, _ data: Data, chunk: Int?) -> Data {
    var out = Data()
    if let chunk {
        var i = 0
        while i < data.count {
            let end = min(i + chunk, data.count)
            out.append(r.feed(data.subdata(in: i..<end)))
            i = end
        }
    } else {
        out.append(r.feed(data))
    }
    out.append(r.finish())
    return out
}

private func count(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }

private let m57 = CollationMapping.mysql57MariaDBCompatible

private struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

// MARK: - mapping

@Suite("Collation mapping")
struct CollationMappingTests {
    @Test func mysql57PresetExactNames() {
        let expectations: [(String, String?)] = [
            ("utf8mb4_0900_ai_ci", "utf8mb4_unicode_520_ci"),
            ("UTF8MB4_0900_AI_CI", "utf8mb4_unicode_520_ci"),
            ("utf8mb4_0900_as_ci", "utf8mb4_unicode_520_ci"),
            ("utf8mb4_0900_as_cs", "utf8mb4_bin"),
            ("utf8mb4_0900_bin", "utf8mb4_bin"),
            ("utf8mb4_de_pb_0900_ai_ci", "utf8mb4_unicode_520_ci"),
            ("utf8mb4_ja_0900_as_cs", "utf8mb4_bin"),
            ("utf8mb4_ja_0900_as_cs_ks", "utf8mb4_bin"),
            ("utf8mb4_uca1400_ai_ci", "utf8mb4_unicode_520_ci"),
            ("utf8mb4_uca1400_as_ci", "utf8mb4_unicode_520_ci"),
            ("utf8mb4_uca1400_ai_cs", "utf8mb4_bin"),
            ("utf8mb4_uca1400_nopad_ai_ci", "utf8mb4_unicode_520_ci"),
            ("utf8mb3_uca1400_ai_ci", "utf8_unicode_520_ci"),
            ("utf8mb3_general_ci", "utf8_general_ci"),
            ("utf8mb3_bin", "utf8_bin"),
            ("utf8mb3_unicode_ci", "utf8_unicode_ci"),
            ("utf8mb4_nopad_bin", "utf8mb4_bin"),
            // unchanged
            ("utf8mb4_unicode_ci", nil),
            ("utf8mb4_unicode_520_ci", nil),
            ("utf8mb4_general_ci", nil),
            ("utf8mb4_bin", nil),
            ("latin1_swedish_ci", nil),
            ("utf8_general_ci", nil),
            ("binary", nil),
            ("", nil),
            ("totally_unknown", nil),
        ]
        for (input, expected) in expectations {
            #expect(m57.mapCollation(input) == expected, "\(input)")
        }
    }

    @Test func mysql57PresetCharsets() {
        #expect(m57.mapCharset("utf8mb3") == "utf8")
        #expect(m57.mapCharset("UTF8MB3") == "utf8")
        #expect(m57.mapCharset("utf8mb4") == nil)
        #expect(m57.mapCharset("latin1") == nil)
        #expect(m57.mapCharset("binary") == nil)
    }

    @Test func legacyPreset() {
        let l = CollationMapping.legacyUnicodeCI
        #expect(l.mapCollation("utf8mb4_0900_ai_ci") == "utf8mb4_unicode_ci")
        #expect(l.mapCollation("utf8mb4_unicode_520_ci") == "utf8mb4_unicode_ci")
        #expect(l.mapCollation("utf8mb4_uca1400_ai_ci") == "utf8mb4_unicode_ci")
        #expect(l.mapCollation("utf8mb4_0900_bin") == "utf8mb4_bin")
        #expect(l.mapCollation("utf8mb4_0900_as_cs") == "utf8mb4_bin")
        #expect(l.mapCollation("utf8mb3_general_ci") == "utf8_general_ci")
        #expect(l.mapCollation("utf8mb4_unicode_ci") == nil)
        #expect(l.mapCharset("utf8mb3") == "utf8")
    }

    @Test func customForcesEverythingExceptBinary() {
        let c = CollationMapping.custom(charset: "utf8mb4", collation: "utf8mb4_unicode_ci")
        #expect(c.mapCharset("latin1") == "utf8mb4")
        #expect(c.mapCharset("utf8mb3") == "utf8mb4")
        #expect(c.mapCharset("utf8mb4") == nil)
        #expect(c.mapCharset("binary") == nil)
        #expect(c.mapCharset("DEFAULT") == nil)
        #expect(c.mapCollation("latin1_swedish_ci") == "utf8mb4_unicode_ci")
        #expect(c.mapCollation("utf8mb4_unicode_ci") == nil)
        #expect(c.mapCollation("latin1_bin") == "utf8mb4_bin")
        #expect(c.mapCollation("utf8mb4_0900_ai_ci") == "utf8mb4_unicode_ci")
        #expect(c.mapCollation("binary") == nil)
        var flat = c
        flat.preserveBinary = false
        #expect(flat.mapCollation("latin1_bin") == "utf8mb4_unicode_ci")
    }

    @Test func identityChangesNothing() {
        #expect(CollationMapping.identity.mapCollation("utf8mb4_0900_ai_ci") == nil)
        #expect(CollationMapping.identity.mapCharset("utf8mb3") == nil)
    }

    @Test func customTableAndRules() {
        let m = CollationMapping(charsets: ["foo": "bar"], collations: ["a_ci": "b_ci"],
                                 collationRules: [.init(prefix: "x_", suffix: "_ci", action: .swapPrefix("y_"))])
        #expect(m.mapCharset("FOO") == "bar")
        #expect(m.mapCollation("a_ci") == "b_ci")
        #expect(m.mapCollation("x_general_ci") == "y_general_ci")
        #expect(m.mapCollation("x_bin") == nil)
    }
}

// MARK: - statement level

@Suite("Collation rewriter: statements")
struct CollationStatementTests {
    private func check(_ input: String, _ expected: String, _ mapping: CollationMapping = m57,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rewrite(input, mapping) == expected, sourceLocation: sourceLocation)
        // identical result for every chunking
        #expect(rewrite(input, mapping, chunk: 1) == expected, "1-byte chunks", sourceLocation: sourceLocation)
        #expect(rewrite(input, mapping, chunk: 7) == expected, "7-byte chunks", sourceLocation: sourceLocation)
    }

    @Test func tableOptions() {
        check("CREATE TABLE t (a int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;\n",
              "CREATE TABLE t (a int) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;\n")
        check("CREATE TABLE t (a int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;",
              "CREATE TABLE t (a int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_520_ci;")
        check("CREATE TABLE t (a int) DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
              "CREATE TABLE t (a int) DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_unicode_520_ci;")
        check("CREATE TABLE t (a int) DEFAULT CHARACTER SET = utf8mb3 DEFAULT COLLATE = utf8mb3_bin;",
              "CREATE TABLE t (a int) DEFAULT CHARACTER SET = utf8 DEFAULT COLLATE = utf8_bin;")
        check("create table t (a int) default charset=UTF8MB3 collate=UTF8MB4_0900_AI_CI;",
              "create table t (a int) default charset=utf8 collate=utf8mb4_unicode_520_ci;")
    }

    @Test func columnOptions() {
        check("CREATE TABLE t (\n  `a` varchar(10) CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci NOT NULL,\n  `b` text COLLATE utf8mb4_0900_ai_ci\n);\n",
              "CREATE TABLE t (\n  `a` varchar(10) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL,\n  `b` text COLLATE utf8mb4_unicode_520_ci\n);\n")
    }

    @Test func alterConvert() {
        check("ALTER TABLE `t` CONVERT TO CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci;",
              "ALTER TABLE `t` CONVERT TO CHARACTER SET utf8 COLLATE utf8_general_ci;")
        check("ALTER DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
              "ALTER DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;")
        check("ALTER TABLE t MODIFY a varchar(5) COLLATE utf8mb4_0900_bin;",
              "ALTER TABLE t MODIFY a varchar(5) COLLATE utf8mb4_bin;")
    }

    @Test func createDatabaseWithVersionedComment() {
        check("CREATE DATABASE /*!32312 IF NOT EXISTS*/ `d` /*!40100 DEFAULT CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci */ /*!80016 DEFAULT ENCRYPTION='N' */;\n",
              "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `d` /*!40100 DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci */ /*!80016 DEFAULT ENCRYPTION='N' */;\n")
        check("CREATE SCHEMA d DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
              "CREATE SCHEMA d DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;")
    }

    @Test func setNames() {
        check("/*!50503 SET NAMES utf8mb3 */;", "/*!50503 SET NAMES utf8 */;")
        check("SET NAMES utf8mb3 COLLATE utf8mb3_general_ci;", "SET NAMES utf8 COLLATE utf8_general_ci;")
        check("SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;", "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_520_ci;")
        check("set names 'utf8mb3' collate 'utf8mb3_bin';", "set names 'utf8' collate 'utf8_bin';")
        check("/*!40101 SET NAMES utf8mb4 */;", "/*!40101 SET NAMES utf8mb4 */;")
        check("SET NAMES DEFAULT;", "SET NAMES DEFAULT;")
        check("SET NAMES binary;", "SET NAMES binary;")
    }

    @Test func setSessionVariables() {
        check("/*!50003 SET character_set_client  = utf8mb3 */ ;", "/*!50003 SET character_set_client  = utf8 */ ;")
        check("/*!50003 SET collation_connection  = utf8mb4_0900_ai_ci */ ;", "/*!50003 SET collation_connection  = utf8mb4_unicode_520_ci */ ;")
        check("SET @@session.collation_connection = utf8mb4_0900_ai_ci;", "SET @@session.collation_connection = utf8mb4_unicode_520_ci;")
        check("SET @@character_set_results = utf8mb3, collation_server = utf8mb4_0900_ai_ci;",
              "SET @@character_set_results = utf8, collation_server = utf8mb4_unicode_520_ci;")
        check("SET GLOBAL character_set_server = utf8mb3;", "SET GLOBAL character_set_server = utf8;")
        check("SET character_set_database := utf8mb3;", "SET character_set_database := utf8;")
    }

    @Test func variableReferencesAndNullsAreLeftAlone() {
        for s in ["/*!40101 SET @saved_cs_client     = @@character_set_client */;",
                  "/*!50003 SET character_set_client  = @saved_cs_client */ ;",
                  "/*!50003 SET collation_connection  = @saved_col_connection */ ;",
                  "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;",
                  "/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;",
                  "/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;",
                  "SET character_set_results = NULL;",
                  "SET @@session.character_set_results = NULL;"] {
            check(s + "\n", s + "\n", CollationMapping.custom(charset: "utf8mb4", collation: "utf8mb4_unicode_ci"))
            check(s + "\n", s + "\n")
        }
    }

    @Test func stringsCommentsAndIdentifiersInsideDDLAreNeverTouched() {
        let s = "CREATE TABLE t (\n  `utf8mb4_0900_ai_ci` int,\n  b varchar(5) DEFAULT 'COLLATE utf8mb4_0900_ai_ci' COMMENT 'CHARSET=utf8mb3 COLLATE=utf8mb4_0900_ai_ci',\n  c int DEFAULT 0 /* COLLATE utf8mb4_0900_ai_ci */ -- COLLATE utf8mb4_0900_ai_ci\n  ,d text COMMENT \"CHARACTER SET utf8mb3\"\n) COMMENT='it''s COLLATE utf8mb4_0900_ai_ci \\' COLLATE utf8mb4_0900_ai_ci';\n"
        check(s, s)
        check(s.replacingOccurrences(of: "\n) COMMENT=", with: "\n) COLLATE=utf8mb4_0900_ai_ci COMMENT="),
              s.replacingOccurrences(of: "\n) COMMENT=", with: "\n) COLLATE=utf8mb4_unicode_520_ci COMMENT="))
    }

    @Test func hashComment() {
        let s = "# COLLATE utf8mb4_0900_ai_ci\nCREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci;\n"
        check(s, "# COLLATE utf8mb4_0900_ai_ci\nCREATE TABLE t (a int) COLLATE=utf8mb4_unicode_520_ci;\n")
    }

    @Test func introducers() {
        check("CREATE TABLE t (a varchar(3) DEFAULT (_utf8mb3'abc'));", "CREATE TABLE t (a varchar(3) DEFAULT (_utf8'abc'));")
        check("CREATE TABLE t (a varchar(3) DEFAULT (_utf8mb4'abc'));", "CREATE TABLE t (a varchar(3) DEFAULT (_utf8mb4'abc'));")
        check("CREATE TABLE t (a varchar(3) DEFAULT (_binary 'abc'));", "CREATE TABLE t (a varchar(3) DEFAULT (_binary 'abc'));")
    }

    @Test func nonAllowListedStatementsAreNeverTouched() {
        let stmts = [
            "INSERT INTO t VALUES ('COLLATE utf8mb4_0900_ai_ci'), (_utf8mb3'x');\n",
            "INSERT INTO t VALUES (1);\nREPLACE INTO t VALUES ('CHARSET=utf8mb3');\n",
            "UPDATE t SET a = 'x' COLLATE utf8mb4_0900_ai_ci;\n",
            "SELECT 'a' COLLATE utf8mb4_0900_ai_ci;\n",
            "DELETE FROM t WHERE a = 'x' COLLATE utf8mb4_0900_ai_ci;\n",
            "LOCK TABLES `utf8mb4_0900_ai_ci` WRITE;\n",
            "USE `utf8mb3`;\n",
            "DROP TABLE IF EXISTS `COLLATE`;\n",
            "LOAD DATA INFILE 'f.csv' INTO TABLE t CHARACTER SET utf8mb3;\n",
            "-- COLLATE utf8mb4_0900_ai_ci\n",
            "/* CHARSET=utf8mb3 */\n",
            "\n\n  \t\n",
        ]
        for s in stmts { check(s, s) }
    }

    @Test func insertDataWithDDLLookalikesFollowedByRealDDL() {
        let data = "INSERT INTO `n` VALUES ('x; CREATE TABLE a (b int) COLLATE utf8mb4_0900_ai_ci;'),('y\\' ; COLLATE utf8mb4_0900_ai_ci'),('z''; SET NAMES utf8mb3;'),('-- \\\\','# /* no'),('*/ ;');\n"
        let input = data + "CREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci;\n" + data
        let expected = data + "CREATE TABLE t (a int) COLLATE=utf8mb4_unicode_520_ci;\n" + data
        check(input, expected)
    }

    @Test func unterminatedLastStatementIsStillRewritten() {
        check("CREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci", "CREATE TABLE t (a int) COLLATE=utf8mb4_unicode_520_ci")
        check("SET NAMES utf8mb3", "SET NAMES utf8")
    }

    @Test func crlfLineEndings() {
        check("CREATE TABLE t (\r\n  a int\r\n) COLLATE=utf8mb4_0900_ai_ci;\r\nINSERT INTO t VALUES (1);\r\n",
              "CREATE TABLE t (\r\n  a int\r\n) COLLATE=utf8mb4_unicode_520_ci;\r\nINSERT INTO t VALUES (1);\r\n")
    }

    @Test func customDelimiter() {
        let input = "DELIMITER //\nCREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW BEGIN\n  SET NEW.a = 'x' COLLATE utf8mb4_0900_ai_ci;\n  SET NEW.b = 'y';\nEND//\nDELIMITER ;\nCREATE TABLE u (a int) COLLATE=utf8mb4_0900_ai_ci;\n"
        let expected = input.replacingOccurrences(of: "'x' COLLATE utf8mb4_0900_ai_ci", with: "'x' COLLATE utf8mb4_unicode_520_ci")
            .replacingOccurrences(of: ") COLLATE=utf8mb4_0900_ai_ci", with: ") COLLATE=utf8mb4_unicode_520_ci")
        check(input, expected)
    }

    @Test func semicolonInsideBodyDoesNotEndStatementUnderCustomDelimiter() {
        let input = "DELIMITER $$\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  CREATE TEMPORARY TABLE x (a varchar(3) COLLATE utf8mb4_0900_ai_ci);\nEND$$\nDELIMITER ;\n"
        let expected = input.replacingOccurrences(of: "utf8mb4_0900_ai_ci", with: "utf8mb4_unicode_520_ci")
        check(input, expected)
    }

    @Test func copyBlocksAreStreamedUntouched() {
        let input = DumpFixtures.render(DumpFixtures.copyTemplate, .init())
        let expected = DumpFixtures.render(DumpFixtures.copyTemplate, .init(c4: "utf8mb4_unicode_520_ci"))
        check(input, expected)
        #expect(expected.contains("one\tCOLLATE utf8mb4_0900_ai_ci"))
        #expect(expected.contains("three 'unbalanced quote"))
    }

    @Test func nonAsciiAroundDDL() {
        check("CREATE TABLE `café` (`名前` varchar(5) COLLATE utf8mb4_0900_ai_ci COMMENT '日本語 😀') COLLATE=utf8mb4_0900_ai_ci;\n",
              "CREATE TABLE `café` (`名前` varchar(5) COLLATE utf8mb4_unicode_520_ci COMMENT '日本語 😀') COLLATE=utf8mb4_unicode_520_ci;\n")
    }

    @Test func customMappingForcesAll() {
        let c = CollationMapping.custom(charset: "utf8mb4", collation: "utf8mb4_unicode_ci")
        check("CREATE TABLE t (a varchar(3) CHARACTER SET latin1 COLLATE latin1_swedish_ci, b char(1) CHARACTER SET binary, c char(2) COLLATE latin1_bin) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;\nSET NAMES latin1;\n",
              "CREATE TABLE t (a varchar(3) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, b char(1) CHARACTER SET binary, c char(2) COLLATE utf8mb4_bin) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\nSET NAMES utf8mb4;\n",
              c)
    }

    @Test func legacyPresetStatement() {
        check("CREATE TABLE t (a int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;", "CREATE TABLE t (a int) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;",
              .legacyUnicodeCI)
    }

    @Test func identityMappingIsByteIdentical() {
        let s = DumpFixtures.render(DumpFixtures.mysql84Template, .init())
        #expect(rewrite(s, .identity) == s)
        #expect(rewrite(s, .identity, chunk: 13) == s)
    }
}

// MARK: - realistic dumps

@Suite("Collation rewriter: mysqldump 8.4 / MariaDB 11")
struct CollationDumpTests {
    private var mysql84: String { DumpFixtures.render(DumpFixtures.mysql84Template, .init()) }

    @Test func mysql84To57IsExactlyTheDDLChanges() {
        let expected = DumpFixtures.render(DumpFixtures.mysql84Template,
                                           .init(c4: "utf8mb4_unicode_520_ci", cs3: "utf8", c3: "utf8_general_ci"))
        let r = CollationRewriter(mapping: m57)
        let out = text(run(r, bytes(mysql84), chunk: nil))
        #expect(out == expected)
        // statistics
        let c4 = count(DumpFixtures.mysql84Template, "%C4%")
        #expect(r.rewriteCounts[CollationRewrite(kind: .collation, from: "utf8mb4_0900_ai_ci", to: "utf8mb4_unicode_520_ci")] == c4)
        #expect(r.rewriteCounts[CollationRewrite(kind: .collation, from: "utf8mb3_general_ci", to: "utf8_general_ci")] == count(DumpFixtures.mysql84Template, "%C3%"))
        #expect(r.rewriteCounts[CollationRewrite(kind: .charset, from: "utf8mb3", to: "utf8")] == count(DumpFixtures.mysql84Template, "%CS3%"))
        #expect(r.totalRewrites == c4 + count(DumpFixtures.mysql84Template, "%C3%") + count(DumpFixtures.mysql84Template, "%CS3%"))
        #expect(r.oversizedStatementCount == 0)
    }

    @Test func dataPayloadsSurviveByteForByte() {
        let out = rewrite(mysql84, m57)
        for line in mysql84.split(separator: "\n") where line.hasPrefix("INSERT INTO") {
            #expect(out.contains(String(line)), "\(line.prefix(60))")
        }
        #expect(out.contains("'COLLATE utf8mb4_0900_ai_ci and DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci'"))
        #expect(out.contains("it''s a \\'quote\\' ; CREATE TABLE x (a int) COLLATE utf8mb4_0900_ai_ci; -- c /* d */ # e"))
        #expect(out.contains("(_utf8mb3'x',_binary 'y',0x00,NULL,'utf8mb4_0900_ai_ci',2)"))
        #expect(out.contains("Café 日本語 😀 _utf8mb3\\'x\\' utf8mb3_general_ci"))
        // literals inside DDL/routine bodies too
        #expect(out.contains("DEFAULT 'utf8mb4_0900_ai_ci' COMMENT 'COLLATE utf8mb4_0900_ai_ci'"))
        #expect(out.contains("option_value = 'COLLATE utf8mb4_0900_ai_ci; still data'"))
        #expect(out.contains("IF NEW.option_value = 'COLLATE utf8mb4_0900_ai_ci' THEN"))
        #expect(out.contains("where (`wp_options`.`option_name` = 'COLLATE utf8mb4_0900_ai_ci')"))
        // untouched identifier / latin1 / binary parts
        #expect(out.contains("`utf8mb4_0900_ai_ci` int DEFAULT NULL"))
        #expect(out.contains("CHARACTER SET latin1 COLLATE latin1_swedish_ci"))
        #expect(out.contains("CHARACTER SET binary DEFAULT NULL"))
        #expect(out.contains("COLLATE utf8mb4_bin DEFAULT NULL"))
    }

    @Test func mysql84ToLegacy() {
        let expected = DumpFixtures.render(DumpFixtures.mysql84Template,
                                           .init(c4: "utf8mb4_unicode_ci", cs3: "utf8", c3: "utf8_general_ci"))
        #expect(rewrite(mysql84, .legacyUnicodeCI) == expected)
    }

    @Test func mysql84ToCustom() {
        let out = rewrite(mysql84, .custom(charset: "utf8mb4", collation: "utf8mb4_general_ci"))
        #expect(out.contains(") ENGINE=InnoDB AUTO_INCREMENT=1234 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;"))
        #expect(!out.contains("`option_name` varchar(191) COLLATE utf8mb4_0900_ai_ci"))
        #expect(!out.contains("latin1_swedish_ci"))
        #expect(!out.contains("CHARACTER SET latin1"))
        #expect(out.contains("CHARACTER SET binary"))
        #expect(out.contains("COLLATE utf8mb4_bin"))
        #expect(out.contains("COLLATE=utf8mb4_general_ci"))
        // INSERT lines unchanged
        for line in mysql84.split(separator: "\n") where line.hasPrefix("INSERT INTO") { #expect(out.contains(String(line))) }
    }

    @Test func mariadb11To57() {
        let input = DumpFixtures.render(DumpFixtures.mariadb11Template, .init(c4: "utf8mb4_uca1400_ai_ci"))
        let expected = DumpFixtures.render(DumpFixtures.mariadb11Template, .init(c4: "utf8mb4_unicode_520_ci", cs3: "utf8", c3: "utf8_general_ci"))
        let out = rewrite(input, m57)
        #expect(out == expected)
        // data with collation text and an embedded versioned-comment survives
        #expect(out.contains("'<p>COLLATE=utf8mb4_uca1400_ai_ci</p>'"))
        #expect(out.contains("'--\\n/*!40101 SET NAMES latin1 */;'"))
        #expect(out.hasPrefix("/*M!999999\\- enable the sandbox mode */\n-- MariaDB dump"))
    }

    @Test func mariadb11ToLegacy() {
        let input = DumpFixtures.render(DumpFixtures.mariadb11Template, .init(c4: "utf8mb4_uca1400_ai_ci"))
        let expected = DumpFixtures.render(DumpFixtures.mariadb11Template, .init(c4: "utf8mb4_unicode_ci", cs3: "utf8", c3: "utf8_general_ci"))
        #expect(rewrite(input, .legacyUnicodeCI) == expected)
    }

    @Test func rewriteIsIdempotent() {
        let once = rewrite(mysql84, m57)
        #expect(rewrite(once, m57) == once)
    }

    // The core streaming guarantee: any chunking gives the same bytes as a single feed.
    @Test func everyTwoWaySplitMatchesWholeInput() {
        let input = DumpFixtures.render(DumpFixtures.mysql84Template, .init())
        let data = bytes(input)
        let whole = text(run(CollationRewriter(mapping: m57), data, chunk: nil))
        var failures = 0
        for split in 0...data.count {
            let r = CollationRewriter(mapping: m57)
            var out = r.feed(data.subdata(in: 0..<split))
            out.append(r.feed(data.subdata(in: split..<data.count)))
            out.append(r.finish())
            if text(out) != whole { failures += 1 }
        }
        #expect(failures == 0)
    }

    @Test func oneByteAtATimeMatchesWholeInputForBothDumps() {
        for template in [DumpFixtures.mysql84Template, DumpFixtures.mariadb11Template] {
            let input = DumpFixtures.render(template, .init(c4: template == DumpFixtures.mariadb11Template ? "utf8mb4_uca1400_ai_ci" : "utf8mb4_0900_ai_ci"))
            let data = bytes(input)
            let whole = run(CollationRewriter(mapping: m57), data, chunk: nil)
            #expect(run(CollationRewriter(mapping: m57), data, chunk: 1) == whole)
            #expect(whole != data)
        }
    }

    @Test func randomChunkSizes() {
        let input = DumpFixtures.render(DumpFixtures.mysql84Template, .init()) + DumpFixtures.render(DumpFixtures.copyTemplate, .init())
        let data = bytes(input)
        let whole = run(CollationRewriter(mapping: m57), data, chunk: nil)
        var rng = LCG(state: 42)
        for _ in 0..<150 {
            let r = CollationRewriter(mapping: m57)
            var out = Data()
            var i = 0
            while i < data.count {
                let n = min(1 + rng.next(rng.next(2) == 0 ? 8 : 400), data.count - i)
                out.append(r.feed(data.subdata(in: i..<(i + n))))
                i += n
            }
            out.append(r.finish())
            #expect(out == whole)
        }
    }

    @Test func emptyChunksAreHarmless() {
        let r = CollationRewriter(mapping: m57)
        var out = r.feed(Data())
        out.append(r.feed(bytes("CREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci;")))
        out.append(r.feed(Data()))
        out.append(r.finish())
        #expect(text(out) == "CREATE TABLE t (a int) COLLATE=utf8mb4_unicode_520_ci;")
        #expect(text(CollationRewriter(mapping: m57).finish()).isEmpty)
    }

    @Test func nonUTF8BytesInDataPassThrough() {
        var data = bytes("CREATE TABLE t (a blob) COLLATE=utf8mb4_0900_ai_ci;\nINSERT INTO t VALUES ('")
        data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x80, 0x5C, 0x27])
        data.append(bytes("COLLATE utf8mb4_0900_ai_ci');\nCREATE TABLE u (a int) COLLATE=utf8mb4_0900_ai_ci;\n"))
        let out = run(CollationRewriter(mapping: m57), data, chunk: 3)
        var expected = bytes("CREATE TABLE t (a blob) COLLATE=utf8mb4_unicode_520_ci;\nINSERT INTO t VALUES ('")
        expected.append(contentsOf: [0xFF, 0xFE, 0x00, 0x80, 0x5C, 0x27])
        expected.append(bytes("COLLATE utf8mb4_0900_ai_ci');\nCREATE TABLE u (a int) COLLATE=utf8mb4_unicode_520_ci;\n"))
        #expect(out == expected)
    }
}

// MARK: - memory bounds

@Suite("Collation rewriter: bounded memory")
struct CollationMemoryTests {
    @Test func hugeExtendedInsertStreamsWithoutBuffering() {
        // A ~3 MB single-line extended INSERT; max statement buffer is 1 KB, so any buffering would show up
        // as an oversized statement or altered output.
        let row = "(1,'COLLATE utf8mb4_0900_ai_ci \\' ; --','CHARSET=utf8mb3 x'),"
        let insert = "INSERT INTO `big` VALUES " + String(repeating: row, count: 50_000) + "(2,'end','z');\n"
        #expect(insert.utf8.count > 3_000_000)
        let ddl = "CREATE TABLE `big` (a int) COLLATE=utf8mb4_0900_ai_ci;\n"
        let input = ddl + insert + ddl
        let r = CollationRewriter(mapping: m57, maxBufferedStatementBytes: 1024)
        let data = bytes(input)
        var out = Data()
        var i = 0
        var maxPending = 0
        while i < data.count {
            let end = min(i + 65_536, data.count)
            let piece = r.feed(data.subdata(in: i..<end))
            maxPending = max(maxPending, (end - i) - piece.count)  // input not yet emitted
            out.append(piece)
            i = end
        }
        out.append(r.finish())
        let expectedDDL = "CREATE TABLE `big` (a int) COLLATE=utf8mb4_unicode_520_ci;\n"
        #expect(text(out) == expectedDDL + insert + expectedDDL)
        #expect(r.oversizedStatementCount == 0)
        #expect(maxPending < 64, "look-ahead must stay tiny, was \(maxPending)")
    }

    @Test func oversizedDDLIsPassedThroughUnchangedAndCounted() {
        let big = "CREATE TABLE t (a int COMMENT '" + String(repeating: "x", count: 5000) + "') COLLATE=utf8mb4_0900_ai_ci;\n"
        let after = "CREATE TABLE u (a int) COLLATE=utf8mb4_0900_ai_ci;\n"
        let r = CollationRewriter(mapping: m57, maxBufferedStatementBytes: 1024)
        let out = text(run(r, bytes(big + after), chunk: 256))
        #expect(out == big + "CREATE TABLE u (a int) COLLATE=utf8mb4_unicode_520_ci;\n")
        #expect(r.oversizedStatementCount == 1)
    }

    @Test func manyStatementsInOneChunk() {
        let stmt = "CREATE TABLE t (a int) COLLATE=utf8mb4_0900_ai_ci;\nINSERT INTO t VALUES (1);\n"
        let input = String(repeating: stmt, count: 5000)
        let expected = String(repeating: stmt.replacingOccurrences(of: "utf8mb4_0900_ai_ci", with: "utf8mb4_unicode_520_ci"), count: 5000)
        #expect(rewrite(input, m57) == expected)
    }
}

// MARK: - scanner

@Suite("Collation scanner")
struct CollationScannerTests {
    @Test func reportsDDLUsageOnly() {
        let dump = DumpFixtures.render(DumpFixtures.mysql84Template, .init())
        let usage = CollationScanner.scan(bytes(dump))
        let t = DumpFixtures.mysql84Template
        #expect(usage.collations["utf8mb4_0900_ai_ci"] == count(t, "%C4%"))
        #expect(usage.collations["utf8mb3_general_ci"] == count(t, "%C3%"))
        #expect(usage.collations["latin1_swedish_ci"] == 1)
        #expect(usage.collations["utf8mb4_bin"] == 1)
        #expect(usage.charsets["utf8mb3"] == count(t, "%CS3%"))
        #expect(usage.charsets["latin1"] == 1)
        #expect((usage.charsets["utf8mb4"] ?? 0) >= 5)
        #expect(usage.charsets["binary"] == nil)
        #expect(usage.charsets["default"] == nil)
        #expect(usage.collations.keys.allSatisfy { !$0.hasPrefix("@") })
        // variable references and data are not collations
        #expect(usage.collations["saved_col_connection"] == nil)
    }

    @Test func unsupportedBySever() {
        let usage = CollationScanner.scan(bytes(DumpFixtures.render(DumpFixtures.mysql84Template, .init())))
        let server57: Set<String> = ["utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_unicode_520_ci", "utf8mb4_bin",
                                     "utf8_general_ci", "latin1_swedish_ci"]
        #expect(usage.unsupportedCollations(supportedBy: server57) == ["utf8mb3_general_ci", "utf8mb4_0900_ai_ci"])
        #expect(usage.unsupportedCharsets(supportedBy: ["utf8", "utf8mb4", "latin1", "binary"]) == ["utf8mb3"])
        #expect(usage.unsupportedCollations(supportedBy: Set(usage.collations.keys)).isEmpty)
    }

    @Test func mariaDB() {
        let usage = CollationScanner.scan(bytes(DumpFixtures.render(DumpFixtures.mariadb11Template, .init(c4: "utf8mb4_uca1400_ai_ci"))))
        #expect(usage.collations["utf8mb4_uca1400_ai_ci"] == count(DumpFixtures.mariadb11Template, "%C4%"))
        #expect(usage.collations["utf8mb4_0900_ai_ci"] == nil)
    }

    @Test func chunkedScanEqualsWholeScan() {
        let data = bytes(DumpFixtures.render(DumpFixtures.mysql84Template, .init()))
        let whole = CollationScanner.scan(data)
        let s = CollationScanner()
        var i = 0
        while i < data.count {
            let end = min(i + 5, data.count)
            s.feed(data.subdata(in: i..<end))
            i = end
        }
        s.finish()
        #expect(s.usage == whole)
    }

    @Test func emptyAndDataOnlyInputs() {
        #expect(CollationScanner.scan(Data()) == CollationUsage())
        #expect(CollationScanner.scan(bytes("INSERT INTO t VALUES ('COLLATE utf8mb4_0900_ai_ci');\n")) == CollationUsage())
    }

    @Test func caseInsensitiveNames() {
        let usage = CollationScanner.scan(bytes("CREATE TABLE t (a int) COLLATE=UTF8MB4_0900_AI_CI;"))
        #expect(usage.collations == ["utf8mb4_0900_ai_ci": 1])
    }
}
