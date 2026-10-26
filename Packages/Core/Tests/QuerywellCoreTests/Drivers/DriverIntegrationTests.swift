import Foundation
import Testing

@testable import QuerywellCore

/// Integration tests against the docker-compose servers. Enabled only with QUERYWELL_INTEGRATION=1:
///   docker compose up -d --wait mysql8 mariadb11 postgres16
private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

struct DBTarget: Sendable, CustomTestStringConvertible {
    var name: String
    var engine: DatabaseEngine
    var port: Int
    /// Engine the server should be detected as.
    var detectedEngine: DatabaseEngine
    /// Whether the docker image ships a usable TLS certificate.
    var hasTLS: Bool

    var testDescription: String { name }
    var isPostgres: Bool { engine == .postgresql }

    static let mysql8 = DBTarget(name: "mysql-8.4", engine: .mysql, port: 13306, detectedEngine: .mysql, hasTLS: true)
    static let mariadb11 = DBTarget(name: "mariadb-11.4", engine: .mariadb, port: 13307, detectedEngine: .mariadb, hasTLS: false)
    static let postgres16 = DBTarget(name: "postgres-16", engine: .postgresql, port: 15432, detectedEngine: .postgresql, hasTLS: true)
    static let all = [mysql8, mariadb11, postgres16]
    static let tlsCapable = all.filter(\.hasTLS)

    func config(
        engine override: DatabaseEngine? = nil,
        password: String = "querywell_pw",
        port overridePort: Int? = nil,
        tls: TLSConfig = TLSConfig(mode: .disabled),
        timeout: Duration = .seconds(10)
    ) -> ConnectionConfiguration {
        ConnectionConfiguration(
            engine: override ?? engine, host: "127.0.0.1", port: overridePort ?? port,
            user: "querywell", password: password, database: "querywell_test",
            tls: tls, connectTimeout: timeout
        )
    }

    func connect(
        engine override: DatabaseEngine? = nil, tls: TLSConfig = TLSConfig(mode: .disabled)
    ) async throws -> any DatabaseSession {
        let cfg = config(engine: override, tls: tls)
        return try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
    }

    func uniqueTable(_ tag: String) -> String {
        "qw_\(tag)_\(UUID().uuidString.prefix(8).lowercased())"
    }
}

/// Runs `body` with a fresh session and drops `table` afterwards, whatever happens.
private func withSession<T>(
    _ target: DBTarget, table: String? = nil, _ body: (any DatabaseSession) async throws -> T
) async throws -> T {
    let session = try await target.connect()
    do {
        let result = try await body(session)
        if let table { _ = try? await session.execute("DROP TABLE IF EXISTS \(table)") }
        await session.close()
        return result
    } catch {
        if let table { _ = try? await session.execute("DROP TABLE IF EXISTS \(table)") }
        await session.close()
        throw error
    }
}

@Suite("Driver integration", .serialized, .enabled(if: integrationEnabled))
struct DriverIntegrationTests {
    // MARK: Connect & metadata

    @Test(arguments: DBTarget.all)
    func connectAndServerInfo(target: DBTarget) async throws {
        try await withSession(target) { session in
            let info = session.serverInfo
            #expect(info.engine == target.detectedEngine)
            #expect(session.engine == target.detectedEngine)
            #expect(info.major >= 8 || info.engine == .mariadb || info.engine == .postgresql)
            #expect(!info.versionString.isEmpty)
            switch target.detectedEngine {
            case .mysql: #expect(info.major == 8 && info.minor == 4)
            case .mariadb: #expect(info.major == 11 && info.minor == 4)
            case .postgresql: #expect(info.major == 16)
            }
            #expect(info.tlsActive == false)
            let current = try await session.currentDatabase()
            #expect(current == "querywell_test")
        }
    }

    @Test func mysqlConfigAgainstMariaDBDetectsMariaDB() async throws {
        let session = try await DBTarget.mariadb11.connect(engine: .mysql)
        #expect(session.serverInfo.engine == .mariadb)
        #expect(session.serverInfo.versionString.contains("MariaDB"))
        await session.close()
    }

