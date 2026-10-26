import Foundation

/// Byte-size parsing and formatting shared by the health metrics and the Doctor baseline.
public enum ByteSize {
    /// Parses "134217728", "128MB", "8kB", "4G", "1.5 GiB". Returns nil for anything else.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var number = ""
        var unit = ""
        for ch in trimmed {
            if unit.isEmpty, ch.isASCII, ch.isNumber || ch == "." || (ch == "-" && number.isEmpty) {
                number.append(ch)
            } else if ch == " " && unit.isEmpty {
                continue
            } else {
                unit.append(ch)
            }
        }
        guard let value = Double(number) else { return nil }
        let multiplier: Double
        switch unit.lowercased() {
        case "", "b": multiplier = 1
        case "k", "kb", "kib": multiplier = 1024
        case "m", "mb", "mib": multiplier = 1024 * 1024
        case "g", "gb", "gib": multiplier = 1024 * 1024 * 1024
        case "t", "tb", "tib": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// "1.5 GiB", "128 MiB", "512 B" for display.
    public static func pretty(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var value = Double(abs(bytes))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let sign = bytes < 0 ? "-" : ""
        if index == 0 { return "\(sign)\(Int(value)) B" }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(sign)\(text) \(units[index])"
    }

    /// A value PostgreSQL accepts for a memory setting: the largest unit that divides exactly ("4GB", "128MB", "64kB").
    public static func postgresValue(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 * 1024, bytes % (1024 * 1024 * 1024) == 0 { return "\(bytes / (1024 * 1024 * 1024))GB" }
        if bytes >= 1024 * 1024, bytes % (1024 * 1024) == 0 { return "\(bytes / (1024 * 1024))MB" }
        return "\(max(bytes / 1024, 1))kB"
    }

    public static func roundUp(_ value: Int64, to step: Int64) -> Int64 {
        guard step > 0 else { return value }
        return ((value + step - 1) / step) * step
    }

    public static func roundDown(_ value: Int64, to step: Int64) -> Int64 {
        guard step > 0 else { return value }
        return (value / step) * step
    }
}

public struct TableSizeEntry: Sendable, Hashable {
    public var schema: String
    public var name: String
    public var totalBytes: Int64
    public var rows: Int64?
    public init(schema: String, name: String, totalBytes: Int64, rows: Int64? = nil) {
        self.schema = schema
        self.name = name
        self.totalBytes = totalBytes
        self.rows = rows
    }
    public var qualifiedName: String { "\(schema).\(name)" }
}

public struct DeadTupleEntry: Sendable, Hashable {
    public var schema: String
    public var name: String
    public var liveTuples: Int64
    public var deadTuples: Int64
    public var lastAutovacuum: String?
    public var lastVacuum: String?
    public init(schema: String, name: String, liveTuples: Int64, deadTuples: Int64,
                lastAutovacuum: String? = nil, lastVacuum: String? = nil) {
        self.schema = schema
        self.name = name
        self.liveTuples = liveTuples
        self.deadTuples = deadTuples
        self.lastAutovacuum = lastAutovacuum
        self.lastVacuum = lastVacuum
    }
    public var deadRatio: Double {
        let total = liveTuples + deadTuples
        return total > 0 ? Double(deadTuples) / Double(total) : 0
    }
}

public struct UnusedIndexEntry: Sendable, Hashable {
    public var schema: String
    public var table: String
    public var index: String
    public var bytes: Int64
    public init(schema: String, table: String, index: String, bytes: Int64) {
        self.schema = schema
        self.table = table
        self.index = index
        self.bytes = bytes
    }
}

/// `pg_stat_database` counters for the connected database.
public struct PostgresDatabaseStats: Sendable, Hashable {
    public var blocksHit: Int64
    public var blocksRead: Int64
    public var commits: Int64
    public var rollbacks: Int64
    public var deadlocks: Int64
    public var tempFiles: Int64
    public var tempBytes: Int64
    public var databaseBytes: Int64
    public init(blocksHit: Int64 = 0, blocksRead: Int64 = 0, commits: Int64 = 0, rollbacks: Int64 = 0,
                deadlocks: Int64 = 0, tempFiles: Int64 = 0, tempBytes: Int64 = 0, databaseBytes: Int64 = 0) {
        self.blocksHit = blocksHit
        self.blocksRead = blocksRead
        self.commits = commits
        self.rollbacks = rollbacks
        self.deadlocks = deadlocks
        self.tempFiles = tempFiles
        self.tempBytes = tempBytes
        self.databaseBytes = databaseBytes
    }
}

/// Everything the health metrics and the Doctor baseline need to know about a server, collected once.
/// Anything the account was not allowed to read is nil / missing, with the reason in `unavailable`.
public struct ServerFacts: Sendable, Equatable {
    public var engine: DatabaseEngine
    public var versionString: String
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Settings keyed by lower-cased name. MySQL/MariaDB: raw `SHOW GLOBAL VARIABLES` values.
    /// PostgreSQL: the form `ALTER SYSTEM SET` accepts ("128MB", "5min", "on").
    public var variables: [String: String] = [:]
    /// `SHOW GLOBAL STATUS` (MySQL/MariaDB), lower-cased names.
    public var status: [String: String] = [:]
    /// PostgreSQL `pg_settings.context` per setting (`postmaster` = restart required).
    public var contexts: [String: String] = [:]
    /// PostgreSQL `pg_settings.source` per setting (`default` = never configured).
    public var sources: [String: String] = [:]
    public var uptimeSeconds: Int64?
    /// PostgreSQL: current client backends and those actively running a statement.
    public var activeConnections: Int64?
    public var runningBackends: Int64?
    public var dataBytes: Int64?
    public var indexBytes: Int64?
    /// MySQL/MariaDB: data + index bytes of InnoDB tables only (what the buffer pool caches).
    public var innodbBytes: Int64?
    public var postgresStats: PostgresDatabaseStats?
    public var tablesWithoutPrimaryKey: [String]?
    public var nonInnoDBTables: [String]?
    public var largestTables: [TableSizeEntry]?
    public var deadTupleTables: [DeadTupleEntry]?
    public var unusedIndexes: [UnusedIndexEntry]?
    /// Section id → why it could not be read ("permission denied …").
    public var unavailable: [String: String] = [:]

    public init(engine: DatabaseEngine, versionString: String = "", major: Int = 0, minor: Int = 0, patch: Int = 0) {
        self.engine = engine
        self.versionString = versionString
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var isPostgres: Bool { engine == .postgresql }
    public var isMariaDB: Bool { engine == .mariadb }
    public var isMySQLFamily: Bool { engine != .postgresql }

    public func variable(_ name: String) -> String? { variables[name.lowercased()] }
    public func int(_ name: String) -> Int64? { variable(name).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    public func double(_ name: String) -> Double? { variable(name).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    public func bytes(_ name: String) -> Int64? { variable(name).flatMap(ByteSize.parse) }
    public func statusInt(_ name: String) -> Int64? { status[name.lowercased()].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    public func isOn(_ name: String) -> Bool? {
        guard let v = variable(name)?.lowercased() else { return nil }
        switch v {
        case "on", "1", "true", "yes": return true
        case "off", "0", "false", "no": return false
        default: return nil
        }
    }

    /// True when this server is at least `major.minor.patch`.
    public func isVersion(atLeast major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        (self.major, self.minor, self.patch) >= (major, minor, patch)
    }
}
