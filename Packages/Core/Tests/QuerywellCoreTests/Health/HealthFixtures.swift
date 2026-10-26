import Foundation

@testable import QuerywellCore

let MiBytes: Int64 = 1 << 20
let GiBytes: Int64 = 1 << 30

/// Fixture server facts for the Health and Doctor tests.
enum HealthFixture {
    static func mysql(
        _ variables: [String: String] = [:], status: [String: String] = [:], major: Int = 8, minor: Int = 4, patch: Int = 0
    ) -> ServerFacts {
        var f = ServerFacts(engine: .mysql, versionString: "\(major).\(minor).\(patch)", major: major, minor: minor, patch: patch)
        f.variables = [
            "max_connections": "151", "innodb_buffer_pool_size": "134217728", "tmp_table_size": "16777216",
            "max_heap_table_size": "16777216", "slow_query_log": "OFF", "long_query_time": "10.000000",
            "innodb_flush_log_at_trx_commit": "1", "innodb_file_per_table": "ON", "character_set_server": "utf8mb4",
            "sql_mode": "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE", "table_open_cache": "4000",
            "innodb_redo_log_capacity": "104857600",
        ]
        for (k, v) in variables { f.variables[k] = v }
        f.status = [
            "uptime": "86400", "threads_connected": "10", "max_used_connections": "20", "threads_running": "2",
            "questions": "8640000", "slow_queries": "10", "innodb_buffer_pool_reads": "1000",
            "innodb_buffer_pool_read_requests": "1000000", "created_tmp_tables": "1000", "created_tmp_disk_tables": "10",
            "table_open_cache_hits": "100000", "table_open_cache_misses": "100", "connections": "5000", "aborted_connects": "5",
            "aborted_clients": "3", "opened_tables": "200", "innodb_os_log_written": "0",
        ]
        for (k, v) in status { f.status[k] = v }
        f.uptimeSeconds = 86_400
        f.dataBytes = 2 * GiBytes
        f.indexBytes = GiBytes / 2
        f.innodbBytes = 2 * GiBytes
        f.tablesWithoutPrimaryKey = []
        f.nonInnoDBTables = []
        f.largestTables = [TableSizeEntry(schema: "shop", name: "orders", totalBytes: GiBytes, rows: 1_000_000)]
        return f
    }

    static func mariadb(_ variables: [String: String] = [:], status: [String: String] = [:]) -> ServerFacts {
        var f = mysql(variables, status: status, major: 11, minor: 4, patch: 2)
        f.engine = .mariadb
        f.versionString = "11.4.2-MariaDB"
        f.variables["innodb_log_file_size"] = "100663296"
        f.variables["innodb_log_files_in_group"] = "1"
        f.variables["innodb_redo_log_capacity"] = nil
        for (k, v) in variables { f.variables[k] = v }
        return f
    }

    static func postgres(_ variables: [String: String] = [:], major: Int = 16) -> ServerFacts {
        var f = ServerFacts(engine: .postgresql, versionString: "\(major).4", major: major, minor: 4)
        f.variables = [
            "max_connections": "100", "superuser_reserved_connections": "3", "shared_buffers": "128MB",
            "effective_cache_size": "4GB", "work_mem": "4MB", "maintenance_work_mem": "64MB", "random_page_cost": "4",
            "autovacuum": "on", "log_min_duration_statement": "-1", "checkpoint_completion_target": "0.9", "wal_compression": "off",
        ]
        for (k, v) in variables { f.variables[k] = v }
        f.contexts = ["shared_buffers": "postmaster", "work_mem": "user", "effective_cache_size": "user",
                      "maintenance_work_mem": "user", "random_page_cost": "user", "autovacuum": "sighup",
                      "log_min_duration_statement": "superuser", "checkpoint_completion_target": "sighup", "wal_compression": "superuser"]
        f.sources = ["shared_buffers": "default", "effective_cache_size": "default", "maintenance_work_mem": "default"]
        f.uptimeSeconds = 7 * 86_400
        f.activeConnections = 20
        f.runningBackends = 1
        f.postgresStats = PostgresDatabaseStats(
            blocksHit: 990_000, blocksRead: 10_000, commits: 99_000, rollbacks: 1_000, deadlocks: 0, tempFiles: 0, tempBytes: 0,
            databaseBytes: 4 * GiBytes)
        f.largestTables = [TableSizeEntry(schema: "public", name: "events", totalBytes: 2 * GiBytes, rows: 5_000_000)]
        f.deadTupleTables = []
        f.unusedIndexes = []
        f.tablesWithoutPrimaryKey = []
        return f
    }
}
