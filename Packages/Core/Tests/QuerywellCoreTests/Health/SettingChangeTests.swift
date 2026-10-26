import Foundation
import Testing

@testable import QuerywellCore

private func prodContext(_ engine: DatabaseEngine, production: Bool = false, readOnly: Bool = false) -> GuardContext {
    GuardContext(isProduction: production, isReadOnly: readOnly, databaseName: "shop", connectionName: "Shop", dialect: SQLDialect(engine))
}

@Suite("Setting SQL")
struct SettingSQLTests {
    @Test("MySQL 8: SET PERSIST, SET GLOBAL and PERSIST_ONLY with literals quoted by the dialect")
    func mysql() throws {
        func sql(_ c: SettingChange) throws -> [String] { try SettingSQL.statements(for: c, engine: .mysql) }
        #expect(try sql(SettingChange(variable: "max_connections", value: "300", scope: .persist)) == ["SET PERSIST max_connections = 300"])
        #expect(try sql(SettingChange(variable: "long_query_time", value: "0.5", scope: .runtime)) == ["SET GLOBAL long_query_time = 0.5"])
        #expect(try sql(SettingChange(variable: "slow_query_log", value: "ON", scope: .persist)) == ["SET PERSIST slow_query_log = 'ON'"])
        #expect(try sql(SettingChange(variable: "sql_mode", value: "A,B", scope: .persist)) == ["SET PERSIST sql_mode = 'A,B'"])
        #expect(try sql(SettingChange(variable: "innodb_log_file_size", value: "1073741824", scope: .persistOnly)) == ["SET PERSIST_ONLY innodb_log_file_size = 1073741824"])
        #expect(try sql(SettingChange(variable: "init_connect", value: "it's", scope: .runtime)) == ["SET GLOBAL init_connect = 'it\\'s'"])
    }

    @Test("MariaDB only knows SET GLOBAL")
    func mariadb() throws {
        #expect(try SettingSQL.statements(for: SettingChange(variable: "max_connections", value: "300", scope: .runtime), engine: .mariadb)
                == ["SET GLOBAL max_connections = 300"])
        #expect(throws: SettingSQLError.self) {
            try SettingSQL.statements(for: SettingChange(variable: "max_connections", value: "300", scope: .persist), engine: .mariadb)
        }
    }

    @Test("PostgreSQL: ALTER SYSTEM then reload; RESET for defaults")
    func postgres() throws {
        let set = try SettingSQL.statements(for: SettingChange(variable: "shared_buffers", value: "4GB", scope: .alterSystem), engine: .postgresql)
        #expect(set == ["ALTER SYSTEM SET shared_buffers = '4GB'", "SELECT pg_reload_conf()"])
        let quoted = try SettingSQL.statements(for: SettingChange(variable: "search_path", value: "a'b", scope: .alterSystem), engine: .postgresql)
        #expect(quoted[0] == "ALTER SYSTEM SET search_path = 'a''b'")
        #expect(try SettingSQL.resetStatements(variable: "work_mem") == ["ALTER SYSTEM RESET work_mem", "SELECT pg_reload_conf()"])
    }

    @Test("variable names are validated so stored data can't inject SQL")
    func nameValidation() {
        for bad in ["a; DROP TABLE x", "a b", "", "1abc", "x'y", "x=1"] {
            #expect(!SettingSQL.isValidVariableName(bad), "\(bad)")
            #expect(throws: SettingSQLError.invalidVariableName(bad)) {
                try SettingSQL.statements(for: SettingChange(variable: bad, value: "1", scope: .runtime), engine: .mysql)
            }
        }
        for good in ["max_connections", "innodb_buffer_pool_size", "pg_stat_statements.max", "_x1"] {
            #expect(SettingSQL.isValidVariableName(good), "\(good)")
        }
    }

    @Test("scopes per engine and version")
    func scopes() {
        #expect(SettingSQL.availableScopes(engine: .mysql, major: 8, minor: 4) == [.persist, .runtime])
        #expect(SettingSQL.availableScopes(engine: .mysql, major: 8, minor: 4, readOnlyVariable: true) == [.persistOnly])
        #expect(SettingSQL.availableScopes(engine: .mysql, major: 5, minor: 7) == [.runtime])
        #expect(SettingSQL.availableScopes(engine: .mariadb, major: 11, minor: 4) == [.runtime])
        #expect(SettingSQL.availableScopes(engine: .mariadb, major: 11, minor: 4, readOnlyVariable: true) == [])
        #expect(SettingSQL.availableScopes(engine: .postgresql, major: 16, minor: 4) == [.alterSystem])
    }

    @Test("config snippets for my.cnf and postgresql.conf")
    func snippets() {
        let changes = [
            SettingChange(variable: "max_connections", value: "300", scope: .runtime),
            SettingChange(variable: "sql_mode", value: "A,B", scope: .runtime),
        ]
        #expect(SettingSQL.configSnippet(for: changes, engine: .mariadb) == "[mysqld]\nmax_connections = 300\nsql_mode = \"A,B\"")
        let pg = [SettingChange(variable: "shared_buffers", value: "4GB", scope: .alterSystem)]
        #expect(SettingSQL.configSnippet(for: pg, engine: .postgresql) == "shared_buffers = '4GB'")
    }

    @Test("generated statements are writes: the guard blocks read-only connections and confirms on Production")
    func guardPath() throws {
        for (engine, scope) in [(DatabaseEngine.mysql, SettingScope.persist), (.mysql, .runtime), (.mariadb, .runtime), (.postgresql, .alterSystem)] {
            let plan = try SettingApplier.plan([SettingChange(variable: "max_connections", value: "300", scope: scope)], engine: engine)
            let readOnly = SettingApplier.makeRunner(context: prodContext(engine, readOnly: true), safety: AppSettings.Safety())
            guard case .blocked = readOnly.prepare(script: plan.script) else {
                Issue.record("\(engine) \(scope) was not blocked on a read-only connection")
                continue
            }
            let prod = SettingApplier.makeRunner(context: prodContext(engine, production: true), safety: AppSettings.Safety())
            guard case .needsConfirmation(let pending) = prod.prepare(script: plan.script) else {
                Issue.record("\(engine) \(scope) did not ask for confirmation on Production")
                continue
            }
            #expect(pending.request.statements.contains { $0.kind.isWriteLike })
        }
    }
}

