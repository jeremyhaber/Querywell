import Foundation
import Testing

@testable import QuerywellCore

private let myD = SQLDialect(.mysql)
private let pgD = SQLDialect(.postgresql)

private func ctx(prod: Bool = false, readOnly: Bool = false, db: String? = "shop", _ d: SQLDialect = myD) -> GuardContext {
    GuardContext(isProduction: prod, isReadOnly: readOnly, databaseName: db, connectionName: "Prod DB", dialect: d)
}

private func decide(_ script: String, _ c: GuardContext, settings: AppSettings.Safety = .init()) -> GuardDecision {
    WriteGuard.evaluate(script: script, context: c, settings: settings)
}

private func request(_ d: GuardDecision) -> ConfirmationRequest? {
    if case .confirm(let r) = d { return r }
    return nil
}

private func dry(_ sql: String, _ d: SQLDialect = myD) -> String? {
    let c = StatementClassifier(dialect: d).classify(text: sql)
    return DryRunPlanner.plans(for: c, statementIndex: 0, dialect: d).first?.sql
}

@Suite("Write guard")
struct WriteGuardTests {
    @Test func readsAlwaysAllowed() {
        for prod in [false, true] {
            #expect(decide("SELECT 1; SHOW TABLES; EXPLAIN SELECT 1", ctx(prod: prod)) == .allow)
            #expect(decide("USE shop; SET NAMES utf8mb4; BEGIN; COMMIT", ctx(prod: prod)) == .allow)
        }
    }

    @Test func nonProductionWritesAllowedWithoutConfirmation() {
        #expect(decide("INSERT INTO t VALUES (1)", ctx()) == .allow)
        #expect(decide("UPDATE t SET a=1 WHERE id=1", ctx()) == .allow)
        #expect(decide("DELETE FROM t WHERE id=1", ctx()) == .allow)
        #expect(decide("CREATE TABLE x (a int)", ctx()) == .allow)
        #expect(decide("DROP TABLE t", ctx()) == .allow)
        #expect(decide("TRUNCATE t", ctx()) == .allow)
    }

    @Test func unfilteredDeleteUpdateAlwaysConfirmsOnAnyConnection() throws {
        for sql in ["DELETE FROM t", "UPDATE t SET a = 1", "DELETE FROM t WHERE 1=1"] {
            let r = try #require(request(decide(sql, ctx())), "\(sql)")
            #expect(r.reasons.contains(.unfilteredMutation(statementIndex: 0)))
            #expect(r.requiresTypedName == nil)
            #expect(!r.isProduction)
            #expect(r.dryRuns.count == 1)
            #expect(r.dryRuns[0].sql == (sql.hasPrefix("DELETE FROM t WHERE") ? "SELECT COUNT(*) FROM t WHERE 1=1" : "SELECT COUNT(*) FROM t"))
        }
    }

    @Test func unfilteredIndexPointsAtTheRightStatement() throws {
        let r = try #require(request(decide("INSERT INTO t VALUES (1); DELETE FROM t", ctx())))
        #expect(r.statements.count == 2)
        #expect(r.reasons == [.unfilteredMutation(statementIndex: 1)])
        #expect(r.dryRuns.first?.statementIndex == 1)
    }

    @Test func productionConfirmsEveryWrite() throws {
        let r = try #require(request(decide("INSERT INTO t VALUES (1)", ctx(prod: true))))
        #expect(r.reasons == [.productionWrite])
        #expect(r.requiresTypedName == nil)
        #expect(r.dryRuns.isEmpty)
        #expect(r.isProduction)
        #expect(r.statements.map(\.verb) == ["INSERT"])
        #expect(request(decide("CREATE TABLE x (a int)", ctx(prod: true))) != nil)
        #expect(request(decide("CALL p()", ctx(prod: true))) != nil)
        #expect(request(decide("FROBNICATE", ctx(prod: true))) != nil)
    }

    @Test func productionDestructiveNeedsTypedDatabaseName() throws {
        let r = try #require(request(decide("DELETE FROM orders WHERE id = 5", ctx(prod: true))))
        #expect(r.requiresTypedName == "shop")
        #expect(r.reasons.contains(.destructiveOnProduction))
        #expect(r.dryRuns.first?.sql == "SELECT COUNT(*) FROM orders WHERE id = 5")
        #expect(r.isSatisfied(byTyped: "shop"))
        #expect(r.isSatisfied(byTyped: "  shop\n"))
        #expect(!r.isSatisfied(byTyped: "SHOP"))
        #expect(!r.isSatisfied(byTyped: ""))
        for sql in ["DROP TABLE t", "TRUNCATE t", "UPDATE t SET a=1 WHERE id=1", "ALTER TABLE t DROP COLUMN c", "RENAME TABLE a TO b"] {
            #expect(request(decide(sql, ctx(prod: true)))?.requiresTypedName == "shop", "\(sql)")
        }
        // non-destructive writes don't need typing
        #expect(request(decide("ALTER TABLE t ADD COLUMN c int", ctx(prod: true)))?.requiresTypedName == nil)
    }

