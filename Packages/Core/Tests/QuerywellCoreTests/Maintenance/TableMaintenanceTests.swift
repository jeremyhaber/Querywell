import Foundation
import Testing

@testable import QuerywellCore

private func server(_ engine: DatabaseEngine = .mysql, _ major: Int = 8, _ minor: Int = 4, _ patch: Int = 0) -> ServerInfo {
    ServerInfo(engine: engine, versionString: "\(major).\(minor).\(patch)", major: major, minor: minor, patch: patch, tlsActive: false)
}

private func table(_ name: String, engine: String? = "MyISAM", collation: String? = "utf8mb3_general_ci", kind: TableKind = .table,
                   rows: Int64? = 10, data: Int64? = 1000, schema: String = "shop") -> TableInfo {
    TableInfo(ref: TableRef(schema: schema, name: name), kind: kind, engine: kind == .table ? engine : nil,
              estimatedRows: rows, dataBytes: data, indexBytes: 0, collation: kind == .table ? collation : nil)
}

private func col(_ name: String, _ fullType: String, collation: String? = nil) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: 1, dataType: fullType.split(separator: "(").first.map(String.init) ?? fullType,
                     fullType: fullType, isNullable: true, collation: collation)
}

private func structure(_ info: TableInfo, columns: [ColumnDefinition] = [], indexes: [IndexDefinition] = [],
                       fks: [ForeignKeyDefinition] = [], refBy: [ForeignKeyDefinition] = []) -> TableStructure {
    TableStructure(info: info, columns: columns, indexes: indexes, foreignKeys: fks, referencedBy: refBy)
}

