import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

public struct PostgresDriver: DatabaseDriver {
    public init() {}

    public var engines: Set<DatabaseEngine> { [.postgresql] }

    public func connect(_ configuration: ConnectionConfiguration) async throws -> any DatabaseSession {
        guard engines.contains(configuration.engine) else {
            throw DatabaseError.unsupported("PostgresDriver can't open \(configuration.engine.displayName) connections.")
        }
        return try await PostgresSession.open(configuration)
    }
}

/// An open PostgreSQL connection. Statements run one at a time.
///
/// Notes on PostgresNIO's surface (1.33):
/// - Queries go through the extended protocol, which always returns *binary* cells, so
///   ``PostgresValueDecoder`` renders Postgres' canonical text form itself.
/// - The async API exposes column metadata but not the command tag; the future-based API
///   exposes the tag but only per-row column data. We use the latter for execution and, for
///   a SELECT that returns zero rows, a `LIMIT 0` wrapper through the async API to learn the
///   column list.
/// - Only one statement per `execute` (extended protocol); splitting happens above this layer.
public actor PostgresSession: DatabaseSession {
    public nonisolated let engine: DatabaseEngine = .postgresql
    public nonisolated let serverInfo: ServerInfo

    private let connection: PostgresConnection
    private let host: String
    private let port: Int
    private let logger: Logger
    private var decoder: PostgresValueDecoder
    private let configuration: ConnectionConfiguration
    /// `pg_backend_pid()` of this session, the target of `pg_cancel_backend`.
    private let backendPID: Int64?
    private var gate = SerialGate()
    private var closed = false
    private var statementCounter = 0
    private var runningStatement: Int?

    private init(
        connection: PostgresConnection, serverInfo: ServerInfo, decoder: PostgresValueDecoder,
        host: String, port: Int, logger: Logger, configuration: ConnectionConfiguration, backendPID: Int64?
    ) {
        self.configuration = configuration
        self.backendPID = backendPID
        self.connection = connection
        self.serverInfo = serverInfo
        self.decoder = decoder
        self.host = host
        self.port = port
        self.logger = logger
    }

    deinit {
        if !closed {
            let connection = connection
            connection.close().whenComplete { _ in _ = connection }
        }
    }

    // MARK: Opening

    private static let nextConnectionID = NIOLockedValueBox(0)

    static func open(_ config: ConnectionConfiguration) async throws -> PostgresSession {
        let logger = Logger(label: "querywell.postgres", factory: { _ in SwiftLogNoOpLogHandler() })
        let plan = TLSSupport.plan(for: config.tls.mode)

        let tls: PostgresConnection.Configuration.TLS
        if let nio = try TLSSupport.clientConfiguration(for: config.tls) {
            let context: NIOSSLContext
            do { context = try NIOSSLContext(configuration: nio) } catch {
                throw DatabaseError.tlsFailed("Could not set up TLS: \(error)")
            }
            tls = plan.enforced ? .require(context) : .prefer(context)
        } else {
            tls = .disable
        }

        var pg = PostgresConnection.Configuration(
            host: config.host, port: config.port, username: config.user,
            password: config.password, database: config.database, tls: tls
        )
        pg.options.connectTimeout = .nanoseconds(DriverSupport.nanoseconds(config.connectTimeout))
        pg.options.tlsServerName = DriverSupport.tlsServerName(for: config)
        // Pin the output styles the binary decoder reproduces, whatever the role defaults are.
        pg.options.additionalStartupParameters = [("DateStyle", "ISO, MDY"), ("IntervalStyle", "postgres")]

        let pgConfig = pg
        let id = nextConnectionID.withLockedValue { value -> Int in value += 1; return value }
        let connection: PostgresConnection
        do {
            connection = try await withTimeout(config.connectTimeout) {
                let c = try await PostgresConnection.connect(
                    on: MultiThreadedEventLoopGroup.singleton.next(),
                    configuration: pgConfig, id: id, logger: logger
                )
                if Task.isCancelled {
                    try? await c.close()
                    throw CancellationError()
                }
                return c
            }
        } catch {
            throw PostgresErrorMapping.map(error, host: config.host, port: config.port, connecting: true)
        }

        do {
            let probe = try await probeServer(connection, config: config, plan: plan, logger: logger)
            var pid: Int64?
            if let raw = try? await runRaw(connection, "SELECT pg_backend_pid()::int8", logger: logger, host: config.host, port: config.port),
               let cell = raw.rows.first.flatMap({ Array($0).first }),
               case .integer(let value) = probe.decoder.value(cell.bytes, oid: cell.dataType.rawValue) {
                pid = value
            }
            return PostgresSession(
                connection: connection, serverInfo: probe.info, decoder: probe.decoder,
                host: config.host, port: config.port, logger: logger, configuration: config, backendPID: pid
            )
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Runs `body`, throwing ``DatabaseError/timeout`` if it takes longer than `limit`.
    private static func withTimeout<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw DatabaseError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DatabaseError.timeout }
            return first
        }
    }

    private static func probeServer(
        _ connection: PostgresConnection, config: ConnectionConfiguration, plan: TLSSupport.Plan, logger: Logger
    ) async throws -> (info: ServerInfo, decoder: PostgresValueDecoder) {
        let decoder = PostgresValueDecoder()
        func scalar(_ sql: String) async throws -> DatabaseValue? {
            let raw = try await runRaw(connection, sql, logger: logger, host: config.host, port: config.port)
            guard let cell = raw.rows.first.flatMap({ Array($0).first }) else { return nil }
            return decoder.value(cell.bytes, oid: cell.dataType.rawValue)
        }

        guard case .text(let banner)? = try await scalar("SHOW server_version") else {
            throw DatabaseError.connectionFailed("The server did not report its version.")
        }
        let parsed = ServerVersion.parsePostgres(banner)

        var tlsActive = false
        if case .bool(let ssl)? = try? await scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()") {
            tlsActive = ssl
        }
        if plan.enforced && !tlsActive {
            throw DatabaseError.tlsFailed("The connection to \(config.host):\(config.port) is not encrypted, but this connection requires TLS.")
        }

        var finalDecoder = decoder
        if case .text(let zone)? = try? await scalar("SHOW TimeZone") {
            finalDecoder.timeZone = TimeZone(identifier: zone) ?? TimeZone(abbreviation: zone) ?? finalDecoder.timeZone
        }
        let info = ServerInfo(
            engine: .postgresql, versionString: banner,
            major: parsed.major, minor: parsed.minor, patch: parsed.patch, tlsActive: tlsActive
        )
        return (info, finalDecoder)
    }

    // MARK: Wire

    struct Raw {
        var rows: [PostgresRow]
        var tag: PostgresCommandTag
    }

    private static func runRaw(
        _ connection: PostgresConnection, _ sql: String, logger: Logger, host: String, port: Int
    ) async throws -> Raw {
        if connection.isClosed {
            throw DatabaseError.connectionFailed("The connection to \(host):\(port) was lost.")
        }
        let box = NIOLockedValueBox<[PostgresRow]>([])
        do {
            let metadata = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) { row in
                box.withLockedValue { $0.append(row) }
            }.get()
            return Raw(rows: box.withLockedValue { $0 }, tag: PostgresCommandTag(metadata: metadata))
        } catch {
            throw PostgresErrorMapping.map(error, host: host, port: port, connecting: false)
        }
    }

    // MARK: DatabaseSession

    private func acquire() async throws {
        if closed { throw DatabaseError.sessionClosed }
        if !gate.tryEnter() {
            await withCheckedContinuation { gate.enqueue($0) }
        }
        if closed {
            gate.leave()
            throw DatabaseError.sessionClosed
        }
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        try await execute(sql, interruptible: false)
    }

    public func execute(_ sql: String, interruptible: Bool) async throws -> QueryResult {
        try await acquire()
        defer { gate.leave() }
        if interruptible { try Task.checkCancellation() }
        statementCounter += 1
        let id = statementCounter
        runningStatement = id
        defer { if runningStatement == id { runningStatement = nil } }
        guard interruptible else { return try await runLocked(sql) }
        do {
            return try await withTaskCancellationHandler {
                try await runLocked(sql)
            } onCancel: {
                Task { await self.abortStatement(id) }
            }
        } catch let error as DatabaseError where error.isCancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    public func cancelCurrentQuery() async throws {
        guard let id = runningStatement else { return }
        await abortStatement(id)
    }

    /// `pg_cancel_backend` from a second connection, repeated until `id` is no longer running (a cancel
    /// that arrives before the server starts the statement is lost).
    private func abortStatement(_ id: Int) async {
        guard let backendPID, runningStatement == id else { return }
        var config = configuration
        config.connectTimeout = .seconds(5)
        guard let killer = try? await PostgresSession.open(config) else { return }
        var attempts = 0
        while runningStatement == id, attempts < 40 {
            _ = try? await killer.execute("SELECT pg_cancel_backend(\(backendPID))")
            attempts += 1
            try? await Task.sleep(for: .milliseconds(150))
        }
        await killer.close()
    }

    private func runLocked(_ sql: String) async throws -> QueryResult {
        let clock = ContinuousClock()
        let start = clock.now
        let raw = try await Self.runRaw(connection, sql, logger: logger, host: host, port: port)

        var columns: [(name: String, oid: UInt32)] = []
        if let first = raw.rows.first {
            columns = first.map { ($0.columnName, $0.dataType.rawValue) }
        } else if raw.tag.command == "SELECT", Self.canWrapAsSubquery(sql) {
            columns = await describeColumns(of: sql)
        }

        try await learnTypes(columns.map(\.oid))
        for row in raw.rows {
            // Rows of one result share a column list, but be safe against type surprises.
            for cell in row where !decoder.isKnown(cell.dataType.rawValue) {
                try await learnTypes([cell.dataType.rawValue])
            }
        }

        if columns.contains(where: { Self.timeZoneDependentOIDs.contains($0.oid) }) {
            try await refreshTimeZone()
        }
        let decoder = self.decoder
        let rows: [[DatabaseValue]] = raw.rows.map { row in
            row.map { decoder.value($0.bytes, oid: $0.dataType.rawValue) }
        }
        return QueryResult(
            columns: columns.map { ColumnInfo(name: $0.name, typeName: decoder.typeName(for: $0.oid)) },
            rows: rows,
            rowsAffected: raw.tag.rowsAffected,
            lastInsertID: nil,
            duration: clock.now - start
        )
    }

    /// Types whose text form depends on the session `TimeZone`, which can change at any time (`SET TIME ZONE`).
    private static let timeZoneDependentOIDs: Set<UInt32> = [1184, 1266, 1185, 1270, 3910]

    private func refreshTimeZone() async throws {
        let raw = try await Self.runRaw(connection, "SHOW TimeZone", logger: logger, host: host, port: port)
        if let cell = raw.rows.first.flatMap({ Array($0).first }),
           case .text(let zone) = decoder.value(cell.bytes, oid: cell.dataType.rawValue) {
            decoder.timeZone = TimeZone(identifier: zone) ?? TimeZone(abbreviation: zone) ?? decoder.timeZone
        }
    }

    /// Column list for a SELECT that returned no rows. PostgresNIO only reveals columns per
    /// row or via the async sequence, so re-ask the server with `LIMIT 0` (never executes the body).
    private func describeColumns(of sql: String) async -> [(name: String, oid: UInt32)] {
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") {
            body.removeLast()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let wrapped = "SELECT * FROM (\n\(body)\n) AS _qw_describe LIMIT 0"
        do {
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: wrapped), logger: logger)
            let columns = sequence.columns.map { ($0.name, $0.dataType.rawValue) }
            _ = try await sequence.collect()
            return columns
        } catch {
            return []
        }
    }

    /// Only plain row-returning statements can be wrapped in a subquery without risking a
    /// syntax error (which would abort an open transaction).
    static func canWrapAsSubquery(_ sql: String) -> Bool {
        let lowered = sql.lowercased()
        let trimmed = lowered.drop(while: { $0.isWhitespace || $0 == "(" })
        guard ["select", "with", "values", "table"].contains(where: { trimmed.hasPrefix($0) }) else { return false }
        return !lowered.contains(" into ") && !lowered.contains("\ninto ")
    }

    /// Resolves names for OIDs not in the built-in table via `pg_type`, following array elements.
    private func learnTypes(_ oids: [UInt32]) async throws {
        var pending = Set(oids.filter { !decoder.isKnown($0) })
        while !pending.isEmpty {
            let list = pending.sorted().map(String.init).joined(separator: ",")
            let raw = try await Self.runRaw(
                connection,
                "SELECT oid::int8, typname::text, typelem::int8, typcategory::text FROM pg_type WHERE oid IN (\(list))",
                logger: logger, host: host, port: port
            )
            var found = Set<UInt32>()
            var next = Set<UInt32>()
            for row in raw.rows {
                let cells = Array(row)
                guard cells.count == 4,
                      case .integer(let oid) = decoder.value(cells[0].bytes, oid: cells[0].dataType.rawValue),
                      case .text(let name) = decoder.value(cells[1].bytes, oid: cells[1].dataType.rawValue),
                      case .integer(let elem) = decoder.value(cells[2].bytes, oid: cells[2].dataType.rawValue),
                      case .text(let category) = decoder.value(cells[3].bytes, oid: cells[3].dataType.rawValue)
                else { continue }
                decoder.extraTypes[UInt32(oid)] = PostgresTypeInfo(name: name, elementOID: UInt32(elem), category: category)
                found.insert(UInt32(oid))
                if category == "A", elem != 0, !decoder.isKnown(UInt32(elem)) { next.insert(UInt32(elem)) }
            }
            for oid in pending.subtracting(found) {
                decoder.extraTypes[oid] = PostgresTypeInfo(name: "oid:\(oid)", elementOID: 0, category: "")
            }
            pending = next
        }
    }

    public func listDatabases() async throws -> [String] {
        try await acquire()
        defer { gate.leave() }
        let result = try await runLocked(
            "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname"
        )
        return result.rows.compactMap { row in
            if case .text(let s)? = row.first { return s }
            return nil
        }
    }

    public func currentDatabase() async throws -> String? {
        try await acquire()
        defer { gate.leave() }
        let result = try await runLocked("SELECT current_database()")
        if case .text(let s)? = result.rows.first?.first { return s }
        return nil
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await connection.close()
    }
}
