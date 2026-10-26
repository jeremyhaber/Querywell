import Foundation
import Logging
import MySQLNIO
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// Driver for MySQL and MariaDB (same wire protocol). A `.mysql` configuration that turns
/// out to be talking to MariaDB reports `.mariadb` in ``ServerInfo/engine``.
public struct MySQLDriver: DatabaseDriver {
    public init() {}

    public var engines: Set<DatabaseEngine> { [.mysql, .mariadb] }

    public func connect(_ configuration: ConnectionConfiguration) async throws -> any DatabaseSession {
        guard engines.contains(configuration.engine) else {
            throw DatabaseError.unsupported("MySQLDriver can't open \(configuration.engine.displayName) connections.")
        }
        return try await MySQLSession.open(configuration)
    }
}

/// An open MySQL / MariaDB connection. Statements run one at a time.
public actor MySQLSession: DatabaseSession {
    public nonisolated let engine: DatabaseEngine
    public nonisolated let serverInfo: ServerInfo

    private let connection: MySQLConnection
    private let host: String
    private let port: Int
    private let logger: Logger
    private var gate = SerialGate()
    private var closed = false

    private init(connection: MySQLConnection, serverInfo: ServerInfo, host: String, port: Int, logger: Logger) {
        self.connection = connection
        self.serverInfo = serverInfo
        self.engine = serverInfo.engine
        self.host = host
        self.port = port
        self.logger = logger
    }

    deinit {
        // MySQLNIO asserts (in debug builds) that a connection is closed before it is freed.
        // Keep it alive until the close actually completes.
        let connection = connection
        if !closed {
            connection.close().whenComplete { _ in _ = connection }
        }
    }

    // MARK: Opening

    static func open(_ config: ConnectionConfiguration) async throws -> MySQLSession {
        let logger = Logger(label: "querywell.mysql", factory: { _ in SwiftLogNoOpLogHandler() })
        let plan = TLSSupport.plan(for: config.tls.mode)
        let tls = try TLSSupport.clientConfiguration(for: config.tls)

        var connection: MySQLConnection
        do {
            connection = try await connectWire(config, tls: tls, logger: logger)
        } catch let error as NIOSSLError where plan.enabled && !plan.enforced {
            // "Preferred": the server advertised TLS but the handshake failed; retry in plaintext.
            logger.debug("TLS handshake failed (\(error)); retrying without TLS")
            connection = try await connectWire(config, tls: nil, logger: logger)
        }

        do {
            let info = try await probeServer(connection, config: config, plan: plan, logger: logger)
            return MySQLSession(
                connection: connection, serverInfo: info,
                host: config.host, port: config.port, logger: logger
            )
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private static func connectWire(
        _ config: ConnectionConfiguration, tls: TLSConfiguration?, logger: Logger
    ) async throws -> MySQLConnection {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let outcome = loop.makePromise(of: MySQLConnection.self)
        let settled = NIOLockedValueBox(false)
        /// True for the first caller only.
        @Sendable func settle() -> Bool {
            settled.withLockedValue { done in
                if done { return false }
                done = true
                return true
            }
        }

        let timeout = loop.scheduleTask(in: .nanoseconds(DriverSupport.nanoseconds(config.connectTimeout))) {
            if settle() { outcome.fail(DatabaseError.timeout) }
        }

        let host = config.host, port = config.port
        let user = config.user, password = config.password
        let database = config.database ?? ""
        let serverName = DriverSupport.tlsServerName(for: config)

        NIOThreadPool.singleton
            .runIfActive(eventLoop: loop) { try SocketAddress.makeAddressResolvingHost(host, port: port) }
            .flatMap { address in
                MySQLConnection.connect(
                    to: address, username: user, database: database, password: password,
                    tlsConfiguration: tls, serverHostname: serverName, logger: logger, on: loop
                )
            }
            .whenComplete { result in
                timeout.cancel()
                switch result {
                case .success(let conn):
                    if settle() { outcome.succeed(conn) } else { _ = conn.close() }
                case .failure(let error):
                    if settle() { outcome.fail(error) }
                }
            }

        do {
            return try await outcome.futureResult.get()
        } catch {
            throw MySQLErrorMapping.map(error, host: host, port: port, connecting: true)
        }
    }

    /// Reads version and TLS state; enforces "required" TLS modes (MySQLNIO silently falls
    /// back to plaintext when the server doesn't advertise TLS).
    private static func probeServer(
        _ connection: MySQLConnection, config: ConnectionConfiguration, plan: TLSSupport.Plan, logger: Logger
    ) async throws -> ServerInfo {
        func scalar(_ sql: String, column: Int = 0) async throws -> String? {
            let out = try await runWire(connection, sql, host: config.host, port: config.port)
            guard let row = out.rows.first, column < row.count else { return nil }
            if case .text(let s) = MySQLValueMapping.value(row[column], column: out.columns[column]) { return s }
            return nil
        }

        let banner = try await scalar("SELECT VERSION()") ?? ""
        let parsed = ServerVersion.parseMySQL(banner)
        // SHOW STATUS LIKE returns (Variable_name, Value).
        let cipher = try await scalar("SHOW SESSION STATUS LIKE 'Ssl_cipher'", column: 1) ?? ""
        let tlsActive = !cipher.isEmpty

        if plan.enforced && !tlsActive {
            throw DatabaseError.tlsFailed("The server at \(config.host):\(config.port) does not support TLS, but this connection requires it.")
        }
        return ServerInfo(
            engine: parsed.engine, versionString: banner,
            major: parsed.major, minor: parsed.minor, patch: parsed.patch, tlsActive: tlsActive
        )
    }

    private static func runWire(
        _ connection: MySQLConnection, _ sql: String, host: String, port: Int
    ) async throws -> MySQLTextQueryCommand.Output {
        if connection.isClosed {
            throw DatabaseError.connectionFailed("The connection to \(host):\(port) was lost.")
        }
        let command = MySQLTextQueryCommand(sql: sql)
        do {
            try await connection.send(command, logger: connection.logger).get()
        } catch {
            throw MySQLErrorMapping.map(error, host: host, port: port, connecting: false)
        }
        return command.output
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
        try await acquire()
        defer { gate.leave() }
        return try await runLocked(sql)
    }

    private func runLocked(_ sql: String) async throws -> QueryResult {
        let clock = ContinuousClock()
        let start = clock.now
        let out = try await Self.runWire(connection, sql, host: host, port: port)
        let rows = out.rows.map { cells in
            zip(cells, out.columns).map { MySQLValueMapping.value($0, column: $1) }
        }
        return QueryResult(
            columns: out.columns.map(\.info),
            rows: rows,
            rowsAffected: out.rowsAffected,
            lastInsertID: out.lastInsertID,
            duration: clock.now - start
        )
    }

    public func listDatabases() async throws -> [String] {
        try await acquire()
        defer { gate.leave() }
        let result = try await runLocked("SHOW DATABASES")
        return result.rows.compactMap { row in
            if case .text(let s)? = row.first { return s }
            return nil
        }
    }

    public func currentDatabase() async throws -> String? {
        try await acquire()
        defer { gate.leave() }
        let result = try await runLocked("SELECT DATABASE()")
        if case .text(let s)? = result.rows.first?.first { return s }
        return nil
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        _ = try? await connection.close().get()
    }
}
