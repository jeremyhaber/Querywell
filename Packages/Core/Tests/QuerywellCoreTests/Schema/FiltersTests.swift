import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func sql(_ op: FilterOperator, _ d: SQLDialect, column: String = "c") -> String? {
    ColumnFilter(column: column, op: op).sql(dialect: d)
}

@Suite("Filters SQL")
struct FilterSQLTests {
    @Test func anyOfAndNoneOf() {
        #expect(sql(.isAnyOf([.text("a"), .text("b")]), my) == "`c` IN ('a', 'b')")
        #expect(sql(.isAnyOf([.text("a"), .null]), my) == "(`c` IN ('a') OR `c` IS NULL)")
        #expect(sql(.isAnyOf([.null]), my) == "`c` IS NULL")
        #expect(sql(.isAnyOf([]), my) == "1 = 0")
        #expect(sql(.isNoneOf([.integer(1), .integer(2)]), pg) == "(\"c\" NOT IN (1, 2) OR \"c\" IS NULL)")
        #expect(sql(.isNoneOf([.integer(1), .null]), pg) == "(\"c\" NOT IN (1) AND \"c\" IS NOT NULL)")
        #expect(sql(.isNoneOf([.null]), pg) == "\"c\" IS NOT NULL")
        #expect(sql(.isNoneOf([]), pg) == "1 = 1")
    }

    @Test func equality() {
        #expect(sql(.equals(.text("it's")), my) == "`c` = 'it\\'s'")
        #expect(sql(.equals(.text("it's")), pg) == "\"c\" = 'it''s'")
        #expect(sql(.equals(.null), my) == "`c` IS NULL")
        #expect(sql(.notEquals(.integer(3)), my) == "NOT (`c` <=> 3)")
        #expect(sql(.notEquals(.integer(3)), pg) == "\"c\" IS DISTINCT FROM 3")
        #expect(sql(.notEquals(.null), pg) == "\"c\" IS NOT NULL")
    }

    @Test func likeFamilyEscapesPatterns() {
        #expect(sql(.contains("50%_"), my) == "`c` LIKE '%50\\\\%\\\\_%' ESCAPE '\\\\'")
        #expect(sql(.contains("50%_"), pg) == "\"c\"::text ILIKE E'%50\\\\%\\\\_%' ESCAPE E'\\\\'")
        #expect(sql(.startsWith("ab"), my) == "`c` LIKE 'ab%' ESCAPE '\\\\'")
        #expect(sql(.endsWith("ab"), pg) == "\"c\"::text ILIKE '%ab' ESCAPE E'\\\\'")
        #expect(sql(.notContains("x"), my) == "(`c` IS NULL OR `c` NOT LIKE '%x%' ESCAPE '\\\\')")
        #expect(sql(.notContains("x"), pg) == "(\"c\" IS NULL OR \"c\"::text NOT ILIKE '%x%' ESCAPE E'\\\\')")
        #expect(sql(.contains("it's \\ ok"), my) == "`c` LIKE '%it\\'s \\\\\\\\ ok%' ESCAPE '\\\\'")
        #expect(sql(.contains("it's"), pg) == "\"c\"::text ILIKE '%it''s%' ESCAPE E'\\\\'")
    }

    @Test func emptiness() {
        #expect(sql(.isEmpty, my) == "(`c` IS NULL OR CAST(`c` AS CHAR) = '')")
        #expect(sql(.isEmpty, pg) == "(\"c\" IS NULL OR \"c\"::text = '')")
        #expect(sql(.isNotEmpty, my) == "(`c` IS NOT NULL AND CAST(`c` AS CHAR) <> '')")
        #expect(sql(.isNull, pg) == "\"c\" IS NULL")
        #expect(sql(.isNotNull, my) == "`c` IS NOT NULL")
    }

