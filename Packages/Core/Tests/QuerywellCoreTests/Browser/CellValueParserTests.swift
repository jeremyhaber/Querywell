import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func col(_ type: String, full: String? = nil, nullable: Bool = true, enumValues: [String]? = nil, def: String? = nil,
                 auto: Bool = false) -> ColumnDefinition {
    ColumnDefinition(name: "c", ordinal: 1, dataType: type, fullType: full ?? type, isNullable: nullable,
                     defaultExpression: def, isAutoIncrement: auto, enumValues: enumValues)
}

private func parse(_ text: String, _ column: ColumnDefinition, _ d: SQLDialect = my) -> Result<DatabaseValue, CellInputError> {
    CellValueParser(column: column, dialect: d).parse(text)
}

@Suite("Cell value parser")
struct CellValueParserTests {
    @Test func integersAreRangeChecked() {
        #expect(parse(" 42 ", col("int")) == .success(.integer(42)))
        #expect(parse("-5", col("int")) == .success(.integer(-5)))
        #expect(parse("+7", col("int")) == .success(.integer(7)))
        if case .failure(let e) = parse("1.5", col("int")) { #expect(e.message.contains("whole number")) } else { Issue.record("expected failure") }
        #expect(parse("128", col("tinyint")) != .success(.integer(128)))
        #expect(parse("127", col("tinyint")) == .success(.integer(127)))
        #expect(parse("-129", col("tinyint")) != .success(.integer(-129)))
        #expect(parse("255", col("tinyint", full: "tinyint(3) unsigned")) == .success(.integer(255)))
        #expect(parse("256", col("tinyint", full: "tinyint unsigned")) != .success(.integer(256)))
        if case .failure = parse("-1", col("int", full: "int unsigned")) {} else { Issue.record("negative unsigned must fail") }
        #expect(parse("18446744073709551615", col("bigint", full: "bigint unsigned")) == .success(.unsignedInteger(UInt64.max)))
        if case .failure = parse("9223372036854775808", col("bigint")) {} else { Issue.record("overflow must fail") }
        if case .failure = parse("abc", col("int")) {} else { Issue.record("text must fail") }
    }

    @Test func emptyIsNullOnlyWhenNullable() {
        #expect(parse("", col("int")) == .success(.null))
        #expect(parse("NULL", col("date")) == .success(.null))
        if case .failure(let e) = parse("", col("int", nullable: false)) { #expect(e.message.contains("NOT NULL")) } else { Issue.record("expected failure") }
        // Text columns keep an empty string; NULL is explicit.
        #expect(parse("", col("varchar", full: "varchar(10)")) == .success(.text("")))
        #expect(parse("NULL", col("varchar", full: "varchar(10)")) == .success(.text("NULL")))
    }

    @Test func decimalsStayTextAndFloatsBecomeDoubles() {
        #expect(parse("12.50", col("decimal", full: "decimal(10,2)")) == .success(.text("12.50")))
        #expect(parse(".5", col("decimal", full: "decimal(10,2)")) == .success(.text("0.5")))
        #expect(parse("-.5", col("decimal", full: "decimal(10,2)")) == .success(.text("-0.5")))
        if case .failure = parse("123456789.00", col("decimal", full: "decimal(10,2)")) {} else { Issue.record("too many integer digits") }
        if case .failure = parse("1,5", col("decimal", full: "decimal(10,2)")) {} else { Issue.record("comma must fail") }
        #expect(parse("1.5", col("double")) == .success(.double(1.5)))
        #expect(parse("1e3", col("float")) == .success(.double(1000)))
        #expect(parse("NaN", col("numeric"), pg) == .success(.text("NaN")))
    }

    @Test func booleans() {
        #expect(parse("true", col("boolean"), pg) == .success(.bool(true)))
        #expect(parse("No", col("boolean"), pg) == .success(.bool(false)))
        #expect(parse("1", col("bit"), my) == .success(.integer(1)))
        #expect(parse("true", col("tinyint", full: "tinyint(1)")) == .success(.integer(1)))
        if case .failure = parse("maybe", col("boolean"), pg) {} else { Issue.record("maybe is not a boolean") }
    }

    @Test func datesAreValidatedLoosely() {
        #expect(parse("2026-10-26", col("date")) == .success(.text("2026-10-26")))
        #expect(parse("0000-00-00", col("date")) == .success(.text("0000-00-00")))
        if case .failure = parse("0000-00-00", col("date"), pg) {} else { Issue.record("pg has no zero date") }
        if case .failure = parse("26/10/2026", col("date")) {} else { Issue.record("wrong format") }
        if case .failure = parse("2026-13-01", col("date")) {} else { Issue.record("month 13") }
        #expect(parse("2026-10-26T09:30", col("datetime")) == .success(.text("2026-10-26 09:30")))
        #expect(parse("2026-10-26", col("datetime")) == .success(.text("2026-10-26 00:00:00")))
        #expect(parse("2026-10-26 09:30:15.250", col("timestamp")) == .success(.text("2026-10-26 09:30:15.250")))
        #expect(parse("2026-10-26 09:30:15+02", col("timestamptz"), pg) == .success(.text("2026-10-26 09:30:15+02")))
        #expect(parse("2026-10-26T09:30:15Z", col("timestamptz"), pg) == .success(.text("2026-10-26 09:30:15+00")))
        if case .failure = parse("2026-10-26 25:00:00", col("timestamp"), pg) {} else { Issue.record("hour 25") }
        #expect(parse("12:30", col("time")) == .success(.text("12:30")))
        #expect(parse("-12:30:00", col("time")) == .success(.text("-12:30:00")))
        if case .failure = parse("12:75", col("time")) {} else { Issue.record("minute 75") }
    }

    @Test func jsonUuidAndBinary() {
        #expect(parse("{\"a\": 1}", col("json")) == .success(.text("{\"a\": 1}")))
        #expect(parse("[1,2]", col("jsonb"), pg) == .success(.text("[1,2]")))
        if case .failure = parse("{a:1}", col("json")) {} else { Issue.record("invalid JSON") }
        #expect(parse("550e8400-e29b-41d4-a716-446655440000", col("uuid"), pg) == .success(.text("550e8400-e29b-41d4-a716-446655440000")))
        if case .failure = parse("not-a-uuid", col("uuid"), pg) {} else { Issue.record("invalid uuid") }
        #expect(parse("0x1F8B", col("blob")) == .success(.bytes(Data([0x1F, 0x8B]))))
        #expect(parse("0X00ff", col("varbinary")) == .success(.bytes(Data([0x00, 0xFF]))))
        if case .failure(let e) = parse("hello", col("blob")) { #expect(e.message.contains("hex")) } else { Issue.record("plain text for blob") }
        if case .failure = parse("0x1", col("blob")) {} else { Issue.record("odd hex digits") }
        #expect(parse("", col("blob")) == .success(.bytes(Data())))
    }

    @Test func enumsAndSetsAreRestricted() {
        let e = col("enum", full: "enum('draft','publish')", enumValues: ["draft", "publish"])
        #expect(parse("publish", e) == .success(.text("publish")))
        #expect(parse("PUBLISH", e) == .success(.text("publish")))
        if case .failure(let err) = parse("trash", e) { #expect(err.message.contains("draft, publish")) } else { Issue.record("not allowed") }
        let s = col("set", full: "set('a','b','c')", enumValues: ["a", "b", "c"])
        #expect(parse("c, a", s) == .success(.text("a,c")))
        if case .failure = parse("a,z", s) {} else { Issue.record("z not in set") }
        #expect(CellValueParser(column: e, dialect: my).usesPicker)
        #expect(CellValueParser(column: e, dialect: my).pickerChoices == ["draft", "publish"])
        #expect(!CellValueParser(column: s, dialect: my).usesPicker)
        // Postgres enums arrive with their type name but still carry the allowed values.
        let pgEnum = col("user_status", enumValues: ["on", "off"])
        #expect(parse("off", pgEnum, pg) == .success(.text("off")))
    }

    @Test func textKeepsWhitespaceAndChecksLength() {
        #expect(parse("  hi  ", col("varchar", full: "varchar(10)")) == .success(.text("  hi  ")))
        if case .failure(let e) = parse("12345678901", col("varchar", full: "varchar(10)")) { #expect(e.message.contains("at most 10")) } else { Issue.record("too long") }
        #expect(parse(String(repeating: "x", count: 100_000), col("longtext")) == .success(.text(String(repeating: "x", count: 100_000))))
    }

    @Test func editorHintsAndEmptyValues() {
        let p = { (c: ColumnDefinition) in CellValueParser(column: c, dialect: my) }
        #expect(p(col("longtext")).prefersInspector)
        #expect(p(col("json")).prefersInspector)
        #expect(!p(col("varchar")).prefersInspector)
        #expect(p(col("varchar")).emptyValue == .text(""))
        #expect(p(col("int")).emptyValue == nil)
        #expect(p(col("blob")).emptyValue == .bytes(Data()))
        #expect(CellValueParser.editingText(for: .null) == "")
        #expect(CellValueParser.editingText(for: .bytes(Data([1, 255]))) == "0x01FF")
        #expect(CellValueParser.editingText(for: .text("a\nb")) == "a\nb")
    }

    @Test func equivalenceIgnoresRepresentationNotContent() {
        #expect(CellValueParser.equivalent(.integer(5), .unsignedInteger(5)))
        #expect(CellValueParser.equivalent(.bool(true), .integer(1)))
        #expect(CellValueParser.equivalent(.double(1.5), .text("1.5")))
        #expect(!CellValueParser.equivalent(.text("1.50"), .text("1.5")))
        #expect(!CellValueParser.equivalent(.null, .text("")))
        #expect(!CellValueParser.equivalent(.integer(5), .integer(6)))
    }

    @Test func defaultsResolveOnlyWhenLiteral() {
        func d(_ c: ColumnDefinition, _ dialect: SQLDialect = my) -> DatabaseValue? { CellValueParser(column: c, dialect: dialect).defaultValue() }
        #expect(d(col("varchar", full: "varchar(20)", def: "publish")) == .text("publish"))
        #expect(d(col("int", def: "0", )) == .integer(0))
        #expect(d(col("datetime", def: "CURRENT_TIMESTAMP")) == nil)
        #expect(d(col("varchar", def: "(uuid())")) == nil)
        #expect(d(col("int", def: "NULL")) == .null)
        #expect(d(col("int", nullable: false, def: "NULL")) == nil)
        #expect(d(col("int")) == nil)
        #expect(d(col("varchar", full: "varchar(20)", def: "'publish'::character varying"), pg) == .text("publish"))
        #expect(d(col("int", def: "nextval('t_id_seq'::regclass)"), pg) == nil)
        #expect(d(col("boolean", def: "true"), pg) == .bool(true))
    }
}
