import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import QuerywellCore

@Suite("Driver unit tests")
struct DriverUnitTests {
    // MARK: Version parsing

    @Test func mysqlVersion() {
        let v = ServerVersion.parseMySQL("8.4.3")
        #expect(v == .init(engine: .mysql, major: 8, minor: 4, patch: 3))
    }

    @Test func mariadbVersionWithSuffix() {
        let v = ServerVersion.parseMySQL("11.4.2-MariaDB-ubu2404")
        #expect(v == .init(engine: .mariadb, major: 11, minor: 4, patch: 2))
    }

    @Test func mariadbReplicationPrefix() {
        let v = ServerVersion.parseMySQL("5.5.5-10.11.6-MariaDB")
        #expect(v == .init(engine: .mariadb, major: 10, minor: 11, patch: 6))
    }

    @Test func mysqlVendorSuffixIsNotMariaDB() {
        let v = ServerVersion.parseMySQL("8.0.36-28.1-log")
        #expect(v == .init(engine: .mysql, major: 8, minor: 0, patch: 36))
    }

    @Test func postgresVersions() {
        #expect(ServerVersion.parsePostgres("16.4 (Debian 16.4-1.pgdg120+2)") == .init(engine: .postgresql, major: 16, minor: 4, patch: 0))
        #expect(ServerVersion.parsePostgres("9.6.24") == .init(engine: .postgresql, major: 9, minor: 6, patch: 24))
        #expect(ServerVersion.parsePostgres("17beta1") == .init(engine: .postgresql, major: 17, minor: 0, patch: 0))
        #expect(ServerVersion.parsePostgres("") == .init(engine: .postgresql, major: 0, minor: 0, patch: 0))
    }

    // MARK: Command tags

    @Test func commandTags() {
        #expect(PostgresCommandTag.parse("INSERT 0 3").rowsAffected == 3)
        #expect(PostgresCommandTag.parse("UPDATE 2").rowsAffected == 2)
        #expect(PostgresCommandTag.parse("DELETE 0").rowsAffected == 0)
        #expect(PostgresCommandTag.parse("MERGE 7").rowsAffected == 7)
        #expect(PostgresCommandTag.parse("COPY 10").rowsAffected == 10)
        #expect(PostgresCommandTag.parse("SELECT 5").rowsAffected == nil)
        #expect(PostgresCommandTag.parse("SELECT 5") == PostgresCommandTag(command: "SELECT", rows: 5))
        #expect(PostgresCommandTag.parse("CREATE TABLE") == PostgresCommandTag(command: "CREATE TABLE", rows: nil))
        #expect(PostgresCommandTag.parse("BEGIN").rowsAffected == nil)
        #expect(PostgresCommandTag.parse("").command == "")
    }

    // MARK: TLS

    @Test func tlsPlans() {
        #expect(TLSSupport.plan(for: .disabled) == .init(enabled: false, enforced: false, verification: .none))
        #expect(TLSSupport.plan(for: .preferred) == .init(enabled: true, enforced: false, verification: .none))
        #expect(TLSSupport.plan(for: .required) == .init(enabled: true, enforced: true, verification: .none))
        #expect(TLSSupport.plan(for: .verifyCA) == .init(enabled: true, enforced: true, verification: .chainOnly))
        #expect(TLSSupport.plan(for: .verifyIdentity) == .init(enabled: true, enforced: true, verification: .full))
    }

    @Test func tlsConfigurationMapping() throws {
        #expect(try TLSSupport.clientConfiguration(for: TLSConfig(mode: .disabled)) == nil)
        #expect(try TLSSupport.clientConfiguration(for: TLSConfig(mode: .preferred))?.certificateVerification == CertificateVerification.none)
        #expect(try TLSSupport.clientConfiguration(for: TLSConfig(mode: .required))?.certificateVerification == CertificateVerification.none)
        #expect(try TLSSupport.clientConfiguration(for: TLSConfig(mode: .verifyCA))?.certificateVerification == .noHostnameVerification)
        #expect(try TLSSupport.clientConfiguration(for: TLSConfig(mode: .verifyIdentity))?.certificateVerification == .fullVerification)
    }