@Suite("Table maintenance planner")
struct TableMaintenancePlannerTests {
    @Test func engineChangeSQLAndSkips() throws {
        let tables = [
            table("a"), table("b", engine: "InnoDB"), table("v", kind: .view), table("c", engine: "MEMORY"),
            table("d", engine: "innodb"),
        ]
        let plan = try TableMaintenancePlanner.plan(tables: tables, change: .engine("InnoDB"), server: server())
        #expect(plan.steps.map(\.id) == [0, 1, 2, 3, 4])
        #expect(plan.statements == [
            "ALTER TABLE `shop`.`a` ENGINE=InnoDB",
            "ALTER TABLE `shop`.`c` ENGINE=InnoDB",
        ])
        #expect(plan.steps[1].skipped == "Already InnoDB")
        #expect(plan.steps[2].skipped?.contains("View") == true)
        #expect(plan.steps[4].skipped == "Already innodb")
        #expect(plan.skippedSteps.count == 3)
        #expect(plan.warnings.first?.contains("not transactional") == true)
    }

    @Test func convertSQLAndDatabaseDefault() throws {
        let tables = [table("a"), table("b", collation: "utf8mb4_unicode_520_ci"), table("c", schema: "other")]
        let plan = try TableMaintenancePlanner.plan(
            tables: tables, change: .convert(charset: "utf8mb4", collation: "utf8mb4_unicode_520_ci"),
            alsoSetDatabaseDefault: true, server: server())
        #expect(plan.statements == [
            "ALTER TABLE `shop`.`a` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci",
            "ALTER TABLE `other`.`c` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci",
            "ALTER DATABASE `shop` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci",
            "ALTER DATABASE `other` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci",
        ])
        #expect(plan.steps[1].skipped == "Already utf8mb4_unicode_520_ci")
        #expect(plan.steps.last?.table == nil)
        // database default comes last, once per schema
        if case .database(let d) = plan.steps[3].target { #expect(d == "shop") } else { Issue.record("expected database step") }
    }

    @Test func databaseDefaultOffByDefault() throws {
        let plan = try TableMaintenancePlanner.plan(
            tables: [table("a")], change: .convert(charset: "utf8mb4", collation: "utf8mb4_general_ci"), server: server())
        #expect(plan.steps.count == 1)
    }

    @Test func tableDefaultMatchesButColumnDoesNotIsNotSkipped() throws {
        let info = table("a", collation: "utf8mb4_unicode_ci")
        let s = structure(info, columns: [col("x", "varchar(10)", collation: "utf8mb4_unicode_ci"), col("y", "varchar(10)", collation: "utf8mb3_general_ci"), col("n", "int")])
        let plan = try TableMaintenancePlanner.plan(
            tables: [info], structures: [info.ref: s], change: .convert(charset: "utf8mb4", collation: "utf8mb4_unicode_ci"), server: server())
        #expect(plan.runnableSteps.count == 1)
        let ok = structure(info, columns: [col("x", "varchar(10)", collation: "utf8mb4_unicode_ci"), col("n", "int")])
        let plan2 = try TableMaintenancePlanner.plan(
            tables: [info], structures: [info.ref: ok], change: .convert(charset: "utf8mb4", collation: "utf8mb4_unicode_ci"), server: server())
        #expect(plan2.isEmpty)
    }

    @Test func postgresIsUnsupported() {
        #expect(throws: MaintenanceError.self) {
            try TableMaintenancePlanner.plan(tables: [table("a")], change: .engine("InnoDB"), server: server(.postgresql, 16, 4))
        }
    }

    @Test func namesAreValidatedNotInterpolated() {
        for bad in ["InnoDB; DROP TABLE x", "In noDB", "", "utf8mb4`", "a-b"] {
            #expect(throws: MaintenanceError.invalidName(bad)) {
                try TableMaintenancePlanner.plan(tables: [table("a")], change: .engine(bad), server: server())
            }
        }
        #expect(throws: MaintenanceError.invalidName("x y")) {
            try TableMaintenancePlanner.plan(tables: [table("a")], change: .convert(charset: "utf8mb4", collation: "x y"), server: server())
        }
        #expect(throws: MaintenanceError.collationDoesNotBelongToCharset(charset: "latin1", collation: "utf8mb4_general_ci")) {
            try TableMaintenancePlanner.plan(tables: [table("a")], change: .convert(charset: "latin1", collation: "utf8mb4_general_ci"), server: server())
        }
        // aliases are fine
        #expect(throws: Never.self) {
            try TableMaintenancePlanner.plan(tables: [table("a")], change: .convert(charset: "utf8", collation: "utf8mb3_general_ci"), server: server())
        }
    }

    @Test func tableNamesAreQuoted() throws {
        let plan = try TableMaintenancePlanner.plan(tables: [table("we`ird name")], change: .engine("InnoDB"), server: server())
        #expect(plan.statements == ["ALTER TABLE `shop`.`we``ird name` ENGINE=InnoDB"])
    }

    @Test func noWarningsWhenNothingToDo() throws {
        let plan = try TableMaintenancePlanner.plan(tables: [table("a", engine: "InnoDB")], change: .engine("InnoDB"), server: server())
        #expect(plan.isEmpty)
        #expect(plan.warnings.isEmpty)
    }

    // MARK: Warnings

    @Test func leavingInnoDBWarnsAboutForeignKeys() throws {
        let child = table("child", engine: "InnoDB")
        let fk = ForeignKeyDefinition(name: "fk", columns: ["p"], referenced: TableRef(schema: "shop", name: "parent"), referencedColumns: ["id"])
        let withStructure = try TableMaintenancePlanner.plan(
            tables: [child], structures: [child.ref: structure(child, fks: [fk])], change: .engine("MyISAM"), server: server())
        #expect(withStructure.warnings.contains { $0.contains("`child`") && $0.contains("foreign keys") && $0.contains("parent") })
        // no FKs, structure known → no FK warning
        let clean = try TableMaintenancePlanner.plan(
            tables: [child], structures: [child.ref: structure(child)], change: .engine("MyISAM"), server: server())
        #expect(!clean.warnings.contains { $0.contains("`child`") || $0.contains("Leaving InnoDB") })
        // structure unknown → generic warning
        let generic = try TableMaintenancePlanner.plan(tables: [child], change: .engine("MyISAM"), server: server())
        #expect(generic.warnings.contains { $0.contains("Leaving InnoDB drops foreign key support") })
        // referenced-by also counts
        let parent = table("parent", engine: "InnoDB")
        let ref = ForeignKeyDefinition(name: "fk", columns: ["p"], referenced: TableRef(schema: "shop", name: "child"), referencedColumns: ["id"])
        let p = try TableMaintenancePlanner.plan(
            tables: [parent], structures: [parent.ref: structure(parent, refBy: [ref])], change: .engine("MyISAM"), server: server())
        #expect(p.warnings.contains { $0.contains("`parent`") && $0.contains("foreign keys") })
    }

    @Test func fulltextOnOldServers() throws {
        let t = table("docs")
        let s = structure(t, indexes: [IndexDefinition(name: "ft", columns: ["body"], isUnique: false, isPrimary: false, method: "FULLTEXT")])
        let old = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: s], change: .engine("InnoDB"), server: server(.mysql, 5, 5, 62))
        #expect(old.warnings.contains { $0.contains("FULLTEXT") && $0.contains("5.5") })
        let oldMaria = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: s], change: .engine("InnoDB"), server: server(.mariadb, 5, 5, 40))
        #expect(oldMaria.warnings.contains { $0.contains("FULLTEXT") })
        for modern in [server(.mysql, 5, 6, 0), server(.mysql, 8, 4, 0), server(.mariadb, 10, 0, 0), server(.mariadb, 11, 4, 0)] {
            let p = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: s], change: .engine("InnoDB"), server: modern)
            #expect(!p.warnings.contains { $0.contains("FULLTEXT") }, "\(modern.shortDescription)")
        }
        // no structure on an old server → generic hint
        let unknown = try TableMaintenancePlanner.plan(tables: [t], change: .engine("InnoDB"), server: server(.mysql, 5, 5, 62))
        #expect(unknown.warnings.contains { $0.contains("FULLTEXT") })
    }

    @Test func indexKeyLengthWhenConvertingToUtf8mb4() throws {
        let t = table("users", engine: "InnoDB")
        let s = structure(
            t, columns: [col("email", "varchar(255)"), col("code", "varchar(100)"), col("id", "int")],
            indexes: [
                IndexDefinition(name: "idx_email", columns: ["email"], isUnique: true, isPrimary: false, method: "BTREE"),
                IndexDefinition(name: "idx_code", columns: ["code"], isUnique: false, isPrimary: false, method: "BTREE"),
                IndexDefinition(name: "idx_both", columns: ["email", "code", "id"], isUnique: false, isPrimary: false, method: "BTREE"),
            ])
        let target = MaintenanceChange.convert(charset: "utf8mb4", collation: "utf8mb4_general_ci")
        // Old server: 767-byte limit → 255*4 = 1020 trips it, 100*4 = 400 doesn't.
        let old = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: s], change: target, server: server(.mysql, 5, 6, 0))
        #expect(old.warnings.contains { $0.contains("idx_email") && $0.contains("767") && $0.contains("1020") })
        #expect(!old.warnings.contains { $0.contains("idx_code") })
        // Modern InnoDB: 3072. idx_both = (255+100)*4 = 1420 → fine.
        let modern = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: s], change: target, server: server())
        #expect(!modern.warnings.contains { $0.contains("key limit") })
        // A wide composite trips even 3072.
        let wide = structure(t, columns: [col("a", "varchar(500)"), col("b", "varchar(300)")],
                             indexes: [IndexDefinition(name: "idx_wide", columns: ["a", "b"], isUnique: false, isPrimary: false)])
        let w = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: wide], change: target, server: server())
        #expect(w.warnings.contains { $0.contains("idx_wide") && $0.contains("3072") && $0.contains("3200") })
        // utf8mb3 costs 3 bytes: 500+300 → 2400, fine
        let three = try TableMaintenancePlanner.plan(
            tables: [t], structures: [t.ref: wide], change: .convert(charset: "utf8mb3", collation: "utf8mb3_general_ci"), server: server())
        #expect(!three.warnings.contains { $0.contains("idx_wide") })
        // MyISAM tables have a 1000-byte limit
        let my = table("m", engine: "MyISAM")
        let ms = structure(my, columns: [col("x", "varchar(255)")], indexes: [IndexDefinition(name: "ix", columns: ["x"], isUnique: false, isPrimary: false)])
        let mp = try TableMaintenancePlanner.plan(tables: [my], structures: [my.ref: ms], change: target, server: server())
        #expect(mp.warnings.contains { $0.contains("ix") && $0.contains("1000") })
    }

    @Test func genericIndexWarningWithoutStructure() throws {
        let p = try TableMaintenancePlanner.plan(
            tables: [table("a")], change: .convert(charset: "utf8mb4", collation: "utf8mb4_general_ci"), server: server())
        #expect(p.warnings.contains { $0.contains("767") && $0.contains("3072") })
    }

    @Test func foreignKeysOutsideTheSelectionWarnOnConvert() throws {
        let t = table("child", engine: "InnoDB")
        let fk = ForeignKeyDefinition(name: "fk", columns: ["p"], referenced: TableRef(schema: "shop", name: "parent"), referencedColumns: ["id"])
        let change = MaintenanceChange.convert(charset: "utf8mb4", collation: "utf8mb4_general_ci")
        let p = try TableMaintenancePlanner.plan(tables: [t], structures: [t.ref: structure(t, fks: [fk])], change: change, server: server())
        #expect(p.warnings.contains { $0.contains("parent") && $0.contains("foreign keys") })
        let parent = table("parent", engine: "InnoDB")
        let both = try TableMaintenancePlanner.plan(
            tables: [t, parent], structures: [t.ref: structure(t, fks: [fk]), parent.ref: structure(parent)], change: change, server: server())
        #expect(!both.warnings.contains { $0.contains("foreign keys") })
    }

    @Test func largeTablesWarn() throws {
        let big = table("big", rows: 5_000_000, data: 100)
        let huge = table("huge", rows: 10, data: 2 << 30)
        let small = table("small")
        let p = try TableMaintenancePlanner.plan(tables: [big, huge, small], change: .engine("InnoDB"), server: server())
        #expect(p.warnings.contains { $0.contains("`big`") && $0.contains("long time") })
        #expect(p.warnings.contains { $0.contains("`huge`") })
        #expect(!p.warnings.contains { $0.contains("`small`") })
        // skipped big tables don't warn
        let skipped = try TableMaintenancePlanner.plan(tables: [table("big", engine: "InnoDB", rows: 9_000_000)], change: .engine("InnoDB"), server: server())
        #expect(skipped.warnings.isEmpty)
    }

    @Test func exoticEngineWarnings() throws {
        func warns(_ engine: String, _ needle: String, structure s: ((TableInfo) -> TableStructure)? = nil) throws {
            let t = table("a", engine: "InnoDB")
            let p = try TableMaintenancePlanner.plan(
                tables: [t], structures: s.map { [t.ref: $0(t)] } ?? [:], change: .engine(engine), server: server())
            #expect(p.warnings.contains { $0.contains(needle) }, "\(engine): \(p.warnings)")
        }
        try warns("MEMORY", "lose all rows")
        try warns("ARCHIVE", "no UPDATE or DELETE")
        try warns("CSV", "NOT NULL")
        try warns("BLACKHOLE", "destroys its data")
        try warns("MyISAM", "no transactions")
        try warns("MEMORY", "will fail") { t in structure(t, columns: [col("b", "blob"), col("t", "text")]) }
    }
}

