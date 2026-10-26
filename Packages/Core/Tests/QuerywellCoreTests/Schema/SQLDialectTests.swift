import Foundation
import Testing

@testable import QuerywellCore

private let mysql = SQLDialect(.mysql)
private let maria = SQLDialect(.mariadb)
private let pg = SQLDialect(.postgresql)

/// Strings that have broken hand-rolled escaping before.
private let nastyStrings: [String] = [
    "plain",
    "'",
    "\\",
    "\\'",
    "''",
    "\\\\'",
    "%_",
    "50% off_sale",
    "line1\nline2\r\nline3\ttab",
    "emoji 😀👨‍👩‍👧 café 日本語",
    "ctrl-z \u{1A} end",
    "quote\" backtick` semi; -- comment /* x */",
    "'; DROP TABLE x; --",
    "E'\\x41'",
    "trailing backslash\\",
    String(repeating: "ab'\\", count: 5000),
    " leading and trailing  ",
]

@Suite("SQLDialect")
struct SQLDialectTests {
    // MARK: identifiers

    @Test func familiesMatchEngines() {
        #expect(mysql.family == .mysql)
        #expect(maria.family == .mysql)
        #expect(pg.family == .postgres)
        #expect(mysql == maria)
    }

    @Test func quoteIdentifier() {
        #expect(mysql.quoteIdentifier("wp_posts") == "`wp_posts`")
        #expect(mysql.quoteIdentifier("a`b") == "`a``b`")
        #expect(mysql.quoteIdentifier("``") == "``````")
        #expect(mysql.quoteIdentifier("a\"b") == "`a\"b`")
        #expect(mysql.quoteIdentifier("") == "``")
        #expect(pg.quoteIdentifier("Wp Posts") == "\"Wp Posts\"")
        #expect(pg.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(pg.quoteIdentifier("a`b") == "\"a`b\"")
        #expect(pg.quoteIdentifier("emoji😀") == "\"emoji😀\"")
        #expect(mysql.qualified(TableRef(schema: "my`db", name: "t")) == "`my``db`.`t`")
        #expect(pg.qualified(TableRef(schema: "public", name: "Order")) == "\"public\".\"Order\"")
    }

    // MARK: strings

    @Test func mysqlStrings() {
        #expect(mysql.quoteString("abc") == "'abc'")
        #expect(mysql.quoteString("it's") == "'it\\'s'")
        #expect(mysql.quoteString("a\\b") == "'a\\\\b'")
        #expect(mysql.quoteString("\\'") == "'\\\\\\''")
        #expect(mysql.quoteString("''") == "'\\'\\''")
        #expect(mysql.quoteString("a\nb\rc") == "'a\\nb\\rc'")
        #expect(mysql.quoteString("x\u{1A}y") == "'x\\Zy'")
        #expect(mysql.quoteString("😀 日本") == "'😀 日本'")
        #expect(mysql.quoteString("") == "''")
        #expect(mysql.quoteString("%_") == "'%_'")
    }

    @Test func postgresStrings() {
        #expect(pg.quoteString("abc") == "'abc'")
        #expect(pg.quoteString("it's") == "'it''s'")
        #expect(pg.quoteString("a\\b") == "E'a\\\\b'")
        #expect(pg.quoteString("\\'") == "E'\\\\'''")
        #expect(pg.quoteString("''") == "''''''")
        #expect(pg.quoteString("a\nb") == "'a\nb'")
        #expect(pg.quoteString("😀") == "'😀'")
        #expect(pg.quoteString("") == "''")
        // Only strings containing a backslash use the E prefix.
        #expect(!pg.quoteString("plain 'quoted'").hasPrefix("E"))
        #expect(pg.quoteString("\\").hasPrefix("E'"))
    }

    // MARK: literal() for every DatabaseValue case

