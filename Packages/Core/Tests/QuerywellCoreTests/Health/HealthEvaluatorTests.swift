import Foundation
import Testing

@testable import QuerywellCore

@Suite("Health metrics")
struct HealthEvaluatorTests {
    private let evaluator = HealthEvaluator()

    @Test("byte sizes parse MySQL and PostgreSQL spellings and format both ways")
    func byteSizes() {
        #expect(ByteSize.parse("134217728") == 134_217_728)
        #expect(ByteSize.parse("128MB") == 128 * MiBytes)
        #expect(ByteSize.parse("8kB") == 8192)
        #expect(ByteSize.parse("4G") == 4 * GiBytes)
        #expect(ByteSize.parse("1.5 GiB") == GiBytes * 3 / 2)
        #expect(ByteSize.parse("fast") == nil)
        #expect(ByteSize.pretty(4 * GiBytes) == "4 GiB")
        #expect(ByteSize.pretty(1536 * 1024) == "1.5 MiB")
        #expect(ByteSize.postgresValue(4 * GiBytes) == "4GB")
        #expect(ByteSize.postgresValue(192 * MiBytes) == "192MB")
        #expect(ByteSize.postgresValue(65_536) == "64kB")
    }

    @Test("a healthy MySQL server is all OK")
    func healthyMySQL() {
        let s = evaluator.evaluate(HealthFixture.mysql())
        #expect(s.metric("connections")?.status == .ok)
        #expect(s.metric("connections")?.value == "10 of 151")
        #expect(s.metric("bufferPoolHit")?.status == .ok)
        #expect(s.metric("slowQueries")?.status == .ok)
        #expect(s.metric("tmpDisk")?.status == .ok)
        #expect(s.metric("tableOpenMisses")?.status == .ok)
        #expect(s.metric("qps")?.value == "100.0")
        #expect(s.list("noPrimaryKey")?.status == .ok)
        #expect(s.overall != .critical)
    }

    @Test("connection usage crosses warn and critical")
    func connectionThresholds() {
        let warn = evaluator.evaluate(HealthFixture.mysql(status: ["threads_connected": "110"]))
        #expect(warn.metric("connections")?.status == .warn)
        let critical = evaluator.evaluate(HealthFixture.mysql(status: ["threads_connected": "145"]))
        #expect(critical.metric("connections")?.status == .critical)
        let peak = evaluator.evaluate(HealthFixture.mysql(status: ["max_used_connections": "150"]))
        #expect(peak.metric("maxUsedConnections")?.status == .critical)
        #expect(critical.overall == .critical)
    }

    @Test("buffer pool hit ratio, coverage and temp-table spill are judged")
    func innodbAndTmp() {
        let f = HealthFixture.mysql(status: ["innodb_buffer_pool_reads": "30000", "created_tmp_disk_tables": "600"])
        let s = evaluator.evaluate(f)
        #expect(s.metric("bufferPoolHit")?.status == .warn)  // 97%: below 99%, above 95%
        #expect(s.metric("tmpDisk")?.status == .critical)
        // 128 MiB pool vs 2 GiB of InnoDB data = 6%: warn (below 25%).
        #expect(s.metric("bufferPoolSize")?.status == .warn)
    }

    @Test("a hit ratio of 98% is a warning, 94% critical")
    func hitRatioBands() {
        let warn = evaluator.evaluate(HealthFixture.mysql(status: ["innodb_buffer_pool_reads": "20000"]))
        #expect(warn.metric("bufferPoolHit")?.status == .warn)
        let critical = evaluator.evaluate(HealthFixture.mysql(status: ["innodb_buffer_pool_reads": "60000"]))
        #expect(critical.metric("bufferPoolHit")?.status == .critical)
    }

    @Test("counters with too few events are info, not a verdict")
    func smallSamples() {
        let s = evaluator.evaluate(HealthFixture.mysql(status: [
            "innodb_buffer_pool_reads": "50", "innodb_buffer_pool_read_requests": "100", "uptime": "60"]))
        #expect(s.metric("bufferPoolHit")?.status == .info)
    }

    @Test("missing privileges show Not available instead of failing the page")
    func unavailableSections() {
        var f = HealthFixture.mysql()
        f.status = [:]
        f.uptimeSeconds = nil
        f.dataBytes = nil
        f.indexBytes = nil
        f.innodbBytes = nil
        f.tablesWithoutPrimaryKey = nil
        f.largestTables = nil
        f.nonInnoDBTables = nil
        f.unavailable = ["status": "Access denied", "storage": "SELECT command denied", "noPrimaryKey": "denied"]
        let s = evaluator.evaluate(f)
        #expect(s.metric("uptime")?.status == .unavailable)
        #expect(s.metric("connections")?.status == .unavailable)
        #expect(s.metric("dataSize")?.value == "Not available")
        #expect(s.metric("dataSize")?.detail?.contains("SELECT command denied") == true)
        #expect(s.list("noPrimaryKey")?.status == .unavailable)
        #expect(s.list("noPrimaryKey")?.summary == "denied")
        // Unavailable never counts as a problem on its own.
        #expect(s.overall != .critical)
    }