@Suite("Applying settings")
struct SettingApplierTests {
    private func run(_ changes: [SettingChange], engine: DatabaseEngine, session: ScriptedSession, origin: RevisionOrigin = .doctor) async throws -> [SettingRevision] {
        let plan = try SettingApplier.plan(changes, engine: engine, origin: origin)
        let runner = SettingApplier.makeRunner(context: prodContext(engine), safety: AppSettings.Safety())
        guard case .ready(let script) = runner.prepare(script: plan.script) else {
            Issue.record("expected a runnable script")
            return []
        }
        return await SettingApplier.run(plan, prepared: script, runner: runner, on: session)
    }

    @Test("success records old and new value, scope and the exact SQL")
    func success() async throws {
        let session = ScriptedSession(engine: .mysql, replies: [])
        let change = SettingChange(variable: "max_connections", value: "300", currentValue: "151", scope: .persist)
        let revisions = try await run([change], engine: .mysql, session: session)
        #expect(session.executed == ["SET PERSIST max_connections = 300"])
        let r = try #require(revisions.first)
        #expect(r.succeeded && r.oldValue == "151" && r.newValue == "300" && r.scope == .persist)
        #expect(r.statements == ["SET PERSIST max_connections = 300"])
        #expect(r.appliedFrom == "Querywell" && r.origin == .doctor)
    }

    @Test("PostgreSQL runs ALTER SYSTEM and the reload")
    func postgres() async throws {
        let session = ScriptedSession(engine: .postgresql, replies: [])
        let change = SettingChange(variable: "work_mem", value: "16MB", currentValue: "4MB", scope: .alterSystem)
        let revisions = try await run([change], engine: .postgresql, session: session)
        #expect(session.executed == ["ALTER SYSTEM SET work_mem = '16MB'", "SELECT pg_reload_conf()"])
        #expect(revisions.count == 1 && revisions[0].succeeded)
    }

