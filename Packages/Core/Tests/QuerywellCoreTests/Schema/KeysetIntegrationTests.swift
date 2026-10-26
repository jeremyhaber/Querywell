import Foundation
import Testing

@testable import QuerywellCore

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

@Suite("Keyset paging against real servers", .serialized, .enabled(if: integrationEnabled))
struct KeysetIntegrationTests {
    private func ids(_ result: QueryResult) -> [Int64] {
        result.rows.compactMap { Record.int(from: $0[0]) }
    }

    @Test("forward, backward and last pages equal the OFFSET pages", arguments: DBTarget.all)
    func walk(_ target: DBTarget) async throws {
        try await SchemaFixture.with(target) { fx in
            let dialect = fx.dialect
            let q = fx.q
            if target.isPostgres {
                try await fx.run("CREATE TABLE \(q).t (id bigint PRIMARY KEY, grp int NOT NULL, label varchar(20) NOT NULL)")
                try await fx.run("CREATE INDEX t_grp ON \(q).t (grp)")
                try await fx.run("INSERT INTO \(q).t SELECT i, i % 4, 'it''s ' || i FROM generate_series(1, 53) i")
            } else {
                try await fx.run("CREATE TABLE \(q).t (id bigint PRIMARY KEY, grp int NOT NULL, label varchar(20) NOT NULL, KEY t_grp (grp)) ENGINE=InnoDB")
                for chunk in stride(from: 1, through: 53, by: 20) {
                    let rows = (chunk..<min(chunk + 20, 54)).map { "(\($0), \($0 % 4), 'it\\'s \($0)')" }.joined(separator: ",")
                    try await fx.run("INSERT INTO \(q).t VALUES \(rows)")
                }
            }
            let structure = try await fx.inspector.structure(of: fx.ref("t"))
            for sort in [[SortKey](), [SortKey(column: "id", ascending: false)], [SortKey(column: "grp")], [SortKey(column: "grp", ascending: false)]] {
                guard let order = structure.keysetOrder(for: sort) else { Issue.record("not eligible: \(sort)"); continue }
                func offsetPage(_ n: Int) async throws -> [Int64] {
                    ids(try await fx.session.execute(
                        TableQuery(table: fx.ref("t"), columns: ["id"], sort: sort, limit: 10, offset: n * 10, primaryKey: ["id"]).sql(dialect: dialect)))
                }
                func keyset(_ page: KeysetPage) async throws -> QueryResult {
                    try await fx.session.execute(TableQuery(table: fx.ref("t"), columns: ["id", "grp"], limit: 10, keyset: page).sql(dialect: dialect))
                }
                func boundary(_ r: [DatabaseValue]) -> [DatabaseValue] {
                    order.map { key in key.column == "id" ? r[0] : r[1] }
                }
                // Forward through all six pages (the sort's total order is (grp, id) / (id) in one direction).
                var cursor: [DatabaseValue]?
                var forwardPages: [[Int64]] = []
                var firstRows: [[DatabaseValue]] = []
                for _ in 0..<6 {
                    let r = try await keyset(KeysetPage(order: order, direction: .forward, boundary: cursor))
                    forwardPages.append(ids(r))
                    firstRows.append(r.rows.first ?? [])
                    cursor = r.rows.last.map(boundary)
                }
                for (n, page) in forwardPages.enumerated() {
                    // The OFFSET order differs from keyset order only in the tiebreak direction for DESC sorts, which TableQuery now aligns.
                    #expect(page == (try await offsetPage(n)), "page \(n) sort \(sort)")
                }
                #expect(forwardPages.joined().count == 53)
                // Backward from page 4's first row yields page 3 (rows reversed to display order).
                let back = try await keyset(KeysetPage(order: order, direction: .backward, boundary: boundary(firstRows[3])))
                #expect(Array(ids(back).reversed()) == forwardPages[2], "prev sort \(sort)")
                // Last page = the final ten rows.
                let last = try await keyset(KeysetPage(order: order, direction: .backward))
                #expect(Array(ids(last).reversed()) == Array(forwardPages.joined().suffix(10)), "last sort \(sort)")
            }
            // Quoting: a text boundary with an apostrophe (not index-served here, so use the fixture's varchar column directly).
            let label = TableQuery(
                table: fx.ref("t"), columns: ["id"], limit: 3,
                keyset: KeysetPage(order: [SortKey(column: "label"), SortKey(column: "id")], boundary: [.text("it's 12"), .integer(12)]))
            let r = try await fx.session.execute(label.sql(dialect: dialect))
            #expect(r.rows.count == 3)
        }
    }
}
