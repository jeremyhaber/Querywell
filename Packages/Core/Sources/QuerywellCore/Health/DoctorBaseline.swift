import Foundation

public enum DoctorSeverity: Int, Sendable, Hashable, Comparable, Codable {
    /// A nice-to-have or a trade-off (durability vs speed, logging).
    case info
    /// Worth changing on most servers.
    case recommended
    /// Likely to cause outages, data loss or wrong results if left as is.
    case important

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .info: "Suggestion"
        case .recommended: "Recommended"
        case .important: "Important"
        }
    }
}

/// How a setting's value is shown.
public enum SettingValueKind: Sendable, Hashable {
    /// MySQL: a byte count; PostgreSQL: "128MB".
    case bytes
    case number
    case flag
    case text
}

/// What the user told us about the server (the app cannot see the host).
public struct DoctorInputs: Sendable, Hashable, Codable {
    /// RAM available to this database server, in bytes. Memory recommendations need it.
    public var serverRAMBytes: Int64?
    public init(serverRAMBytes: Int64? = nil) { self.serverRAMBytes = serverRAMBytes }
}

/// What a rule concluded for one server.
public enum RuleVerdict: Sendable, Equatable {
    case ok(note: String?)
    /// `variable` overrides the rule's own when the fix belongs to a sibling setting.
    case recommend(value: String, variable: String?, note: String?)
    /// Cannot decide without more information (usually the server's RAM).
    case needsInput(String)
    case notApplicable
}

/// One entry of the built-in baseline.
public struct BaselineRule: Sendable, Identifiable {
    public var id: String
    public var variable: String
    public var title: String
    public var severity: DoctorSeverity
    public var kind: SettingValueKind
    public var rationale: String
    public var needsServerRAM: Bool
    public var applies: @Sendable (ServerFacts) -> Bool
    public var evaluate: @Sendable (ServerFacts, DoctorInputs) -> RuleVerdict
    /// Changing it needs a server restart to take effect.
    public var restartRequired: @Sendable (ServerFacts) -> Bool
    /// The variable cannot be set while the server runs (MySQL: PERSIST_ONLY; MariaDB: my.cnf only).
    public var readOnlyAtRuntime: @Sendable (ServerFacts) -> Bool

    public init(
        id: String, variable: String, title: String, severity: DoctorSeverity, kind: SettingValueKind,
        rationale: String, needsServerRAM: Bool = false,
        applies: @escaping @Sendable (ServerFacts) -> Bool,
        restartRequired: (@Sendable (ServerFacts) -> Bool)? = nil,
        readOnlyAtRuntime: @escaping @Sendable (ServerFacts) -> Bool = { _ in false },
        evaluate: @escaping @Sendable (ServerFacts, DoctorInputs) -> RuleVerdict
    ) {
        self.id = id
        self.variable = variable
        self.title = title
        self.severity = severity
        self.kind = kind
        self.rationale = rationale
        self.needsServerRAM = needsServerRAM
        self.applies = applies
        self.evaluate = evaluate
        self.readOnlyAtRuntime = readOnlyAtRuntime
        self.restartRequired = restartRequired ?? { facts in
            facts.isPostgres && facts.contexts[variable.lowercased()] == "postmaster"
        }
    }
}

private let MiB: Int64 = 1 << 20
private let GiB: Int64 = 1 << 30

/// The built-in baseline of common recommended settings. Data-driven: add a rule here and it shows up in the
/// Doctor, with its rationale, SQL and revision history, without touching any UI.
public enum DoctorBaseline {
    public static let rules: [BaselineRule] = mysqlRules + postgresRules

    public static func rule(id: String) -> BaselineRule? { rules.first { $0.id == id } }
    public static func rules(forVariable name: String) -> [BaselineRule] { rules.filter { $0.variable.caseInsensitiveCompare(name) == .orderedSame } }

    /// How `variable` should be shown, from the baseline (unknown variables are plain text).
    public static func kind(of variable: String) -> SettingValueKind { rules(forVariable: variable).first?.kind ?? .text }

    // MARK: Helpers

    private static func mysqlOnly(_ f: ServerFacts) -> Bool { f.isMySQLFamily }
    private static func pgOnly(_ f: ServerFacts) -> Bool { f.isPostgres }

