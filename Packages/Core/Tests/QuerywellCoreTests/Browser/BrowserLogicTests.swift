import Foundation
import Testing

@testable import QuerywellCore

@Suite("Compact counts and paging")
struct CompactCountTests {
    @Test func compactFormatting() {
        let cases: [(Int64, String)] = [
            (0, "0"), (212, "212"), (999, "999"), (1_000, "1k"), (1_400, "1.4k"), (2_148, "2.1k"), (9_949, "9.9k"),
            (9_950, "10k"), (38_000, "38k"), (38_400, "38k"), (999_499, "999k"), (999_500, "1M"), (1_200_000, "1.2M"),
            (38_000_000, "38M"), (2_500_000_000, "2.5B"), (-5, "0"),
        ]
        for (n, expected) in cases { #expect(CompactCount.string(n) == expected, "\(n)") }
    }

    @Test func grouping() {
        #expect(CompactCount.grouped(0) == "0")
        #expect(CompactCount.grouped(999) == "999")
        #expect(CompactCount.grouped(2_148) == "2,148")
        #expect(CompactCount.grouped(1_234_567) == "1,234,567")
        #expect(CompactCount.grouped(-4_321) == "-4,321")
    }

    @Test func pageLabels() {
        var page = PageInfo(offset: 0, rowCount: 500, pageSize: 500, total: 2_148, totalIsExact: true)
        #expect(page.label == "Rows 1–500 of 2,148 (exact)")
        #expect(page.hasNext && !page.hasPrevious)
        #expect(page.lastPageOffset == 2_000)
        page = PageInfo(offset: 2_000, rowCount: 148, pageSize: 500, total: 2_148, totalIsExact: true)
        #expect(page.label == "Rows 2,001–2,148 of 2,148 (exact)")
        #expect(!page.hasNext && page.hasPrevious)
        page = PageInfo(offset: 0, rowCount: 500, pageSize: 500, total: 2_100, totalIsExact: false)
        #expect(page.label == "Rows 1–500 of ~2,100 (est.)")
        page = PageInfo(offset: 0, rowCount: 500, pageSize: 500)
        #expect(page.label == "Rows 1–500 of …")
        #expect(page.lastPageOffset == nil)
        #expect(PageInfo(offset: 0, rowCount: 0, pageSize: 500, total: 0, totalIsExact: true).label == "No rows")
        // Estimates never claim there is no next page when the page is full.
        #expect(PageInfo(offset: 500, rowCount: 500, pageSize: 500, total: 600, totalIsExact: false).hasNext)
        #expect(!PageInfo(offset: 0, rowCount: 12, pageSize: 500, total: 12, totalIsExact: false).hasNext)
        #expect(PageInfo(offset: 0, rowCount: 0, pageSize: 500, total: 0, totalIsExact: true).lastPageOffset == 0)
    }
}

@Suite("Column presentation")
struct ColumnPresentationTests {
    @Test func classification() {
        #expect(ColumnKind.classify(dataType: "bigint") == .integer)
        #expect(ColumnKind.classify(dataType: "bigint(20) unsigned") == .integer)
        #expect(ColumnKind.classify(dataType: "int4") == .integer)
        #expect(ColumnKind.classify(dataType: "numeric(10,2)") == .decimal)
        #expect(ColumnKind.classify(dataType: "double precision") == .decimal)
        #expect(ColumnKind.classify(dataType: "datetime") == .dateTime)
        #expect(ColumnKind.classify(dataType: "timestamp with time zone") == .dateTime)
        #expect(ColumnKind.classify(dataType: "character varying") == .text)
        #expect(ColumnKind.classify(dataType: "longtext") == .longText)
        #expect(ColumnKind.classify(dataType: "jsonb") == .json)
        #expect(ColumnKind.classify(dataType: "uuid") == .uuid)
        #expect(ColumnKind.classify(dataType: "blob") == .binary)
        #expect(ColumnKind.classify(dataType: "enum('a','b')") == .enumeration)
        #expect(ColumnKind.classify(dataType: "geometry") == .other)
    }