    @Test func missingCAFileIsTLSError() {
        let config = TLSConfig(mode: .verifyCA, caCertificatePath: "/nonexistent/ca.pem")
        #expect {
            try TLSSupport.clientConfiguration(for: config)
        } throws: { error in
            if case DatabaseError.tlsFailed = error { return true }
            return false
        }
    }

    // MARK: Error mapping

    @Test func mysqlErrorMapping() {
        #expect(MySQLErrorMapping.map(errno: 1045, message: "denied", connecting: true) == .authenticationFailed("denied"))
        #expect(MySQLErrorMapping.map(errno: 1064, message: "syntax", connecting: false) == .query(message: "syntax", code: "1064"))
        #expect(MySQLErrorMapping.map(errno: 1062, message: "dup", connecting: false) == .query(message: "dup", code: "1062"))
        #expect(MySQLErrorMapping.map(errno: 1049, message: "unknown db", connecting: true) == .connectionFailed("unknown db"))
    }

    @Test func postgresErrorMapping() {
        #expect(PostgresErrorMapping.map(sqlState: "28P01", message: "bad pw", connecting: true) == .authenticationFailed("bad pw"))
        #expect(PostgresErrorMapping.map(sqlState: "28000", message: "no hba", connecting: true) == .authenticationFailed("no hba"))
        #expect(PostgresErrorMapping.map(sqlState: "42601", message: "syntax", connecting: false) == .query(message: "syntax", code: "42601"))
        #expect(PostgresErrorMapping.map(sqlState: "3D000", message: "no db", connecting: true) == .connectionFailed("no db"))
    }

    @Test func transportErrorMapping() {
        let timeout = DriverSupport.mapTransportError(ChannelError.connectTimeout(.seconds(1)), host: "h", port: 1)
        #expect(timeout == .timeout)
        let closed = DriverSupport.mapTransportError(ChannelError.ioOnClosedChannel, host: "h", port: 1)
        if case .connectionFailed = closed {} else { Issue.record("expected connectionFailed, got \(closed)") }
        let refused = DriverSupport.mapTransportError(IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "h", port: 1)
        if case .connectionFailed(let m) = refused { #expect(m.contains("h:1")) } else { Issue.record("got \(refused)") }
        let tls = DriverSupport.mapTransportError(NIOSSLError.handshakeFailed(.sslError([])), host: "h", port: 1)
        if case .tlsFailed = tls {} else { Issue.record("expected tlsFailed, got \(tls)") }
    }

    @Test func durationToNanoseconds() {
        #expect(DriverSupport.nanoseconds(.seconds(2)) == 2_000_000_000)
        #expect(DriverSupport.nanoseconds(.milliseconds(1500)) == 1_500_000_000)
    }

    // MARK: DatabaseValue

    @Test func displayStrings() {
        #expect(DatabaseValue.null.displayString == "NULL")
        #expect(DatabaseValue.integer(-5).displayString == "-5")
        #expect(DatabaseValue.unsignedInteger(UInt64.max).displayString == "18446744073709551615")
        #expect(DatabaseValue.double(3.5).displayString == "3.5")
        #expect(DatabaseValue.bool(true).displayString == "true")
        #expect(DatabaseValue.text("héllo").displayString == "héllo")
        #expect(DatabaseValue.bytes(Data([0xDE, 0xAD])).displayString == "0xDEAD")
        let long = DatabaseValue.bytes(Data(repeating: 0xAB, count: 40)).displayString
        #expect(long.hasPrefix("0xABAB") && long.hasSuffix("… (40 bytes)"))
    }

    // MARK: MySQL value mapping

    private func cell(_ s: String) -> ByteBuffer { ByteBuffer(string: s) }

    @Test func mysqlValueMapping() {
        func v(_ s: String?, _ type: UInt8, flags: UInt16 = 0, charset: UInt8 = 45) -> DatabaseValue {
            MySQLValueMapping.value(s.map(cell), column: MySQLColumnMeta(name: "c", typeCode: type, flags: flags, charset: charset))
        }
        let c = MySQLColumnMeta.Code.self
        #expect(v(nil, c.long) == .null)
        #expect(v("-7", c.long, charset: 63) == .integer(-7))
        #expect(v("18446744073709551615", c.longlong, flags: MySQLColumnMeta.unsignedFlag, charset: 63) == .unsignedInteger(UInt64.max))
        #expect(v("200", c.tiny, flags: MySQLColumnMeta.unsignedFlag, charset: 63) == .unsignedInteger(200))
        #expect(v("3.5", c.double, charset: 63) == .double(3.5))
        #expect(v("12345678901234.123400", c.newdecimal, charset: 63) == .text("12345678901234.123400"))
        #expect(v("2024-03-05 06:07:08", c.datetime, charset: 63) == .text("2024-03-05 06:07:08"))
        #expect(v("2024", c.year, charset: 63) == .text("2024"))
        #expect(v("{\"a\": 1}", c.json) == .text("{\"a\": 1}"))
        #expect(v("hello", c.varString) == .text("hello"))
        #expect(v("hello", c.varString, charset: 63) == .bytes(Data("hello".utf8)))
        #expect(v("text body", c.blob) == .text("text body"))
        #expect(v("bin", c.blob, charset: 63) == .bytes(Data("bin".utf8)))
        #expect(v("a", c.string, flags: MySQLColumnMeta.enumFlag) == .text("a"))
        #expect(v("😀", c.varString) == .text("😀"))
    }

    @Test func mysqlInvalidUTF8FallsBackToBytes() {
        let bad = ByteBuffer(bytes: [0xFF, 0xFE, 0x41])
        let value = MySQLValueMapping.value(bad, column: MySQLColumnMeta(name: "c", typeCode: MySQLColumnMeta.Code.varString))
        #expect(value == .bytes(Data([0xFF, 0xFE, 0x41])))
    }

    @Test func mysqlTypeNames() {
        let c = MySQLColumnMeta.Code.self
        #expect(MySQLColumnMeta(name: "a", typeCode: c.longlong).typeName == "bigint")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.blob, charset: 63).typeName == "blob")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.blob).typeName == "text")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.varString).typeName == "varchar")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.varString, charset: 63).typeName == "varbinary")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.string, flags: MySQLColumnMeta.setFlag).typeName == "set")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.newdecimal).typeName == "decimal")
        #expect(MySQLColumnMeta(name: "a", typeCode: c.long, flags: MySQLColumnMeta.notNullFlag).info.isNullable == false)
    }

    // MARK: Postgres decoding

    private func buf(_ build: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var b = ByteBuffer()
        build(&b)
        return b
    }

    private typealias OID = PostgresValueDecoder.OID

    @Test func pgScalars() {
        let d = PostgresValueDecoder()
        #expect(d.value(buf { $0.writeInteger(Int16(-3)) }, oid: OID.int2) == .integer(-3))
        #expect(d.value(buf { $0.writeInteger(Int32(7)) }, oid: OID.int4) == .integer(7))
        #expect(d.value(buf { $0.writeInteger(Int64.max) }, oid: OID.int8) == .integer(Int64.max))
        #expect(d.value(buf { $0.writeInteger(UInt64(3.5.bitPattern)) }, oid: OID.float8) == .double(3.5))
        #expect(d.value(buf { $0.writeInteger(Float(1.5).bitPattern) }, oid: OID.float4) == .double(1.5))
        #expect(d.value(buf { $0.writeInteger(UInt8(1)) }, oid: OID.bool) == .bool(true))
        #expect(d.value(buf { $0.writeBytes([1, 2, 3]) }, oid: OID.bytea) == .bytes(Data([1, 2, 3])))
        #expect(d.value(buf { $0.writeString("héllo 😀") }, oid: OID.text) == .text("héllo 😀"))
        #expect(d.value(nil, oid: OID.int4) == .null)
        #expect(d.value(buf { $0.writeInteger(UInt8(1)); $0.writeString("{\"a\": 1}") }, oid: OID.jsonb) == .text("{\"a\": 1}"))
        #expect(PostgresValueDecoder.floatText(5.0, isFloat4: false, float: 0) == "5")
        #expect(PostgresValueDecoder.floatText(.nan, isFloat4: false, float: 0) == "NaN")
        #expect(PostgresValueDecoder.floatText(-.infinity, isFloat4: false, float: 0) == "-Infinity")
    }

    private func numeric(digits: [Int16], weight: Int16, sign: UInt16, dscale: Int16) -> ByteBuffer {
        buf {
            $0.writeInteger(Int16(digits.count))
            $0.writeInteger(weight)
            $0.writeInteger(sign)
            $0.writeInteger(dscale)
            for digit in digits { $0.writeInteger(digit) }
        }
    }

    @Test func pgNumeric() {
        let d = PostgresValueDecoder()
        #expect(d.value(numeric(digits: [12, 3456, 7890, 1234, 1234], weight: 3, sign: 0, dscale: 6), oid: OID.numeric) == .text("12345678901234.123400"))
        #expect(d.value(numeric(digits: [1], weight: -1, sign: 0, dscale: 4), oid: OID.numeric) == .text("0.0001"))
        #expect(d.value(numeric(digits: [1000], weight: -2, sign: 0, dscale: 5), oid: OID.numeric) == .text("0.00001"))
        #expect(d.value(numeric(digits: [1, 5000], weight: 0, sign: 0x4000, dscale: 1), oid: OID.numeric) == .text("-1.5"))
        #expect(d.value(numeric(digits: [], weight: 0, sign: 0, dscale: 2), oid: OID.numeric) == .text("0.00"))
        #expect(d.value(numeric(digits: [1, 0], weight: 1, sign: 0, dscale: 0), oid: OID.numeric) == .text("10000"))
        #expect(d.value(numeric(digits: [], weight: 0, sign: 0xC000, dscale: 0), oid: OID.numeric) == .text("NaN"))
    }

    @Test func pgDatesAndTimes() {
        let d = PostgresValueDecoder()
        #expect(d.value(buf { $0.writeInteger(Int32(8830)) }, oid: OID.date) == .text("2024-03-05"))
        #expect(d.value(buf { $0.writeInteger(Int32(0)) }, oid: OID.date) == .text("2000-01-01"))
        #expect(d.value(buf { $0.writeInteger(Int32(-1)) }, oid: OID.date) == .text("1999-12-31"))
        #expect(d.value(buf { $0.writeInteger(Int32.max) }, oid: OID.date) == .text("infinity"))

        let micros: Int64 = 8830 * 86_400_000_000 + 22_028_000_000
        #expect(d.value(buf { $0.writeInteger(micros) }, oid: OID.timestamp) == .text("2024-03-05 06:07:08"))
        #expect(d.value(buf { $0.writeInteger(micros + 123_456) }, oid: OID.timestamp) == .text("2024-03-05 06:07:08.123456"))
        #expect(d.value(buf { $0.writeInteger(micros + 500_000) }, oid: OID.timestamp) == .text("2024-03-05 06:07:08.5"))
        #expect(d.value(buf { $0.writeInteger(Int64.min) }, oid: OID.timestamp) == .text("-infinity"))
        #expect(d.value(buf { $0.writeInteger(Int64(-1_000_000)) }, oid: OID.timestamp) == .text("1999-12-31 23:59:59"))

        #expect(d.value(buf { $0.writeInteger(micros) }, oid: OID.timestamptz) == .text("2024-03-05 06:07:08+00"))
        var ny = PostgresValueDecoder()
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(ny.value(buf { $0.writeInteger(micros) }, oid: OID.timestamptz) == .text("2024-03-05 01:07:08-05"))
        var india = PostgresValueDecoder()
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        #expect(india.value(buf { $0.writeInteger(micros) }, oid: OID.timestamptz) == .text("2024-03-05 11:37:08+05:30"))

        #expect(d.value(buf { $0.writeInteger(Int64(22_028_000_000)) }, oid: OID.time) == .text("06:07:08"))
        // timetz stores seconds *west* of UTC: 18000 = UTC-5.
        #expect(d.value(buf { $0.writeInteger(Int64(22_028_000_000)); $0.writeInteger(Int32(18000)) }, oid: OID.timetz) == .text("06:07:08-05"))
    }

    @Test func pgIntervalUUIDInetBits() {
        let d = PostgresValueDecoder()
        #expect(d.value(buf { $0.writeInteger(Int64(14_706_789_000)); $0.writeInteger(Int32(3)); $0.writeInteger(Int32(14)) }, oid: OID.interval)
            == .text("1 year 2 mons 3 days 04:05:06.789"))
        #expect(d.value(buf { $0.writeInteger(Int64(0)); $0.writeInteger(Int32(0)); $0.writeInteger(Int32(0)) }, oid: OID.interval) == .text("00:00:00"))
        #expect(d.value(buf { $0.writeInteger(Int64(-3_600_000_000)); $0.writeInteger(Int32(1)); $0.writeInteger(Int32(0)) }, oid: OID.interval)
            == .text("1 day -01:00:00"))

        let uuid: [UInt8] = [0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, 0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00]
        #expect(d.value(buf { $0.writeBytes(uuid) }, oid: OID.uuid) == .text("123e4567-e89b-12d3-a456-426614174000"))

        #expect(d.value(buf { $0.writeBytes([2, 32, 0, 4, 192, 168, 1, 5]) }, oid: OID.inet) == .text("192.168.1.5"))
        #expect(d.value(buf { $0.writeBytes([2, 24, 0, 4, 192, 168, 1, 0]) }, oid: OID.inet) == .text("192.168.1.0/24"))
        #expect(d.value(buf { $0.writeBytes([2, 8, 1, 4, 10, 0, 0, 0]) }, oid: OID.cidr) == .text("10.0.0.0/8"))
        #expect(d.value(buf { $0.writeBytes([0x08, 0x00, 0x2b, 0x01, 0x02, 0x03]) }, oid: OID.macaddr) == .text("08:00:2b:01:02:03"))
        #expect(d.value(buf { $0.writeInteger(Int32(5)); $0.writeInteger(UInt8(0b10110000)) }, oid: OID.bit) == .text("10110"))
        #expect(d.value(buf { $0.writeInteger(Int64(-123456)) }, oid: OID.money) == .text("-$1,234.56"))
    }

    @Test func pgArraysAndRanges() {
        let d = PostgresValueDecoder()
        let ints = buf {
            $0.writeInteger(Int32(1)); $0.writeInteger(Int32(0)); $0.writeInteger(UInt32(23))
            $0.writeInteger(Int32(3)); $0.writeInteger(Int32(1))
            for n in 1...3 { $0.writeInteger(Int32(4)); $0.writeInteger(Int32(n)) }
        }
        #expect(d.value(ints, oid: 1007) == .text("{1,2,3}"))

        let texts = buf {
            $0.writeInteger(Int32(1)); $0.writeInteger(Int32(1)); $0.writeInteger(UInt32(25))
            $0.writeInteger(Int32(3)); $0.writeInteger(Int32(1))
            $0.writeInteger(Int32(3)); $0.writeString("a b")
            $0.writeInteger(Int32(-1))
            $0.writeInteger(Int32(1)); $0.writeString("x")
        }
        #expect(d.value(texts, oid: 1009) == .text("{\"a b\",NULL,x}"))

        let empty = buf { $0.writeInteger(Int32(0)); $0.writeInteger(Int32(0)); $0.writeInteger(UInt32(23)) }
        #expect(d.value(empty, oid: 1007) == .text("{}"))

        let range = buf {
            $0.writeInteger(UInt8(0x02)) // lower inclusive, upper exclusive
            $0.writeInteger(Int32(4)); $0.writeInteger(Int32(1))
            $0.writeInteger(Int32(4)); $0.writeInteger(Int32(5))
        }
        #expect(d.value(range, oid: OID.int4range) == .text("[1,5)"))
        #expect(d.value(buf { $0.writeInteger(UInt8(0x01)) }, oid: OID.int4range) == .text("empty"))
    }

    @Test func pgUnknownTypesFallBack() {
        var d = PostgresValueDecoder()
        // Enum label: unknown OID, valid UTF-8.
        #expect(d.value(buf { $0.writeString("happy") }, oid: 99999) == .text("happy"))
        // Non-UTF-8 payload of an unknown type stays bytes.
        #expect(d.value(buf { $0.writeBytes([0xFF, 0xFE]) }, oid: 99999) == .bytes(Data([0xFF, 0xFE])))
        #expect(d.typeName(for: 99999) == "oid:99999")
        d.extraTypes[99999] = PostgresTypeInfo(name: "mood", elementOID: 0, category: "E")
        #expect(d.typeName(for: 99999) == "mood")
        #expect(d.typeName(for: PostgresValueDecoder.OID.jsonb) == "jsonb")
    }

    @Test func pgWrapGuard() {
        #expect(PostgresSession.canWrapAsSubquery("SELECT 1"))
        #expect(PostgresSession.canWrapAsSubquery("  (select 1)"))
        #expect(PostgresSession.canWrapAsSubquery("WITH a AS (SELECT 1) SELECT * FROM a"))
        #expect(!PostgresSession.canWrapAsSubquery("SELECT * INTO t2 FROM t"))
        #expect(!PostgresSession.canWrapAsSubquery("INSERT INTO t VALUES (1)"))
        #expect(!PostgresSession.canWrapAsSubquery("SHOW server_version"))
    }

    @Test func registry() {
        #expect(DriverRegistry.driver(for: .mysql).engines.contains(.mariadb))
        #expect(DriverRegistry.driver(for: .mariadb).engines.contains(.mysql))
        #expect(DriverRegistry.driver(for: .postgresql).engines == [.postgresql])
    }

    @Test func serialGateOrdersWaiters() async {
        actor Runner {
            var gate = SerialGate()
            var log: [Int] = []
            func acquire() async {
                if !gate.tryEnter() { await withCheckedContinuation { gate.enqueue($0) } }
            }
            func work(_ id: Int) async {
                await acquire()
                log.append(id)
                try? await Task.sleep(for: .milliseconds(10))
                log.append(-id)
                gate.leave()
            }
        }
        let runner = Runner()
        await withTaskGroup(of: Void.self) { group in
            for i in 1...4 { group.addTask { await runner.work(i) } }
        }
        let log = await runner.log
        // Every start is immediately followed by its own finish: no interleaving.
        for pair in stride(from: 0, to: log.count, by: 2) {
            #expect(log[pair] == -log[pair + 1])
        }
        #expect(log.count == 8)
    }
}