    @Test("one rejected setting is recorded as failed and the others still run")
    func partialFailure() async throws {
        let session = ScriptedSession(engine: .mysql, replies: [
            ("max_connections", .failure(.query(message: "Access denied; you need (at least one of) the SUPER or SYSTEM_VARIABLES_ADMIN privilege(s) for this operation", code: "1227"))),
        ])
        let changes = [
            SettingChange(variable: "max_connections", value: "300", currentValue: "151", scope: .persist),
            SettingChange(variable: "slow_query_log", value: "ON", currentValue: "OFF", scope: .persist),
        ]
        let revisions = try await run(changes, engine: .mysql, session: session)
        #expect(revisions.map(\.outcome) == [.failed, .succeeded])
        #expect(revisions[0].errorMessage?.contains("SUPER or SYSTEM_VARIABLES_ADMIN") == true)
        #expect(revisions[0].errorMessage?.contains("max_connections") == true)
        #expect(session.executed.count == 2)
    }

    @Test("privilege and read-only errors are explained for each engine")
    func errorMessages() {
        let pg = SettingApplier.describe(.query(message: "permission denied to set parameter \"shared_buffers\"", code: "42501"), engine: .postgresql, variable: "shared_buffers")
        #expect(pg.contains("superuser"))
        let maria = SettingApplier.describe(.query(message: "Access denied; you need (at least one of) the SUPER privilege(s)", code: "1227"), engine: .mariadb, variable: "max_connections")
        #expect(maria.contains("SUPER"))
        let ro = SettingApplier.describe(.query(message: "Variable 'innodb_log_file_size' is a read only variable", code: "1238"), engine: .mysql, variable: "innodb_log_file_size")
        #expect(ro.contains("PERSIST_ONLY"))
        let other = SettingApplier.describe(.query(message: "Incorrect argument", code: "1231"), engine: .mysql, variable: "x")
        #expect(other == "Incorrect argument [1231]")
    }
}

@Suite("Revisions, drift and revert")
struct RevisionTests {
    private func revision(_ variable: String, old: String?, new: String, scope: SettingScope = .persist, ok: Bool = true,
                          restart: Bool = false, oldDefault: Bool = false) -> SettingRevision {
        SettingRevision(variable: variable, oldValue: old, newValue: new, scope: scope, statements: ["x"],
                        outcome: ok ? .succeeded : .failed, restartRequired: restart, oldWasDefault: oldDefault)
    }

    @Test("value comparison ignores spelling differences")
    func comparison() {
        #expect(SettingValueComparison.equivalent("ON", "1"))
        #expect(SettingValueComparison.equivalent("on", "'ON'"))
        #expect(SettingValueComparison.equivalent("1.000000", "1"))
        #expect(SettingValueComparison.equivalent("128MB", "134217728"))
        #expect(SettingValueComparison.equivalent("B,A", "a,b"))
        #expect(!SettingValueComparison.equivalent("300", "301"))
        #expect(!SettingValueComparison.equivalent("OFF", "ON"))
    }

    @Test("drift flags settings changed outside Querywell")
    func drift() {
        let revs = [
            revision("max_connections", old: "151", new: "300"),
            revision("max_connections", old: "300", new: "400"),
            revision("slow_query_log", old: "OFF", new: "ON"),
            revision("long_query_time", old: "10", new: "1", ok: false),
        ]
        let live = ["max_connections": "250", "slow_query_log": "ON", "long_query_time": "10"]
        let drift = DriftChecker.drift(revisions: revs, current: live)
        #expect(drift.map(\.variable) == ["max_connections"])
        #expect(drift[0].recordedValue == "400")
        #expect(drift[0].currentValue == "250")
        #expect(DriftChecker.drift(revisions: revs, current: ["max_connections": "400", "slow_query_log": "1"]).isEmpty)
    }

    @Test("a restart-required change that is not live yet is not drift")
    func pendingRestart() {
        let revs = [revision("shared_buffers", old: "128MB", new: "4GB", scope: .alterSystem, restart: true)]
        #expect(DriftChecker.drift(revisions: revs, current: ["shared_buffers": "128MB"]).isEmpty)
        #expect(DriftChecker.drift(revisions: revs, current: ["shared_buffers": "1GB"]).count == 1)
    }

