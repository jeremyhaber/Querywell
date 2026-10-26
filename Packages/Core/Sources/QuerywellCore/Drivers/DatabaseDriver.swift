import Foundation

// Shared driver contracts. Engine-specific code lives in Drivers/MySQL and Drivers/Postgres;
// everything above this layer (UI, query execution, export) talks only to these types.

/// Everything a driver needs to open a session. Already resolved: secrets read from the
/// ``SecretStore`` and, when tunnelled, `host`/`port` pointing at the local forward.
public struct ConnectionConfiguration: Sendable, Hashable {
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    public var database: String?
    public var tls: TLSConfig
    /// Hostname to verify the server certificate against (``TLSMode/verifyIdentity``).
    /// Differs from `host` when connecting through an SSH tunnel.
    public var tlsServerName: String?
    public var connectTimeout: Duration

    public init(
        engine: DatabaseEngine,
        host: String,
        port: Int,
        user: String,
        password: String? = nil,
        database: String? = nil,
        tls: TLSConfig = TLSConfig(),
        tlsServerName: String? = nil,
        connectTimeout: Duration = .seconds(15)
    ) {
        self.engine = engine
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
        self.tlsServerName = tlsServerName
        self.connectTimeout = connectTimeout
    }
}

/// A single cell value. Drivers preserve the server's textual form where lossless
/// conversion isn't guaranteed (decimals, dates, JSON), so edits round-trip exactly.
public enum DatabaseValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case unsignedInteger(UInt64)
    case double(Double)
    case bool(Bool)
    /// Text, plus types kept as their server text form (decimal, date/time, json, uuid, enum, …).
    case text(String)
    case bytes(Data)

    public var isNull: Bool { self == .null }

    /// Human-readable form for grids and logs. Bytes render as a short hex preview.
    public var displayString: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .unsignedInteger(let v): String(v)
        case .double(let v): String(v)
        case .bool(let v): v ? "true" : "false"
        case .text(let v): v
        case .bytes(let d):
            d.count <= 32
                ? "0x" + d.map { String(format: "%02X", $0) }.joined()
                : "0x" + d.prefix(32).map { String(format: "%02X", $0) }.joined() + "… (\(d.count) bytes)"
        }
    }
}

/// Metadata for a result column.
public struct ColumnInfo: Sendable, Hashable {
    public var name: String
    /// Engine type name as the server reports it, lowercased (e.g. "varchar", "bigint", "jsonb").
    public var typeName: String
    /// Originating table when the server reports it (used later for editable results).
    public var table: String?
    public var isNullable: Bool?

    public init(name: String, typeName: String, table: String? = nil, isNullable: Bool? = nil) {
        self.name = name
        self.typeName = typeName
        self.table = table
        self.isNullable = isNullable
    }
}

/// The outcome of one statement.
public struct QueryResult: Sendable, Hashable {
    public var columns: [ColumnInfo]
    public var rows: [[DatabaseValue]]
    /// Rows changed by a write; `nil` for statements that don't report it.
    public var rowsAffected: UInt64?
    public var lastInsertID: UInt64?
    public var duration: Duration

    public init(
        columns: [ColumnInfo] = [],
        rows: [[DatabaseValue]] = [],
        rowsAffected: UInt64? = nil,
        lastInsertID: UInt64? = nil,
        duration: Duration = .zero
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.lastInsertID = lastInsertID
        self.duration = duration
    }
}

/// Parsed server identity, e.g. MySQL 8.4.3 / MariaDB 11.4.2 / PostgreSQL 16.4.
public struct ServerInfo: Sendable, Hashable {
    /// The flavour actually detected (a "mysql" profile may turn out to be MariaDB).
    public var engine: DatabaseEngine
    /// Full version string from the server (`SELECT VERSION()` / `SHOW server_version`).
    public var versionString: String
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Whether the session's transport is encrypted.
    public var tlsActive: Bool

    public init(engine: DatabaseEngine, versionString: String, major: Int, minor: Int, patch: Int, tlsActive: Bool) {
        self.engine = engine
        self.versionString = versionString
        self.major = major
        self.minor = minor
        self.patch = patch
        self.tlsActive = tlsActive
    }

    /// e.g. "MySQL 8.4", "MariaDB 11.4", "PostgreSQL 16.4".
    public var shortDescription: String { "\(engine.displayName) \(major).\(minor)" }
}

/// Typed driver errors; the message is suitable for showing to the user.
public enum DatabaseError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case tlsFailed(String)
    case timeout
    /// Server-side error for a statement. `code` is the MySQL errno or Postgres SQLSTATE.
    case query(message: String, code: String?)
    case sessionClosed
    case unsupported(String)
}

/// An open connection to one server. Implementations are actors; calls are serialized
/// per session (one in-flight statement, like a single client connection).
public protocol DatabaseSession: AnyObject, Sendable {
    var engine: DatabaseEngine { get }
    var serverInfo: ServerInfo { get }

    /// Runs one statement. Multi-statement splitting is done above this layer (Phase 5).
    func execute(_ sql: String) async throws -> QueryResult

    /// Database names visible to the user (Postgres: databases on the cluster; MySQL: schemas).
    func listDatabases() async throws -> [String]

    /// Currently selected database / schema context, if any.
    func currentDatabase() async throws -> String?

    /// Closes the connection. Further calls throw ``DatabaseError/sessionClosed``. Idempotent.
    func close() async
}

/// Opens sessions for one engine family. Stateless; safe to share.
public protocol DatabaseDriver: Sendable {
    /// Engines this driver handles (MySQL driver: mysql + mariadb).
    var engines: Set<DatabaseEngine> { get }
    func connect(_ configuration: ConnectionConfiguration) async throws -> any DatabaseSession
}
