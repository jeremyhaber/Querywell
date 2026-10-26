import Foundation
import Testing

@testable import QuerywellCore

@Suite("Distinct values: sampling SQL")
struct DistinctSamplingSQLTests {
    let t = TableRef(schema: "wp", name: "big")

    @Test func limitSampleCountsTheFirstRowsAfterFilters() {
        var q = DistinctValuesQuery(table: t, column: "post_name", rawWhere: "post_author = 3", search: "ab", limit: 10)
        q.filter = nil
        let sql = q.sql(dialect: SQLDialect(.mysql), source: .limitSample(100_000))
        #expect(sql.hasPrefix("SELECT qw_value, COUNT(*) AS qw_count FROM (SELECT `post_name` AS qw_value FROM `wp`.`big` WHERE "))
        #expect(sql.contains("LIMIT 100000) AS qw_sample GROUP BY qw_value ORDER BY qw_count DESC, (qw_value IS NULL) ASC, qw_value ASC LIMIT 11"))
    }

    @Test func tableSampleIsPostgresOnly() {
        let q = DistinctValuesQuery(table: t, column: "post_name")
        let sql = q.sql(dialect: SQLDialect(.postgresql), source: .tableSample(percent: 10))
        #expect(sql.contains("FROM \"wp\".\"big\" TABLESAMPLE SYSTEM (10.0000) GROUP BY \"post_name\""))
    }

    @Test func exactSQLUnchanged() {
        let q = DistinctValuesQuery(table: t, column: "s", limit: 5)
        #expect(q.sql(dialect: SQLDialect(.mysql))
            == "SELECT `s` AS qw_value, COUNT(*) AS qw_count FROM `wp`.`big` GROUP BY `s` ORDER BY qw_count DESC, (`s` IS NULL) ASC, `s` ASC LIMIT 6")
    }
}

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

@Suite("Distinct values: timeout and sample", .serialized, .enabled(if: integrationEnabled))
struct DistinctSamplingIntegrationTests {
    @Test("an exact query that hits the limit falls back to a sample; a fast one stays exact", arguments: DBTarget.all)
    func fallback(_ target: DBTarget) async throws {
        try await SchemaFixture.with(target) { fx in
            if target.isPostgres {
                try await fx.run("CREATE TABLE \(fx.q).t (id bigint PRIMARY KEY, v text)")
                try await fx.run("INSERT INTO \(fx.q).t SELECT i, 'v' || (i % 40) FROM generate_series(1, 300000) i")
                try await fx.run("ANALYZE \(fx.q).t")
            } else {
                try await fx.run("CREATE TABLE \(fx.q).t (id bigint PRIMARY KEY, v varchar(20)) ENGINE=InnoDB")
                try await fx.run(target.engine == .mariadb
                    ? "SET SESSION max_recursive_iterations = 400000" : "SET SESSION cte_max_recursion_depth = 400000")
                try await fx.run("INSERT INTO \(fx.q).t SELECT i, CONCAT('v', i % 40) FROM (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300000) SELECT i FROM n) x")
            }
            let query = DistinctValuesQuery(table: fx.ref("t"), column: "v", limit: 100)
            let aux = try await target.connectPrivileged()
            // Generous limit: exact.
            let exact = try await query.run(on: aux, policy: DistinctValuesPolicy(timeout: .seconds(30), sampleRows: 5000))
            #expect(exact.sampledRows == nil)
            #expect(exact.values.count == 40)
            #expect(exact.values.reduce(0) { $0 + $1.count } == 300_000)
            // A 1 ms limit can't finish a 300k-row GROUP BY: sampled.
            let sampled = try await query.run(
                on: aux, policy: DistinctValuesPolicy(timeout: .milliseconds(1), sampleRows: 5000, estimatedRows: 300_000))
            #expect(sampled.sampledRows == 5000)
            #expect(sampled.values.count > 20)
            let sampleTotal = sampled.values.reduce(0) { $0 + $1.count }
            // MySQL/MariaDB take exactly N rows; Postgres' block sampling is approximate.
            if target.isPostgres { #expect(sampleTotal > 500 && sampleTotal < 50_000, "got \(sampleTotal)") } else { #expect(sampleTotal == 5000) }
            // The connection is usable afterwards (Postgres transaction rolled back).
            #expect(try await aux.execute("SELECT 1").rows.count == 1)
            await aux.close()
        }
    }
}
