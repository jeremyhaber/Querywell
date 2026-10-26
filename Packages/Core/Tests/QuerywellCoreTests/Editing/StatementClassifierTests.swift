import Foundation
import Testing

@testable import QuerywellCore

private let myC = StatementClassifier(dialect: SQLDialect(.mysql))
private let pgC = StatementClassifier(dialect: SQLDialect(.postgresql))

private func kind(_ sql: String, pg: Bool = false) -> StatementKind {
    (pg ? pgC : myC).classify(text: sql).kind
}

@Suite("Statement classifier")
struct StatementClassifierTests {
    @Test(arguments: [
        "SELECT 1", "select * from t where a = 1", "  (SELECT 1) UNION (SELECT 2)", "SHOW TABLES", "SHOW CREATE TABLE t",
        "DESCRIBE t", "DESC t", "EXPLAIN SELECT * FROM t", "EXPLAIN FORMAT=JSON SELECT 1",
        "EXPLAIN DELETE FROM t", "VALUES (1),(2)", "TABLE t", "WITH c AS (SELECT 1) SELECT * FROM c",
        "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<5) SELECT * FROM c",
        "SELECT sleep(1)", "SELECT SLEEP(0.1)", "SELECT REPLACE(a, 'x', 'y') FROM t",
        "SELECT INSERT('abc', 1, 1, 'x')", "SELECT concat(replace(a,'a','b'), insert(b,1,1,'c')) FROM t",
        "-- DROP TABLE t\nSELECT 1", "/* DELETE FROM t */ SELECT 1", "SELECT 'DROP TABLE t; DELETE FROM x'",
        "SELECT \"DROP\" FROM t", "SELECT `delete` FROM t", "SELECT * FROM t WHERE a = 'for update'",
        "SELECT 1; ", "EXPLAIN ANALYZE FALSE", "HELP 'contents'", "CHECKSUM TABLE t",
        "EXPLAIN t", "SELECT a AS `into` FROM t",
    ])
    func readStatements(sql: String) {
        let c = myC.classify(text: sql)
        // "EXPLAIN ANALYZE FALSE" is nonsense but must not crash; skip it for the kind assertion
        if sql.hasPrefix("EXPLAIN ANALYZE FALSE") { return }
        #expect(c.kind == .read, "\(sql)")
        #expect(!c.isDestructive, "\(sql)")
    }

    @Test(arguments: [
        "INSERT INTO t VALUES (1)", "INSERT t (a) VALUES (1)", "insert ignore into t set a=1", "REPLACE INTO t VALUES (1)",
        "UPDATE t SET a=1", "DELETE FROM t", "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE",
        "LOAD DATA INFILE '/x' INTO TABLE t", "CALL p()", "DO SLEEP(1)", "SELECT * FROM t FOR UPDATE",
        "SELECT * FROM t LOCK IN SHARE MODE", "SELECT * FROM t FOR SHARE", "SELECT a INTO @x FROM t",
        "SELECT * INTO OUTFILE '/tmp/x' FROM t", "SELECT (SELECT 1 FROM t FOR UPDATE)",
        "WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c", "WITH c AS (SELECT 1) UPDATE t SET a=1",
        "WITH c AS (SELECT 1) DELETE FROM t", "EXPLAIN ANALYZE DELETE FROM t", "EXPLAIN ANALYSE UPDATE t SET a=1",
        "SET GLOBAL max_connections = 5", "SET PERSIST x = 1", "SET PASSWORD = 'x'", "SET @@GLOBAL.sql_mode = ''",
        "START TRANSACTION READ WRITE", "SET TRANSACTION READ WRITE", "FLUSH PRIVILEGES", "KILL 5",
        "OPTIMIZE TABLE t", "ANALYZE TABLE t", "LOCK TABLES t WRITE", "RESET MASTER", "START REPLICA",
        "SELECT /*! 1, */ 2 FROM t FOR UPDATE",
    ])
    func writeStatements(sql: String) {
        let c = myC.classify(text: sql)
        #expect(c.kind == .write, "\(sql) -> \(c.kind)")
    }

    @Test(arguments: [
        "CREATE TABLE t (a int)", "create or replace view v as select 1", "ALTER TABLE t ADD COLUMN b int",
        "DROP TABLE t", "TRUNCATE TABLE t", "TRUNCATE t", "RENAME TABLE a TO b", "GRANT ALL ON *.* TO u",
        "REVOKE ALL ON *.* FROM u", "COMMENT ON TABLE t IS 'x'", "CREATE DATABASE d", "DROP DATABASE d",
        "CREATE INDEX i ON t (a)", "DROP INDEX i ON t",
    ])
    func ddlStatements(sql: String) {
        #expect(myC.classify(text: sql).kind == .ddl, "\(sql)")
    }

