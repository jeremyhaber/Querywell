import Foundation

/// Turns a saved ``ConnectionProfile`` into a ``LiveConnection``: validates, reads secrets,
/// opens the SSH tunnel if configured, then connects the database driver.
public struct ConnectionOpener: Sendable {
    public let secretStore: any SecretStore
    public let tunnelProvider: any SSHTunnelProvider
    public let driverForEngine: @Sendable (DatabaseEngine) -> any DatabaseDriver

    public init(
        secretStore: any SecretStore,
        tunnelProvider: any SSHTunnelProvider = SystemSSHTunnelProvider(),
        driverForEngine: @escaping @Sendable (DatabaseEngine) -> any DatabaseDriver = DriverRegistry.driver(for:)
    ) {
        self.secretStore = secretStore
        self.tunnelProvider = tunnelProvider
        self.driverForEngine = driverForEngine
    }

    /// Opens `profile`. `database` overrides the profile's default database.
    public func open(
        _ profile: ConnectionProfile,
        database: String? = nil,
        progress: (@Sendable (ConnectionStage) -> Void)? = nil
    ) async throws -> LiveConnection {
        progress?(.validating)
        let issues = ConnectionValidator.validate(profile)
        guard issues.isEmpty else { throw ConnectionOpenError.invalidProfile(issues) }

        progress?(.readingSecrets)
        let owner = profile.id.uuidString
        let dbPassword: String?
        var sshSecret: String?
        do {
            dbPassword = try secretStore.read(SecretKey(ownerID: owner, kind: .databasePassword))
            if let ssh = profile.ssh {
                switch ssh.auth {
                case .password: sshSecret = try secretStore.read(SecretKey(ownerID: owner, kind: .sshPassword))
                case .keyFile: sshSecret = try secretStore.read(SecretKey(ownerID: owner, kind: .sshKeyPassphrase))
                case .agent: break
                }
            }
        } catch {
            throw ConnectionOpenError.secretUnavailable(Self.describe(error))
        }

        var tunnel: (any SSHTunnel)?
        var host = profile.host
        var port = profile.port
        var tlsServerName: String?
        if let ssh = profile.ssh {
            progress?(.openingTunnel(host: ssh.host))
            do {
                let request = SSHTunnelRequest(ssh: ssh, secret: sshSecret, remoteHost: profile.host, remotePort: profile.port)
                let opened = try await tunnelProvider.open(request)
                tunnel = opened
                host = opened.localHost
                port = opened.localPort
                tlsServerName = profile.host
            } catch let error as SSHTunnelError {
                throw ConnectionOpenError.tunnel(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ConnectionOpenError.tunnel(.forwardFailed(Self.describe(error)))
            }
        }

        progress?(.connecting(host: profile.host, port: profile.port))
        let configuration = ConnectionConfiguration(
            engine: profile.engine, host: host, port: port, user: profile.user,
            password: dbPassword, database: database ?? profile.defaultDatabase,
            tls: profile.tls, tlsServerName: tlsServerName)
        let driver = driverForEngine(profile.engine)
        let outcome = await Self.connect(driver, configuration, watching: tunnel)
        switch outcome {
        case .session(let session):
            progress?(.connected)
            var auxiliary = configuration
            auxiliary.connectTimeout = .seconds(10)
            let auxiliaryConfiguration = auxiliary
            return LiveConnection(
                profile: profile, session: session, tunnel: tunnel,
                auxiliaryOpener: { try await driver.connect(auxiliaryConfiguration) })
        case .forwardFailure(let reason):
            await tunnel?.close()
            throw ConnectionOpenError.databaseUnreachableThroughTunnel(
                host: profile.host, port: profile.port, underlying: .connectionFailed(reason))
        case .failed(let error):
            let forwardFailure = await tunnel?.forwardFailure
            await tunnel?.close()
            if error is CancellationError { throw error }
            if let forwardFailure {
                throw ConnectionOpenError.databaseUnreachableThroughTunnel(
                    host: profile.host, port: profile.port, underlying: .connectionFailed(forwardFailure))
            }
            let dbError = (error as? DatabaseError) ?? .connectionFailed(Self.describe(error))
            if tunnel != nil {
                // A dead or unresolvable target behind the bastion shows up as EOF/reset or as a
                // handshake that never completes.
                switch dbError {
                case .connectionFailed, .timeout:
                    throw ConnectionOpenError.databaseUnreachableThroughTunnel(host: profile.host, port: profile.port, underlying: dbError)
                default: break
                }
            }
            throw ConnectionOpenError.database(dbError)
        }
    }

    private enum ConnectOutcome: Sendable {
        case session(any DatabaseSession)
        case failed(any Error)
        case forwardFailure(String)
    }

    /// Connects the driver, racing it against the tunnel's forward-failure signal.
    ///
    /// ssh only dials the target when the driver connects. If the bastion can't reach it, ssh logs
    /// "open failed" while the driver's handshake can sit until its timeout (MySQLNIO doesn't fail a
    /// pending handshake when the socket closes), so whichever finishes first wins. A connect that
    /// loses the race is cancelled and any session it still produces is closed.
    private static func connect(
        _ driver: any DatabaseDriver, _ configuration: ConnectionConfiguration, watching tunnel: (any SSHTunnel)?
    ) async -> ConnectOutcome {
        let (outcomes, continuation) = AsyncStream.makeStream(of: ConnectOutcome.self)
        let connectTask = Task {
            do {
                let session = try await driver.connect(configuration)
                continuation.yield(.session(session))
                return session
            } catch {
                continuation.yield(.failed(error))
                throw error
            }
        }
        let watchTask = tunnel.map { tunnel in
            Task {
                while !Task.isCancelled {
                    if let reason = await tunnel.forwardFailure {
                        continuation.yield(.forwardFailure(reason))
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        let first = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next() ?? .failed(CancellationError())
        } onCancel: {
            connectTask.cancel()
            continuation.yield(.failed(CancellationError()))
        }
        watchTask?.cancel()
        continuation.finish()
        if case .session = first { return first }
        // The connect lost (or failed): make sure a late session doesn't leak.
        connectTask.cancel()
        Task { if let late = try? await connectTask.value { await late.close() } }
        return first
    }

    private static func describe(_ error: any Error) -> String {
        if case SecretStoreError.keychain(_, let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
