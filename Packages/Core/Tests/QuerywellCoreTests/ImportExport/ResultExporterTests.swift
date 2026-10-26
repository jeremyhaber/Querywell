import Foundation
import Testing

@testable import QuerywellCore

/// Minimal RFC 4180 parser used to check that what we write reads back exactly.
private func parseCSV(_ text: String, delimiter: Character = ",") -> [[String?]] {
    var rows: [[String?]] = []
    var row: [String?] = []
    var field = ""
    var quoted = false      // currently inside quotes
    var wasQuoted = false   // this field had quotes (so "" is an empty string, not NULL-ish)
    func endField() {
        row.append(field.isEmpty && !wasQuoted ? nil : field)
        field = ""
        wasQuoted = false
    }
    let chars = Array(text)
    var k = 0
    while k < chars.count {
        let c = chars[k]
        if quoted {
            if c == "\"" {
                if k + 1 < chars.count, chars[k + 1] == "\"" { field.append("\""); k += 1 } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" {
            quoted = true
            wasQuoted = true
        } else if c == delimiter {
            endField()
        } else if c == "\r\n" || c == "\n" || c == "\r" {
            endField()
            rows.append(row)
            row = []
        } else {
            field.append(c)
        }
        k += 1
    }
    if !field.isEmpty || wasQuoted || !row.isEmpty { endField(); rows.append(row) }
    return rows
}

private func result(_ cols: [String], _ rows: [[DatabaseValue]], types: [String]? = nil) -> QueryResult {
    QueryResult(columns: cols.enumerated().map { ColumnInfo(name: $1, typeName: types?[$0] ?? "text") }, rows: rows)
}

private func exportString(_ r: QueryResult, _ f: ResultFormat, dialect: SQLDialect = SQLDialect(.mysql)) throws -> String {
    let sink = DataSink()
    try ResultExporter.export(r, format: f, to: sink, dialect: dialect)
    return sink.string
}

@Suite("CSV export")
struct CSVExportTests {
    static let tricky: [[DatabaseValue]] = [
        [.text("plain"), .text("with,comma"), .text("with \"quotes\""), .integer(1)],
        [.text("multi\nline"), .text("crlf\r\nline"), .text("  padded  "), .unsignedInteger(18_446_744_073_709_551_615)],
        [.text("ünï 🙂 日本語"), .text(""), .null, .double(1.5)],
        [.text("\\N"), .text("NULL"), .bool(true), .double(-0.000001)],
    ]

    @Test func quotesOnlyWhatNeedsIt() throws {
        let out = try exportString(result(["a", "b", "c", "d"], Self.tricky), .csv(CSVOptions()))
        let lines = out.components(separatedBy: "\r\n")
        #expect(lines[0] == "a,b,c,d")
        #expect(lines[1] == "plain,\"with,comma\",\"with \"\"quotes\"\"\",1")
        #expect(out.contains("\"multi\nline\",\"crlf\r\nline\",  padded  ,18446744073709551615"))
        #expect(out.hasSuffix("\r\n"))
    }

    @Test func roundTripsThroughAnRFC4180Parser() throws {
        let out = try exportString(result(["a", "b", "c", "d"], Self.tricky), .csv(CSVOptions()))
        let parsed = parseCSV(out)
        #expect(parsed.count == 5)
        #expect(parsed[1] == ["plain", "with,comma", "with \"quotes\"", "1"])
        #expect(parsed[2] == ["multi\nline", "crlf\r\nline", "  padded  ", "18446744073709551615"])
        #expect(parsed[3] == ["ünï 🙂 日本語", "", nil, "1.5"])  // empty string quoted, NULL bare
        #expect(parsed[4] == ["\\N", "NULL", "true", "-1e-06"])
    }

    @Test func nullVersusEmptyIsPreservedInEveryMode() throws {
        let r = result(["x", "y"], [[.null, .text("")], [.text(""), .null]])
        // NULL as empty field: empty strings are written as ""
        #expect(try exportString(r, .csv(CSVOptions(includeHeader: false))) == ",\"\"\r\n\"\",\r\n")
        // NULL as \N: empty strings are plain empty fields
        #expect(try exportString(r, .csv(CSVOptions(includeHeader: false, nullRepresentation: .backslashN))) == "\\N,\r\n,\\N\r\n")
        // a literal "\N" text is quoted so it can't be mistaken for NULL
        let lit = result(["x"], [[.text("\\N")], [.null]])
        #expect(try exportString(lit, .csv(CSVOptions(includeHeader: false, nullRepresentation: .backslashN))) == "\"\\N\"\r\n\\N\r\n")
        // custom marker
        let custom = result(["x"], [[.text("NULL")], [.null]])
        #expect(try exportString(custom, .csv(CSVOptions(includeHeader: false, nullRepresentation: .custom("NULL")))) == "\"NULL\"\r\nNULL\r\n")
        // explicit override
        #expect(try exportString(r, .csv(CSVOptions(includeHeader: false, quoteEmptyStrings: false))) == ",\r\n,\r\n")
    }

    @Test func optionsApply() throws {
        let r = result(["a;b", "c"], [[.text("x;y"), .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF]))]])
        let tsvLike = try exportString(r, .csv(CSVOptions(delimiter: ";", utf8BOM: true, lineEnding: .lf)))
        #expect(tsvLike.hasPrefix("\u{FEFF}"))
        #expect(tsvLike.dropFirst() == "\"a;b\";c\n\"x;y\";0xDEADBEEF\n")
        let b64 = try exportString(r, .csv(CSVOptions(includeHeader: false, bytesEncoding: .base64)))
        #expect(b64 == "x;y,3q2+7w==\r\n")
        let all = try exportString(r, .csv(CSVOptions(includeHeader: false, quoteAllFields: true)))
        #expect(all.hasPrefix("\"x;y\",\"0xDEADBEEF\""))
        #expect(ResultFormat.csv(CSVOptions(delimiter: "\t")).fileExtension == "tsv")
    }

    @Test func emptyResultStillHasAHeader() throws {
        #expect(try exportString(result(["a", "b"], []), .csv(CSVOptions())) == "a,b\r\n")
        #expect(try exportString(result(["a", "b"], []), .csv(CSVOptions(includeHeader: false))) == "")
    }

    @Test func bomBytesAreWrittenOnce() throws {
        let sink = DataSink()
        let w = ResultWriter(format: .csv(CSVOptions(utf8BOM: true)), columns: [ColumnInfo(name: "a", typeName: "text")], sink: sink)
        try w.write(rows: [[.text("1")]])
        try w.write(rows: [[.text("2")]])
        try w.finish()
        #expect(Array(sink.data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(sink.string.dropFirst() == "a\r\n1\r\n2\r\n")
        #expect(w.rowsWritten == 2)
    }
}