// MARK: - Integration

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"
private let mysqlTargets = [DBTarget.mysql8, DBTarget.mariadb11]
private let schemaName = "querywell_test"

/// Creates tables (`MyISAM`, utf8mb3 unless told otherwise), runs `body`, drops everything.
private func withMaintenanceTables<T>(
    _ target: DBTarget, count: Int = 2, engine: String = "MyISAM", charset: String = "utf8mb3",
    _ body: (any DatabaseSession, [String]) async throws -> T
) async throws -> T {
    let session = try await target.connect()
    var names: [String] = []
    do {
        for i in 0..<count {
            let name = target.uniqueTable("mt\(i)")
            names.append(name)
            let collate = charset == "utf8mb3" ? "utf8mb3_general_ci" : "\(charset)_general_ci"
            _ = try await session.execute("""
                CREATE TABLE \(name) (id INT PRIMARY KEY, name VARCHAR(50), body TEXT, FULLTEXT KEY ft (body))
                ENGINE=\(engine) DEFAULT CHARSET=\(charset) COLLATE=\(collate)
                """)
            _ = try await session.execute("INSERT INTO \(name) VALUES (1, 'één', 'hello world'), (2, 'two', 'foo')")
        }
        let r = try await body(session, names)
        for n in names { _ = try? await session.execute("DROP TABLE IF EXISTS \(n)") }
        await session.close()
        return r
    } catch {
        for n in names { _ = try? await session.execute("DROP TABLE IF EXISTS \(n)") }
        await session.close()
        throw error
    }
}

