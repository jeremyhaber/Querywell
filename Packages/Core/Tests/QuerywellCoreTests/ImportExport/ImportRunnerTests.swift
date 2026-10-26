import Foundation
import Testing

@testable import QuerywellCore

// MARK: - Helpers

func tempFile(_ name: String, _ data: Data) throws -> (url: URL, cleanup: () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return (url, { try? FileManager.default.removeItem(at: dir) })
}

/// Records statements; fails the ones containing "FAIL".
final class RecordingSession: DatabaseSession, @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var _statements: [String] = []
    let engine: DatabaseEngine
    let serverInfo: ServerInfo
    var onExecute: (@Sendable (Int) -> Void)?

    init(engine: DatabaseEngine = .mysql) {
        self.engine = engine
        serverInfo = ServerInfo(engine: engine, versionString: "x", major: 8, minor: 0, patch: 0, tlsActive: false)
    }

    var statements: [String] { lock.withLock { _statements } }

    func execute(_ sql: String) async throws -> QueryResult {
        let n = lock.withLock { () -> Int in
            _statements.append(sql)
            return _statements.count
        }
        onExecute?(n)
        if sql.contains("FAIL") { throw DatabaseError.query(message: "boom", code: "1064") }
        return QueryResult()
    }

    func listDatabases() async throws -> [String] { [] }
    func currentDatabase() async throws -> String? { nil }
    func close() async {}
}

private let devContext = GuardContext(isProduction: false, isReadOnly: false, databaseName: "app", dialect: SQLDialect(.mysql))
private func token() -> ImportAuthorization { ImportGuard.authorize(context: devContext)! }

// MARK: - Unit

@Suite("Import runner (unit)")
struct ImportRunnerUnitTests {
    private let script = """
    CREATE TABLE a (id int);
    INSERT INTO a VALUES (1);
    INSERT INTO a VALUES (FAIL);
    INSERT INTO a VALUES (3);
    """

    @Test func stopsAtTheFirstErrorByDefault() async throws {
        let f = try tempFile("d.sql", Data(script.utf8))
        defer { f.cleanup() }
        let session = RecordingSession()
        let report = try await ImportRunner(session: session).run(file: f.url, authorization: token())
        #expect(report.statementsExecuted == 2)
        #expect(report.statementsFailed == 1)
        #expect(report.stoppedOnError && !report.completed && !report.succeeded)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].statementIndex == 2)
        #expect(report.errors[0].line == 3)
        #expect(report.errors[0].snippet == "INSERT INTO a VALUES (FAIL)")
        #expect(report.errors[0].message == "boom" && report.errors[0].code == "1064")
        #expect(!session.statements.contains { $0.contains("(3)") })
        // the session is put back into a sane state
        #expect(session.statements.suffix(2) == ["UNLOCK TABLES", "SET FOREIGN_KEY_CHECKS = 1, UNIQUE_CHECKS = 1"])
    }

    @Test func continuesPastErrorsAndCollectsThem() async throws {
        let f = try tempFile("d.sql", Data(script.utf8))
        defer { f.cleanup() }
        let session = RecordingSession()
        let events = EventBox()
        let report = try await ImportRunner(session: session).run(
            file: f.url, options: ImportOptions(stopOnError: false), authorization: token()) { events.add($0) }
        #expect(report.statementsExecuted == 3 && report.statementsFailed == 1 && report.completed && !report.succeeded)
        #expect(session.statements.contains { $0.contains("(3)") })
        #expect(events.failures.count == 1)
        #expect(events.started)
        #expect(report.bytesRead == report.totalBytes)
    }

    @Test func snippetIsLimitedTo200Characters() async throws {
        let long = "INSERT INTO a VALUES ('FAIL" + String(repeating: "x", count: 1000) + "');"
        let f = try tempFile("d.sql", Data(long.utf8))
        defer { f.cleanup() }
        let report = try await ImportRunner(session: RecordingSession()).run(file: f.url, authorization: token())
        #expect(report.errors[0].snippet.count == 200)
    }

    @Test func gzipInputIsDetectedByContentNotName() async throws {
        let gz = try Gzip.compress(Data(script.replacingOccurrences(of: "FAIL", with: "2").utf8))
        let f = try tempFile("dump.bin", gz)
        defer { f.cleanup() }
        let session = RecordingSession()
        let events = EventBox()
        let report = try await ImportRunner(session: session).run(file: f.url, authorization: token()) { events.add($0) }
        #expect(report.succeeded && report.statementsExecuted == 4)
        #expect(events.gzipFlag == true)
        #expect(report.totalBytes == Int64(gz.count))
        #expect(report.bytesRead == Int64(gz.count))
    }