    @Test func comparisonsRangesAndRegex() {
        #expect(sql(.greaterThan(.integer(5)), my) == "`c` > 5")
        #expect(sql(.lessThan(.double(1.5)), pg) == "\"c\" < 1.5")
        #expect(sql(.between(.integer(1), .integer(9)), my) == "`c` BETWEEN 1 AND 9")
        #expect(sql(.dateRange(from: "2026-09-26", to: "2026-10-01"), my) == "(`c` >= '2026-09-26' AND `c` < '2026-10-01')")
        #expect(sql(.dateRange(from: "2026-09-26", to: nil), pg) == "\"c\" >= '2026-09-26'")
        #expect(sql(.dateRange(from: nil, to: "2026-10-01 10:00:00"), pg) == "\"c\" < '2026-10-01 10:00:00'")
        #expect(sql(.dateRange(from: nil, to: nil), my) == nil)
        #expect(sql(.regex("^a.*\\d$"), my) == "`c` REGEXP '^a.*\\\\d$'")
        #expect(sql(.regex("^a.*\\d$"), pg) == "\"c\"::text ~ E'^a.*\\\\d$'")
    }

    @Test func columnNamesAreQuoted() {
        #expect(sql(.isNull, my, column: "we`ird") == "`we``ird` IS NULL")
        #expect(sql(.isNull, pg, column: "we\"ird") == "\"we\"\"ird\" IS NULL")
    }

    @Test func groupCombinesEnabledFilters() {
        let a = ColumnFilter(column: "a", op: .equals(.integer(1)))
        let b = ColumnFilter(column: "b", op: .isNull)
        let off = ColumnFilter(column: "x", op: .isNull, isEnabled: false)
        #expect(FilterGroup().sql(dialect: my) == nil)
        #expect(FilterGroup(filters: [off]).sql(dialect: my) == nil)
        #expect(FilterGroup(filters: [a, off]).sql(dialect: my) == "`a` = 1")
        #expect(FilterGroup(filters: [a, b, off]).sql(dialect: my) == "((`a` = 1) AND (`b` IS NULL))")
        #expect(FilterGroup(filters: [a, b], combinator: .or).sql(dialect: pg) == "((\"a\" = 1) OR (\"b\" IS NULL))")
    }

    @Test func excludingColumnDropsOnlyThatColumn() {
        let group = FilterGroup(filters: [
            ColumnFilter(column: "Status", op: .equals(.text("x"))),
            ColumnFilter(column: "status", op: .isNotNull),
            ColumnFilter(column: "other", op: .isNull),
        ], combinator: .or)
        let rest = group.excluding(column: "STATUS")
        #expect(rest.filters.map(\.column) == ["other"])
        #expect(rest.combinator == .or)
    }
}

@Suite("Filter chips and persistence")
struct FilterChipTests {
    private func label(_ op: FilterOperator, column: String = "post_status") -> String {
        ColumnFilter(column: column, op: op).chipLabel
    }

    @Test func labels() {
        #expect(label(.isAnyOf([.text("publish")])) == "post_status is publish")
        #expect(label(.isAnyOf([.text("a"), .text("b")])) == "post_status is any of a, b")
        #expect(label(.isAnyOf([.text("a"), .text("b"), .text("c"), .text("d"), .text("e")])) == "post_status is any of a, b, c +2 more")
        #expect(label(.isNoneOf([.text("draft")])) == "post_status is not draft")
        #expect(label(.isNoneOf([.text("a"), .null])) == "post_status is none of a, NULL")
        #expect(label(.equals(.integer(5)), column: "n") == "n is 5")
        #expect(label(.equals(.text(""))) == "post_status is \"\"")
        #expect(label(.notEquals(.null)) == "post_status is not NULL")
        #expect(label(.contains("x")) == "post_status contains x")
        #expect(label(.notContains("x")) == "post_status does not contain x")
        #expect(label(.startsWith("x")) == "post_status starts with x")
        #expect(label(.endsWith("x")) == "post_status ends with x")
        #expect(label(.isEmpty) == "post_status is empty")
        #expect(label(.isNotEmpty) == "post_status is not empty")
        #expect(label(.isNull) == "post_status is NULL")
        #expect(label(.isNotNull) == "post_status is not NULL")
        #expect(label(.greaterThan(.integer(3)), column: "n") == "n > 3")
        #expect(label(.lessThan(.double(2.5)), column: "n") == "n < 2.5")
        #expect(label(.between(.integer(1), .integer(9)), column: "n") == "n between 1 and 9")
        #expect(label(.dateRange(from: "2026-09-26", to: nil), column: "post_modified") == "post_modified ≥ 2026-09-26")
        #expect(label(.dateRange(from: nil, to: "2026-10-01"), column: "d") == "d < 2026-10-01")
        #expect(label(.dateRange(from: "2026-09-26", to: "2026-10-01"), column: "d") == "d ≥ 2026-09-26 and < 2026-10-01")
        #expect(label(.regex("^a")) == "post_status matches /^a/")
    }