    @Test func typedNameSettingCanBeTurnedOffButProductionStillConfirms() throws {
        var s = AppSettings.Safety()
        s.requireTypingDatabaseNameForDestructive = false
        let r = try #require(request(decide("DROP TABLE t", ctx(prod: true), settings: s)))
        #expect(r.requiresTypedName == nil)
        #expect(r.reasons.contains(.productionWrite))
        // a hand-edited settings file cannot switch production confirmation off
        s.confirmWritesOnProduction = false
        #expect(request(decide("INSERT INTO t VALUES (1)", ctx(prod: true), settings: s)) != nil)
    }

    @Test func typedNameFallsBack() throws {
        let noDB = ctx(prod: true, db: nil)
        #expect(request(decide("DROP TABLE t", noDB))?.requiresTypedName == "Prod DB")
        let nothing = GuardContext(isProduction: true, isReadOnly: false, databaseName: "", connectionName: nil, dialect: myD)
        #expect(request(decide("DROP TABLE t", nothing))?.requiresTypedName == "PRODUCTION")
    }

    @Test func gridEditUpdatesOnProductionNeedOnlyAClick() throws {
        let updates = ["UPDATE `wp_posts` SET `post_title` = 'x' WHERE `ID` = 1 AND `post_title` = 'y'"]
        let grid = try #require(request(WriteGuard.evaluate(statements: updates, context: ctx(prod: true), origin: .gridEdit)))
        #expect(grid.requiresTypedName == nil)
        // The same UPDATE typed in the editor still needs the database name.
        let script = try #require(request(WriteGuard.evaluate(statements: updates, context: ctx(prod: true))))
        #expect(script.requiresTypedName == "shop")
        // Grid deletes still need typing.
        let del = try #require(request(WriteGuard.evaluate(
            statements: ["DELETE FROM `wp_posts` WHERE `ID` = 1"], context: ctx(prod: true), origin: .gridEdit)))
        #expect(del.requiresTypedName == "shop")
        // Off Production, PK-targeted grid edits don't confirm at all.
        #expect(WriteGuard.evaluate(statements: updates, context: ctx(), origin: .gridEdit) == .allow)
    }

    @Test func requestListsOnlyWriteLikeStatements() throws {
        let r = try #require(request(decide("USE shop; SELECT 1; UPDATE t SET a=1 WHERE id=1; COMMIT", ctx(prod: true))))
        #expect(r.statements.count == 1)
    }

    @Test func escalationForBatchOperations() throws {
        let r = try #require(request(WriteGuard.evaluate(
            statements: ["ALTER TABLE `shop`.`t` ENGINE=InnoDB"], context: ctx(prod: true), escalateToDestructive: true)))
        #expect(r.requiresTypedName == "shop")
        #expect(r.reasons.contains(.escalated))
        // non-production escalation alone does not force typing, but still reports
        let dev = WriteGuard.evaluate(statements: ["ALTER TABLE t ENGINE=InnoDB"], context: ctx(), escalateToDestructive: true)
        #expect(request(dev)?.requiresTypedName == nil)
    }

    // MARK: Read-only

    @Test func readOnlyBlocksWritesButNotReads() {
        let c = ctx(readOnly: true)
        #expect(decide("SELECT 1; SHOW TABLES; USE shop; BEGIN; ROLLBACK; SET NAMES utf8mb4", c) == .allow)
        for sql in [
            "INSERT INTO t VALUES (1)", "DELETE FROM t", "DROP TABLE t", "CREATE TABLE x (a int)", "CALL p()",
            "SELECT * FROM t FOR UPDATE", "SET GLOBAL x = 1", "START TRANSACTION READ WRITE", "FROBNICATE",
            "SELECT a INTO OUTFILE '/tmp/x' FROM t", "GRANT ALL ON *.* TO u",
        ] {
            guard case .blockedReadOnly(let why) = decide(sql, c) else {
                Issue.record("not blocked: \(sql)")
                continue
            }
            #expect(why.contains("read-only"))
        }
    }

    @Test func readOnlyMessageNamesTheStatement() {
        guard case .blockedReadOnly(let why) = decide("SELECT 1; INSERT INTO t VALUES (1); DELETE FROM t", ctx(readOnly: true)) else {
            Issue.record("not blocked")
            return
        }
        #expect(why.contains("Statement 2"))
        #expect(why.contains("INSERT"))
    }

    @Test func readOnlyWinsOverProduction() {
        if case .blockedReadOnly = decide("DELETE FROM t", ctx(prod: true, readOnly: true)) {} else { Issue.record("expected block") }
    }

    @Test func contextFromProfile() {
        let p = ConnectionProfile(name: "P", colorTag: .production, engine: .postgresql, user: "u", defaultDatabase: "app", readOnly: true)
        let c = GuardContext(profile: p, currentDatabase: nil)
        #expect(c.isProduction && c.isReadOnly)
        #expect(c.databaseName == "app")
        #expect(c.dialect.family == .postgres)
        #expect(GuardContext(profile: p, currentDatabase: "other").databaseName == "other")
    }

    @Test func evaluatesEditSessionStyleStatements() throws {
        let r = try #require(request(WriteGuard.evaluate(
            statements: ["UPDATE `t` SET `a` = 1 WHERE `id` = 1"], context: ctx(prod: true))))
        #expect(r.statements.count == 1)
    }
}