    @Test func truncatedGzipThrows() async throws {
        let gz = try Gzip.compress(Data(String(repeating: "INSERT INTO a VALUES (1);\n", count: 5000).utf8))
        let f = try tempFile("dump.sql.gz", gz.prefix(gz.count / 2))
        defer { f.cleanup() }
        await #expect(throws: GzipError.self) {
            _ = try await ImportRunner(session: RecordingSession()).run(file: f.url, authorization: token())
        }
    }

    @Test func collationRewriteStageIsApplied() async throws {
        let sql = "CREATE TABLE t (a varchar(5) COLLATE utf8mb4_0900_ai_ci) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;\nINSERT INTO t VALUES ('utf8mb4_0900_ai_ci');\n"
        let f = try tempFile("d.sql", Data(sql.utf8))
        defer { f.cleanup() }
        let session = RecordingSession()
        let report = try await ImportRunner(session: session).run(
            file: f.url, options: ImportOptions(collation: .mysql57MariaDBCompatible), authorization: token())
        #expect(report.collationRewrites == 2)
        #expect(session.statements[0].contains("utf8mb4_unicode_520_ci") && !session.statements[0].contains("0900"))
        #expect(session.statements[1] == "INSERT INTO t VALUES ('utf8mb4_0900_ai_ci')")
    }

    @Test func cancellationStopsAfterTheStatementInFlight() async throws {
        let big = String(repeating: "INSERT INTO a VALUES (1);\n", count: 5000)
        let f = try tempFile("d.sql", Data(big.utf8))
        defer { f.cleanup() }
        let session = RecordingSession()
        let box = TaskHolder()
        session.onExecute = { n in
            if n == 50 {
                while box.task == nil { usleep(200) }
                box.cancel()
            }
        }
        let url = f.url
        let task = Task { try await ImportRunner(session: session).run(file: url, authorization: token()) }
        box.task = task
        let report = try await task.value
        #expect(report.wasCancelled && !report.completed)
        #expect(report.statementsExecuted >= 50 && report.statementsExecuted < 5000)
    }

    @Test func chunkBoundariesNeverSplitStatements() async throws {
        // Statements much larger than the 256 KB read size.
        let payload = String(repeating: "é;'\"x", count: 80_000)
        let sql = "INSERT INTO a VALUES ('\(payload.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\"", with: "\\\""))');\nSELECT 1;\n"
        let f = try tempFile("d.sql", Data(sql.utf8))
        defer { f.cleanup() }
        let session = RecordingSession()
        let report = try await ImportRunner(session: session).run(file: f.url, authorization: token())
        #expect(report.statementsExecuted == 2)
        #expect(session.statements[0].count > 400_000)
        #expect(session.statements[1] == "SELECT 1")
    }

    @Test func guardRequiresConfirmationOnProduction() {
        let prod = GuardContext(isProduction: true, isReadOnly: false, databaseName: "shop", dialect: SQLDialect(.mysql))
        #expect(ImportGuard.authorize(context: prod) == nil)
        #expect(ImportGuard.authorize(context: prod, typedConfirmation: "wrong") == nil)
        #expect(ImportGuard.authorize(context: prod, typedConfirmation: "shop") != nil)
        let readOnly = GuardContext(isProduction: false, isReadOnly: true, databaseName: "shop", dialect: SQLDialect(.mysql))
        #expect(ImportGuard.authorize(context: readOnly) == nil)
        #expect(ImportGuard.authorize(context: devContext) != nil)
        guard case .confirm(let req) = ImportGuard.evaluate(context: prod) else { Issue.record("expected confirmation"); return }
        #expect(req.requiresTypedName == "shop")
    }

    @Test func scanSuggestsAMappingTheServerAccepts() throws {
        let sql = "CREATE TABLE t (a varchar(5)) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;\n"
        let f = try tempFile("d.sql", Data(sql.utf8))
        defer { f.cleanup() }
        let maria = [CollationInfo(name: "utf8mb4_general_ci", characterSet: "utf8mb4", isDefault: true),
                     CollationInfo(name: "utf8mb4_unicode_520_ci", characterSet: "utf8mb4", isDefault: false),
                     CollationInfo(name: "utf8mb4_bin", characterSet: "utf8mb4", isDefault: false)]
        let r = try ImportScanner.scan(file: f.url, supportedCollations: maria)
        #expect(r.unsupportedCollations == ["utf8mb4_0900_ai_ci"])
        #expect(r.needsRewrite && r.isComplete && !r.isGzip)
        #expect(r.suggestedMapping == .mysql57MariaDBCompatible)
        // a server that has the collation needs nothing
        let eight = maria + [CollationInfo(name: "utf8mb4_0900_ai_ci", characterSet: "utf8mb4", isDefault: false)]
        #expect(try ImportScanner.scan(file: f.url, supportedCollations: eight).needsRewrite == false)
        // limited scans say so
        let limited = try ImportScanner.scan(file: f.url, supportedCollations: maria, limitBytes: 10)
        #expect(!limited.isComplete)
    }
}