    /// MySQL 8.0.30+ sizes the redo log with `innodb_redo_log_capacity`.
    private static func usesRedoCapacity(_ f: ServerFacts) -> Bool { f.engine == .mysql && f.isVersion(atLeast: 8, 0, 30) }

    private static func poolHitRatio(_ f: ServerFacts) -> Double? {
        guard let reads = f.statusInt("innodb_buffer_pool_reads"), let requests = f.statusInt("innodb_buffer_pool_read_requests"), requests > 10_000 else { return nil }
        return 1 - Double(reads) / Double(requests)
    }

    // MARK: MySQL / MariaDB

    static let mysqlRules: [BaselineRule] = [
        BaselineRule(
            id: "my.innodb_buffer_pool_size", variable: "innodb_buffer_pool_size", title: "InnoDB buffer pool size",
            severity: .important, kind: .bytes,
            rationale: "The buffer pool caches table and index pages in memory. Too small and every query reads from disk; too large and the OS starts swapping. On a dedicated database server around 60% of RAM is a common starting point, but there is no benefit in exceeding the size of your InnoDB data plus some growth.",
            needsServerRAM: true, applies: mysqlOnly,
            evaluate: { f, input in
                guard let current = f.int("innodb_buffer_pool_size") else { return .notApplicable }
                let step = 128 * MiB
                guard let ram = input.serverRAMBytes else {
                    if let data = f.innodbBytes, current < data, let hit = poolHitRatio(f), hit < 0.99 {
                        return .needsInput("The pool (\(ByteSize.pretty(current))) is smaller than your InnoDB data (\(ByteSize.pretty(data))) and only \(String(format: "%.1f", hit * 100))% of reads hit memory. Enter the server's RAM above to get a concrete size.")
                    }
                    return .ok(note: "Without the server's RAM this can only be checked against your data size.")
                }
                let cap = ByteSize.roundDown(Int64(Double(ram) * 0.6), to: step)
                if current > Int64(Double(ram) * 0.8) {
                    return .recommend(value: String(max(cap, step)), variable: nil,
                                      note: "The pool takes more than 80% of the \(ByteSize.pretty(ram)) of RAM, leaving little for connections and the OS (risk of swapping).")
                }
                guard let data = f.innodbBytes else { return .ok(note: "Data size unavailable, so the pool could not be compared with it.") }
                if current >= data { return .ok(note: "The pool holds all \(ByteSize.pretty(data)) of InnoDB data and indexes.") }
                let wanted = min(cap, ByteSize.roundUp(max(Int64(Double(data) * 1.25), 256 * MiB), to: step))
                if current < Int64(Double(wanted) * 0.75) {
                    return .recommend(value: String(max(wanted, step)), variable: nil,
                                      note: "InnoDB data and indexes total \(ByteSize.pretty(data)); \(ByteSize.pretty(max(wanted, step))) is the smaller of 60% of RAM and data + 25% growth.")
                }
                return .ok(note: nil)
            }),

        BaselineRule(
            id: "my.max_connections", variable: "max_connections", title: "Maximum connections",
            severity: .recommended, kind: .number,
            rationale: "When the peak number of simultaneous connections gets close to max_connections, the next burst of traffic is refused with “Too many connections”. Each connection also costs memory, so raise the limit only as far as needed (or add a connection pool).",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let max = f.int("max_connections"), let peak = f.statusInt("max_used_connections"), max > 0 else { return .notApplicable }
                guard Double(peak) / Double(max) >= 0.85 else { return .ok(note: "Peak so far: \(peak) of \(max).") }
                let wanted = max + Swift.max(ByteSize.roundUp(Int64(Double(peak) * 0.5), to: 50), 50)
                return .recommend(value: String(Swift.min(wanted, 5_000)), variable: nil,
                                  note: "The peak of \(peak) connections since the server started is \(Int(Double(peak) / Double(max) * 100))% of the limit. Each extra connection can use several MB under load, so check available memory.")
            }),