    @Test func literalsForEveryCase() {
        for d in [mysql, pg] {
            #expect(d.literal(.null) == "NULL")
            #expect(d.literal(.integer(0)) == "0")
            #expect(d.literal(.integer(-42)) == "-42")
            #expect(d.literal(.integer(Int64.min)) == "-9223372036854775808")
            #expect(d.literal(.unsignedInteger(UInt64.max)) == "18446744073709551615")
            #expect(d.literal(.double(1.5)) == "1.5")
            #expect(d.literal(.double(-0.25)) == "-0.25")
            #expect(d.literal(.text("o'k")) == d.quoteString("o'k"))
        }
        #expect(mysql.literal(.bool(true)) == "1")
        #expect(mysql.literal(.bool(false)) == "0")
        #expect(pg.literal(.bool(true)) == "TRUE")
        #expect(pg.literal(.bool(false)) == "FALSE")
        // Non-finite doubles can only be expressed as text.
        #expect(pg.literal(.double(.nan)) == "'nan'")
        #expect(pg.literal(.double(.infinity)) == "'inf'")
        #expect(pg.literal(.double(-.infinity)) == "'-inf'")
        #expect(mysql.literal(.bytes(Data([0x00, 0xFF, 0x10]))) == "0x00FF10")
        #expect(mysql.literal(.bytes(Data())) == "''")
        #expect(pg.literal(.bytes(Data([0x00, 0xFF, 0x10]))) == "'\\x00ff10'::bytea")
        #expect(pg.literal(.bytes(Data())) == "'\\x'::bytea")
    }

    @Test func unicodeAndEmojiPassThroughUntouched() {
        let s = "café 😀 日本語 👨‍👩‍👧"
        #expect(mysql.quoteString(s) == "'\(s)'")
        #expect(pg.quoteString(s) == "'\(s)'")
        #expect(mysql.quoteIdentifier(s) == "`\(s)`")
    }

    @Test func limitAndLikeHelpers() {
        #expect(mysql.limitClause(limit: 50, offset: 0) == " LIMIT 50")
        #expect(pg.limitClause(limit: 50, offset: 100) == " LIMIT 50 OFFSET 100")
        #expect(mysql.escapeLikePattern("50%_\\") == "50\\%\\_\\\\")
    }

    // MARK: sql_mode helper

    @Test func noBackslashEscapesIsStripped() {
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES") == "ANSI_QUOTES")
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "ANSI_QUOTES") == nil)
    }
}

// MARK: - Integration

private func scalar(_ session: any DatabaseSession, _ sql: String) async throws -> DatabaseValue {
    let result = try await session.execute(sql)
    return try #require(result.rows.first?.first)
}

private func expectRoundTrip(_ session: any DatabaseSession, _ strings: [String]) async throws {
    let dialect = SQLDialect(session.engine)
    for s in strings {
        let value = try await scalar(session, "SELECT \(dialect.literal(.text(s)))")
        #expect(value == .text(s), "round trip failed for \(s.prefix(40).debugDescription) on \(session.serverInfo.shortDescription)")
    }
}