    @Test func everyOperatorSurvivesCodable() throws {
        let ops: [FilterOperator] = [
            .isAnyOf([.text("a"), .null, .integer(-1), .unsignedInteger(UInt64.max), .double(1.25), .bool(true), .bytes(Data([0, 255]))]),
            .isNoneOf([.text("é😀")]), .equals(.text("x")), .notEquals(.integer(2)), .contains("a%"), .notContains("b"),
            .startsWith("c"), .endsWith("d"), .isEmpty, .isNotEmpty, .isNull, .isNotNull, .greaterThan(.double(.infinity)),
            .lessThan(.integer(1)), .between(.integer(1), .text("z")), .dateRange(from: "2026-01-01", to: nil),
            .dateRange(from: nil, to: nil), .regex("^x$"),
        ]
        let group = FilterGroup(
            filters: ops.map { ColumnFilter(column: "c", op: $0) } + [ColumnFilter(column: "off", op: .isNull, isEnabled: false)],
            combinator: .or)
        let data = try JSONFileStore.makeEncoder().encode(group)
        let back = try JSONFileStore.makeDecoder().decode(FilterGroup.self, from: data)
        // +infinity is stored as text (JSON can't carry it) so it compares unequal by design; everything else is identical.
        #expect(back.combinator == .or)
        #expect(back.filters.count == group.filters.count)
        for (a, b) in zip(group.filters, back.filters) {
            if case .greaterThan = a.op { continue }
            #expect(a == b)
        }
        #expect(back.filters.last?.isEnabled == false)
    }

    @Test func databaseValueCodingRejectsGarbage() {
        let bad = Data(#"{"t":"nope"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DatabaseValue.self, from: bad) }
        let badBytes = Data(#"{"t":"bytes","v":"***"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DatabaseValue.self, from: badBytes) }
    }
}

@Suite("Saved filters store")
struct SavedFiltersStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qw-saved-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("saved-filters.json")
    }

    private let table = TableRef(schema: "wp", name: "wp_posts")