        BaselineRule(
            id: "my.tmp_table_size", variable: "tmp_table_size", title: "tmp_table_size matches max_heap_table_size",
            severity: .recommended, kind: .bytes,
            rationale: "An implicit in-memory temporary table may grow to the smaller of tmp_table_size and max_heap_table_size, then it is written to disk. Setting only one of them has no effect beyond the other, so keep them equal.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let tmp = f.int("tmp_table_size"), let heap = f.int("max_heap_table_size") else { return .notApplicable }
                if tmp == heap { return .ok(note: nil) }
                if tmp < heap {
                    return .recommend(value: String(heap), variable: nil,
                                      note: "tmp_table_size (\(ByteSize.pretty(tmp))) is the effective limit; raising it to max_heap_table_size (\(ByteSize.pretty(heap))) uses the room that is already allowed.")
                }
                return .recommend(value: String(tmp), variable: "max_heap_table_size",
                                  note: "max_heap_table_size (\(ByteSize.pretty(heap))) is the effective limit; raising it to tmp_table_size (\(ByteSize.pretty(tmp))) makes both equal.")
            }),

        BaselineRule(
            id: "my.slow_query_log", variable: "slow_query_log", title: "Slow query log",
            severity: .recommended, kind: .flag,
            rationale: "Without the slow query log there is no record of which statements are slow. It is cheap when long_query_time is sensible, and is the first thing to look at when the server is under load.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let on = f.isOn("slow_query_log") else { return .notApplicable }
                return on ? .ok(note: nil) : .recommend(value: "ON", variable: nil, note: nil)
            }),

        BaselineRule(
            id: "my.long_query_time", variable: "long_query_time", title: "Slow query threshold",
            severity: .info, kind: .number,
            rationale: "Statements slower than this many seconds are written to the slow query log. The default of 10 seconds hides most problems; 1 second is a common compromise. Lower it temporarily to hunt for more.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let value = f.double("long_query_time") else { return .notApplicable }
                return value <= 2 ? .ok(note: nil) : .recommend(value: "1", variable: nil, note: "Current threshold: \(String(format: "%g", value)) s.")
            }),

        BaselineRule(
            id: "my.innodb_flush_log_at_trx_commit", variable: "innodb_flush_log_at_trx_commit", title: "Flush redo log on every commit",
            severity: .recommended, kind: .number,
            rationale: "1 flushes the redo log to disk at every commit, which is what makes committed transactions durable (ACID). 0 or 2 are faster but can lose up to about a second of committed transactions in a crash. Keep 1 unless you have consciously accepted that trade-off - in which case use Ignore.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let value = f.int("innodb_flush_log_at_trx_commit") else { return .notApplicable }
                return value == 1 ? .ok(note: nil) : .recommend(value: "1", variable: nil, note: "Currently \(value): committed transactions can be lost in a crash.")
            }),

        BaselineRule(
            id: "my.innodb_file_per_table", variable: "innodb_file_per_table", title: "One tablespace file per table",
            severity: .recommended, kind: .flag,
            rationale: "With file-per-table, dropping or truncating a table gives its disk space back and tables can be moved and rebuilt individually. It only applies to tables created afterwards; existing tables stay in the shared tablespace until rebuilt.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let on = f.isOn("innodb_file_per_table") else { return .notApplicable }
                return on ? .ok(note: nil) : .recommend(value: "ON", variable: nil, note: nil)
            }),

        BaselineRule(
            id: "my.character_set_server", variable: "character_set_server", title: "Default character set",
            severity: .recommended, kind: .text,
            rationale: "utf8mb4 stores every Unicode character (emoji included). The older utf8/utf8mb3 and latin1 silently reject or mangle some text. This changes the default for new databases only; existing tables keep theirs, and collation_server may also want changing (e.g. utf8mb4_unicode_ci).",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let value = f.variable("character_set_server") else { return .notApplicable }
                return value.lowercased() == "utf8mb4" ? .ok(note: nil) : .recommend(value: "utf8mb4", variable: nil, note: "Currently \(value).")
            }),

        BaselineRule(
            id: "my.sql_mode", variable: "sql_mode", title: "Strict SQL mode",
            severity: .recommended, kind: .text,
            rationale: "Without a strict mode the server silently truncates too-long strings and turns invalid numbers and dates into zeros instead of failing. Strict mode surfaces those bugs. Test legacy applications first: code that relied on the lenient behaviour will start getting errors.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let value = f.variable("sql_mode") else { return .notApplicable }
                let modes = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                if modes.contains("STRICT_TRANS_TABLES") || modes.contains("STRICT_ALL_TABLES") || modes.contains("TRADITIONAL") { return .ok(note: nil) }
                let new = (value.isEmpty ? [] : [value]) + ["STRICT_TRANS_TABLES"]
                return .recommend(value: new.joined(separator: ","), variable: nil, note: "Adds STRICT_TRANS_TABLES to the current modes.")
            }),

        BaselineRule(
            id: "my.table_open_cache", variable: "table_open_cache", title: "Table open cache",
            severity: .info, kind: .number,
            rationale: "MySQL keeps opened table handles in a cache. When many opens miss the cache, each costs file system work. Raising it increases the number of file descriptors used, so check open_files_limit too.",
            applies: mysqlOnly,
            evaluate: { f, _ in
                guard let cache = f.int("table_open_cache"), cache > 0 else { return .notApplicable }
                let wanted = String(Swift.min(cache * 2, 16_384))
                if let hits = f.statusInt("table_open_cache_hits"), let misses = f.statusInt("table_open_cache_misses") {
                    guard hits + misses >= 1_000 else { return .ok(note: "Too few table opens so far to judge.") }
                    let ratio = Double(misses) / Double(hits + misses)
                    if ratio >= 0.10, cache < 16_384 {
                        return .recommend(value: wanted, variable: nil, note: "\(Int(ratio * 100))% of table opens missed the cache.")
                    }
                    return .ok(note: nil)
                }
                if let opened = f.statusInt("opened_tables"), opened > cache * 2, cache < 16_384, (f.uptimeSeconds ?? 0) >= 3_600 {
                    return .recommend(value: wanted, variable: nil, note: "\(opened) tables have been opened since start-up, more than twice the cache size.")
                }
                return .ok(note: nil)
            }),

        BaselineRule(
            id: "my.innodb_redo_log_capacity", variable: "innodb_redo_log_capacity", title: "InnoDB redo log capacity",
            severity: .recommended, kind: .bytes,
            rationale: "The redo log should hold roughly an hour of writes. A log that is too small forces InnoDB to flush dirty pages early and stalls write-heavy workloads. It can be resized while the server runs.",
            applies: usesRedoCapacity,
            evaluate: { f, _ in
                guard let capacity = f.int("innodb_redo_log_capacity") else { return .notApplicable }
                return redoVerdict(f, current: capacity)
            }),

        BaselineRule(
            id: "my.innodb_log_file_size", variable: "innodb_log_file_size", title: "InnoDB redo log size",
            severity: .recommended, kind: .bytes,
            rationale: "The redo log should hold roughly an hour of writes. A log that is too small forces InnoDB to flush dirty pages early and stalls write-heavy workloads. MariaDB 10.9+ resizes it online; older servers need a restart (and the value is the size of each file).",
            applies: { f in f.isMySQLFamily && !usesRedoCapacity(f) },
            restartRequired: { f in !(f.isMariaDB && f.isVersion(atLeast: 10, 9)) },
            readOnlyAtRuntime: { f in !(f.isMariaDB && f.isVersion(atLeast: 10, 9)) },
            evaluate: { f, _ in
                guard let size = f.int("innodb_log_file_size") else { return .notApplicable }
                let files = Swift.max(f.int("innodb_log_files_in_group") ?? 1, 1)
                let verdict = redoVerdict(f, current: size * files)
                if case .recommend(let value, let variable, let note) = verdict, let total = Int64(value) {
                    return .recommend(value: String(ByteSize.roundUp(total / files, to: 64 * MiB)), variable: variable, note: note)
                }
                return verdict
            }),
    ]

    /// Compares the redo log with the write volume measured since start-up.
    private static func redoVerdict(_ f: ServerFacts, current: Int64) -> RuleVerdict {
        let step = 256 * MiB
        if let written = f.statusInt("innodb_os_log_written"), let up = f.uptimeSeconds, up >= 3_600 {
            let perHour = Int64(Double(written) / Double(up) * 3_600)
            if current < Int64(Double(perHour) * 0.75) {
                let wanted = min(max(ByteSize.roundUp(perHour, to: step), step), 8 * GiB)
                return .recommend(value: String(wanted), variable: nil,
                                  note: "About \(ByteSize.pretty(perHour)) of redo is written per hour, more than the \(ByteSize.pretty(current)) log can hold.")
            }
            return .ok(note: "About \(ByteSize.pretty(perHour)) of redo is written per hour.")
        }
        if let pool = f.int("innodb_buffer_pool_size"), pool >= 4 * GiB, current < 512 * MiB {
            return .recommend(value: String(GiB), variable: nil,
                              note: "The server has not been up long enough to measure the write volume; with a \(ByteSize.pretty(pool)) buffer pool a 1 GiB log is a safe starting point.")
        }
        return .ok(note: "The server has not been up long enough to measure the write volume.")
    }

    // MARK: PostgreSQL

    static let postgresRules: [BaselineRule] = [
        BaselineRule(
            id: "pg.shared_buffers", variable: "shared_buffers", title: "shared_buffers",
            severity: .important, kind: .bytes,
            rationale: "PostgreSQL's own page cache. The default of 128MB is tiny for a real server. About 25% of RAM is the usual starting point; the OS cache holds the rest. Needs a restart.",
            needsServerRAM: true, applies: pgOnly,
            evaluate: { f, input in
                guard let current = f.bytes("shared_buffers") else { return .notApplicable }
                if let size = f.postgresStats?.databaseBytes, current >= size { return .ok(note: "The cache is larger than the whole database (\(ByteSize.pretty(size))).") }
                guard let ram = input.serverRAMBytes else {
                    if f.sources["shared_buffers"] == "default" {
                        return .needsInput("shared_buffers is still the built-in 128MB. Enter the server's RAM above to get a concrete size.")
                    }
                    return .ok(note: "Without the server's RAM this cannot be checked.")
                }
                let wanted = max(ByteSize.roundDown(ram / 4, to: 128 * MiB), 128 * MiB)
                if current > ram / 2 {
                    return .recommend(value: ByteSize.postgresValue(wanted), variable: nil, note: "More than half of the \(ByteSize.pretty(ram)) of RAM is dedicated to shared_buffers.")
                }
                if current < Int64(Double(wanted) * 0.6) {
                    return .recommend(value: ByteSize.postgresValue(wanted), variable: nil, note: "25% of \(ByteSize.pretty(ram)) of RAM.")
                }
                return .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.effective_cache_size", variable: "effective_cache_size", title: "effective_cache_size",
            severity: .recommended, kind: .bytes,
            rationale: "Tells the planner how much memory is available for caching (shared_buffers plus the OS cache). It allocates nothing, but a value that is too low makes the planner avoid index scans. 50-75% of RAM is typical.",
            needsServerRAM: true, applies: pgOnly,
            evaluate: { f, input in
                guard let current = f.bytes("effective_cache_size") else { return .notApplicable }
                guard let ram = input.serverRAMBytes else {
                    if f.sources["effective_cache_size"] == "default" {
                        return .needsInput("effective_cache_size is still the built-in 4GB. Enter the server's RAM above to get a concrete size.")
                    }
                    return .ok(note: "Without the server's RAM this cannot be checked.")
                }
                let wanted = max(ByteSize.roundDown(Int64(Double(ram) * 0.6), to: 128 * MiB), 128 * MiB)
                return current < Int64(Double(wanted) * 0.7)
                    ? .recommend(value: ByteSize.postgresValue(wanted), variable: nil, note: "60% of \(ByteSize.pretty(ram)) of RAM.")
                    : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.work_mem", variable: "work_mem", title: "work_mem",
            severity: .recommended, kind: .bytes,
            rationale: "Memory each sort or hash step may use before spilling to temporary files. Every connection can use it several times over, so the safe value depends on RAM and max_connections. Raised here only when the server is already spilling to disk.",
            needsServerRAM: true, applies: pgOnly,
            evaluate: { f, input in
                guard let current = f.bytes("work_mem") else { return .notApplicable }
                guard let spills = f.postgresStats?.tempFiles, spills > 0 else { return .ok(note: "No temporary files have been written, so there is no sign of spilling.") }
                guard let ram = input.serverRAMBytes else {
                    return .needsInput("\(spills) temporary files have been written (queries spilled to disk). Enter the server's RAM above to get a safe work_mem.")
                }
                let connections = max(f.int("max_connections") ?? 100, 1)
                let shared = f.bytes("shared_buffers") ?? 128 * MiB
                let budget = max(ram - shared, 0) / (connections * 3)
                let wanted = min(max(ByteSize.roundDown(budget, to: MiB), 4 * MiB), 64 * MiB)
                return current < Int64(Double(wanted) * 0.75)
                    ? .recommend(value: ByteSize.postgresValue(wanted), variable: nil,
                                 note: "\(spills) temporary files written. (RAM - shared_buffers) / (3 x \(connections) connections) = \(ByteSize.pretty(budget)), capped at 64 MiB.")
                    : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.maintenance_work_mem", variable: "maintenance_work_mem", title: "maintenance_work_mem",
            severity: .info, kind: .bytes,
            rationale: "Memory for VACUUM, CREATE INDEX and similar maintenance. A larger value makes them much faster. About 1/16 of RAM, between 64MB and 2GB, is a common choice.",
            needsServerRAM: true, applies: pgOnly,
            evaluate: { f, input in
                guard let current = f.bytes("maintenance_work_mem") else { return .notApplicable }
                guard let ram = input.serverRAMBytes else {
                    return f.sources["maintenance_work_mem"] == "default"
                        ? .needsInput("maintenance_work_mem is still the built-in 64MB. Enter the server's RAM above to get a concrete size.")
                        : .ok(note: "Without the server's RAM this cannot be checked.")
                }
                let wanted = min(max(ByteSize.roundDown(ram / 16, to: 64 * MiB), 64 * MiB), 2 * GiB)
                return current < wanted / 2
                    ? .recommend(value: ByteSize.postgresValue(wanted), variable: nil, note: "1/16 of \(ByteSize.pretty(ram)) of RAM, between 64MB and 2GB.")
                    : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.random_page_cost", variable: "random_page_cost", title: "random_page_cost",
            severity: .info, kind: .number,
            rationale: "The planner's cost of a random disk read relative to a sequential one. The default of 4 assumes spinning disks. On SSD / NVMe storage 1.1 is typical and makes index scans more attractive. Querywell cannot see your storage: ignore this if the data lives on spinning disks.",
            applies: pgOnly,
            evaluate: { f, _ in
                guard let value = f.double("random_page_cost") else { return .notApplicable }
                return value > 2 ? .recommend(value: "1.1", variable: nil, note: "Assuming SSD or NVMe storage.") : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.autovacuum", variable: "autovacuum", title: "Autovacuum",
            severity: .important, kind: .flag,
            rationale: "Autovacuum removes dead rows and refreshes planner statistics. With it off, tables bloat, queries slow down, and eventually transaction ID wraparound can force the database read-only.",
            applies: pgOnly,
            evaluate: { f, _ in
                guard let on = f.isOn("autovacuum") else { return .notApplicable }
                return on ? .ok(note: nil) : .recommend(value: "on", variable: nil, note: nil)
            }),

        BaselineRule(
            id: "pg.log_min_duration_statement", variable: "log_min_duration_statement", title: "Log slow statements",
            severity: .recommended, kind: .text,
            rationale: "-1 disables slow statement logging, leaving no record of which queries are slow. Logging statements over one second is a common, low-overhead baseline.",
            applies: pgOnly,
            evaluate: { f, _ in
                guard let value = f.variable("log_min_duration_statement") else { return .notApplicable }
                return value == "-1" ? .recommend(value: "1000ms", variable: nil, note: nil) : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.checkpoint_completion_target", variable: "checkpoint_completion_target", title: "checkpoint_completion_target",
            severity: .info, kind: .number,
            rationale: "Spreads checkpoint writes over this fraction of the checkpoint interval. 0.9 avoids I/O spikes; PostgreSQL 14 made it the default, older servers default to 0.5.",
            applies: pgOnly,
            evaluate: { f, _ in
                guard let value = f.double("checkpoint_completion_target") else { return .notApplicable }
                return value < 0.9 ? .recommend(value: "0.9", variable: nil, note: nil) : .ok(note: nil)
            }),

        BaselineRule(
            id: "pg.wal_compression", variable: "wal_compression", title: "WAL compression",
            severity: .info, kind: .flag,
            rationale: "Compresses full-page images in the write-ahead log, usually shrinking WAL volume noticeably for a small CPU cost. Helpful on write-heavy servers and with replication over slower links.",
            applies: pgOnly,
            evaluate: { f, _ in
                guard let value = f.variable("wal_compression")?.lowercased() else { return .notApplicable }
                return value == "off" || value == "false" || value == "0" ? .recommend(value: "on", variable: nil, note: nil) : .ok(note: nil)
            }),
    ]
}