final class EventBox: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var events: [ImportEvent] = []
    func add(_ e: ImportEvent) { lock.withLock { events.append(e) } }
    var failures: [ImportStatementError] { lock.withLock { events.compactMap { if case .statementFailed(let e) = $0 { e } else { nil } } } }
    var started: Bool { lock.withLock { events.contains { if case .started = $0 { true } else { false } } } }
    var gzipFlag: Bool? { lock.withLock { events.compactMap { if case .started(_, let g) = $0 { g } else { nil } }.first } }
    var progress: [ImportProgress] { lock.withLock { events.compactMap { if case .progress(let p) = $0 { p } else { nil } } } }
}

final class TaskHolder: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var _task: Task<ImportReport, any Error>?
    var task: Task<ImportReport, any Error>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    func cancel() { task?.cancel() }
}

// MARK: - Integration

/// A scratch database/schema the import runs in (dropped afterwards), with an admin session pointed at it.
struct ImportFixture {
    let f: SchemaFixture
    var d: SQLDialect { f.dialect }
    var pg: Bool { f.target.isPostgres }

    /// Makes `f.schema` the default so unqualified names in dump files land there.
    func use() async throws {
        if pg { try await f.run("SET search_path TO \(f.q)") } else { try await f.run("USE \(f.q)") }
    }

    func count(_ table: String) async throws -> Int {
        let r = try await f.session.execute("SELECT COUNT(*) FROM \(f.q).\(d.quoteIdentifier(table))")
        return Int(r.rows[0][0].displayString) ?? -1
    }

    func tableExists(_ table: String) async throws -> Bool {
        let sql = "SELECT 1 FROM information_schema.tables WHERE table_schema = \(d.quoteString(f.schema)) AND table_name = \(d.quoteString(table))"
        return !(try await f.session.execute(sql)).rows.isEmpty
    }

    func runner() -> ImportRunner { ImportRunner(session: f.session) }
    func auth() -> ImportAuthorization {
        ImportGuard.authorize(context: GuardContext(isProduction: false, isReadOnly: false, databaseName: f.schema, dialect: d))!
    }
}