@Suite("JSON export")
struct JSONExportTests {
    @Test func arrayOfObjectsWithLosslessNumbers() throws {
        let r = result(
            ["i", "u", "d", "dec", "b", "n", "t", "bin"],
            [[.integer(-5), .unsignedInteger(7), .double(2.5), .text("12345678901234567890.123456789"), .bool(false), .null,
              .text("quote\" back\\ nl\n tab\t ctrl\u{1}"), .bytes(Data([1, 2, 3]))]],
            types: ["int", "bigint unsigned", "double", "decimal", "bool", "text", "text", "blob"])
        let out = try exportString(r, .json(JSONExportOptions()))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]).first
        #expect(obj?["i"] as? Int == -5)
        #expect(obj?["u"] as? Int == 7)
        #expect(obj?["d"] as? Double == 2.5)
        #expect(obj?["dec"] as? String == "12345678901234567890.123456789")  // decimals stay strings
        #expect(obj?["b"] as? Bool == false)
        #expect(obj?["n"] is NSNull)
        #expect(obj?["t"] as? String == "quote\" back\\ nl\n tab\t ctrl\u{1}")
        #expect(obj?["bin"] as? String == "AQID")
        #expect(out.contains("\"i\":-5"))
        #expect(out.hasPrefix("[\n  {") && out.hasSuffix("}\n]\n"))
    }

    @Test func bigIntegersBecomeStringsUnlessDisabled() throws {
        let r = result(["a", "b"], [[.integer(Int64.max), .unsignedInteger(UInt64.max)]])
        let safe = try exportString(r, .json(JSONExportOptions(layout: .lines)))
        #expect(safe == "{\"a\":\"9223372036854775807\",\"b\":\"18446744073709551615\"}\n")
        let raw = try exportString(r, .json(JSONExportOptions(layout: .lines, bigIntegersAsStrings: false)))
        #expect(raw == "{\"a\":9223372036854775807,\"b\":18446744073709551615}\n")
    }

    @Test func jsonLinesAndHexBytes() throws {
        let r = result(["a"], [[.text("x")], [.bytes(Data([0xAB]))], [.double(.nan)], [.double(.infinity)]])
        let out = try exportString(r, .json(JSONExportOptions(layout: .lines, bytesEncoding: .hex)))
        #expect(out == "{\"a\":\"x\"}\n{\"a\":\"0xAB\"}\n{\"a\":\"nan\"}\n{\"a\":\"inf\"}\n")
        #expect(ResultFormat.json(JSONExportOptions(layout: .lines)).fileExtension == "jsonl")
    }

    @Test func jsonColumnsAreEmbeddedAndDuplicateNamesDisambiguated() throws {
        let r = result(["doc", "doc", "bad"], [[.text("{ \"k\": [1, 2] }"), .text("[]"), .text("{not json")]], types: ["json", "jsonb", "json"])
        let out = try exportString(r, .json(JSONExportOptions(layout: .lines)))
        #expect(out == "{\"doc\":{\"k\":[1,2]},\"doc_2\":[],\"bad\":\"{not json\"}\n")
        let off = try exportString(r, .json(JSONExportOptions(layout: .lines, embedJSONColumns: false)))
        #expect(off.contains("\"doc\":\"{ \\\"k\\\": [1, 2] }\""))
    }

    @Test func emptyResultIsAValidArray() throws {
        let out = try exportString(result(["a"], []), .json(JSONExportOptions()))
        #expect((try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [Any])?.isEmpty == true)
        #expect(try exportString(result(["a"], []), .json(JSONExportOptions(layout: .lines))) == "")
    }

    @Test func unicodeIsNotEscapedButSeparatorsAre() throws {
        let out = try exportString(result(["a"], [[.text("日本 🙂 \u{2028}")]]), .json(JSONExportOptions(layout: .lines)))
        #expect(out == "{\"a\":\"日本 🙂 \\u2028\"}\n")
    }
}