/// Reads table metadata the way the (separately built) inspector will.
private func infos(_ s: any DatabaseSession, _ names: [String], views: [String] = []) async throws -> [TableInfo] {
    let list = (names + views).map { "'\($0)'" }.joined(separator: ",")
    let r = try await s.execute("""
        SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COLLATION FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (\(list))
        """)
    var byName: [String: TableInfo] = [:]
    for row in r.rows {
        let name = row[0].displayString
        let isView = row[1].displayString.uppercased().contains("VIEW")
        byName[name] = TableInfo(
            ref: TableRef(schema: schemaName, name: name), kind: isView ? .view : .table,
            engine: row[2] == .null ? nil : row[2].displayString, estimatedRows: 2,
            collation: row[3] == .null ? nil : row[3].displayString)
    }
    return (names + views).compactMap { byName[$0] }
}

private func engineOf(_ s: any DatabaseSession, _ name: String) async throws -> String {
    try await s.execute("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(name)'")
        .rows[0][0].displayString
}

@Suite("Table maintenance integration", .serialized, .enabled(if: integrationEnabled))
struct TableMaintenanceIntegrationTests {
    @Test(arguments: mysqlTargets)
    func myisamToInnoDBSkippingMatchingTablesAndViews(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 2) { db, names in
            let inno = target.uniqueTable("inno")
            let view = target.uniqueTable("vw")
            _ = try await db.execute("CREATE TABLE \(inno) (id INT PRIMARY KEY) ENGINE=InnoDB")
            _ = try await db.execute("CREATE VIEW \(view) AS SELECT id FROM \(names[0])")

            let all = try await infos(db, names + [inno], views: [view])
            #expect(all.count == 4)
            let plan = try TableMaintenancePlanner.plan(tables: all, change: .engine("InnoDB"), server: db.serverInfo)
            #expect(plan.runnableSteps.count == 2)
            #expect(plan.skippedSteps.count == 2)

            let report = await MaintenanceRunner(session: db).runToCompletion(plan)
            #expect(report.isClean)
            #expect(report.succeededCount == 2)
            #expect(report.skippedCount == 2)
            for n in names {
                let e = try await engineOf(db, n)
                #expect(e == "InnoDB")
            }
            // data and FULLTEXT search survive
            let r = try await db.execute("SELECT name FROM \(names[0]) WHERE MATCH(body) AGAINST ('hello')")
            #expect(r.rows.map { $0[0] } == [.text("één")])

            // planning again finds nothing to do
            let again = try TableMaintenancePlanner.plan(tables: try await infos(db, names), change: .engine("InnoDB"), server: db.serverInfo)
            #expect(again.isEmpty)
            _ = try? await db.execute("DROP VIEW IF EXISTS \(view)")
            _ = try? await db.execute("DROP TABLE IF EXISTS \(inno)")
        }
    }

    @Test(arguments: mysqlTargets)
    func convertUtf8mb3ToUtf8mb4(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 2, engine: "InnoDB", charset: "utf8mb3") { db, names in
            let change = MaintenanceChange.convert(charset: "utf8mb4", collation: "utf8mb4_unicode_520_ci")
            let plan = try TableMaintenancePlanner.plan(
                tables: try await infos(db, names), change: change, alsoSetDatabaseDefault: false, server: db.serverInfo)
            #expect(plan.runnableSteps.count == 2)

            let report = await MaintenanceRunner(session: db).runToCompletion(plan)
            #expect(report.isClean, "\(report)")
            for n in names {
                let r = try await db.execute("""
                    SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(n)'
                    """)
                #expect(r.rows[0][0].displayString == "utf8mb4_unicode_520_ci")
                let c = try await db.execute("""
                    SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(n)' AND COLUMN_NAME = 'name'
                    """)
                #expect(c.rows[0][0].displayString == "utf8mb4_unicode_520_ci")
            }
            // 4-byte characters are now storable
            _ = try await db.execute("INSERT INTO \(names[0]) VALUES (3, '😀', 'emoji')")
            #expect(try await db.execute("SELECT name FROM \(names[0]) WHERE id = 3").rows[0][0] == .text("😀"))
            // and a second plan skips everything
            let again = try TableMaintenancePlanner.plan(tables: try await infos(db, names), change: change, server: db.serverInfo)
            #expect(again.isEmpty)
        }
    }

    @Test(arguments: mysqlTargets)
    func databaseDefaultStepRuns(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 1, engine: "InnoDB", charset: "utf8mb4") { db, names in
            // Re-apply the database's current default so the shared test database isn't altered.
            let cur = try await db.execute("""
                SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = DATABASE()
                """)
            let charset = cur.rows[0][0].displayString, collation = cur.rows[0][1].displayString
            let plan = try TableMaintenancePlanner.plan(
                tables: try await infos(db, names), change: .convert(charset: charset, collation: collation),
                alsoSetDatabaseDefault: true, server: db.serverInfo)
            #expect(plan.steps.last?.sql.hasPrefix("ALTER DATABASE `\(schemaName)`") == true)
            let report = await MaintenanceRunner(session: db).runToCompletion(plan)
            #expect(report.failedCount == 0, "\(report)")
            #expect(report.entries.last?.step.table == nil)
        }
    }

    private func brokenPlan(_ names: [String]) -> MaintenancePlan {
        let ref = { (n: String) in TableRef(schema: schemaName, name: n) }
        let d = SQLDialect(.mysql)
        return MaintenancePlan(steps: [
            MaintenanceStep(id: 0, target: .table(ref(names[0])), sql: "ALTER TABLE \(d.qualified(ref(names[0]))) ENGINE=InnoDB"),
            MaintenanceStep(id: 1, target: .table(ref("qw_does_not_exist")), sql: "ALTER TABLE \(d.qualified(ref("qw_does_not_exist"))) ENGINE=InnoDB"),
            MaintenanceStep(id: 2, target: .table(ref(names[1])), sql: "ALTER TABLE \(d.qualified(ref(names[1]))) ENGINE=InnoDB"),
        ], warnings: [])
    }

    @Test(arguments: mysqlTargets)
    func errorMidwayStopsWhenAskedTo(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 2) { db, names in
            let runner = MaintenanceRunner(session: db)
            var events: [MaintenanceEvent] = []
            for await e in await runner.run(brokenPlan(names), stopOnError: true) { events.append(e) }

            guard case .completed(let report) = events.last else { Issue.record("no completed event"); return }
            #expect(report.stoppedOnError)
            #expect(report.failedCount == 1)
            #expect(report.succeededCount == 1)
            #expect(report.entries[2].outcome == .notRun(.stoppedAfterError))
            #expect(!report.isClean)
            // event order: started(0) finished(0) started(1) failed(1) completed
            let tags = events.map { e -> String in
                switch e {
                case .started(let s): "start\(s.id)"
                case .finished(let s, _): "done\(s.id)"
                case .failed(let s, _): "fail\(s.id)"
                case .skipped(let s, _): "skip\(s.id)"
                case .completed: "completed"
                }
            }
            #expect(tags == ["start0", "done0", "start1", "fail1", "completed"])
            let eng0 = try await engineOf(db, names[0])
            #expect(eng0 == "InnoDB")
            let eng1 = try await engineOf(db, names[1])
            #expect(eng1 == "MyISAM")
        }
    }

    @Test(arguments: mysqlTargets)
    func errorMidwayContinuesWhenAskedTo(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 2) { db, names in
            let report = await MaintenanceRunner(session: db).runToCompletion(brokenPlan(names), stopOnError: false)
            #expect(!report.stoppedOnError)
            #expect(report.failedCount == 1)
            #expect(report.succeededCount == 2)
            if case .failed(let message) = report.entries[1].outcome { #expect(!message.isEmpty) } else { Issue.record("step 1 should fail") }
            let eng1 = try await engineOf(db, names[1])
            #expect(eng1 == "InnoDB")
        }
    }

    @Test(arguments: mysqlTargets)
    func cancellationStopsBetweenTables(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 3) { db, names in
            let d = SQLDialect(.mysql)
            let ref = { (n: String) in TableRef(schema: schemaName, name: n) }
            // First step takes ~0.6s so cancel() lands while it runs.
            let plan = MaintenancePlan(steps: [
                MaintenanceStep(id: 0, target: .table(ref(names[0])), sql: "DO SLEEP(0.6)"),
                MaintenanceStep(id: 1, target: .table(ref(names[1])), sql: "ALTER TABLE \(d.qualified(ref(names[1]))) ENGINE=InnoDB"),
                MaintenanceStep(id: 2, target: .table(ref(names[2])), sql: "ALTER TABLE \(d.qualified(ref(names[2]))) ENGINE=InnoDB"),
            ], warnings: [])
            let runner = MaintenanceRunner(session: db)
            var report: MaintenanceReport?
            for await e in await runner.run(plan) {
                if case .started(let s) = e, s.id == 0 { await runner.cancel() }
                if case .completed(let r) = e { report = r }
            }
            let r = try #require(report)
            #expect(r.wasCancelled)
            #expect(r.succeededCount == 1)
            #expect(r.entries[1].outcome == .notRun(.cancelled))
            #expect(r.entries[2].outcome == .notRun(.cancelled))
            let eng1 = try await engineOf(db, names[1])
            #expect(eng1 == "MyISAM")
            let eng2 = try await engineOf(db, names[2])
            #expect(eng2 == "MyISAM")
        }
    }

    @Test(arguments: mysqlTargets)
    func cancellingTheCallerOfRunToCompletion(target: DBTarget) async throws {
        try await withMaintenanceTables(target, count: 2) { db, names in
            let d = SQLDialect(.mysql)
            let ref = { (n: String) in TableRef(schema: schemaName, name: n) }
            let plan = MaintenancePlan(steps: [
                MaintenanceStep(id: 0, target: .table(ref(names[0])), sql: "DO SLEEP(0.5)"),
                MaintenanceStep(id: 1, target: .table(ref(names[1])), sql: "ALTER TABLE \(d.qualified(ref(names[1]))) ENGINE=InnoDB"),
            ], warnings: [])
            let runner = MaintenanceRunner(session: db)
            let t = Task { await runner.runToCompletion(plan) }
            try await Task.sleep(for: .milliseconds(150))
            t.cancel()
            let report = await t.value
            #expect(report.wasCancelled)
            #expect(report.entries[1].outcome == .notRun(.cancelled))
        }
    }

    @Test func postgresIsRejected() async throws {
        let session = try await DBTarget.postgres16.connect()
        let info = session.serverInfo
        await session.close()
        #expect(throws: MaintenanceError.self) {
            try TableMaintenancePlanner.plan(
                tables: [TableInfo(ref: TableRef(schema: "public", name: "t"), kind: .table)],
                change: .engine("InnoDB"), server: info)
        }
    }
}