@Suite("Import integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct ImportIntegrationTests {
    static func mysqlDump(_ n: Int = 0) -> String {
        """
        /*M!999999\\- enable the sandbox mode */
        -- MySQL dump 10.13  Distrib 8.4.0, for macos14 (arm64)
        --
        -- Host: localhost    Database: shop
        -- ------------------------------------------------------
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40101 SET NAMES utf8mb4 */;
        /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
        /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
        /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;

        --
        -- Table structure for table `items`
        --

        DROP TABLE IF EXISTS `items`;
        /*!40101 SET @saved_cs_client     = @@character_set_client */;
        /*!40101 SET character_set_client = utf8mb4 */;
        CREATE TABLE `items` (
          `id` int NOT NULL AUTO_INCREMENT,
          `name` varchar(50) DEFAULT NULL,
          `note` text,
          `flag` tinyint DEFAULT '0',
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        /*!40101 SET character_set_client = @saved_cs_client */;

        LOCK TABLES `items` WRITE;
        /*!40000 ALTER TABLE `items` DISABLE KEYS */;
        INSERT INTO `items` VALUES (1,'plain','a; b -- not a comment',0),(2,'quote\\'s','back\\\\slash \\'x\\' "dq"',0),(3,'multi\\nline','😀 ünï ; /* not a comment */',0);
        /*!40000 ALTER TABLE `items` ENABLE KEYS */;
        UNLOCK TABLES;

        DELIMITER ;;
        CREATE TRIGGER `items_bi` BEFORE INSERT ON `items` FOR EACH ROW BEGIN
          IF NEW.name IS NULL THEN SET NEW.name = 'defaulted'; END IF;
          SET NEW.flag = 1;
        END ;;
        DELIMITER ;

        INSERT INTO `items` (`name`) VALUES (NULL);
        /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
        /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
        /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
        -- Dump completed on 2026-10-26 12:00:00
        """
    }

    func pgDump(_ s: String) -> String {
        """
        \\restrict TOKEN123abc
        SET statement_timeout = 0;
        SET client_encoding = 'UTF8';
        SET standard_conforming_strings = on;
        CREATE TABLE \(s).items (id integer NOT NULL, name text, data jsonb, raw bytea, PRIMARY KEY (id));
        CREATE FUNCTION \(s).twice(x integer) RETURNS integer
            LANGUAGE plpgsql
            AS $fn$
        BEGIN
          -- semicolons; and 'quotes inside a dollar-quoted body
          RETURN x * 2;
        END;
        $fn$;
        CREATE FUNCTION \(s).label() RETURNS text LANGUAGE sql AS $$ SELECT 'a;b' $$;
        COPY \(s).items (id, name, data, raw) FROM stdin;
        1\tplain; text\t{"a": 1}\t\\\\x00ff
        2\ttab\\there\t\\N\t\\N
        3\tnew\\nline \\\\ back\t[1, 2]\t\\\\x41
        \\.
        INSERT INTO \(s).items VALUES (4, E'esc\\'aped; ok', '{}', NULL);
        INSERT INTO \(s).items VALUES (5, 'it''s', '{"k": "v"}', NULL);
        \\unrestrict TOKEN123abc
        """
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func mysqlDumpWithTriggersLocksAndDelimiters(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            try await fx.use()
            let file = try tempFile("shop.sql", Data(Self.mysqlDump().utf8))
            defer { file.cleanup() }
            let report = try await fx.runner().run(file: file.url, authorization: fx.auth())
            #expect(report.errors.isEmpty, "errors: \(report.errors)")
            #expect(report.succeeded)
            #expect(try await fx.count("items") == 4)
            let rows = try await f.session.execute("SELECT id, name, note, flag FROM \(f.q).items ORDER BY id")
            #expect(rows.rows[0][2] == .text("a; b -- not a comment"))
            #expect(rows.rows[1][1] == .text("quote's"))
            #expect(rows.rows[1][2] == .text("back\\slash 'x' \"dq\""))
            #expect(rows.rows[2][1] == .text("multi\nline"))
            #expect(rows.rows[2][2] == .text("😀 ünï ; /* not a comment */"))
            #expect(rows.rows[3][1] == .text("defaulted"))  // the trigger from the dump ran
            #expect(rows.rows[3][3].displayString == "1")
            // session state restored by the dump's own footer; FK checks are back on
            let fk = try await f.session.execute("SELECT @@FOREIGN_KEY_CHECKS")
            #expect(fk.rows[0][0].displayString == "1")
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func gzippedDumpImportsAndReportsCompressedProgress(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            try await fx.use()
            let gz = try Gzip.compress(Data(Self.mysqlDump().utf8))
            let file = try tempFile("shop.sql.gz", gz)
            defer { file.cleanup() }
            let events = EventBox()
            let report = try await fx.runner().run(file: file.url, authorization: fx.auth()) { events.add($0) }
            #expect(report.succeeded)
            #expect(report.totalBytes == Int64(gz.count) && report.bytesRead == report.totalBytes)
            #expect(events.progress.last?.fraction == 1)
            #expect(try await fx.count("items") == 4)
        }
    }

    @Test(arguments: DBTarget.all)
    func errorMidFileStopsOrContinues(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            try await fx.use()
            let sql = """
            CREATE TABLE ok1 (id integer PRIMARY KEY);
            INSERT INTO ok1 VALUES (1);
            INSERT INTO does_not_exist VALUES (1);
            INSERT INTO ok1 VALUES (2);
            CREATE TABLE ok2 (id integer);
            """
            let file = try tempFile("e.sql", Data(sql.utf8))
            defer { file.cleanup() }

            let stopped = try await fx.runner().run(file: file.url, authorization: fx.auth())
            #expect(stopped.statementsExecuted == 2 && stopped.statementsFailed == 1 && stopped.stoppedOnError)
            #expect(stopped.errors[0].statementIndex == 2)
            #expect(stopped.errors[0].snippet.hasPrefix("INSERT INTO does_not_exist"))
            #expect(stopped.errors[0].line == 3)
            #expect(!stopped.errors[0].message.isEmpty)
            #expect(try await fx.count("ok1") == 1)
            #expect(try await fx.tableExists("ok2") == false)

            let cont = try await fx.runner().run(
                file: file.url, options: ImportOptions(stopOnError: false), authorization: fx.auth())
            // ok1 already exists now -> first CREATE fails, row 1 duplicates, then the rest goes through
            #expect(cont.completed && !cont.stoppedOnError)
            #expect(cont.statementsFailed >= 2)
            #expect(cont.errors.count == cont.statementsFailed)
            #expect(try await fx.tableExists("ok2") == true)
            #expect(try await fx.count("ok1") == 2)
        }
    }

    @Test func postgresPlainDumpWithDollarQuotesCopyAndMetaCommands() async throws {
        let target = DBTarget.postgres16
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            let file = try tempFile("pg.sql", Data(pgDump(f.q).utf8))
            defer { file.cleanup() }
            let report = try await fx.runner().run(file: file.url, authorization: fx.auth())
            #expect(report.errors.isEmpty, "errors: \(report.errors)")
            #expect(try await fx.count("items") == 5)
            let r = try await f.session.execute("SELECT id, name, data::text, encode(raw, 'hex') FROM \(f.q).items ORDER BY id")
            #expect(r.rows[0][1] == .text("plain; text"))
            #expect(r.rows[0][2] == .text(#"{"a": 1}"#))
            #expect(r.rows[0][3] == .text("00ff"))
            #expect(r.rows[1][1] == .text("tab\there"))
            #expect(r.rows[1][2] == .null && r.rows[1][3] == .null)
            #expect(r.rows[2][1] == .text("new\nline \\ back"))
            #expect(r.rows[2][3] == .text("41"))
            #expect(r.rows[3][1] == .text("esc'aped; ok"))
            #expect(r.rows[4][1] == .text("it's"))
            let fn = try await f.session.execute("SELECT \(f.q).twice(21), \(f.q).label()")
            #expect(fn.rows[0][0].displayString == "42")
            #expect(fn.rows[0][1] == .text("a;b"))
        }
    }

    @Test(arguments: DBTarget.all)
    func cancellationStopsALargeImport(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            try await fx.use()
            var sql = "CREATE TABLE big (id integer, payload varchar(100));\n"
            for i in 0..<20_000 { sql += "INSERT INTO big VALUES (\(i), 'row \(i)');\n" }
            let file = try tempFile("big.sql", Data(sql.utf8))
            defer { file.cleanup() }
            let holder = TaskHolder()
            let runner = fx.runner()
            let auth = fx.auth()
            let url = file.url
            let task = Task {
                try await runner.run(file: url, authorization: auth) { e in
                    if case .progress(let p) = e, p.statementsExecuted > 300 { holder.cancel() }
                }
            }
            holder.task = task
            let report = try await task.value
            #expect(report.wasCancelled && !report.completed)
            let n = try await fx.count("big")
            #expect(n > 0 && n < 20_000)
            _ = try await f.session.execute("SELECT 1")  // session still usable
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func collationPreScanAndRewriteOnImport(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = ImportFixture(f: f)
            try await fx.use()
            // The collation this server does NOT know.
            // A collation this server does not list: MariaDB 11.4 knows utf8mb4_0900_ai_ci but not the language variants.
            let foreign = target.name == "mysql-8.4" ? "utf8mb4_uca1400_ai_ci" : "utf8mb4_ja_0900_as_cs"
            let expectedAfter = target.name == "mysql-8.4" ? "utf8mb4_unicode_520_ci" : "utf8mb4_bin"
            let sql = """
            CREATE TABLE `docs` (`id` int NOT NULL, `title` varchar(50) COLLATE \(foreign) DEFAULT NULL, PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=\(foreign);
            INSERT INTO `docs` VALUES (1,'mentions \(foreign) in data');
            """
            let file = try tempFile("c.sql", Data(sql.utf8))
            defer { file.cleanup() }
            let supported = try await f.inspector.availableCollations()
            let scan = try ImportScanner.scan(file: file.url, supportedCollations: supported)
            #expect(scan.unsupportedCollations == [foreign], "scan: \(scan.unsupportedCollations)")
            let mapping = try #require(scan.suggestedMapping)

            // without the fix the server rejects the DDL and the import stops there
            let plain = try await fx.runner().run(file: file.url, authorization: fx.auth())
            #expect(plain.statementsFailed == 1 && plain.stoppedOnError)
            #expect(plain.errors[0].message.lowercased().contains("collation"))

            let fixed = try await fx.runner().run(file: file.url, options: ImportOptions(collation: mapping), authorization: fx.auth())
            #expect(fixed.succeeded, "errors: \(fixed.errors)")
            #expect(fixed.collationRewrites >= 2)
            let row = try await f.session.execute("SELECT title FROM \(f.q).docs")
            #expect(row.rows[0][0] == .text("mentions \(foreign) in data"))
            let create = try await f.session.execute("SHOW CREATE TABLE \(f.q).docs")
            #expect(create.rows[0][1].displayString.contains(expectedAfter))
            #expect(!create.rows[0][1].displayString.contains(foreign))
        }
    }

    @Test(arguments: DBTarget.all)
    func exportedDumpsRoundTripThroughTheImporter(target: DBTarget) async throws {
        let tools = await DumpToolLocator().locate()
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let source = ExportFixture(f: f)
            try await source.create()
            let selection = DumpToolSelector.select(for: f.session.serverInfo, from: tools)
            guard selection.isUsable else { return }
            var plan = try ExportPlanner.plan(
                target: source.target(bed: bed), options: source.options { $0.location = .localThroughTunnel }, tool: selection)
            plan.tables = source.tableNames()
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            let dest = out.appendingPathComponent(plan.outputFilename)
            try await ExportRunner(secretStore: InMemorySecretStore()).run(plan: plan, to: dest)

            // import into a second scratch schema
            let session2 = try await target.connectPrivileged()
            let target2Schema = "qw_imp_" + UUID().uuidString.prefix(8).lowercased()
            let q2 = f.dialect.quoteIdentifier(target2Schema)
            _ = try await session2.execute(target.isPostgres ? "CREATE SCHEMA \(q2)" : "CREATE DATABASE \(q2)")
            do {
                if target.isPostgres {
                    // pg_dump qualifies names with the source schema; rewrite it for the copy
                    var text = String(decoding: try Gzip.decompress(try Data(contentsOf: dest)), as: UTF8.self)
                    text = text.replacingOccurrences(of: f.schema, with: target2Schema)
                    try Data(text.utf8).write(to: dest.deletingPathExtension())
                    // pg_dump 17+ emits `SET transaction_timeout`, which PostgreSQL 16 rejects; that is the only tolerated error.
                    let r = try await ImportRunner(session: session2).run(
                        file: dest.deletingPathExtension(), options: ImportOptions(stopOnError: false),
                        authorization: ImportGuard.authorize(
                            context: GuardContext(isProduction: false, isReadOnly: false, databaseName: nil, dialect: f.dialect))!)
                    #expect(r.errors.allSatisfy { $0.snippet.contains("transaction_timeout") }, "errors: \(r.errors)")
                } else {
                    _ = try await session2.execute("USE \(q2)")
                    let r = try await ImportRunner(session: session2).run(
                        file: dest, authorization: ImportGuard.authorize(
                            context: GuardContext(isProduction: false, isReadOnly: false, databaseName: nil, dialect: f.dialect))!)
                    #expect(r.errors.isEmpty, "errors: \(r.errors)")
                }
                let a = try await f.session.execute("SELECT option_name, option_value FROM \(f.q).wp_options ORDER BY option_id")
                let b = try await session2.execute("SELECT option_name, option_value FROM \(q2).wp_options ORDER BY option_id")
                #expect(a.rows == b.rows)
                #expect(a.rows.count == 6)
            } catch {
                _ = try? await session2.execute(target.isPostgres ? "DROP SCHEMA IF EXISTS \(q2) CASCADE" : "DROP DATABASE IF EXISTS \(q2)")
                await session2.close()
                throw error
            }
            _ = try? await session2.execute(target.isPostgres ? "DROP SCHEMA IF EXISTS \(q2) CASCADE" : "DROP DATABASE IF EXISTS \(q2)")
            await session2.close()
        }
    }
}