    @Test func fontRule() {
        // Mockup: ids, slugs, dates are mono; titles (text) are proportional; status is a pill.
        #expect(ColumnPresentation(name: "ID", dataType: "bigint").usesMonospace)
        #expect(ColumnPresentation(name: "post_modified", dataType: "datetime").usesMonospace)
        #expect(ColumnPresentation(name: "post_name", dataType: "varchar", fullType: "varchar(200)").usesMonospace)
        #expect(ColumnPresentation(name: "code", dataType: "varchar", fullType: "varchar(20)").usesMonospace)
        #expect(!ColumnPresentation(name: "post_title", dataType: "text").usesMonospace)
        #expect(!ColumnPresentation(name: "display_name", dataType: "varchar", fullType: "varchar(250)").usesMonospace)
        #expect(!ColumnPresentation(name: "post_content", dataType: "longtext").usesMonospace)
        #expect(ColumnPresentation(name: "post_status", dataType: "varchar", fullType: "varchar(20)").usesPill)
        #expect(!ColumnPresentation(name: "post_type", dataType: "varchar", fullType: "varchar(20)").usesPill)
        #expect(ColumnPresentation(name: "kind", dataType: "enum", fullType: "enum('a')").usesPill)
        #expect(ColumnPresentation.pillTone(for: "publish") == .positive)
        #expect(ColumnPresentation.pillTone(for: "draft") == .neutral)
    }

    @Test func cellText() {
        #expect(CellDisplay.text(.null, nullDisplay: "∅") == "∅")
        #expect(CellDisplay.text(.integer(5), nullDisplay: "NULL") == "5")
        #expect(CellDisplay.text(.text("a\nb\r\nc\td"), nullDisplay: "NULL") == "a↵b↵c d")
        let long = String(repeating: "x", count: 1_000)
        let shown = CellDisplay.text(.text(long), nullDisplay: "NULL")
        #expect(shown.count == CellDisplay.cellLimit + 1 && shown.hasSuffix("…"))
        #expect(CellDisplay.text(.bytes(Data([0xDE, 0xAD])), nullDisplay: "NULL") == "0xDEAD")
        #expect(CellDisplay.full(.text(long), limit: 10) == String(repeating: "x", count: 10) + "…")
    }

    @Test func sniffing() {
        #expect(ValueSniffer.isJSONLike(#"{"a": [1, 2]}"#))
        #expect(ValueSniffer.isJSONLike("[1,2,3]"))
        #expect(!ValueSniffer.isJSONLike("{not json}"))
        #expect(!ValueSniffer.isJSONLike("hello"))
        #expect(ValueSniffer.isPHPSerialized(#"a:2:{i:0;s:3:"foo";i:1;b:1;}"#))
        #expect(ValueSniffer.isPHPSerialized(#"s:5:"hello";"#))
        #expect(ValueSniffer.isPHPSerialized("i:42;"))
        #expect(ValueSniffer.isPHPSerialized("N;"))
        #expect(!ValueSniffer.isPHPSerialized("a: plain text"))
        #expect(!ValueSniffer.isPHPSerialized("hello"))
    }
}

@Suite("Grid interactions")
struct GridInteractionTests {
    private func k(_ c: String, _ asc: Bool = true) -> SortKey { SortKey(column: c, ascending: asc) }

    @Test func plainClickCycles() {
        var sort: [SortKey] = []
        sort = SortCycle.next(current: sort, column: "a", additive: false)
        #expect(sort == [k("a")])
        sort = SortCycle.next(current: sort, column: "a", additive: false)
        #expect(sort == [k("a", false)])
        sort = SortCycle.next(current: sort, column: "A", additive: false)
        #expect(sort.isEmpty)
        // Clicking another column replaces a multi-key sort.
        #expect(SortCycle.next(current: [k("a"), k("b")], column: "b", additive: false) == [k("b")])
        #expect(SortCycle.next(current: [k("a")], column: "b", additive: false) == [k("b")])
    }

    @Test func shiftClickBuildsSecondarySort() {
        var sort = [k("a")]
        sort = SortCycle.next(current: sort, column: "b", additive: true)
        #expect(sort == [k("a"), k("b")])
        sort = SortCycle.next(current: sort, column: "b", additive: true)
        #expect(sort == [k("a"), k("b", false)])
        sort = SortCycle.next(current: sort, column: "b", additive: true)
        #expect(sort == [k("a")])
        #expect(SortCycle.next(current: [], column: "x", additive: true) == [k("x")])
        let ind = SortCycle.indicator(for: "B", in: [k("a"), k("b", false)])
        #expect(ind?.ascending == false && ind?.priority == 2)
        #expect(SortCycle.indicator(for: "a", in: [k("a")])?.priority == nil)
        #expect(SortCycle.indicator(for: "z", in: [k("a")]) == nil)
    }

    @Test func conditionAvailability() {
        let text = FilterCondition.available(for: .text)
        #expect(text.contains(.regex) && !text.contains(.between) && !text.contains(.dateRange))
        #expect(FilterCondition.available(for: .integer).contains(.between))
        #expect(!FilterCondition.available(for: .integer).contains(.regex))
        #expect(FilterCondition.available(for: .dateTime).contains(.dateRange))
        #expect(text.first == .isAnyOf)
    }