    private func sample(_ name: String, table: TableRef? = nil, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SavedFilter {
        SavedFilter(
            name: name, table: table ?? self.table,
            group: FilterGroup(filters: [ColumnFilter(column: "post_status", op: .isAnyOf([.text("publish")]))]),
            rawWhere: "ID > 5", createdAt: date)
    }

    @Test func missingFileIsEmpty() async throws {
        let store = SavedFiltersStore(fileURL: tempURL())
        #expect(try await store.filters(connectionID: UUID(), table: table).isEmpty)
    }

    @Test func savesPerConnectionAndTableAndSurvivesReload() async throws {
        let url = tempURL()
        let c1 = UUID(), c2 = UUID()
        let other = TableRef(schema: "wp", name: "wp_users")
        let a = sample("Published", date: Date(timeIntervalSince1970: 100))
        let b = sample("Newer", date: Date(timeIntervalSince1970: 200))
        let store = SavedFiltersStore(fileURL: url)
        try await store.save(b, connectionID: c1)
        try await store.save(a, connectionID: c1)
        try await store.save(sample("Users", table: other), connectionID: c1)
        try await store.save(sample("Elsewhere"), connectionID: c2)

        #expect(try await store.filters(connectionID: c1, table: table).map(\.name) == ["Published", "Newer"])
        #expect(try await store.filters(connectionID: c1, table: other).map(\.name) == ["Users"])
        #expect(try await store.filters(connectionID: c2, table: table).map(\.name) == ["Elsewhere"])
        #expect(try await store.filters(connectionID: c1).count == 3)

        let reloaded = SavedFiltersStore(fileURL: url)
        let loaded = try await reloaded.filters(connectionID: c1, table: table)
        #expect(loaded == [a, b])
        #expect(loaded.first?.rawWhere == "ID > 5")
    }

    @Test func fileIsOwnerOnly() async throws {
        let url = tempURL()
        let store = SavedFiltersStore(fileURL: url)
        try await store.save(sample("x"), connectionID: UUID())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func saveReplacesSameIDAndDeleteWorks() async throws {
        let store = SavedFiltersStore(fileURL: tempURL())
        let c = UUID()
        var filter = sample("one")
        try await store.save(filter, connectionID: c)
        filter.name = "renamed"
        try await store.save(filter, connectionID: c)
        #expect(try await store.filters(connectionID: c, table: table).map(\.name) == ["renamed"])
        try await store.delete(id: filter.id, connectionID: UUID())  // other connection: no-op
        #expect(try await store.filters(connectionID: c, table: table).count == 1)
        try await store.delete(id: filter.id, connectionID: c)
        #expect(try await store.filters(connectionID: c, table: table).isEmpty)
    }

    @Test func deleteAllForConnection() async throws {
        let store = SavedFiltersStore(fileURL: tempURL())
        let c1 = UUID(), c2 = UUID()
        try await store.save(sample("a"), connectionID: c1)
        try await store.save(sample("b"), connectionID: c2)
        try await store.deleteAll(connectionID: c1)
        #expect(try await store.filters(connectionID: c1).isEmpty)
        #expect(try await store.filters(connectionID: c2).count == 1)
    }

    @Test func corruptFileIsReportedAndNeverOverwritten() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let store = SavedFiltersStore(fileURL: url)
        await #expect(throws: SavedFiltersError.self) { try await store.save(self.sample("x"), connectionID: UUID()) }
        #expect(try Data(contentsOf: url) == Data("{not json".utf8))
    }

    @Test func newerSchemaVersionIsRefused() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99,"entries":[]}"#.utf8).write(to: url)
        let store = SavedFiltersStore(fileURL: url)
        await #expect(throws: SavedFiltersError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try await store.save(self.sample("x"), connectionID: UUID())
        }
    }

    @Test func appDirectoriesExposesTheFileName() throws {
        let url = try AppDirectories.savedFiltersFileURL(appName: "QuerywellTests-\(UUID().uuidString)")
        #expect(url.lastPathComponent == "saved-filters.json")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: - Integration: filters and distinct values against real servers

@Suite("Filters and distinct values integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct FilterIntegrationTests {
    private func makeItems(_ f: SchemaFixture) async throws -> String {
        let table = "\(f.q).items"
        let datetime = f.target.isPostgres ? "timestamp" : "datetime"
        try await f.run(
            """
            CREATE TABLE \(table) (id int PRIMARY KEY, name varchar(50) NOT NULL, qty int NOT NULL, \
            note varchar(50), created \(datetime) NOT NULL)
            """)
        let d = f.dialect
        let rows: [(Int, String, Int, String?, String)] = [
            (1, "alpha", 10, "x", "2026-09-01 10:00:00"),
            (2, "beta", 20, nil, "2026-09-15 00:00:00"),
            (3, "gamma%", 30, "", "2026-09-26 00:00:00"),
            (4, "delta_x", 40, "y", "2026-10-01 00:00:00"),
            (5, "ALPHA beta", 50, nil, "2026-10-10 12:00:00"),
            (6, "o'brien\\", 60, "x", "2026-11-01 00:00:00"),
            (7, "eta", 0, "x", "2026-08-01 00:00:00"),
        ]
        for r in rows {
            let note = r.3.map { d.quoteString($0) } ?? "NULL"
            try await f.run("INSERT INTO \(table) VALUES (\(r.0), \(d.quoteString(r.1)), \(r.2), \(note), \(d.quoteString(r.4)))")
        }
        return table
    }

    private func ids(_ f: SchemaFixture, _ op: FilterOperator, column: String = "name", raw: String? = nil) async throws -> [Int64] {
        var group = FilterGroup()
        group.filters = [ColumnFilter(column: column, op: op)]
        return try await ids(f, group, raw: raw)
    }

    private func ids(_ f: SchemaFixture, _ group: FilterGroup, raw: String? = nil) async throws -> [Int64] {
        let q = TableQuery(
            table: f.ref("items"), columns: ["id"], filter: group, rawWhere: raw, sort: [SortKey(column: "id")],
            limit: 100, primaryKey: ["id"])
        let result = try await f.session.execute(q.sql(dialect: f.dialect))
        let count = try await f.session.execute(q.countSQL(dialect: f.dialect))
        let list = result.rows.compactMap { Record.int(from: $0[0]) }
        #expect(Record.int(from: count.rows[0][0]) == Int64(list.count), "COUNT(*) must match the page")
        return list
    }

    @Test(arguments: DBTarget.all)
    func everyOperatorExecutesWithExpectedRows(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            _ = try await makeItems(f)
            let pgx = target.isPostgres

            #expect(try await ids(f, .isAnyOf([.text("alpha"), .text("beta")])) == [1, 2])
            #expect(try await ids(f, .isNoneOf([.text("alpha")])) == [2, 3, 4, 5, 6, 7])
            #expect(try await ids(f, .isAnyOf([.text("x"), .null]), column: "note") == [1, 2, 5, 6, 7])
            #expect(try await ids(f, .isNoneOf([.text("x")]), column: "note") == [2, 3, 4, 5])
            #expect(try await ids(f, .equals(.null), column: "note") == [2, 5])
            #expect(try await ids(f, .notEquals(.text("x")), column: "note") == [2, 3, 4, 5])
            #expect(try await ids(f, .notEquals(.null), column: "note") == [1, 3, 4, 6, 7])
            #expect(try await ids(f, .equals(.integer(30)), column: "qty") == [3])

            #expect(try await ids(f, .contains("a")) == [1, 2, 3, 4, 5, 7])
            #expect(try await ids(f, .contains("%")) == [3])  // not a wildcard
            #expect(try await ids(f, .contains("_")) == [4])  // not a wildcard
            #expect(try await ids(f, .contains("'")) == [6])
            #expect(try await ids(f, .contains("\\")) == [6])
            #expect(try await ids(f, .contains("ma%")) == [3])
            #expect(try await ids(f, .notContains("a")) == [6])
            #expect(try await ids(f, .startsWith("al")) == [1, 5])
            #expect(try await ids(f, .endsWith("_x")) == [4])
            #expect(try await ids(f, .startsWith("o'b")) == [6])
            #expect(try await ids(f, .endsWith("\\")) == [6])

            #expect(try await ids(f, .isEmpty, column: "note") == [2, 3, 5])
            #expect(try await ids(f, .isNotEmpty, column: "note") == [1, 4, 6, 7])
            #expect(try await ids(f, .isEmpty, column: "qty") == [])  // 0 is not empty
            #expect(try await ids(f, .isNotEmpty, column: "qty") == [1, 2, 3, 4, 5, 6, 7])
            #expect(try await ids(f, .isNull, column: "note") == [2, 5])
            #expect(try await ids(f, .isNotNull, column: "note") == [1, 3, 4, 6, 7])

            #expect(try await ids(f, .greaterThan(.integer(40)), column: "qty") == [5, 6])
            #expect(try await ids(f, .lessThan(.integer(20)), column: "qty") == [1, 7])
            #expect(try await ids(f, .between(.integer(20), .integer(40)), column: "qty") == [2, 3, 4])

            #expect(try await ids(f, .dateRange(from: "2026-09-15", to: "2026-10-01"), column: "created") == [2, 3])
            #expect(try await ids(f, .dateRange(from: "2026-10-01", to: nil), column: "created") == [4, 5, 6])
            #expect(try await ids(f, .dateRange(from: nil, to: "2026-09-01"), column: "created") == [7])
            #expect(try await ids(f, .dateRange(from: "2026-09-01 10:00:00", to: "2026-09-01 10:00:01"), column: "created") == [1])

            #expect(try await ids(f, .regex("^(alpha|beta)$")) == [1, 2])
            // Case sensitivity differs by design: MySQL follows the (ci) collation, Postgres `~` is exact.
            #expect(try await ids(f, .regex("^a")) == (pgx ? [1] : [1, 5]))
        }
    }

    @Test(arguments: DBTarget.all)
    func combinatorsDisabledFiltersAndRawWhere(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            _ = try await makeItems(f)
            let noteX = ColumnFilter(column: "note", op: .equals(.text("x")))
            let bigQty = ColumnFilter(column: "qty", op: .greaterThan(.integer(5)))
            let isNullNote = ColumnFilter(column: "note", op: .isNull)
            #expect(try await ids(f, FilterGroup(filters: [noteX, bigQty])) == [1, 6])
            #expect(try await ids(f, FilterGroup(filters: [noteX, isNullNote], combinator: .or)) == [1, 2, 5, 6, 7])
            var off = isNullNote
            off.isEnabled = false
            #expect(try await ids(f, FilterGroup(filters: [noteX, off])) == [1, 6, 7])
            // OR group stays grouped when ANDed with the raw WHERE.
            #expect(try await ids(f, FilterGroup(filters: [noteX, isNullNote], combinator: .or), raw: "WHERE qty >= 50;") == [5, 6])
            #expect(try await ids(f, FilterGroup(), raw: "qty = 10 -- trailing comment") == [1])
        }
    }

    @Test(arguments: DBTarget.all)
    func pagingIsDeterministicWithTiebreaker(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let table = "\(f.q).paged"
            try await f.run("CREATE TABLE \(table) (id int PRIMARY KEY, grp int NOT NULL)")
            for i in 1...30 { try await f.run("INSERT INTO \(table) VALUES (\(i), \(i % 3))") }
            var seen: [Int64] = []
            for page in 0..<3 {
                let q = TableQuery(
                    table: f.ref("paged"), columns: ["id"], sort: [SortKey(column: "grp", ascending: false)],
                    limit: 10, offset: page * 10, primaryKey: ["id"])
                let result = try await f.session.execute(q.sql(dialect: f.dialect))
                seen += result.rows.compactMap { Record.int(from: $0[0]) }
            }
            #expect(seen.count == 30 && Set(seen).count == 30)
            // The primary-key tiebreak follows the sort direction (DESC, DESC) so an index can serve the whole order.
            #expect(Array(seen.prefix(10)) == [29, 26, 23, 20, 17, 14, 11, 8, 5, 2])
        }
    }

    // MARK: distinct values

    @Test(arguments: DBTarget.all)
    func distinctValuesCountsOrderingAndTruncation(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            _ = try await makeItems(f)
            let all = try await DistinctValuesQuery(table: f.ref("items"), column: "note").run(on: f.session)
            #expect(all.values == [
                DistinctValue(value: .text("x"), count: 3),
                DistinctValue(value: .null, count: 2),
                DistinctValue(value: .text(""), count: 1),
                DistinctValue(value: .text("y"), count: 1),
            ])
            #expect(!all.isTruncated)

            let top3 = try await DistinctValuesQuery(table: f.ref("items"), column: "note", limit: 3).run(on: f.session)
            #expect(top3.values.count == 3)
            #expect(top3.isTruncated)
            #expect(top3.values.map(\.count) == [3, 2, 1])
            let exact = try await DistinctValuesQuery(table: f.ref("items"), column: "note", limit: 4).run(on: f.session)
            #expect(exact.values.count == 4 && !exact.isTruncated)
        }
    }

    @Test(arguments: DBTarget.all)
    func distinctValuesIgnoreOwnFilterButHonourOthers(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            _ = try await makeItems(f)
            let group = FilterGroup(filters: [
                ColumnFilter(column: "note", op: .equals(.text("y"))),
                ColumnFilter(column: "qty", op: .greaterThan(.integer(25))),
            ])
            let result = try await DistinctValuesQuery(table: f.ref("items"), column: "note", filter: group).run(on: f.session)
            // qty > 25 → ids 3 (''), 4 (y), 5 (NULL), 6 (x); the note = 'y' chip must not hide the others.
            #expect(result.values.count == 4)
            #expect(result.values.allSatisfy { $0.count == 1 })
            #expect(result.values.map(\.value) == [.text(""), .text("x"), .text("y"), .null])

            let withRaw = try await DistinctValuesQuery(table: f.ref("items"), column: "note", filter: group, rawWhere: "qty < 55")
                .run(on: f.session)
            #expect(Set(withRaw.values.map(\.value)) == [.text(""), .text("y"), .null])
        }
    }

    @Test(arguments: DBTarget.all)
    func distinctValuesSearch(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            _ = try await makeItems(f)
            let table = f.ref("items")
            let x = try await DistinctValuesQuery(table: table, column: "note", search: "X").run(on: f.session)
            if target.isPostgres {
                #expect(x.values == [DistinctValue(value: .text("x"), count: 3)])  // ILIKE
            } else {
                #expect(x.values == [DistinctValue(value: .text("x"), count: 3)])  // ci collation
            }
            let numeric = try await DistinctValuesQuery(table: table, column: "qty", search: "3").run(on: f.session)
            #expect(numeric.values == [DistinctValue(value: .integer(30), count: 1)])
            let percent = try await DistinctValuesQuery(table: table, column: "name", search: "%").run(on: f.session)
            #expect(percent.values.map(\.value) == [.text("gamma%")])
            let quote = try await DistinctValuesQuery(table: table, column: "name", search: "o'b").run(on: f.session)
            #expect(quote.values.map(\.value) == [.text("o'brien\\")])
            let none = try await DistinctValuesQuery(table: table, column: "name", search: "zzz").run(on: f.session)
            #expect(none.values.isEmpty && !none.isTruncated)
            // Empty search text behaves like no search.
            let blank = try await DistinctValuesQuery(table: table, column: "note", search: "").run(on: f.session)
            #expect(blank.values.count == 4)
        }
    }

    @Test func distinctSQLShape() {
        let q = DistinctValuesQuery(
            table: TableRef(schema: "s", name: "t"), column: "c", filter: FilterGroup(filters: [
                ColumnFilter(column: "c", op: .isNull), ColumnFilter(column: "d", op: .equals(.integer(1))),
            ]), search: "a_b", limit: 10)
        #expect(q.sql(dialect: my)
            == "SELECT `c` AS qw_value, COUNT(*) AS qw_count FROM `s`.`t` WHERE `d` = 1 AND CAST(`c` AS CHAR) LIKE '%a\\\\_b%' ESCAPE '\\\\' GROUP BY `c` ORDER BY qw_count DESC, (`c` IS NULL) ASC, `c` ASC LIMIT 11")
        #expect(q.sql(dialect: pg).contains("\"c\"::text ILIKE '%a\\_b%'") == false)  // Postgres uses an E-string for the backslash
        #expect(q.sql(dialect: pg).contains("ILIKE E'%a\\\\_b%' ESCAPE E'\\\\'"))
    }
}