@Suite("SQL INSERT export")
struct SQLExportTests {
    @Test func batchesRowsAndQuotesThroughTheDialect() throws {
        let r = result(["id", "name", "blob"], [
            [.integer(1), .text("it's"), .bytes(Data([0xCA, 0xFE]))],
            [.integer(2), .null, .null],
            [.integer(3), .text("back\\slash\nnl"), .bool(true)],
        ])
        let opts = SQLInsertOptions(table: TableRef(schema: "shop", name: "we`ird"), rowsPerStatement: 2)
        let mysql = try exportString(r, .sqlInserts(opts))
        #expect(mysql == """
            INSERT INTO `shop`.`we``ird` (`id`, `name`, `blob`) VALUES
            (1, 'it\\'s', 0xCAFE),
            (2, NULL, NULL);
            INSERT INTO `shop`.`we``ird` (`id`, `name`, `blob`) VALUES
            (3, 'back\\\\slash\\nnl', 1);

            """)
        let pg = try exportString(r, .sqlInserts(opts), dialect: SQLDialect(.postgresql))
        #expect(pg.hasPrefix("INSERT INTO \"shop\".\"we`ird\" (\"id\", \"name\", \"blob\") VALUES\n(1, 'it''s', '\\xcafe'::bytea),"))
        #expect(pg.contains("(3, E'back\\\\slash\nnl', TRUE);"))
        let noCols = try exportString(r, .sqlInserts(SQLInsertOptions(table: opts.table, rowsPerStatement: 10, includeColumnList: false)))
        #expect(noCols.hasPrefix("INSERT INTO `shop`.`we``ird` VALUES\n"))
    }

    @Test func outputExecutesBack() async throws {
        // Statement shape is also checked against a real server in the integration tests below.
        let r = result(["a"], [[.text("x")]])
        #expect(try exportString(r, .sqlInserts(SQLInsertOptions(table: TableRef(schema: "s", name: "t")))).hasSuffix(";\n"))
    }
}

@Suite("Result export pages")
struct PagedExportTests {
    struct Pages: AsyncSequence {
        typealias Element = QueryResult
        var pages: [QueryResult]
        struct It: AsyncIteratorProtocol {
            var pages: [QueryResult]
            mutating func next() async throws -> QueryResult? { pages.isEmpty ? nil : pages.removeFirst() }
        }
        func makeAsyncIterator() -> It { It(pages: pages) }
    }

    @Test func pagesAreConcatenatedUnderOneHeader() async throws {
        let cols = ["id"]
        let pages = Pages(pages: [result(cols, [[.integer(1)], [.integer(2)]]), result(cols, [[.integer(3)]])])
        let sink = DataSink()
        let n = try await ResultExporter.export(pages: pages, format: .csv(CSVOptions()), to: sink)
        #expect(n == 3)
        #expect(sink.string == "id\r\n1\r\n2\r\n3\r\n")
        let json = DataSink()
        try await ResultExporter.export(pages: Pages(pages: [result(cols, [[.integer(1)]]), result(cols, [[.integer(2)]])]),
                                        format: .json(JSONExportOptions()), to: json)
        #expect(try JSONSerialization.jsonObject(with: json.data) as? [[String: Int]] == [["id": 1], ["id": 2]])
    }

    @Test func fileHandleSinkWritesToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qw-sink-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try FileHandleSink(url: url)
        try ResultExporter.export(result(["a"], [[.text("é")]]), format: .csv(CSVOptions()), to: sink)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\r\né\r\n")
    }
}

@Suite("Whole-table export integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct TableExportIntegrationTests {
    private func makeTable(_ f: SchemaFixture, rows: Int) async throws {
        try await f.run("CREATE TABLE \(f.q).items (a integer NOT NULL, b varchar(10) NOT NULL, note varchar(100), PRIMARY KEY (a, b))")
        var values: [String] = []
        for i in 0..<rows { values.append("(\(i / 3), '\(["x", "y", "z"][i % 3])', \(i % 7 == 0 ? "NULL" : "'n\(i), \"q\"'"))") }
        for chunk in stride(from: 0, to: values.count, by: 500) {
            try await f.run("INSERT INTO \(f.q).items (a, b, note) VALUES " + values[chunk..<min(chunk + 500, values.count)].joined(separator: ","))
        }
    }

    @Test(arguments: DBTarget.all)
    func keysetPagingExportsEveryRowOnceInKeyOrder(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await makeTable(f, rows: 2500)
            let info = try await f.inspector.structure(of: f.ref("items"))
            let query = TableQuery(table: f.ref("items"), primaryKey: info.primaryKey)
            let sink = DataSink()
            let n = try await ResultExporter.exportTable(query, session: f.session, format: .csv(CSVOptions()), to: sink, pageSize: 300)
            #expect(n == 2500)
            let rows = parseCSV(sink.string)
            #expect(rows.count == 2501)
            #expect(rows[0] == ["a", "b", "note"])
            // key order, no duplicates, no gaps
            let keys = rows.dropFirst().map { ($0[0] ?? "", $0[1] ?? "") }
            #expect(Set(keys.map { "\($0.0)|\($0.1)" }).count == 2500)
            let sorted = keys.sorted { Int($0.0)! != Int($1.0)! ? Int($0.0)! < Int($1.0)! : $0.1 < $1.1 }
            #expect(keys.map { "\($0.0)|\($0.1)" } == sorted.map { "\($0.0)|\($0.1)" })
            // NULL (bare) vs text with commas and quotes survives
            #expect(rows[1][2] == nil)
            #expect(rows[2][2] == "n1, \"q\"")
        }
    }

    @Test(arguments: DBTarget.all)
    func customSortAndFilterFallBackToOffsetPaging(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await makeTable(f, rows: 700)
            let query = TableQuery(
                table: f.ref("items"), columns: ["note", "a"], rawWhere: "b = 'x'", sort: [SortKey(column: "a", ascending: false)],
                primaryKey: ["a", "b"])
            let sink = DataSink()
            let n = try await ResultExporter.exportTable(query, session: f.session, format: .json(JSONExportOptions(layout: .lines)), to: sink, pageSize: 100)
            #expect(n == 234)  // i % 3 == 0 for i in 0..<700
            let lines = sink.string.split(separator: "\n")
            let first = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
            #expect(first["a"] as? Int == 233)
            #expect(Set(first.keys) == ["note", "a"])
        }
    }

    @Test(arguments: DBTarget.all)
    func keysetPagingKeepsOnlyRequestedColumnsAndAnEmptyTableHasAHeader(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await makeTable(f, rows: 450)
            let q = TableQuery(table: f.ref("items"), columns: ["note"], primaryKey: ["a", "b"])
            let sink = DataSink()
            #expect(try await ResultExporter.exportTable(q, session: f.session, format: .csv(CSVOptions()), to: sink, pageSize: 100) == 450)
            #expect(sink.string.hasPrefix("note\r\n"))
            let none = TableQuery(table: f.ref("items"), rawWhere: "a < 0", primaryKey: ["a", "b"])
            let empty = DataSink()
            #expect(try await ResultExporter.exportTable(none, session: f.session, format: .csv(CSVOptions()), to: empty) == 0)
            #expect(empty.string == "a,b,note\r\n")
        }
    }

    @Test(arguments: DBTarget.all)
    func generatedInsertsExecuteOnTheSameEngine(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await makeTable(f, rows: 120)
            try await f.run("CREATE TABLE \(f.q).copy_of (a integer NOT NULL, b varchar(10) NOT NULL, note varchar(100), PRIMARY KEY (a, b))")
            let query = TableQuery(table: f.ref("items"), primaryKey: ["a", "b"])
            let sink = DataSink()
            try await ResultExporter.exportTable(
                query, session: f.session, format: .sqlInserts(SQLInsertOptions(table: f.ref("copy_of"), rowsPerStatement: 25)), to: sink, pageSize: 50)
            let statements = StatementSplitter.split(sink.string, dialect: f.dialect)
            #expect(statements.count == 5)
            for s in statements { _ = try await f.session.execute(s.text) }
            let a = try await f.session.execute("SELECT a, b, note FROM \(f.q).items ORDER BY a, b")
            let b = try await f.session.execute("SELECT a, b, note FROM \(f.q).copy_of ORDER BY a, b")
            #expect(a.rows == b.rows)
        }
    }
}
