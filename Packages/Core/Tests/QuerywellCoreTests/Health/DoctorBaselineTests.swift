import Foundation
import Testing

@testable import QuerywellCore

@Suite("Doctor baseline rules")
struct DoctorBaselineTests {
    private let doctor = DoctorEvaluator()

    private func finding(_ report: DoctorReport, _ id: String) -> DoctorFinding? { report.findings.first { $0.ruleID == id } }

    @Test("rule ids are unique and every rule explains itself")
    func catalogue() {
        let ids = DoctorBaseline.rules.map(\.id)
        #expect(Set(ids).count == ids.count)
        for rule in DoctorBaseline.rules {
            #expect(rule.rationale.count > 40, "\(rule.id) needs a plain-language rationale")
            #expect(SettingSQL.isValidVariableName(rule.variable))
        }
    }

    @Test("a MySQL server with defaults gets the expected recommendations")
    func mysqlDefaults() {
        let report = doctor.evaluate(HealthFixture.mysql())
        let ids = Set(report.recommendations.map(\.ruleID))
        #expect(ids.contains("my.slow_query_log"))
        #expect(ids.contains("my.long_query_time"))
        #expect(!ids.contains("my.innodb_flush_log_at_trx_commit"))
        #expect(!ids.contains("my.character_set_server"))
        #expect(!ids.contains("my.sql_mode"))
        #expect(!ids.contains("my.tmp_table_size"))
        // Rules for other engines never show up.
        #expect(report.findings.allSatisfy { $0.ruleID.hasPrefix("my.") })
        let slow = finding(report, "my.slow_query_log")
        #expect(slow?.recommendedValue == "ON")
        #expect(slow?.currentValue == "OFF")
        #expect(slow?.scopes == [.persist, .runtime])
    }

    @Test("flush, file-per-table, charset and strict mode")
    func durabilityAndEncoding() {
        let f = HealthFixture.mysql([
            "innodb_flush_log_at_trx_commit": "2", "innodb_file_per_table": "OFF", "character_set_server": "latin1",
            "sql_mode": "NO_ENGINE_SUBSTITUTION",
        ])
        let r = doctor.evaluate(f)
        #expect(finding(r, "my.innodb_flush_log_at_trx_commit")?.recommendedValue == "1")
        #expect(finding(r, "my.innodb_file_per_table")?.recommendedValue == "ON")
        #expect(finding(r, "my.character_set_server")?.recommendedValue == "utf8mb4")
        #expect(finding(r, "my.sql_mode")?.recommendedValue == "NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES")
    }

    @Test("tmp_table_size and max_heap_table_size must match; the fix targets the smaller one")
    func tmpTables() {
        let small = doctor.evaluate(HealthFixture.mysql(["tmp_table_size": "16777216", "max_heap_table_size": "67108864"]))
        let a = finding(small, "my.tmp_table_size")
        #expect(a?.variable == "tmp_table_size")
        #expect(a?.recommendedValue == "67108864")
        let big = doctor.evaluate(HealthFixture.mysql(["tmp_table_size": "134217728", "max_heap_table_size": "16777216"]))
        let b = finding(big, "my.tmp_table_size")
        #expect(b?.variable == "max_heap_table_size")
        #expect(b?.recommendedValue == "134217728")
        #expect(b?.currentValue == "16777216")
    }

    @Test("max_connections is raised only when the peak is close to the limit")
    func maxConnections() {
        let calm = doctor.evaluate(HealthFixture.mysql(status: ["max_used_connections": "100"]))
        #expect(finding(calm, "my.max_connections")?.state == .ok)
        let busy = doctor.evaluate(HealthFixture.mysql(status: ["max_used_connections": "148"]))
        let f = finding(busy, "my.max_connections")
        #expect(f?.state == .recommendation)
        #expect(f?.recommendedValue == "251")
        #expect(f?.restartRequired == false)
    }