    @Test func operators() {
        #expect(FilterCondition.isAnyOf.makeOperator(values: [], text: "", text2: "", kind: .text) == nil)
        #expect(FilterCondition.isAnyOf.makeOperator(values: [.text("a")], text: "", text2: "", kind: .text) == .isAnyOf([.text("a")]))
        #expect(FilterCondition.isNot.makeOperator(values: [.text("a")], text: "", text2: "", kind: .text) == .isNoneOf([.text("a")]))
        #expect(FilterCondition.contains.makeOperator(values: [], text: "", text2: "", kind: .text) == nil)
        #expect(FilterCondition.contains.makeOperator(values: [], text: "x", text2: "", kind: .text) == .contains("x"))
        #expect(FilterCondition.isEmpty.makeOperator(values: [], text: "", text2: "", kind: .text) == .isEmpty)
        #expect(FilterCondition.between.makeOperator(values: [], text: "1", text2: "9", kind: .integer) == .between(.integer(1), .integer(9)))
        #expect(FilterCondition.between.makeOperator(values: [], text: "1.5", text2: "9", kind: .decimal) == .between(.double(1.5), .double(9)))
        #expect(FilterCondition.between.makeOperator(values: [], text: "1", text2: "", kind: .integer) == nil)
        #expect(FilterCondition.dateRange.makeOperator(values: [], text: "2026-01-01", text2: "", kind: .date) == .dateRange(from: "2026-01-01", to: nil))
        #expect(FilterCondition.dateRange.makeOperator(values: [], text: " ", text2: "", kind: .date) == nil)
    }

    @Test func draftsRoundTrip() {
        let ops: [FilterOperator] = [
            .isAnyOf([.text("a"), .null]), .isNoneOf([.text("b")]), .contains("x"), .regex("^a"), .isEmpty, .isNotEmpty,
            .dateRange(from: "2026-01-01", to: "2026-02-01"), .between(.integer(1), .integer(5)),
        ]
        for op in ops {
            let d = try! #require(FilterCondition.draft(from: op))
            let rebuilt = d.condition.makeOperator(values: d.values, text: d.text, text2: d.text2, kind: .integer)
            #expect(rebuilt == op, "\(op)")
        }
        #expect(FilterCondition.draft(from: .equals(.integer(3)))?.condition == .isAnyOf)
        #expect(FilterCondition.draft(from: .startsWith("x")) == nil)
    }

    private let dialect = SQLDialect(.mysql)
    private let columns = ["id", "title", "note"]
    private let rows: [[DatabaseValue]] = [
        [.integer(1), .text("Hello, \"world\""), .null],
        [.integer(2), .text("tab\there\nnewline"), .text("it's")],
    ]

    @Test func tsvAndCSV() {
        let tsv = RowCopy.text(format: .tsv, columns: columns, rows: rows, table: nil, dialect: dialect, includeHeader: false)
        #expect(tsv == "1\t\"Hello, \"\"world\"\"\"\t\n2\t\"tab\there\nnewline\"\tit's")
        let csv = RowCopy.text(format: .csv, columns: columns, rows: rows, table: nil, dialect: dialect)
        #expect(csv.hasPrefix("id,title,note\n1,\"Hello, \"\"world\"\"\","))
        #expect(csv.contains("\n2,\"tab\there\nnewline\",it's"))
        let withNull = RowCopy.text(format: .csv, columns: columns, rows: rows, table: nil, dialect: dialect, nullText: "NULL")
        #expect(withNull.contains(",NULL\n"))
    }

    @Test func jsonAndInsert() throws {
        let json = RowCopy.text(format: .json, columns: columns, rows: rows, table: nil, dialect: dialect)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.count == 2)
        #expect(parsed[0]["id"] as? Int == 1)
        #expect(parsed[0]["title"] as? String == "Hello, \"world\"")
        #expect(parsed[0]["note"] is NSNull)
        #expect(parsed[1]["title"] as? String == "tab\there\nnewline")
        #expect(RowCopy.text(format: .json, columns: columns, rows: [], table: nil, dialect: dialect) == "[]")

        let sql = RowCopy.text(format: .sqlInsert, columns: columns, rows: rows, table: TableRef(schema: "db", name: "t"), dialect: dialect)
        #expect(sql.hasPrefix("INSERT INTO `db`.`t` (`id`, `title`, `note`) VALUES (1, 'Hello, \"world\"', NULL);"))
        #expect(sql.contains("'it\\'s'"))
        let pg = RowCopy.text(format: .sqlInsert, columns: ["a"], rows: [[.bool(true)]], table: TableRef(schema: "public", name: "t"), dialect: SQLDialect(.postgresql))
        #expect(pg == "INSERT INTO \"public\".\"t\" (\"a\") VALUES (TRUE);")
    }
}
