import Foundation

/// Turns collected ``ServerFacts`` into judged metrics. Pure: the same facts always give the same page.
public struct HealthEvaluator: Sendable {
    public var thresholds: HealthThresholds

    public init(thresholds: HealthThresholds = HealthThresholds()) {
        self.thresholds = thresholds
    }

    public func evaluate(_ facts: ServerFacts, at date: Date = Date()) -> HealthSnapshot {
        let (groups, lists) = facts.isPostgres ? postgres(facts) : mysql(facts)
        return HealthSnapshot(engine: facts.engine, groups: groups, lists: lists, collectedAt: date)
    }

    // MARK: Formatting

    static func percent(_ ratio: Double) -> String {
        let p = ratio * 100
        if p >= 99.95 && p < 100 { return "99.9%" }
        return p >= 10 || p == 0 ? String(format: "%.0f%%", p) : String(format: "%.1f%%", p)
    }

    static func count(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func duration(_ seconds: Int64) -> String {
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(seconds % 60)s"
    }

    private func unavailable(_ id: String, _ title: String, _ facts: ServerFacts, section: String) -> HealthMetric {
        HealthMetric(id: id, title: title, value: "Not available",
                     detail: facts.unavailable[section].map { "The server refused: \($0)" } ?? "The server does not report this.",
                     status: .unavailable)
    }

    private func ratioMetric(id: String, title: String, ratio: Double?, sample: Int64, threshold: HealthThreshold,
                             detailOK: String, detailBad: String, minimum: Int64? = nil) -> HealthMetric {
        guard let ratio else {
            return HealthMetric(id: id, title: title, value: "Not available", detail: "The server does not report this.", status: .unavailable)
        }
        let need = minimum ?? thresholds.minimumSample
        guard sample >= need else {
            return HealthMetric(id: id, title: title, value: Self.percent(ratio),
                                detail: "Only \(Self.count(sample)) events since the counters started; too few to judge.", status: .info)
        }
        let status = threshold.status(ratio)
        return HealthMetric(id: id, title: title, value: Self.percent(ratio), detail: status == .ok ? detailOK : detailBad, status: status)
    }

    // MARK: MySQL / MariaDB

    private func mysql(_ f: ServerFacts) -> ([HealthGroup], [HealthList]) {
        var server: [HealthMetric] = []
        server.append(HealthMetric(id: "version", title: "Version", value: f.versionString.isEmpty ? "\(f.engine.displayName) \(f.major).\(f.minor)" : f.versionString,
                                   detail: Self.versionNote(f), status: Self.versionNote(f) == nil ? .info : .warn))
        if let up = f.uptimeSeconds {
            server.append(HealthMetric(id: "uptime", title: "Uptime", value: Self.duration(up),
                                       detail: up < 3_600 ? "Restarted recently: counters and ratios below are still warming up." : nil, status: .info))
        } else {
            server.append(unavailable("uptime", "Uptime", f, section: "status"))
        }

        var connections: [HealthMetric] = []
        let threadsConnected = f.statusInt("threads_connected")
        if let max = f.int("max_connections"), max > 0, let used = threadsConnected {
            let ratio = Double(used) / Double(max)
            let status = thresholds.connectionUsage.status(ratio)
            connections.append(HealthMetric(id: "connections", title: "Connections", value: "\(used) of \(max)",
                detail: status == .ok ? "\(Self.percent(ratio)) of max_connections in use." : "\(Self.percent(ratio)) of max_connections in use; clients get “Too many connections” at 100%.", status: status))
        } else {
            connections.append(unavailable("connections", "Connections", f, section: "status"))
        }
        if let max = f.int("max_connections"), max > 0, let peak = f.statusInt("max_used_connections") {
            let ratio = Double(peak) / Double(max)
            let status = thresholds.maxUsedConnections.status(ratio)
            connections.append(HealthMetric(id: "maxUsedConnections", title: "Peak connections", value: "\(peak) of \(max)",
                detail: status == .ok ? "Highest concurrent connections since the server started." : "The peak came close to max_connections since the server started.", status: status))
        }
        if let running = f.statusInt("threads_running") {
            let status = thresholds.threadsRunning.status(Double(running))
            connections.append(HealthMetric(id: "threadsRunning", title: "Threads running", value: "\(running)",
                detail: status == .ok ? nil : "Many statements are executing at once; check the process list for slow queries.", status: status))
        }
        if let aborted = f.statusInt("aborted_connects"), let total = f.statusInt("connections"), total > 0 {
            connections.append(ratioMetric(id: "abortedConnects", title: "Aborted connection attempts",
                ratio: Double(aborted) / Double(total), sample: total, threshold: thresholds.abortedConnects,
                detailOK: "\(Self.count(aborted)) failed attempts out of \(Self.count(total)) (bad passwords, timeouts or blocked hosts).",
                detailBad: "\(Self.count(aborted)) of \(Self.count(total)) connection attempts failed: check credentials, network timeouts and host blocking."))
        }
        if let aborted = f.statusInt("aborted_clients") {
            connections.append(HealthMetric(id: "abortedClients", title: "Aborted clients", value: Self.count(aborted),
                detail: "Connections dropped without a clean close (client crashes, wait_timeout, big packets).", status: .info))
        }

        var workload: [HealthMetric] = []
        if let questions = f.statusInt("questions"), let up = f.uptimeSeconds, up > 0 {
            workload.append(HealthMetric(id: "qps", title: "Queries per second", value: String(format: "%.1f", Double(questions) / Double(up)),
                                         detail: "Average since the server started (\(Self.count(questions)) statements).", status: .info))
            if let slow = f.statusInt("slow_queries") {
                workload.append(ratioMetric(id: "slowQueries", title: "Slow queries", ratio: Double(slow) / Double(max(questions, 1)), sample: questions,
                    threshold: thresholds.slowQueryShare,
                    detailOK: "\(Self.count(slow)) statements slower than long_query_time.",
                    detailBad: "\(Self.count(slow)) statements were slower than long_query_time; review the slow query log."))
            }
        }
        if let created = f.statusInt("created_tmp_tables"), let disk = f.statusInt("created_tmp_disk_tables") {
            workload.append(ratioMetric(id: "tmpDisk", title: "Temp tables on disk",
                ratio: created > 0 ? Double(disk) / Double(created) : 0, sample: created, threshold: thresholds.tmpDiskShare, detailOK: "\(Self.count(disk)) of \(Self.count(created)) implicit temp tables spilled to disk.",
                detailBad: "\(Self.count(disk)) of \(Self.count(created)) implicit temp tables spilled to disk; tmp_table_size / max_heap_table_size may be too small, or queries return large TEXT/BLOB columns.",
                minimum: 100))
        }
        let hits = f.statusInt("table_open_cache_hits"), misses = f.statusInt("table_open_cache_misses")
        if let hits, let misses {
            workload.append(ratioMetric(id: "tableOpenMisses", title: "Table open cache misses",
                ratio: hits + misses > 0 ? Double(misses) / Double(hits + misses) : 0, sample: hits + misses, threshold: thresholds.tableOpenMisses,
                detailOK: "Most table opens were served from table_open_cache.",
                detailBad: "Many table opens miss table_open_cache (\(Self.count(misses)) misses); consider raising table_open_cache."))
        } else if let opened = f.statusInt("opened_tables"), let up = f.uptimeSeconds, up >= 3_600 {
            let perHour = Double(opened) / (Double(up) / 3_600)
            let status: HealthStatus = perHour > 1_000 ? .warn : .ok
            workload.append(HealthMetric(id: "tableOpenMisses", title: "Tables opened", value: "\(Self.count(opened)) total",
                detail: status == .ok ? String(format: "About %.0f per hour.", perHour) : String(format: "About %.0f per hour; table_open_cache may be too small.", perHour), status: status))
        }

        var innodb: [HealthMetric] = []
        let poolSize = f.int("innodb_buffer_pool_size")
        if let reads = f.statusInt("innodb_buffer_pool_reads"), let requests = f.statusInt("innodb_buffer_pool_read_requests") {
            innodb.append(ratioMetric(id: "bufferPoolHit", title: "Buffer pool hit ratio",
                ratio: requests > 0 ? 1 - Double(reads) / Double(requests) : 1, sample: requests, threshold: thresholds.bufferPoolHit,
                detailOK: "Reads served from memory instead of disk.",
                detailBad: "\(Self.count(reads)) reads had to go to disk; the hot data may not fit in innodb_buffer_pool_size."))
        } else {
            innodb.append(unavailable("bufferPoolHit", "Buffer pool hit ratio", f, section: "status"))
        }
        if let poolSize {
            if let data = f.innodbBytes, data > 0 {
                let ratio = Double(poolSize) / Double(data)
                let status = thresholds.bufferPoolCoverage.status(ratio)
                innodb.append(HealthMetric(id: "bufferPoolSize", title: "Buffer pool size", value: "\(ByteSize.pretty(poolSize)) vs \(ByteSize.pretty(data)) of InnoDB data",
                    detail: status == .ok ? "Pool is \(Self.percent(ratio)) of InnoDB data and indexes; the hot subset is usually much smaller than the total."
                        : "Pool covers only \(Self.percent(ratio)) of InnoDB data and indexes. That is fine if the hot data is small; otherwise raise it.", status: status))
            } else {
                innodb.append(HealthMetric(id: "bufferPoolSize", title: "Buffer pool size", value: ByteSize.pretty(poolSize),
                                           detail: f.unavailable["storage"].map { "Data size unavailable: \($0)" }, status: .info))
            }
        }

        var storage: [HealthMetric] = []
        if let data = f.dataBytes, let index = f.indexBytes {
            storage.append(HealthMetric(id: "dataSize", title: "Data size", value: ByteSize.pretty(data), detail: "Table data across all user databases.", status: .info))
            storage.append(HealthMetric(id: "indexSize", title: "Index size", value: ByteSize.pretty(index),
                                        detail: data > 0 ? "\(Self.percent(Double(index) / Double(data))) of data size." : nil, status: .info))
        } else {
            storage.append(unavailable("dataSize", "Data and index size", f, section: "storage"))
        }

        let groups = [
            HealthGroup(id: "server", title: "Server", metrics: server),
            HealthGroup(id: "connections", title: "Connections", metrics: connections),
            HealthGroup(id: "workload", title: "Workload", metrics: workload),
            HealthGroup(id: "innodb", title: "InnoDB", metrics: innodb),
            HealthGroup(id: "storage", title: "Storage", metrics: storage),
        ].filter { !$0.metrics.isEmpty }

        var lists: [HealthList] = []
        lists.append(Self.noPrimaryKeyList(f))
        if let others = f.nonInnoDBTables {
            lists.append(HealthList(id: "nonInnoDB", title: "Tables not using InnoDB",
                summary: others.isEmpty ? "All tables use InnoDB." : "\(others.count) table\(others.count == 1 ? "" : "s") use another engine (no crash recovery or row locking for MyISAM).",
                rows: others.map { HealthRow(id: $0, title: $0, detail: "Consider ALTER TABLE … ENGINE=InnoDB") }, status: others.isEmpty ? .ok : .warn))
        } else {
            lists.append(HealthList(id: "nonInnoDB", title: "Tables not using InnoDB", summary: f.unavailable["nonInnoDB"] ?? "Not available", rows: [], status: .unavailable))
        }
        lists.append(Self.largestList(f))
        return (groups, lists)
    }

    /// A short note when the version is probably outside vendor support; deliberately hedged.
    static func versionNote(_ f: ServerFacts) -> String? {
        switch f.engine {
        case .mysql where !f.isVersion(atLeast: 8, 4): "MySQL older than 8.4 (the current LTS) may be past its vendor support; check the MySQL release page."
        case .mariadb where !f.isVersion(atLeast: 10, 11): "MariaDB older than 10.11 may be past its community support; check the MariaDB release page."
        case .postgresql where f.major < 14: "PostgreSQL \(f.major) is probably past its community support window; check the PostgreSQL versioning page."
        default: nil
        }
    }

    private static func noPrimaryKeyList(_ f: ServerFacts) -> HealthList {
        guard let tables = f.tablesWithoutPrimaryKey else {
            return HealthList(id: "noPrimaryKey", title: "Tables without a primary key", summary: f.unavailable["noPrimaryKey"] ?? "Not available", rows: [], status: .unavailable)
        }
        return HealthList(id: "noPrimaryKey", title: "Tables without a primary key",
            summary: tables.isEmpty ? "Every table has a primary key." : "\(tables.count)\(tables.count >= 100 ? "+" : "") table\(tables.count == 1 ? "" : "s") without one: replication, row-level edits in Querywell and online schema changes all suffer.",
            rows: tables.map { HealthRow(id: $0, title: $0, detail: "No primary key") }, status: tables.isEmpty ? .ok : .warn)
    }

    private static func largestList(_ f: ServerFacts) -> HealthList {
        guard let tables = f.largestTables else {
            return HealthList(id: "largestTables", title: "Largest tables", summary: f.unavailable["largestTables"] ?? "Not available", rows: [], status: .unavailable)
        }
        return HealthList(id: "largestTables", title: "Largest tables", summary: tables.isEmpty ? "No user tables." : "Data + indexes, top \(tables.count).",
            rows: tables.map { t in
                HealthRow(id: t.qualifiedName, title: t.qualifiedName,
                          detail: ByteSize.pretty(t.totalBytes) + (t.rows.map { " · ~\(count($0)) rows" } ?? ""))
            }, status: .info)
    }

    // MARK: PostgreSQL

    private func postgres(_ f: ServerFacts) -> ([HealthGroup], [HealthList]) {
        var server: [HealthMetric] = []
        server.append(HealthMetric(id: "version", title: "Version", value: f.versionString.isEmpty ? "PostgreSQL \(f.major).\(f.minor)" : f.versionString,
                                   detail: Self.versionNote(f), status: Self.versionNote(f) == nil ? .info : .warn))
        if let up = f.uptimeSeconds {
            server.append(HealthMetric(id: "uptime", title: "Uptime", value: Self.duration(up),
                                       detail: up < 3_600 ? "Restarted recently: counters below are still warming up." : nil, status: .info))
        } else {
            server.append(unavailable("uptime", "Uptime", f, section: "uptime"))
        }
        if let size = f.postgresStats?.databaseBytes {
            server.append(HealthMetric(id: "databaseSize", title: "Database size", value: ByteSize.pretty(size), detail: "The connected database, including indexes and TOAST.", status: .info))
        } else {
            server.append(unavailable("databaseSize", "Database size", f, section: "databaseStats"))
        }

        var connections: [HealthMetric] = []
        if let max = f.int("max_connections"), max > 0, let used = f.activeConnections {
            let reserved = f.int("superuser_reserved_connections") ?? 0
            let usable = Swift.max(max - reserved, 1)
            let ratio = Double(used) / Double(usable)
            let status = thresholds.connectionUsage.status(ratio)
            connections.append(HealthMetric(id: "connections", title: "Connections", value: "\(used) of \(max)",
                detail: status == .ok ? "\(Self.percent(ratio)) of the \(usable) connections available to normal roles." : "\(Self.percent(ratio)) of available connections used; new clients are refused at 100%. Consider a pooler (PgBouncer).", status: status))
        } else {
            connections.append(unavailable("connections", "Connections", f, section: "connections"))
        }
        if let running = f.runningBackends {
            connections.append(HealthMetric(id: "activeBackends", title: "Active statements", value: "\(running)",
                detail: "Backends running a statement right now (not counting this one).", status: thresholds.threadsRunning.status(Double(running)) == .ok ? .info : thresholds.threadsRunning.status(Double(running))))
        }

        var workload: [HealthMetric] = []
        if let s = f.postgresStats {
            let reads = s.blocksHit + s.blocksRead
            workload.append(ratioMetric(id: "cacheHit", title: "Cache hit ratio", ratio: reads > 0 ? Double(s.blocksHit) / Double(reads) : 1,
                sample: reads, threshold: thresholds.pgCacheHit, detailOK: "Blocks found in shared_buffers instead of read from the OS.",
                detailBad: "\(Self.count(s.blocksRead)) block reads missed shared_buffers (they may still be in the OS cache)."))
            let xacts = s.commits + s.rollbacks
            workload.append(ratioMetric(id: "rollbackShare", title: "Rollback share", ratio: xacts > 0 ? Double(s.rollbacks) / Double(xacts) : 0,
                sample: xacts, threshold: thresholds.pgRollbackShare, detailOK: "\(Self.count(s.rollbacks)) rollbacks vs \(Self.count(s.commits)) commits.",
                detailBad: "\(Self.count(s.rollbacks)) rollbacks vs \(Self.count(s.commits)) commits; the application is aborting many transactions."))
            workload.append(HealthMetric(id: "deadlocks", title: "Deadlocks", value: Self.count(s.deadlocks),
                detail: s.deadlocks == 0 ? "None since statistics were last reset." : "Since statistics were last reset; look for transactions that lock rows in different orders.",
                status: thresholds.pgDeadlocks.status(Double(s.deadlocks))))
            workload.append(HealthMetric(id: "tempFiles", title: "Temp files", value: "\(Self.count(s.tempFiles)) · \(ByteSize.pretty(s.tempBytes))",
                detail: s.tempBytes >= Int64(thresholds.pgTempBytes.warn) ? "Sorts and hashes spill to disk; work_mem may be too small for some queries." : "Spilled sorts and hashes since the statistics reset.",
                status: thresholds.pgTempBytes.status(Double(s.tempBytes))))
        } else {
            workload.append(unavailable("cacheHit", "Cache hit ratio", f, section: "databaseStats"))
        }

        var storage: [HealthMetric] = []
        if let tables = f.largestTables, !tables.isEmpty {
            storage.append(HealthMetric(id: "dataSize", title: "Ten largest tables", value: ByteSize.pretty(tables.reduce(0) { $0 + $1.totalBytes }),
                                        detail: "Combined size, including indexes.", status: .info))
        }

        let groups = [
            HealthGroup(id: "server", title: "Server", metrics: server),
            HealthGroup(id: "connections", title: "Connections", metrics: connections),
            HealthGroup(id: "workload", title: "Workload", metrics: workload),
            HealthGroup(id: "storage", title: "Storage", metrics: storage),
        ].filter { !$0.metrics.isEmpty }

        var lists: [HealthList] = []
        if let dead = f.deadTupleTables {
            let flagged = dead.filter { $0.deadTuples >= 1_000 && thresholds.pgDeadTupleShare.status($0.deadRatio) != .ok }
            let worst = flagged.map { thresholds.pgDeadTupleShare.status($0.deadRatio) }.max() ?? .ok
            lists.append(HealthList(id: "deadTuples", title: "Tables with many dead tuples",
                summary: flagged.isEmpty ? "No table has a high share of dead rows." : "\(flagged.count) table\(flagged.count == 1 ? "" : "s") with over \(Self.percent(thresholds.pgDeadTupleShare.warn)) dead rows; autovacuum is falling behind or is blocked by long transactions.",
                rows: flagged.map { d in
                    HealthRow(id: "\(d.schema).\(d.name)", title: "\(d.schema).\(d.name)",
                              detail: "\(Self.percent(d.deadRatio)) dead (\(Self.count(d.deadTuples)) rows) · last autovacuum \(d.lastAutovacuum ?? "never")",
                              status: thresholds.pgDeadTupleShare.status(d.deadRatio))
                }, status: worst))
        } else {
            lists.append(HealthList(id: "deadTuples", title: "Tables with many dead tuples", summary: f.unavailable["deadTuples"] ?? "Not available", rows: [], status: .unavailable))
        }
        if let unused = f.unusedIndexes {
            let total = unused.reduce(0) { $0 + $1.bytes }
            lists.append(HealthList(id: "unusedIndexes", title: "Unused indexes",
                summary: unused.isEmpty ? "Every non-unique index has been scanned at least once." : "\(unused.count) index\(unused.count == 1 ? "" : "es") never scanned since statistics were reset (\(ByteSize.pretty(total))). Check replicas and recent resets before dropping.",
                rows: unused.map { HealthRow(id: "\($0.schema).\($0.index)", title: "\($0.schema).\($0.index)", detail: "on \($0.table) · \(ByteSize.pretty($0.bytes))") },
                status: unused.isEmpty ? .ok : .warn))
        } else {
            lists.append(HealthList(id: "unusedIndexes", title: "Unused indexes", summary: f.unavailable["unusedIndexes"] ?? "Not available", rows: [], status: .unavailable))
        }
        lists.append(Self.noPrimaryKeyList(f))
        lists.append(Self.largestList(f))
        return (groups, lists)
    }
}