    @Test(arguments: [
        "BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT a", "ROLLBACK TO SAVEPOINT a",
        "RELEASE SAVEPOINT a", "START TRANSACTION READ ONLY", "START TRANSACTION WITH CONSISTENT SNAPSHOT", "XA START 'x'",
    ])
    func transactionStatements(sql: String) {
        #expect(myC.classify(text: sql).kind == .transaction, "\(sql)")
    }

    @Test(arguments: [
        "SET NAMES utf8mb4", "SET autocommit = 0", "SET @a = 1", "SET SESSION sql_mode = ''", "SET sql_safe_updates = 1",
        "USE mydb", "SET TRANSACTION ISOLATION LEVEL READ COMMITTED", "PREPARE s FROM 'select 1'", "DEALLOCATE PREPARE s",
        "SET @@SESSION.sql_mode = ''",
    ])
    func sessionStatements(sql: String) {
        #expect(myC.classify(text: sql).kind == .session, "\(sql)")
    }

    @Test(arguments: ["FROBNICATE t", "", "()", "123", "'select 1'", "EXECUTE s", "SELECT"])
    func unknownOrConservative(sql: String) {
        let c = myC.classify(text: sql)
        if sql == "EXECUTE s" { #expect(c.kind == .write); return }
        if sql == "SELECT" { #expect(c.kind == .read); return }
        #expect(c.kind == .unknown, "\(sql)")
        #expect(c.kind.isWriteLike)
        #expect(c.isDestructive)
    }

    @Test func commentsCannotHideKeywords() {
        #expect(kind("/* SELECT */ DELETE FROM t") == .write)
        #expect(kind("-- harmless\nDROP TABLE t") == .ddl)
        #expect(kind("# note\nUPDATE t SET a = 1") == .write)
        #expect(kind("/*!50000 DROP TABLE t */") == .ddl)
        #expect(kind("/*!50000 DELETE FROM t */") == .write)
        #expect(kind("/*M!100000 TRUNCATE t */") == .ddl)
        #expect(myC.classify(text: "/*!40101 DROP TABLE t */").isDestructive)
        #expect(kind("SELECT 1 /* ; DROP TABLE t */") == .read)
    }

    @Test func stringsContainingKeywordsStayReads() {
        #expect(kind("SELECT 'DROP TABLE users'") == .read)
        #expect(kind("SELECT \"DELETE FROM t\" AS q") == .read)
        #expect(kind("SELECT * FROM t WHERE note = 'x; UPDATE t SET a=1'") == .read)
        #expect(kind("SELECT $$DROP TABLE t$$", pg: true) == .read)
    }

    @Test func cteWithDataModification() {
        #expect(kind("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", pg: true) == .write)
        #expect(kind("WITH i AS (INSERT INTO t VALUES (1) RETURNING id) SELECT id FROM i", pg: true) == .write)
        #expect(kind("WITH u AS (UPDATE t SET a=1 WHERE id=1 RETURNING *) SELECT * FROM u", pg: true) == .write)
        let c = pgC.classify(text: "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d")
        #expect(c.isDestructive)
        #expect(c.isUnfilteredMutation)
        let filtered = pgC.classify(text: "WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d")
        #expect(filtered.isDestructive)
        #expect(!filtered.isUnfilteredMutation)
        #expect(filtered.targetTables.first == TableReference(name: "t"))
    }

    @Test func cteReadOnlyWithKeywordLikeNames() {
        #expect(kind("WITH deleted AS (SELECT 1), updated AS (SELECT 2) SELECT * FROM deleted, updated") == .read)
        #expect(kind("WITH c AS (SELECT replace(a,'x','y') FROM t) SELECT * FROM c") == .read)
    }

    @Test func explainAnalyzeVariants() {
        #expect(kind("EXPLAIN ANALYZE SELECT * FROM t") == .read)
        #expect(kind("EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t WHERE a=1", pg: true) == .write)
        #expect(kind("EXPLAIN (ANALYZE) INSERT INTO t VALUES (1)", pg: true) == .write)
        #expect(kind("EXPLAIN (ANALYZE false) DELETE FROM t", pg: true) == .read)
        #expect(kind("EXPLAIN (VERBOSE) DELETE FROM t", pg: true) == .read)
        #expect(kind("EXPLAIN ANALYZE VERBOSE UPDATE t SET a=1", pg: true) == .write)
        #expect(myC.classify(text: "EXPLAIN ANALYZE DELETE FROM t").isDestructive)
        #expect(!myC.classify(text: "EXPLAIN DELETE FROM t").isDestructive)
        #expect(myC.classify(text: "EXPLAIN ANALYZE DELETE FROM t").isUnfilteredMutation)
    }

    @Test func sideEffectFunctionsInSelect() {
        #expect(kind("SELECT nextval('s')", pg: true) == .write)
        #expect(kind("SELECT pg_terminate_backend(123)", pg: true) == .write)
        #expect(kind("SELECT setval('s', 10)", pg: true) == .write)
        #expect(kind("SELECT pg_sleep(1)", pg: true) == .read)
        #expect(kind("SELECT lo_unlink(1234)", pg: true) == .write)
        #expect(kind("SELECT now()", pg: true) == .read)
    }

    @Test func postgresSpecifics() {
        #expect(kind("COPY t FROM '/tmp/x.csv'", pg: true) == .write)
        #expect(kind("COPY t TO STDOUT", pg: true) == .read)
        #expect(kind("COPY (SELECT 1) TO STDOUT", pg: true) == .read)
        #expect(kind("COPY t TO '/tmp/x'", pg: true) == .write)
        #expect(kind("SELECT * INTO newtable FROM t", pg: true) == .write)
        #expect(kind("SELECT * FROM t FOR NO KEY UPDATE", pg: true) == .write)
        #expect(kind("SET search_path TO a, b", pg: true) == .session)
        #expect(kind("SET LOCAL x = 1", pg: true) == .session)
        #expect(kind("RESET ALL", pg: true) == .session)
        #expect(kind("DISCARD ALL", pg: true) == .session)
        #expect(kind("VACUUM t", pg: true) == .write)
        #expect(kind("END", pg: true) == .transaction)
        #expect(kind("DO $$ BEGIN PERFORM 1; END $$", pg: true) == .write)
        #expect(kind("CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql", pg: true) == .ddl)
        #expect(kind("PREPARE TRANSACTION 'x'", pg: true) == .transaction)
        #expect(kind("PREPARE p AS SELECT 1", pg: true) == .session)
        #expect(kind("TABLE t", pg: true) == .read)
    }

    // MARK: Destructive & WHERE

    @Test func destructiveFlags() {
        func d(_ s: String) -> Bool { myC.classify(text: s).isDestructive }
        #expect(d("DELETE FROM t WHERE id = 1"))
        #expect(d("UPDATE t SET a = 1 WHERE id = 1"))
        #expect(d("DROP TABLE t"))
        #expect(d("DROP DATABASE x"))
        #expect(d("TRUNCATE t"))
        #expect(d("RENAME TABLE a TO b"))
        #expect(d("ALTER TABLE t DROP COLUMN c"))
        #expect(d("ALTER TABLE t RENAME TO u"))
        #expect(d("ALTER TABLE t TRUNCATE PARTITION p0"))
        #expect(d("REPLACE INTO t VALUES (1)"))
        #expect(d("MERGE INTO t USING s ON t.id=s.id WHEN MATCHED THEN DELETE"))
        #expect(!d("SELECT * FROM t"))
        #expect(!d("INSERT INTO t VALUES (1)"))
        #expect(!d("INSERT INTO t VALUES (1) ON DUPLICATE KEY UPDATE a = 2"))
        #expect(!d("ALTER TABLE t ADD COLUMN c int"))
        #expect(!d("CREATE TABLE t (a int)"))
        #expect(!d("CALL p()"))
        #expect(!d("GRANT SELECT ON t TO u"))
    }

    @Test func whereDetection() {
        func w(_ s: String) -> Bool { myC.classify(text: s).hasWhereClause }
        func u(_ s: String) -> Bool { myC.classify(text: s).isUnfilteredMutation }
        #expect(w("DELETE FROM t WHERE id = 1"))
        #expect(!w("DELETE FROM t"))
        #expect(!u("DELETE FROM t WHERE id = 1"))
        #expect(u("DELETE FROM t"))
        #expect(u("UPDATE t SET a = 1"))
        #expect(!u("UPDATE t SET a = 1 WHERE id = 2"))
        // a WHERE inside a subquery doesn't count for the outer statement
        #expect(u("UPDATE t SET a = (SELECT b FROM s WHERE s.id = 1)"))
        #expect(u("DELETE FROM t ORDER BY id LIMIT 10"))
        #expect(!u("DELETE FROM t WHERE id > 1 ORDER BY id LIMIT 10"))
        // tautologies are not filters
        #expect(u("DELETE FROM t WHERE 1"))
        #expect(u("DELETE FROM t WHERE 1=1"))
        #expect(u("UPDATE t SET a = 1 WHERE TRUE"))
        #expect(!u("DELETE FROM t WHERE 1 = 2"))
        #expect(!u("DELETE FROM t WHERE id IN (SELECT id FROM s WHERE 1)"))
        // the word WHERE inside a string or comment is not a clause
        #expect(u("DELETE FROM t /* WHERE id=1 */"))
        #expect(u("DELETE FROM t -- WHERE id=1"))
        #expect(!w("SELECT * FROM t"))
        #expect(w("SELECT * FROM t WHERE a = 1"))
        #expect(!u("TRUNCATE t"))
        #expect(!u("SELECT 1"))
    }

    // MARK: Targets

    @Test func targetTables() {
        func tt(_ s: String, pg: Bool = false) -> [TableReference] { (pg ? pgC : myC).classify(text: s).targetTables }
        #expect(tt("DELETE FROM t WHERE a=1") == [TableReference(name: "t")])
        #expect(tt("DELETE FROM `db`.`t`") == [TableReference(schema: "db", name: "t")])
        #expect(tt("DELETE FROM ONLY s.t WHERE a=1", pg: true) == [TableReference(schema: "s", name: "t")])
        #expect(tt("UPDATE db.t SET a=1") == [TableReference(schema: "db", name: "t")])
        #expect(tt("UPDATE LOW_PRIORITY IGNORE t SET a=1") == [TableReference(name: "t")])
        #expect(tt("UPDATE t1 JOIN t2 ON t1.a=t2.a SET t1.b=1") == [TableReference(name: "t1"), TableReference(name: "t2")])
        #expect(tt("INSERT INTO t (a) VALUES (1)") == [TableReference(name: "t")])
        #expect(tt("INSERT IGNORE t SET a=1") == [TableReference(name: "t")])
        #expect(tt("REPLACE INTO `a b` VALUES (1)") == [TableReference(name: "a b")])
        #expect(tt("TRUNCATE TABLE x.y") == [TableReference(schema: "x", name: "y")])
        #expect(tt("TRUNCATE a, b", pg: true) == [TableReference(name: "a"), TableReference(name: "b")])
        #expect(tt("DROP TABLE IF EXISTS a, b.c") == [TableReference(name: "a"), TableReference(schema: "b", name: "c")])
        #expect(tt("ALTER TABLE `t` ADD c int") == [TableReference(name: "t")])
        #expect(tt("RENAME TABLE a TO b, c TO d") == ["a", "b", "c", "d"].map { TableReference(name: $0) })
        #expect(tt("SELECT * FROM a JOIN b ON a.id=b.id, c WHERE 1") == ["a", "b", "c"].map { TableReference(name: $0) })
        #expect(tt("SELECT * FROM a x LEFT JOIN b AS y USING (id)") == ["a", "b"].map { TableReference(name: $0) })
        #expect(tt("DELETE a FROM a JOIN b ON a.id=b.id") == ["a", "b"].map { TableReference(name: $0) })
        #expect(tt("EXPLAIN SELECT * FROM t") == [TableReference(name: "t")])
        #expect(tt("DESCRIBE users") == [TableReference(name: "users")])
        #expect(tt("DROP TABLE t").first?.resolved(defaultSchema: "d") == TableRef(schema: "d", name: "t"))
    }

    @Test func objectType() {
        #expect(myC.classify(text: "DROP TABLE t").objectType == "TABLE")
        #expect(myC.classify(text: "DROP DATABASE d").objectType == "DATABASE")
        #expect(myC.classify(text: "DROP SCHEMA d").objectType == "SCHEMA")
        #expect(myC.classify(text: "CREATE TEMPORARY TABLE t (a int)").objectType == "TABLE")
        #expect(myC.classify(text: "CREATE UNIQUE INDEX i ON t (a)").objectType == "INDEX")
        #expect(myC.classify(text: "TRUNCATE t").objectType == "TABLE")
    }

    @Test func classifyScriptKeepsSourceRanges() {
        let script = "SELECT 1;\nDELETE FROM t;\n"
        let all = myC.classify(script: script)
        #expect(all.map(\.kind) == [.read, .write])
        #expect(all[1].source?.startLine == 2)
        #expect(all[1].range.map { String(script[$0]) } == "DELETE FROM t")
    }
}