    @Test("the buffer pool rule needs RAM and says so")
    func bufferPoolNeedsRAM() {
        let f = HealthFixture.mysql(status: ["innodb_buffer_pool_reads": "50000"])
        let without = doctor.evaluate(f)
        let w = finding(without, "my.innodb_buffer_pool_size")
        #expect(w?.state == .needsInput)
        #expect(w?.needsServerRAM == true)
        #expect(w?.note?.contains("RAM") == true)
        #expect(w?.change() == nil)

        let with = doctor.evaluate(f, inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes))
        let r = finding(with, "my.innodb_buffer_pool_size")
        #expect(r?.state == .recommendation)
        // 2 GiB of data + 25% = 2.5 GiB, below 60% of 16 GiB.
        #expect(r?.recommendedValue == String(Int64(2.5 * Double(GiBytes))))
        #expect(r?.scopes.first == .persist)
    }

    @Test("a buffer pool that holds all data is fine; one that eats the RAM is flagged")
    func bufferPoolBounds() {
        var f = HealthFixture.mysql(["innodb_buffer_pool_size": String(4 * GiBytes)])
        #expect(finding(doctor.evaluate(f, inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes)), "my.innodb_buffer_pool_size")?.state == .ok)
        f.variables["innodb_buffer_pool_size"] = String(15 * GiBytes)
        let big = finding(doctor.evaluate(f, inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes)), "my.innodb_buffer_pool_size")
        #expect(big?.state == .recommendation)
        #expect(big?.note?.contains("swapping") == true)
        // 60% of 16 GiB rounded down to 128 MiB.
        #expect(Int64(big?.recommendedValue ?? "") == ByteSize.roundDown(Int64(Double(16 * GiBytes) * 0.6), to: 128 * MiBytes))
    }

    @Test("MySQL 8.0.30+ checks innodb_redo_log_capacity, not innodb_log_file_size")
    func redoMySQL() {
        let f = HealthFixture.mysql(status: ["innodb_os_log_written": String(Int64(86_400) * 100 * MiBytes / 60)])  // 100 MiB/min
        let r = doctor.evaluate(f)
        #expect(finding(r, "my.innodb_log_file_size") == nil)
        let redo = finding(r, "my.innodb_redo_log_capacity")
        #expect(redo?.state == .recommendation)
        #expect(redo?.restartRequired == false)
        // 6000 MiB per hour, rounded up to 256 MiB, capped at 8 GiB.
        #expect(redo?.recommendedValue == String(ByteSize.roundUp(6000 * MiBytes, to: 256 * MiBytes)))
    }

    @Test("older MySQL uses innodb_log_file_size and needs PERSIST_ONLY")
    func redoMySQL57() {
        var f = HealthFixture.mysql(["innodb_log_file_size": "50331648", "innodb_log_files_in_group": "2"], major: 5, minor: 7, patch: 44)
        f.variables["innodb_redo_log_capacity"] = nil
        f.status["innodb_os_log_written"] = String(Int64(86_400) * 100 * MiBytes / 60)
        let r = doctor.evaluate(f)
        let log = finding(r, "my.innodb_log_file_size")
        #expect(log?.state == .recommendation)
        #expect(log?.restartRequired == true)
        #expect(log?.readOnlyAtRuntime == true)
        #expect(log?.scopes == [])  // 5.7 can't set it at runtime and has no PERSIST_ONLY
        // The recommendation is per file: total / 2 files.
        let total = ByteSize.roundUp(6000 * MiBytes, to: 256 * MiBytes)
        #expect(Int64(log?.recommendedValue ?? "") == ByteSize.roundUp(total / 2, to: 64 * MiBytes))

        var eight = HealthFixture.mysql(["innodb_log_file_size": "50331648"], major: 8, minor: 0, patch: 22)
        eight.variables["innodb_redo_log_capacity"] = nil
        eight.status["innodb_os_log_written"] = f.status["innodb_os_log_written"]
        let e = finding(doctor.evaluate(eight), "my.innodb_log_file_size")
        #expect(e?.scopes == [.persistOnly])
    }

    @Test("MariaDB 11 resizes the redo log online")
    func redoMariaDB() {
        let f = HealthFixture.mariadb(status: ["innodb_os_log_written": String(Int64(86_400) * 100 * MiBytes / 60)])
        let log = finding(doctor.evaluate(f), "my.innodb_log_file_size")
        #expect(log?.state == .recommendation)
        #expect(log?.restartRequired == false)
        #expect(log?.scopes == [.runtime])
    }

    @Test("MariaDB gets SET GLOBAL only")
    func mariadbScopes() {
        let r = doctor.evaluate(HealthFixture.mariadb())
        let slow = finding(r, "my.slow_query_log")
        #expect(slow?.scopes == [.runtime])
        #expect(slow?.change()?.scope == .runtime)
    }

    @Test("table_open_cache reacts to cache misses")
    func tableOpenCache() {
        let missing = doctor.evaluate(HealthFixture.mysql(status: ["table_open_cache_hits": "1000", "table_open_cache_misses": "9000"]))
        let f = finding(missing, "my.table_open_cache")
        #expect(f?.state == .recommendation)
        #expect(f?.recommendedValue == "8000")
        #expect(finding(doctor.evaluate(HealthFixture.mysql()), "my.table_open_cache")?.state == .ok)
    }

    // MARK: PostgreSQL

    @Test("PostgreSQL defaults: memory rules ask for RAM, others recommend directly")
    func postgresDefaults() {
        let r = doctor.evaluate(HealthFixture.postgres())
        #expect(finding(r, "pg.shared_buffers")?.state == .needsInput)
        #expect(finding(r, "pg.effective_cache_size")?.state == .needsInput)
        #expect(finding(r, "pg.maintenance_work_mem")?.state == .needsInput)
        #expect(finding(r, "pg.work_mem")?.state == .ok)  // no temp files, so no sign of trouble
        #expect(finding(r, "pg.random_page_cost")?.recommendedValue == "1.1")
        #expect(finding(r, "pg.log_min_duration_statement")?.recommendedValue == "1000ms")
        #expect(finding(r, "pg.wal_compression")?.recommendedValue == "on")
        #expect(finding(r, "pg.autovacuum")?.state == .ok)
        #expect(finding(r, "pg.checkpoint_completion_target")?.state == .ok)
        #expect(r.findings.allSatisfy { $0.ruleID.hasPrefix("pg.") })
    }

    @Test("PostgreSQL memory sizing from RAM; shared_buffers needs a restart")
    func postgresMemory() {
        let r = doctor.evaluate(HealthFixture.postgres(), inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes))
        let sb = finding(r, "pg.shared_buffers")
        #expect(sb?.state == .recommendation)
        #expect(sb?.recommendedValue == "4GB")
        #expect(sb?.restartRequired == true)
        #expect(sb?.scopes == [.alterSystem])
        let ecs = finding(r, "pg.effective_cache_size")
        #expect(ecs?.recommendedValue == "9728MB")
        #expect(ecs?.restartRequired == false)
        #expect(finding(r, "pg.maintenance_work_mem")?.recommendedValue == "1GB")
    }

    @Test("work_mem is raised only when queries spill, and stays within the RAM budget")
    func postgresWorkMem() {
        var f = HealthFixture.postgres()
        f.postgresStats?.tempFiles = 500
        let without = finding(doctor.evaluate(f), "pg.work_mem")
        #expect(without?.state == .needsInput)
        let with = finding(doctor.evaluate(f, inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes)), "pg.work_mem")
        #expect(with?.state == .recommendation)
        // (16 GiB - 128 MiB) / (3 x 100) is about 54 MiB.
        #expect(with?.recommendedValue == "54MB")
    }

    @Test("autovacuum off is important; a tuned server is not nagged")
    func postgresAutovacuum() {
        let off = finding(doctor.evaluate(HealthFixture.postgres(["autovacuum": "off"])), "pg.autovacuum")
        #expect(off?.state == .recommendation)
        #expect(off?.severity == .important)
        let tuned = doctor.evaluate(HealthFixture.postgres([
            "random_page_cost": "1.1", "log_min_duration_statement": "500ms", "wal_compression": "on", "shared_buffers": "4GB"]),
            inputs: DoctorInputs(serverRAMBytes: 16 * GiBytes))
        #expect(tuned.recommendations.map(\.ruleID).contains("pg.random_page_cost") == false)
        #expect(tuned.recommendations.map(\.ruleID).contains("pg.shared_buffers") == false)
        #expect(tuned.recommendations.map(\.ruleID).contains("pg.wal_compression") == false)
    }

    @Test("checkpoint_completion_target on an old default is recommended")
    func postgresCheckpoint() {
        let f = doctor.evaluate(HealthFixture.postgres(["checkpoint_completion_target": "0.5"], major: 12))
        #expect(finding(f, "pg.checkpoint_completion_target")?.recommendedValue == "0.9")
    }

    @Test("ignored rules leave the active list but stay visible")
    func ignoring() {
        let r = doctor.evaluate(HealthFixture.mysql(), ignoredRuleIDs: ["my.slow_query_log"])
        #expect(r.recommendations.map(\.ruleID).contains("my.slow_query_log") == false)
        #expect(r.ignored.map(\.ruleID) == ["my.slow_query_log"])
    }

    @Test("findings sort by state then severity")
    func ordering() {
        let r = doctor.evaluate(HealthFixture.mysql(["innodb_flush_log_at_trx_commit": "2"]))
        let states = r.findings.map(\.state)
        #expect(states == states.sorted { rank($0) < rank($1) })
        let recs = r.recommendations.map(\.severity)
        #expect(recs == recs.sorted(by: >))
    }

    private func rank(_ s: DoctorState) -> Int { s == .recommendation ? 0 : s == .needsInput ? 1 : 2 }
}