@Suite("Dry-run planner")
struct DryRunPlannerTests {
    @Test func simpleDeleteAndUpdate() {
        #expect(dry("DELETE FROM orders WHERE id = 5") == "SELECT COUNT(*) FROM orders WHERE id = 5")
        #expect(dry("DELETE FROM `db`.`orders` WHERE status = 'x;y' AND n > 3;") == "SELECT COUNT(*) FROM `db`.`orders` WHERE status = 'x;y' AND n > 3")
        #expect(dry("DELETE FROM orders") == "SELECT COUNT(*) FROM orders")
        #expect(dry("UPDATE orders SET a = 1, b = 'where' WHERE id = 5") == "SELECT COUNT(*) FROM orders WHERE id = 5")
        #expect(dry("update orders set a = 1") == "SELECT COUNT(*) FROM orders")
        #expect(dry("UPDATE LOW_PRIORITY IGNORE orders SET a = 1 WHERE b IS NULL") == "SELECT COUNT(*) FROM orders WHERE b IS NULL")
        #expect(dry("DELETE QUICK FROM orders WHERE 1=0") == "SELECT COUNT(*) FROM orders WHERE 1=0")
    }

    @Test func aliasesAreKept() {
        #expect(dry("DELETE FROM orders AS o WHERE o.id = 1", pgD) == "SELECT COUNT(*) FROM orders AS o WHERE o.id = 1")
        #expect(dry("UPDATE orders o SET a = 1 WHERE o.id = 1", pgD) == "SELECT COUNT(*) FROM orders o WHERE o.id = 1")
        #expect(dry("DELETE FROM ONLY s.t WHERE a = 1", pgD) == "SELECT COUNT(*) FROM s.t WHERE a = 1")
    }