    @Test("tables without primary key and non-InnoDB tables warn")
    func tableLists() {
        var f = HealthFixture.mysql()
        f.tablesWithoutPrimaryKey = ["shop.log", "shop.tmp"]
        f.nonInnoDBTables = ["legacy.hits (MyISAM)"]
        let s = evaluator.evaluate(f)
        #expect(s.list("noPrimaryKey")?.status == .warn)
        #expect(s.list("noPrimaryKey")?.rows.count == 2)
        #expect(s.list("nonInnoDB")?.status == .warn)
        #expect(s.list("largestTables")?.rows.first?.title == "shop.orders")
    }

    @Test("old versions get a hedged support note")
    func versionNotes() {
        #expect(evaluator.evaluate(HealthFixture.mysql(major: 5, minor: 7)).metric("version")?.status == .warn)
        #expect(evaluator.evaluate(HealthFixture.mysql(major: 8, minor: 4)).metric("version")?.status == .info)
        #expect(evaluator.evaluate(HealthFixture.mariadb()).metric("version")?.status == .info)
        #expect(evaluator.evaluate(HealthFixture.postgres(major: 12)).metric("version")?.status == .warn)
        #expect(evaluator.evaluate(HealthFixture.postgres()).metric("version")?.status == .info)
    }

    @Test("MariaDB without cache hit counters falls back to Opened_tables per hour")
    func tableOpenFallback() {
        var f = HealthFixture.mariadb()
        f.status["table_open_cache_hits"] = nil
        f.status["table_open_cache_misses"] = nil
        f.status["opened_tables"] = "400000"
        let s = evaluator.evaluate(f)
        #expect(s.metric("tableOpenMisses")?.status == .warn)
    }

    // MARK: PostgreSQL

    @Test("a healthy PostgreSQL server")
    func healthyPostgres() {
        let s = evaluator.evaluate(HealthFixture.postgres())
        #expect(s.metric("connections")?.value == "20 of 100")
        #expect(s.metric("connections")?.status == .ok)
        #expect(s.metric("cacheHit")?.status == .ok)
        #expect(s.metric("rollbackShare")?.status == .ok)
        #expect(s.metric("deadlocks")?.status == .ok)
        #expect(s.metric("databaseSize")?.value == "4 GiB")
        #expect(s.list("unusedIndexes")?.status == .ok)
    }

    @Test("PostgreSQL thresholds: connections, cache, rollbacks, deadlocks, temp files")
    func postgresThresholds() {
        var f = HealthFixture.postgres()
        f.activeConnections = 95
        f.postgresStats = PostgresDatabaseStats(
            blocksHit: 900_000, blocksRead: 100_000, commits: 70_000, rollbacks: 30_000, deadlocks: 12,
            tempFiles: 400, tempBytes: 2 * GiBytes, databaseBytes: GiBytes)
        let s = evaluator.evaluate(f)
        #expect(s.metric("connections")?.status == .critical)  // 95 of 97 usable
        #expect(s.metric("cacheHit")?.status == .critical)  // 90%
        #expect(s.metric("rollbackShare")?.status == .critical)  // 30%
        #expect(s.metric("deadlocks")?.status == .critical)
        #expect(s.metric("tempFiles")?.status == .warn)
    }

    @Test("dead tuples and unused indexes are listed with their status")
    func postgresLists() {
        var f = HealthFixture.postgres()
        f.deadTupleTables = [
            DeadTupleEntry(schema: "public", name: "jobs", liveTuples: 100_000, deadTuples: 150_000, lastAutovacuum: nil),
            DeadTupleEntry(schema: "public", name: "fine", liveTuples: 1_000_000, deadTuples: 5_000),
            DeadTupleEntry(schema: "public", name: "tiny", liveTuples: 1, deadTuples: 50),
        ]
        f.unusedIndexes = [UnusedIndexEntry(schema: "public", table: "jobs", index: "jobs_old_idx", bytes: 200 * MiBytes)]
        let s = evaluator.evaluate(f)
        let dead = s.list("deadTuples")
        #expect(dead?.rows.map(\.title) == ["public.jobs"])
        #expect(dead?.status == .critical)
        #expect(dead?.rows.first?.detail.contains("never") == true)
        #expect(s.list("unusedIndexes")?.status == .warn)
    }

    @Test("PostgreSQL pg_settings values are shown in a form ALTER SYSTEM accepts")
    func postgresDisplayValues() {
        #expect(HealthCollector.postgresDisplayValue(setting: "16384", unit: "8kB") == "128MB")
        #expect(HealthCollector.postgresDisplayValue(setting: "4096", unit: "kB") == "4MB")
        #expect(HealthCollector.postgresDisplayValue(setting: "524288", unit: "kB") == "512MB")
        #expect(HealthCollector.postgresDisplayValue(setting: "300", unit: "s") == "300s")
        #expect(HealthCollector.postgresDisplayValue(setting: "-1", unit: "ms") == "-1")
        #expect(HealthCollector.postgresDisplayValue(setting: "0.9", unit: nil) == "0.9")
        #expect(HealthCollector.postgresDisplayValue(setting: "on", unit: nil) == "on")
    }
}