    @Test("reverting one revision sets the old value back in the same scope")
    func revertOne() throws {
        let rev = revision("max_connections", old: "151", new: "300", scope: .runtime)
        let change = try RevertPlanner.change(reverting: rev, current: ["max_connections": "300"], engine: .mysql)
        #expect(change.value == "151" && change.currentValue == "300" && change.scope == .runtime)
        #expect(throws: RevertError.revisionFailed) {
            try RevertPlanner.change(reverting: revision("a", old: "1", new: "2", ok: false), current: [:], engine: .mysql)
        }
        #expect(throws: RevertError.oldValueUnknown) {
            try RevertPlanner.change(reverting: revision("a", old: nil, new: "2"), current: [:], engine: .mysql)
        }
    }

    @Test("PostgreSQL reverts to a former default with RESET")
    func revertDefault() throws {
        let rev = revision("work_mem", old: "4MB", new: "64MB", scope: .alterSystem, oldDefault: true)
        let change = try RevertPlanner.change(reverting: rev, current: ["work_mem": "64MB"], engine: .postgresql)
        #expect(change.resetToDefault)
        let plan = try SettingApplier.plan([change], engine: .postgresql, origin: .revert, revertedRevisionID: rev.id)
        #expect(plan.statements == ["ALTER SYSTEM RESET work_mem", "SELECT pg_reload_conf()"])
    }

    @Test("revert all goes back to the value before the first change in the window, newest variable first")
    func revertAll() throws {
        let a1 = revision("max_connections", old: "151", new: "300")
        let b1 = revision("slow_query_log", old: "OFF", new: "ON")
        let a2 = revision("max_connections", old: "300", new: "400")
        let failed = revision("long_query_time", old: "10", new: "1", ok: false)
        let all = [a1, b1, a2, failed]
        let live = ["max_connections": "400", "slow_query_log": "ON", "long_query_time": "10"]

        let from1 = try RevertPlanner.changes(revertingFrom: a1, in: all, current: live, engine: .mysql)
        #expect(from1.map(\.variable) == ["slow_query_log", "max_connections"])
        #expect(from1.map(\.value) == ["OFF", "151"])
        #expect(from1.map(\.currentValue) == ["ON", "400"])

        let fromB = try RevertPlanner.changes(revertingFrom: b1, in: all, current: live, engine: .mysql)
        #expect(fromB.map(\.variable) == ["max_connections", "slow_query_log"])
        // Only the changes from b1 on: max_connections goes back to 300, not 151.
        #expect(fromB.first { $0.variable == "max_connections" }?.value == "300")

        // A variable that already has its old value is left out.
        let already = try RevertPlanner.changes(revertingFrom: a1, in: all, current: ["max_connections": "151", "slow_query_log": "ON"], engine: .mysql)
        #expect(already.map(\.variable) == ["slow_query_log"])

        #expect(throws: RevertError.notFound) {
            try RevertPlanner.changes(revertingFrom: revision("x", old: "1", new: "2"), in: all, current: live, engine: .mysql)
        }
    }

    @Test("an MySQL persist revision reverts as persist on MySQL and as SET GLOBAL on MariaDB")
    func scopeMapping() throws {
        let rev = revision("max_connections", old: "151", new: "300", scope: .persist)
        #expect(try RevertPlanner.change(reverting: rev, current: [:], engine: .mysql).scope == .persist)
        #expect(try RevertPlanner.change(reverting: rev, current: [:], engine: .mariadb).scope == .runtime)
    }
}