    @Test func subqueriesInWhereStayIntact() {
        #expect(dry("DELETE FROM t WHERE id IN (SELECT id FROM s WHERE x = 1) AND y = 2")
            == "SELECT COUNT(*) FROM t WHERE id IN (SELECT id FROM s WHERE x = 1) AND y = 2")
        #expect(dry("UPDATE t SET a = (SELECT max(b) FROM s WHERE s.k = 1) WHERE id = 3") == "SELECT COUNT(*) FROM t WHERE id = 3")
    }

    @Test func commentsAndCase() {
        #expect(dry("/* hi */ DELETE FROM t -- c\n WHERE a = 1") == "SELECT COUNT(*) FROM t WHERE a = 1")
        #expect(dry("delete from t where a = 1 returning *", pgD) == "SELECT COUNT(*) FROM t WHERE a = 1")
    }

    @Test func mysqlLimitUsesSubselect() {
        #expect(dry("DELETE FROM t WHERE a > 1 ORDER BY id LIMIT 10")
            == "SELECT COUNT(*) FROM (SELECT 1 FROM t WHERE a > 1 ORDER BY id LIMIT 10) AS qw_dry_run")
        #expect(dry("DELETE FROM t LIMIT 5") == "SELECT COUNT(*) FROM (SELECT 1 FROM t LIMIT 5) AS qw_dry_run")
        #expect(dry("UPDATE t SET a=1 ORDER BY id LIMIT 2")
            == "SELECT COUNT(*) FROM (SELECT 1 FROM t ORDER BY id LIMIT 2) AS qw_dry_run")
        // ORDER BY without LIMIT is irrelevant to the count
        #expect(dry("DELETE FROM t WHERE a = 1 ORDER BY id") == "SELECT COUNT(*) FROM t WHERE a = 1")
    }

    @Test(arguments: [
        "DELETE t1 FROM t1 JOIN t2 ON t1.id = t2.id",
        "DELETE FROM t USING t JOIN s ON t.a = s.a",
        "UPDATE t1 JOIN t2 ON t1.a = t2.a SET t1.b = 1",
        "UPDATE t1, t2 SET t1.a = t2.a",
        "WITH c AS (SELECT 1) DELETE FROM t",
        "DELETE FROM t WHERE id = ?",
        "DELETE FROM t WHERE a = 1 LIMIT 1, 2",
        "/*!40000 DELETE FROM t */",
        "DELETE FROM t WHERE a = 'unterminated",
    ])
    func unsupportedShapesYieldNil(sql: String) {
        let c = StatementClassifier(dialect: myD).classify(text: sql)
        let plans = DryRunPlanner.plans(for: c, statementIndex: 0, dialect: myD)
        #expect(plans.count == 1, "\(sql)")
        #expect(plans[0].sql == nil, "\(sql)")
        #expect(plans[0].explanation.hasPrefix("Can't estimate affected rows"))
    }

    @Test func postgresUnsupportedShapes() {
        #expect(dry("UPDATE t SET a = s.a FROM s WHERE t.id = s.id", pgD) == nil)
        #expect(dry("DELETE FROM t USING s WHERE t.id = s.id", pgD) == nil)
        #expect(dry("DELETE FROM t WHERE a = $1", pgD) == nil)
        #expect(dry("DELETE FROM t WHERE a = 1 LIMIT 1", pgD) == nil)
    }

    @Test func truncateAndDropTable() {
        #expect(dry("TRUNCATE TABLE `db`.`t`") == "SELECT COUNT(*) FROM `db`.`t`")
        #expect(dry("DROP TABLE IF EXISTS a") == "SELECT COUNT(*) FROM `a`")
        let c = StatementClassifier(dialect: myD).classify(text: "DROP TABLE a, b.c")
        let plans = DryRunPlanner.plans(for: c, statementIndex: 3, dialect: myD)
        #expect(plans.map(\.sql) == ["SELECT COUNT(*) FROM `a`", "SELECT COUNT(*) FROM `b`.`c`"])
        #expect(plans.allSatisfy { $0.statementIndex == 3 })
        let pgc = StatementClassifier(dialect: pgD).classify(text: "TRUNCATE a, s.b CASCADE")
        let pp = DryRunPlanner.plans(for: pgc, statementIndex: 0, dialect: pgD)
        #expect(pp.map(\.sql) == ["SELECT COUNT(*) FROM \"a\"", "SELECT COUNT(*) FROM \"s\".\"b\""])
        #expect(pp[0].explanation.contains("CASCADE"))
    }

    @Test func otherDestructiveStatements() {
        let dd = StatementClassifier(dialect: myD).classify(text: "DROP DATABASE shop")
        let p = DryRunPlanner.plans(for: dd, statementIndex: 0, dialect: myD)
        #expect(p.count == 1 && p[0].sql == nil)
        let view = StatementClassifier(dialect: myD).classify(text: "DROP VIEW v")
        #expect(DryRunPlanner.plans(for: view, statementIndex: 0, dialect: myD).isEmpty)
        let alter = StatementClassifier(dialect: myD).classify(text: "ALTER TABLE t DROP COLUMN c")
        #expect(DryRunPlanner.plans(for: alter, statementIndex: 0, dialect: myD).isEmpty)
        let unknown = StatementClassifier(dialect: myD).classify(text: "FROBNICATE t")
        #expect(DryRunPlanner.plans(for: unknown, statementIndex: 0, dialect: myD).first?.sql == nil)
    }

    @Test func countParsing() {
        #expect(DryRunExecutor.count(from: .integer(5)) == 5)
        #expect(DryRunExecutor.count(from: .unsignedInteger(7)) == 7)
        #expect(DryRunExecutor.count(from: .text("12")) == 12)
        #expect(DryRunExecutor.count(from: .null) == nil)
    }
}
