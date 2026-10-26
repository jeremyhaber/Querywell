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
        do {
            let session = try await driverForEngine(profile.engine).connect(configuration)
            progress?(.connected)
            return LiveConnection(profile: profile, session: session, tunnel: tunnel)
        } catch {
            await tunnel?.close()
            if error is CancellationError { throw error }
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

    private static func describe(_ error: any Error) -> String {
        if case SecretStoreError.keychain(_, let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