@Suite("SQLDialect integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct SQLDialectIntegrationTests {
    @Test(arguments: DBTarget.all)
    func nastyStringsRoundTrip(target: DBTarget) async throws {
        let session = try await target.connect()
        defer { Task { await session.close() } }
        try await expectRoundTrip(session, nastyStrings)
    }

    @Test(arguments: DBTarget.all)
    func stringsRoundTripThroughTableStorage(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let t = "\(f.q).\(f.dialect.quoteIdentifier("rt"))"
            let textType = target.isPostgres ? "text" : "longtext"
            try await f.run("CREATE TABLE \(t) (id int PRIMARY KEY, v \(textType))")
            for (i, s) in nastyStrings.enumerated() {
                try await f.run("INSERT INTO \(t) VALUES (\(i), \(f.dialect.literal(.text(s))))")
            }
            let result = try await f.session.execute("SELECT v FROM \(t) ORDER BY id")
            #expect(result.rows.map { $0[0] } == nastyStrings.map { .text($0) })
            // And matching on the literal finds exactly its own row.
            for (i, s) in nastyStrings.enumerated() where s.count < 100 {
                let found = try await f.session.execute("SELECT id FROM \(t) WHERE v = \(f.dialect.literal(.text(s)))")
                #expect(found.rows.contains([.integer(Int64(i))]))
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func bytesRoundTrip(target: DBTarget) async throws {
        let session = try await target.connect()
        defer { Task { await session.close() } }
        let dialect = SQLDialect(session.engine)
        let samples: [Data] = [
            Data([0x00]), Data([0xFF, 0x00, 0x27, 0x5C, 0x1A]), Data("it's \\ ok 😀".utf8),
            Data((0...255).map { UInt8($0) }), Data(repeating: 0xAB, count: 70_000),
        ]
        for d in samples {
            let value = try await scalar(session, "SELECT \(dialect.literal(.bytes(d)))")
            #expect(value == .bytes(d), "bytes of length \(d.count)")
        }
    }

    @Test(arguments: DBTarget.all)
    func numbersBoolsAndNullRoundTrip(target: DBTarget) async throws {
        let session = try await target.connect()
        defer { Task { await session.close() } }
        let dialect = SQLDialect(session.engine)
        #expect(try await scalar(session, "SELECT \(dialect.literal(.null))") == .null)
        #expect(try await scalar(session, "SELECT \(dialect.literal(.integer(-42)))") == .integer(-42))
        #expect(try await scalar(session, "SELECT \(dialect.literal(.integer(Int64.min)))") == .integer(Int64.min))
        if target.isPostgres {
            #expect(try await scalar(session, "SELECT \(dialect.literal(.bool(true)))") == .bool(true))
            #expect(try await scalar(session, "SELECT \(dialect.literal(.bool(false)))") == .bool(false))
            let nan = try await scalar(session, "SELECT \(dialect.literal(.double(.nan)))::float8")
            if case .double(let d) = nan { #expect(d.isNaN) } else { #expect(Bool(false), "expected double NaN, got \(nan)") }
        } else {
            #expect(try await scalar(session, "SELECT \(dialect.literal(.bool(true)))") == .integer(1))
            #expect(try await scalar(session, "SELECT \(dialect.literal(.unsignedInteger(UInt64.max)))") == .unsignedInteger(UInt64.max))
        }
    }

    // MARK: sql_mode

    private struct RootAccess {
        let session: any DatabaseSession

        static func connect(_ target: DBTarget) async throws -> RootAccess {
            RootAccess(session: try await target.connectPrivileged())
        }

        func globalMode() async throws -> String {
            let v = try await scalar(session, "SELECT @@GLOBAL.sql_mode")
            return Record.string(from: v) ?? ""
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func sessionDropsNoBackslashEscapes(target: DBTarget) async throws {
        let root = try await RootAccess.connect(target)
        let original = try await root.globalMode()
        let withFlag = original.isEmpty ? "NO_BACKSLASH_ESCAPES" : original + ",NO_BACKSLASH_ESCAPES"
        _ = try await root.session.execute("SET GLOBAL sql_mode = '\(withFlag)'")
        do {
            let flagged = try await root.globalMode()
            #expect(flagged.contains("NO_BACKSLASH_ESCAPES"))

            // New sessions inherit the GLOBAL mode and must strip the flag.
            let session = try await target.connect()
            let mode = Record.string(from: try await scalar(session, "SELECT @@SESSION.sql_mode")) ?? ""
            #expect(!mode.contains("NO_BACKSLASH_ESCAPES"))
            // Everything else the server had set is preserved, in order.
            #expect(mode == original)
            try await expectRoundTrip(session, nastyStrings)
            await session.close()
        } catch {
            _ = try? await root.session.execute("SET GLOBAL sql_mode = \(SQLDialect(.mysql).quoteString(original))")
            await root.session.close()
            throw error
        }
        _ = try? await root.session.execute("SET GLOBAL sql_mode = \(SQLDialect(.mysql).quoteString(original))")
        let restored = try await root.globalMode()
        #expect(restored == original)
        await root.session.close()
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func sessionKeepsUnrelatedModesUntouched(target: DBTarget) async throws {
        let session = try await target.connect()
        let mode = Record.string(from: try await scalar(session, "SELECT @@SESSION.sql_mode")) ?? ""
        #expect(mode.contains("STRICT_TRANS_TABLES"))
        await session.close()
    }
}