@Suite("Dry-run integration", .serialized, .enabled(if: integrationEnabled))
struct DryRunIntegrationTests {
    @Test(arguments: DBTarget.all)
    func countsMatchWhatTheStatementWouldAffect(target: DBTarget) async throws {
        let session = try await target.connect()
        let name = target.uniqueTable("dry")
        _ = try await session.execute("CREATE TABLE \(name) (id INT PRIMARY KEY, grp INT, note VARCHAR(20))")
        do { try await dryRunBody(target, session, name) } catch {
            _ = try? await session.execute("DROP TABLE IF EXISTS \(name)")
            await session.close()
            throw error
        }
        _ = try? await session.execute("DROP TABLE IF EXISTS \(name)")
        await session.close()
    }

    private func dryRunBody(_ target: DBTarget, _ session: any DatabaseSession, _ name: String) async throws {
        _ = try await session.execute("INSERT INTO \(name) VALUES (1,1,'a'),(2,1,'b'),(3,2,'c'),(4,2,'d'),(5,3,'e')")

        let dialect = SQLDialect(target.engine)
        let classifier = StatementClassifier(dialect: dialect)
        func counts(_ sql: String) async -> [Int64?] {
            let c = classifier.classify(text: sql)
            let plans = DryRunPlanner.plans(for: c, statementIndex: 0, dialect: dialect)
            return await DryRunExecutor.run(plans, on: session).map(\.count)
        }
        #expect(await counts("DELETE FROM \(name) WHERE grp = 2") == [2])
        #expect(await counts("UPDATE \(name) SET note = 'x' WHERE grp = 1 OR id = 5") == [3])
        #expect(await counts("DELETE FROM \(name)") == [5])
        #expect(await counts("DELETE FROM \(name) WHERE note = 'it''s; where'") == [0])
        #expect(await counts("TRUNCATE TABLE \(name)") == [5])
        #expect(await counts("DROP TABLE \(name)") == [5])
        #expect(await counts("DELETE FROM \(name) WHERE id IN (SELECT id FROM \(name) WHERE grp = 2)") == [2])
        if !target.isPostgres {
            #expect(await counts("DELETE FROM \(name) ORDER BY id LIMIT 3") == [3])
            #expect(await counts("DELETE FROM \(name) WHERE grp = 2 LIMIT 10") == [2])
            #expect(await counts("UPDATE \(name) SET note = 'z' WHERE grp = 1 ORDER BY id LIMIT 1") == [1])
        }
        // the dry run must not have changed anything
        #expect(try await session.execute("SELECT COUNT(*) FROM \(name)").rows[0][0] != .integer(0))
        #expect(await counts("DELETE FROM \(name)") == [5])
    }

    @Test(arguments: DBTarget.all)
    func failingCountIsReportedNotThrown(target: DBTarget) async throws {
        let session = try await target.connect()
        let dialect = SQLDialect(target.engine)
        let c = StatementClassifier(dialect: dialect).classify(text: "DROP TABLE IF EXISTS qw_no_such_table_zz")
        let plans = DryRunPlanner.plans(for: c, statementIndex: 0, dialect: dialect)
        let results = await DryRunExecutor.run(plans, on: session)
        #expect(results.count == 1)
        #expect(results[0].count == nil)
        #expect(results[0].error?.isEmpty == false)
        // un-estimable plans pass through without touching the server
        let drop = StatementClassifier(dialect: dialect).classify(text: "DROP DATABASE qw_none")
        let r2 = await DryRunExecutor.run(DryRunPlanner.plans(for: drop, statementIndex: 0, dialect: dialect), on: session)
        #expect(r2[0].count == nil && r2[0].error == nil && r2[0].plan.sql == nil)
        await session.close()
    }
}
