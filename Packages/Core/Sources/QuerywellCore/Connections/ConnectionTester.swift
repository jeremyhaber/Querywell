import Foundation
import os

/// Secrets typed into an unsaved connection editor; they take precedence over the secret store.
/// `nil` means "not provided" and falls through to the store.
public struct ConnectionSecrets: Sendable, Equatable {
    public var databasePassword: String?
    /// SSH password (for ``SSHAuthMethod/password``) or key passphrase (for ``SSHAuthMethod/keyFile(path:)``).
    public var sshSecret: String?

    public init(databasePassword: String? = nil, sshSecret: String? = nil) {
        self.databasePassword = databasePassword
        self.sshSecret = sshSecret
    }
}

/// In-memory values layered over a real store. Reads prefer the overlay; writes go to the base.
struct OverlaySecretStore: SecretStore {
    let base: any SecretStore
    let overrides: [SecretKey: String]

    func read(_ key: SecretKey) throws -> String? { try overrides[key] ?? base.read(key) }
    func write(_ value: String, for key: SecretKey) throws { try base.write(value, for: key) }
    func delete(_ key: SecretKey) throws { try base.delete(key) }
    func deleteAll(ownerID: String) throws { try base.deleteAll(ownerID: ownerID) }
}

/// When a stage was reached, as an offset from the start of the test.
public struct ConnectionStageTiming: Sendable, Hashable {
    public var stage: ConnectionStage
    public var offset: Duration
}

/// Outcome of a connection test.
public struct ConnectionTestReport: Sendable {
    public var succeeded: Bool
    public var error: ConnectionOpenError?
    /// The last stage reached when the test failed.
    public var failedStage: ConnectionStage?
    public var stages: [ConnectionStageTiming]
    public var totalDuration: Duration
    /// Median round trip of three `SELECT 1` statements.
    public var latency: Duration?
    public var serverInfo: ServerInfo?
    public var tlsActive: Bool
    public var usedTunnel: Bool
    public var warnings: [String]
}

/// Tries a connection end to end and reports what happened. Never throws.
public struct ConnectionTester: Sendable {
    public let opener: ConnectionOpener

    public init(opener: ConnectionOpener) {
        self.opener = opener
    }

    public init(
        secretStore: any SecretStore,
        tunnelProvider: any SSHTunnelProvider = SystemSSHTunnelProvider(),
        driverForEngine: @escaping @Sendable (DatabaseEngine) -> any DatabaseDriver = DriverRegistry.driver(for:)
    ) {
        self.opener = ConnectionOpener(secretStore: secretStore, tunnelProvider: tunnelProvider, driverForEngine: driverForEngine)
    }

    /// Tests a saved profile, reading secrets from the store.
    public func test(
        _ profile: ConnectionProfile,
        progress: (@Sendable (ConnectionStage) -> Void)? = nil
    ) async -> ConnectionTestReport {
        await run(profile, using: opener, progress: progress)
    }

    /// Tests a possibly unsaved profile; `secrets` override the store.
    public func test(
        _ profile: ConnectionProfile,
        secrets: ConnectionSecrets,
        progress: (@Sendable (ConnectionStage) -> Void)? = nil
    ) async -> ConnectionTestReport {
        var overrides: [SecretKey: String] = [:]
        let owner = profile.id.uuidString
        if let pw = secrets.databasePassword { overrides[SecretKey(ownerID: owner, kind: .databasePassword)] = pw }
        if let secret = secrets.sshSecret, let ssh = profile.ssh {
            switch ssh.auth {
            case .password: overrides[SecretKey(ownerID: owner, kind: .sshPassword)] = secret
            case .keyFile: overrides[SecretKey(ownerID: owner, kind: .sshKeyPassphrase)] = secret
            case .agent: break
            }
        }
        let overlay = OverlaySecretStore(base: opener.secretStore, overrides: overrides)
        let layered = ConnectionOpener(secretStore: overlay, tunnelProvider: opener.tunnelProvider, driverForEngine: opener.driverForEngine)
        return await run(profile, using: layered, progress: progress)
    }

    private func run(
        _ profile: ConnectionProfile,
        using opener: ConnectionOpener,
        progress: (@Sendable (ConnectionStage) -> Void)?
    ) async -> ConnectionTestReport {
        let clock = ContinuousClock()
        let start = clock.now
        let recorded = OSAllocatedUnfairLock(initialState: [ConnectionStageTiming]())
        let record: @Sendable (ConnectionStage) -> Void = { stage in
            let offset = start.duration(to: clock.now)
            recorded.withLock { $0.append(ConnectionStageTiming(stage: stage, offset: offset)) }
            progress?(stage)
        }
        let usedTunnel = profile.ssh != nil

        func failure(_ error: ConnectionOpenError) -> ConnectionTestReport {
            let stages = recorded.withLock { $0 }
            return ConnectionTestReport(
                succeeded: false, error: error, failedStage: stages.last?.stage, stages: stages,
                totalDuration: start.duration(to: clock.now), latency: nil, serverInfo: nil,
                tlsActive: false, usedTunnel: usedTunnel, warnings: [])
        }

        let live: LiveConnection
        do {
            live = try await opener.open(profile, progress: record)
        } catch let error as ConnectionOpenError {
            return failure(error)
        } catch {
            return failure(.database(.connectionFailed(error.localizedDescription)))
        }

        var latencies: [Duration] = []
        do {
            for _ in 0..<3 {
                let t0 = clock.now
                _ = try await live.session.execute("SELECT 1")
                latencies.append(t0.duration(to: clock.now))
            }
        } catch {
            await live.close()
            return failure(.database((error as? DatabaseError) ?? .connectionFailed(error.localizedDescription)))
        }
        let info = live.session.serverInfo
        await live.close()

        return ConnectionTestReport(
            succeeded: true, error: nil, failedStage: nil, stages: recorded.withLock { $0 },
            totalDuration: start.duration(to: clock.now), latency: latencies.sorted()[1], serverInfo: info,
            tlsActive: info.tlsActive, usedTunnel: usedTunnel,
            warnings: Self.warnings(for: profile, info: info, usedTunnel: usedTunnel))
    }

    static func warnings(for profile: ConnectionProfile, info: ServerInfo, usedTunnel: Bool) -> [String] {
        var out: [String] = []
        if profile.engine != info.engine {
            out.append("This connection is set up as \(profile.engine.displayName), but the server is \(info.engine.displayName). Switch the engine to \(info.engine.displayName) in the connection settings.")
        }
        if profile.tls.mode == .preferred && !info.tlsActive {
            out.append("Connection is not encrypted. The server didn't offer TLS; choose a stricter TLS mode if you need encryption.")
        }
        if profile.isProduction && !info.tlsActive && !usedTunnel {
            out.append("This production connection is neither encrypted with TLS nor tunnelled over SSH.")
        }
        return out
    }
}