    @Test(arguments: DBTarget.all)
    func listDatabases(target: DBTarget) async throws {
        try await withSession(target) { session in
            let dbs = try await session.listDatabases()
            #expect(dbs.contains("querywell_test"))
            if target.isPostgres {
                #expect(!dbs.contains("template0") && !dbs.contains("template1"))
            }
        }
    }

    // MARK: Writes

    @Test(arguments: DBTarget.all)
    func insertReportsRowsAffectedAndLastInsertID(target: DBTarget) async throws {
        let table = target.uniqueTable("ins")
        try await withSession(target, table: table) { session in
            let create = target.isPostgres
                ? "CREATE TABLE \(table) (id bigserial PRIMARY KEY, v text)"
                : "CREATE TABLE \(table) (id BIGINT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(20))"
            let created = try await session.execute(create)
            #expect(created.columns.isEmpty && created.rows.isEmpty)

            let ins = try await session.execute("INSERT INTO \(table) (v) VALUES ('a'), ('b'), ('c')")
            #expect(ins.rowsAffected == 3)
            #expect(ins.rows.isEmpty)
            if !target.isPostgres { #expect(ins.lastInsertID == 1) } else { #expect(ins.lastInsertID == nil) }

            let one = try await session.execute("INSERT INTO \(table) (v) VALUES ('d')")
            #expect(one.rowsAffected == 1)
            if !target.isPostgres { #expect(one.lastInsertID == 4) }

            let upd = try await session.execute("UPDATE \(table) SET v = 'z' WHERE id <= 2")
            #expect(upd.rowsAffected == 2)

            let del = try await session.execute("DELETE FROM \(table) WHERE id > 100")
            #expect(del.rowsAffected == 0)

            let sel = try await session.execute("SELECT count(*) AS n FROM \(table)")
            #expect(sel.rowsAffected == nil)
            #expect(sel.rows == [[.integer(4)]])
            #expect(sel.columns.map(\.name) == ["n"])
        }
    }

    // MARK: Value mapping

    @Test func mysqlFamilyValueMapping() async throws {
        for target in [DBTarget.mysql8, DBTarget.mariadb11] {
            let table = target.uniqueTable("vals")
            try await withSession(target, table: table) { session in
                _ = try await session.execute("""
                    CREATE TABLE \(table) (
                      id BIGINT AUTO_INCREMENT PRIMARY KEY,
                      c_null INT NULL, c_int INT, c_neg INT, c_ubig BIGINT UNSIGNED,
                      c_dec DECIMAL(20,6), c_dbl DOUBLE, c_dt DATETIME, c_ts TIMESTAMP NULL,
                      c_date DATE, c_json JSON, c_blob BLOB, c_text VARCHAR(100) CHARACTER SET utf8mb4,
                      c_flt FLOAT, c_tiny TINYINT UNSIGNED, c_time TIME, c_enum ENUM('a','b'))
                    """)
                _ = try await session.execute("""
                    INSERT INTO \(table) (c_null, c_int, c_neg, c_ubig, c_dec, c_dbl, c_dt, c_ts, c_date, c_json, c_blob, c_text, c_flt, c_tiny, c_time, c_enum)
                    VALUES (NULL, 42, -7, 18446744073709551615, 12345678901234.123400, 3.5,
                            '2024-03-05 06:07:08', '2024-03-05 06:07:08', '2024-03-05', '{"a": 1}',
                            X'DEADBEEF', '😀 héllo', 1.5, 200, '12:34:56', 'b')
                    """)
                let r = try await session.execute("SELECT * FROM \(table)")
                #expect(r.rows.count == 1)
                let row = r.rows[0]
                let byName = Dictionary(uniqueKeysWithValues: zip(r.columns.map(\.name), row))
                #expect(byName["id"] == .integer(1))
                #expect(byName["c_null"] == .null)
                #expect(byName["c_int"] == .integer(42))
                #expect(byName["c_neg"] == .integer(-7))
                #expect(byName["c_ubig"] == .unsignedInteger(UInt64.max))
                #expect(byName["c_dec"] == .text("12345678901234.123400"))
                #expect(byName["c_dbl"] == .double(3.5))
                #expect(byName["c_dt"] == .text("2024-03-05 06:07:08"))
                #expect(byName["c_ts"] == .text("2024-03-05 06:07:08"))
                #expect(byName["c_date"] == .text("2024-03-05"))
                #expect(byName["c_json"] == .text("{\"a\": 1}"))
                #expect(byName["c_blob"] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
                #expect(byName["c_text"] == .text("😀 héllo"))
                #expect(byName["c_flt"] == .double(1.5))
                #expect(byName["c_tiny"] == .unsignedInteger(200))
                #expect(byName["c_time"] == .text("12:34:56"))
                #expect(byName["c_enum"] == .text("b"))

                let types = Dictionary(uniqueKeysWithValues: r.columns.map { ($0.name, $0.typeName) })
                #expect(types["c_ubig"] == "bigint")
                #expect(types["c_dec"] == "decimal")
                #expect(types["c_blob"] == "blob")
                #expect(types["c_text"] == "varchar")
                #expect(types["c_enum"] == "enum")
                #expect(r.columns.first?.table == table)
                #expect(r.columns.first(where: { $0.name == "id" })?.isNullable == false)
                #expect(r.columns.first(where: { $0.name == "c_int" })?.isNullable == true)

                // Non-table statements
                let show = try await session.execute("SHOW VARIABLES LIKE 'version'")
                #expect(show.columns.count == 2 && show.rows.count == 1)
                let set = try await session.execute("SET @qw_x = 1")
                #expect(set.rowsAffected == 0)
            }
        }
    }

    @Test func postgresValueMapping() async throws {
        let target = DBTarget.postgres16
        let table = target.uniqueTable("vals")
        try await withSession(target, table: table) { session in
            _ = try await session.execute("SET TIME ZONE 'UTC'")
            _ = try await session.execute("""
                CREATE TABLE \(table) (
                  id bigserial PRIMARY KEY,
                  c_null int, c_int int4, c_neg int4, c_big int8, c_small int2,
                  c_dec numeric(20,6), c_dbl float8, c_flt float4, c_ts timestamp, c_tstz timestamptz,
                  c_date date, c_time time, c_json json, c_jsonb jsonb, c_bytea bytea, c_text text,
                  c_bool boolean, c_uuid uuid, c_arr int4[], c_tarr text[], c_interval interval,
                  c_inet inet, c_vc varchar(10), c_range int4range)
                """)
            let ins = try await session.execute("""
                INSERT INTO \(table) (c_null, c_int, c_neg, c_big, c_small, c_dec, c_dbl, c_flt, c_ts, c_tstz,
                  c_date, c_time, c_json, c_jsonb, c_bytea, c_text, c_bool, c_uuid, c_arr, c_tarr, c_interval, c_inet, c_vc, c_range)
                VALUES (NULL, 42, -7, 9223372036854775807, 12, 12345678901234.123400, 3.5, 1.5,
                  '2024-03-05 06:07:08.25', '2024-03-05 06:07:08+00', '2024-03-05', '12:34:56',
                  '{"a":  1}', '{"a":  1}', '\\xdeadbeef', '😀 héllo', true,
                  '123e4567-e89b-12d3-a456-426614174000', '{1,2,3}', ARRAY['a b', NULL, 'x'],
                  '1 year 2 months 3 days 04:05:06.789', '192.168.1.0/24', 'vc', '[1,5)')
                """)
            #expect(ins.rowsAffected == 1)

            let r = try await session.execute("SELECT * FROM \(table)")
            #expect(r.rows.count == 1)
            let byName = Dictionary(uniqueKeysWithValues: zip(r.columns.map(\.name), r.rows[0]))
            #expect(byName["id"] == .integer(1))
            #expect(byName["c_null"] == .null)
            #expect(byName["c_int"] == .integer(42))
            #expect(byName["c_neg"] == .integer(-7))
            #expect(byName["c_big"] == .integer(Int64.max))
            #expect(byName["c_small"] == .integer(12))
            #expect(byName["c_dec"] == .text("12345678901234.123400"))
            #expect(byName["c_dbl"] == .double(3.5))
            #expect(byName["c_flt"] == .double(1.5))
            #expect(byName["c_ts"] == .text("2024-03-05 06:07:08.25"))
            #expect(byName["c_tstz"] == .text("2024-03-05 06:07:08+00"))
            #expect(byName["c_date"] == .text("2024-03-05"))
            #expect(byName["c_time"] == .text("12:34:56"))
            #expect(byName["c_json"] == .text("{\"a\":  1}"))
            #expect(byName["c_jsonb"] == .text("{\"a\": 1}"))
            #expect(byName["c_bytea"] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
            #expect(byName["c_text"] == .text("😀 héllo"))
            #expect(byName["c_bool"] == .bool(true))
            #expect(byName["c_uuid"] == .text("123e4567-e89b-12d3-a456-426614174000"))
            #expect(byName["c_arr"] == .text("{1,2,3}"))
            #expect(byName["c_tarr"] == .text("{\"a b\",NULL,x}"))
            #expect(byName["c_interval"] == .text("1 year 2 mons 3 days 04:05:06.789"))
            #expect(byName["c_inet"] == .text("192.168.1.0/24"))
            #expect(byName["c_vc"] == .text("vc"))
            #expect(byName["c_range"] == .text("[1,5)"))

            let types = Dictionary(uniqueKeysWithValues: r.columns.map { ($0.name, $0.typeName) })
            #expect(types["c_big"] == "int8")
            #expect(types["c_jsonb"] == "jsonb")
            #expect(types["c_arr"] == "_int4")
            #expect(types["c_tstz"] == "timestamptz")

            // Postgres' own text rendering must agree with ours, for every column.
            let asText = try await session.execute("""
                SELECT c_dec::text, c_ts::text, c_tstz::text, c_date::text, c_time::text, c_jsonb::text,
                       c_uuid::text, c_arr::text, c_tarr::text, c_interval::text, c_inet::text, c_range::text FROM \(table)
                """)
            let ours: [DatabaseValue] = ["c_dec", "c_ts", "c_tstz", "c_date", "c_time", "c_jsonb", "c_uuid", "c_arr", "c_tarr", "c_interval", "c_inet", "c_range"]
                .map { byName[$0] ?? .null }
            #expect(asText.rows[0] == ours)

            // Time zone handling follows the session setting at query time.
            _ = try await session.execute("SET TIME ZONE 'America/New_York'")
            let ny = try await session.execute("SELECT c_tstz, c_tstz::text FROM \(table)")
            #expect(ny.rows[0][0] == ny.rows[0][1])
            #expect(ny.rows[0][0] == .text("2024-03-05 01:07:08-05"))
        }
    }

    @Test func postgresEnumsAndCustomArrays() async throws {
        let target = DBTarget.postgres16
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let enumName = "qw_mood_\(suffix)"
        try await withSession(target) { session in
            _ = try await session.execute("CREATE TYPE \(enumName) AS ENUM ('sad', 'happy')")
            defer { Task { _ = try? await session.execute("DROP TYPE IF EXISTS \(enumName)") } }
            let r = try await session.execute("SELECT 'happy'::\(enumName) AS m, ARRAY['sad','happy']::\(enumName)[] AS ms")
            #expect(r.rows == [[.text("happy"), .text("{sad,happy}")]])
            #expect(r.columns.map(\.typeName) == [enumName, "_\(enumName)"])
            _ = try await session.execute("DROP TYPE \(enumName)")
        }
    }

    // MARK: Result shape

    @Test(arguments: DBTarget.all)
    func zeroRowSelectStillHasColumns(target: DBTarget) async throws {
        let table = target.uniqueTable("zero")
        try await withSession(target, table: table) { session in
            let create = target.isPostgres
                ? "CREATE TABLE \(table) (id int PRIMARY KEY, name text, born date)"
                : "CREATE TABLE \(table) (id INT PRIMARY KEY, name VARCHAR(50), born DATE)"
            _ = try await session.execute(create)
            let r = try await session.execute("SELECT id, name, born FROM \(table) WHERE 1 = 0;")
            #expect(r.rows.isEmpty)
            #expect(r.columns.map(\.name) == ["id", "name", "born"])
            if target.isPostgres {
                #expect(r.columns.map(\.typeName) == ["int4", "text", "date"])
            } else {
                #expect(r.columns.map(\.typeName) == ["int", "varchar", "date"])
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func literalSelectAndNullHandling(target: DBTarget) async throws {
        try await withSession(target) { session in
            let r = try await session.execute("SELECT 1 AS one, NULL AS nothing, 'x' AS s")
            #expect(r.columns.map(\.name) == ["one", "nothing", "s"])
            #expect(r.rows.count == 1)
            #expect(r.rows[0][0] == .integer(1))
            #expect(r.rows[0][1] == .null)
            #expect(r.rows[0][2] == .text("x"))
            #expect(r.duration >= .zero)
        }
    }

    // MARK: Errors

    @Test(arguments: DBTarget.all)
    func syntaxErrorMapsToQueryError(target: DBTarget) async throws {
        try await withSession(target) { session in
            do {
                _ = try await session.execute("SELEC 1")
                Issue.record("expected an error")
            } catch let DatabaseError.query(message, code) {
                #expect(!message.isEmpty)
                #expect(!message.contains("PSQLError("))
                if target.isPostgres { #expect(code == "42601") } else { #expect(code == "1064") }
            }
            // The session survives a failed statement.
            let ok = try await session.execute("SELECT 1")
            #expect(ok.rows == [[.integer(1)]])
        }
    }

    @Test(arguments: DBTarget.all)
    func missingTableErrorCode(target: DBTarget) async throws {
        try await withSession(target) { session in
            do {
                _ = try await session.execute("SELECT * FROM qw_does_not_exist")
                Issue.record("expected an error")
            } catch let DatabaseError.query(_, code) {
                if target.isPostgres { #expect(code == "42P01") } else { #expect(code == "1146") }
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func wrongPasswordIsAuthenticationFailed(target: DBTarget) async throws {
        let cfg = target.config(password: "definitely-wrong")
        do {
            _ = try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
            Issue.record("expected authentication failure")
        } catch DatabaseError.authenticationFailed(let message) {
            #expect(!message.isEmpty)
        }
    }

    @Test(arguments: DBTarget.all)
    func closedPortIsConnectionFailedQuickly(target: DBTarget) async throws {
        let cfg = target.config(port: 1)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
            Issue.record("expected connection failure")
        } catch DatabaseError.connectionFailed(let message) {
            #expect(!message.isEmpty)
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test(arguments: DBTarget.all)
    func unresolvableHostIsConnectionFailed(target: DBTarget) async throws {
        var cfg = target.config()
        cfg.host = "no-such-host.invalid"
        do {
            _ = try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
            Issue.record("expected connection failure")
        } catch DatabaseError.connectionFailed {
        } catch DatabaseError.timeout {
            // Acceptable on resolvers that black-hole .invalid names.
        }
    }

    @Test(arguments: DBTarget.all)
    func connectTimeoutIsHonoured(target: DBTarget) async throws {
        // 10.255.255.1 is non-routable: SYNs go unanswered (or the network rejects them immediately).
        var cfg = target.config(timeout: .milliseconds(500))
        cfg.host = "10.255.255.1"
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
            Issue.record("expected failure")
        } catch DatabaseError.timeout {
        } catch DatabaseError.connectionFailed {
            // Networks that reject immediately ("no route to host") are fine too.
        }
        #expect(clock.now - start < .seconds(5))
    }

    // MARK: Lifecycle

    @Test(arguments: DBTarget.all)
    func closeThenExecuteThrowsSessionClosed(target: DBTarget) async throws {
        let session = try await target.connect()
        let ok = try await session.execute("SELECT 1")
        #expect(ok.rows.count == 1)
        await session.close()
        await session.close() // idempotent
        await #expect(throws: DatabaseError.sessionClosed) { try await session.execute("SELECT 1") }
        await #expect(throws: DatabaseError.sessionClosed) { try await session.listDatabases() }
        await #expect(throws: DatabaseError.sessionClosed) { try await session.currentDatabase() }
    }

    @Test(arguments: DBTarget.all)
    func concurrentStatementsAreSerialized(target: DBTarget) async throws {
        try await withSession(target) { session in
            let results = try await withThrowingTaskGroup(of: (Int, QueryResult).self) { group in
                for i in 0..<20 {
                    group.addTask { (i, try await session.execute("SELECT \(i) AS n")) }
                }
                var out: [Int: QueryResult] = [:]
                for try await (i, r) in group { out[i] = r }
                return out
            }
            for i in 0..<20 {
                #expect(results[i]?.rows == [[.integer(Int64(i))]])
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func largeResultSet(target: DBTarget) async throws {
        try await withSession(target) { session in
            if target.detectedEngine == .mysql { _ = try await session.execute("SET SESSION cte_max_recursion_depth = 10000") }
            if target.detectedEngine == .mariadb { _ = try await session.execute("SET SESSION max_recursive_iterations = 10000") }
            let sql = target.isPostgres
                ? "SELECT g AS n, repeat('x', 100) AS pad FROM generate_series(1, 5000) g"
                : "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 5000) SELECT n, REPEAT('x', 100) AS pad FROM s"
            let r = try await session.execute(sql)
            #expect(r.rows.count == 5000)
            #expect(r.rows.last?.first == .integer(5000))
        }
    }

    // MARK: TLS

    @Test(arguments: DBTarget.tlsCapable)
    func requiredTLSIsActive(target: DBTarget) async throws {
        let session = try await target.connect(tls: TLSConfig(mode: .required))
        #expect(session.serverInfo.tlsActive == true)
        let r = try await session.execute("SELECT 1")
        #expect(r.rows == [[.integer(1)]])
        await session.close()
    }

    @Test(arguments: DBTarget.all)
    func disabledTLSIsNotActive(target: DBTarget) async throws {
        let session = try await target.connect(tls: TLSConfig(mode: .disabled))
        #expect(session.serverInfo.tlsActive == false)
        await session.close()
    }

    @Test(arguments: DBTarget.all)
    func preferredTLSConnects(target: DBTarget) async throws {
        let session = try await target.connect(tls: TLSConfig(mode: .preferred))
        let r = try await session.execute("SELECT 1")
        #expect(r.rows == [[.integer(1)]])
        if target.hasTLS { #expect(session.serverInfo.tlsActive == true) }
        await session.close()
    }

    @Test(arguments: DBTarget.tlsCapable)
    func verifyingASelfSignedCertificateFails(target: DBTarget) async throws {
        do {
            let session = try await target.connect(tls: TLSConfig(mode: .verifyIdentity))
            await session.close()
            Issue.record("expected TLS failure")
        } catch DatabaseError.tlsFailed(let message) {
            #expect(!message.isEmpty)
        }
    }

    @Test func requiredTLSAgainstServerWithoutTLSFails() async throws {
        // MariaDB's image in this setup has no usable certificate; Postgres/MySQL tests cover success.
        let target = DBTarget.mariadb11
        do {
            let session = try await target.connect(tls: TLSConfig(mode: .required))
            // If this MariaDB build does enable TLS, the connection must at least report it truthfully.
            #expect(session.serverInfo.tlsActive == true)
            await session.close()
        } catch DatabaseError.tlsFailed {
        }
    }
}