@Suite("Health store")
struct HealthStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qw-health-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("health.json")
    }

    private func revision(_ variable: String = "max_connections", new: String = "300") -> SettingRevision {
        SettingRevision(variable: variable, oldValue: "151", newValue: new, scope: .persist, statements: ["SET PERSIST \(variable) = \(new)"], outcome: .succeeded)
    }

    @Test("round trip: revisions, RAM and ignored rules persist across instances; file is 0600")
    func roundTrip() async throws {
        let url = tempFile()
        let id = UUID()
        let store = HealthStore(fileURL: url)
        let r1 = revision(), r2 = revision("slow_query_log", new: "ON")
        try await store.append([r1, r2], for: id)
        try await store.setServerRAM(16 * GiBytes, for: id)
        try await store.setIgnored("my.slow_query_log", true, for: id)
        try await store.setIgnored("my.long_query_time", true, for: id)
        try await store.setIgnored("my.long_query_time", false, for: id)

        let reopened = HealthStore(fileURL: url)
        let data = await reopened.data(for: id)
        #expect(data.revisions.map(\.id) == [r1.id, r2.id])
        #expect(data.revisions[0].statements == r1.statements)
        #expect(data.serverRAMBytes == 16 * GiBytes)
        #expect(data.ignoredRuleIDs == ["my.slow_query_log"])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(await HealthStore(fileURL: url).data(for: UUID()) == HealthConnectionData())
    }

    @Test("purging a connection removes only its data")
    func purge() async throws {
        let url = tempFile()
        let a = UUID(), b = UUID()
        let store = HealthStore(fileURL: url)
        try await store.append([revision()], for: a)
        try await store.append([revision()], for: b)
        try await store.purge(connectionID: a)
        #expect(await store.revisions(for: a).isEmpty)
        #expect(await HealthStore(fileURL: url).revisions(for: b).count == 1)
        try await store.purge(connectionID: UUID())  // unknown ids are a no-op
    }

    @Test("history is capped, dropping the oldest")
    func cap() async throws {
        let store = HealthStore(fileURL: tempFile())
        let id = UUID()
        let batch = (0..<(HealthStore.maxRevisionsPerConnection + 5)).map { revision(new: String($0)) }
        try await store.append(batch, for: id)
        let kept = await store.revisions(for: id)
        #expect(kept.count == HealthStore.maxRevisionsPerConnection)
        #expect(kept.first?.newValue == "5")
    }

    @Test("tolerant decoding: unreadable revisions are skipped, missing fields default, unknown scopes fall back")
    func tolerantDecoding() async throws {
        let url = tempFile()
        let id = UUID()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = UUID()
        let json = """
        {"schemaVersion":1,"extra":true,"connections":{"\(id.uuidString)":{
          "serverRAMBytes": 8589934592,
          "revisions":[
            {"id":"\(good.uuidString)","date":"2026-10-26T10:00:00Z","variable":"max_connections","newValue":"300","scope":"somethingNew","outcome":"succeeded","futureField":1},
            {"variable": 5},
            "garbage",
            {"variable":"slow_query_log","newValue":"ON"}
          ]}}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let data = await HealthStore(fileURL: url).data(for: id)
        #expect(data.serverRAMBytes == 8 * GiBytes)
        #expect(data.revisions.count == 2)
        #expect(data.revisions[0].id == good)
        #expect(data.revisions[0].scope == .runtime)
        #expect(data.revisions[0].statements.isEmpty)
        #expect(data.revisions[1].variable == "slow_query_log")
        #expect(data.revisions[1].outcome == .failed)  // unknown outcome is never presented as a success
        #expect(data.ignoredRuleIDs.isEmpty)
    }

    @Test("a corrupt file is kept aside and replaced on the next write")
    func corruptFile() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let store = HealthStore(fileURL: url)
        let id = UUID()
        #expect(await store.revisions(for: id).isEmpty)
        try await store.append([revision()], for: id)
        #expect(await HealthStore(fileURL: url).revisions(for: id).count == 1)
        let aside = url.deletingLastPathComponent().appendingPathComponent("health.json.unreadable")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
    }

    @Test("a file from a newer Querywell is never overwritten")
    func newerSchema() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = #"{"schemaVersion":99,"connections":{}}"#
        try newer.write(to: url, atomically: true, encoding: .utf8)
        let store = HealthStore(fileURL: url)
        await #expect(throws: HealthStoreError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try await store.append([revision()], for: UUID())
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == newer)
    }
}

@Suite("Health collector")
struct HealthCollectorTests {
    private func table(_ columns: [String], _ rows: [[DatabaseValue]]) -> QueryResult {
        QueryResult(columns: columns.map { ColumnInfo(name: $0, typeName: "text") }, rows: rows)
    }

    @Test("MySQL: variables, status and storage are read; a refused query is recorded, not fatal")
    func mysql() async {
        let session = ScriptedSession(engine: .mysql, replies: [
            ("SHOW GLOBAL VARIABLES", .result(table(["Variable_name", "Value"], [[.text("Max_Connections"), .text("151")], [.text("slow_query_log"), .text("OFF")]]))),
            ("SHOW GLOBAL STATUS", .result(table(["Variable_name", "Value"], [[.text("Uptime"), .text("7200")], [.text("Threads_connected"), .text("5")]]))),
            ("SUM(data_length)", .result(table(["a", "b", "c"], [[.integer(100), .integer(50), .text("120")]]))),
            ("LEFT JOIN information_schema.table_constraints", .failure(.query(message: "SELECT command denied", code: "1142"))),
            ("engine <> 'InnoDB'", .result(table(["s", "t", "e"], [[.text("old"), .text("hits"), .text("MyISAM")]]))),
            ("ORDER BY COALESCE", .result(table(["s", "t", "b", "r"], [[.text("shop"), .text("orders"), .integer(900), .integer(10)]]))),
        ])
        let facts = await HealthCollector().collect(session: session)
        #expect(facts.engine == .mysql)
        #expect(facts.int("max_connections") == 151)
        #expect(facts.uptimeSeconds == 7200)
        #expect(facts.statusInt("threads_connected") == 5)
        #expect(facts.dataBytes == 100 && facts.indexBytes == 50 && facts.innodbBytes == 120)
        #expect(facts.tablesWithoutPrimaryKey == nil)
        #expect(facts.unavailable["noPrimaryKey"]?.contains("SELECT command denied") == true)
        #expect(facts.nonInnoDBTables == ["old.hits (MyISAM)"])
        #expect(facts.largestTables?.first?.totalBytes == 900)
        // Every collector query is a read.
        #expect(session.executed.allSatisfy { $0.hasPrefix("SHOW") || $0.hasPrefix("SELECT") })
        let page = HealthEvaluator().evaluate(facts)
        #expect(page.list("noPrimaryKey")?.status == .unavailable)
    }

    @Test("PostgreSQL: settings are normalised and statistics read")
    func postgres() async {
        let session = ScriptedSession(engine: .postgresql, replies: [
            ("FROM pg_settings", .result(table(["name", "setting", "unit", "context", "source"], [
                [.text("shared_buffers"), .text("16384"), .text("8kB"), .text("postmaster"), .text("default")],
                [.text("autovacuum"), .text("on"), .null, .text("sighup"), .text("default")],
            ]))),
            ("pg_postmaster_start_time", .result(table(["u"], [[.integer(3600)]]))),
            ("FROM pg_stat_activity", .result(table(["a", "b"], [[.integer(12), .integer(2)]]))),
            ("FROM pg_stat_database", .result(table(["a"], [[.integer(10), .integer(1), .integer(100), .integer(2), .integer(0), .integer(3), .integer(4096), .integer(1_000_000)]]))),
            ("FROM pg_stat_user_tables", .failure(.query(message: "permission denied for view pg_stat_user_tables", code: "42501"))),
        ])
        let facts = await HealthCollector().collect(session: session)
        #expect(facts.variable("shared_buffers") == "128MB")
        #expect(facts.contexts["shared_buffers"] == "postmaster")
        #expect(facts.sources["shared_buffers"] == "default")
        #expect(facts.isOn("autovacuum") == true)
        #expect(facts.uptimeSeconds == 3600)
        #expect(facts.activeConnections == 12 && facts.runningBackends == 2)
        #expect(facts.postgresStats?.tempBytes == 4096)
        #expect(facts.postgresStats?.databaseBytes == 1_000_000)
        #expect(facts.deadTupleTables == nil)
        #expect(facts.unavailable["deadTuples"]?.contains("permission denied") == true)
        #expect(session.executed.allSatisfy { $0.hasPrefix("SELECT") })
    }
}
