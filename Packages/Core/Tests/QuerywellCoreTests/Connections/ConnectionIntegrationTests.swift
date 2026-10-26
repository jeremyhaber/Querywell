import Foundation
import Testing
import os

@testable import QuerywellCore

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

/// Wraps the real provider and remembers the tunnels it opened.
private final class RecordingProvider: SSHTunnelProvider {
    let inner: SystemSSHTunnelProvider
    private let opened = OSAllocatedUnfairLock(initialState: [any SSHTunnel]())
    init(inner: SystemSSHTunnelProvider) { self.inner = inner }
    var tunnels: [any SSHTunnel] { opened.withLock { $0 } }
    func open(_ request: SSHTunnelRequest) async throws -> any SSHTunnel {
        let t = try await inner.open(request)
        opened.withLock { $0.append(t) }
        return t
    }
}

/// Key copy (0600) and a throwaway known_hosts.
private final class SSHFixture: @unchecked Sendable {
    // @unchecked Sendable: immutable after init.
    let dir: URL
    let keyPlain: String
    let knownHosts: String

    init() throws {
        guard let src = ProcessInfo.processInfo.environment["QUERYWELL_TEST_SSH_DIR"] else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "QUERYWELL_TEST_SSH_DIR not set"])
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-conn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dst = dir.appendingPathComponent("id_ed25519")
        try FileManager.default.copyItem(atPath: src + "/id_ed25519", toPath: dst.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        keyPlain = dst.path
        knownHosts = dir.appendingPathComponent("known_hosts").path
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func provider() -> RecordingProvider {
        RecordingProvider(inner: SystemSSHTunnelProvider(options: SSHClientOptions(knownHostsFile: knownHosts, useUserSSHConfig: false)))
    }
}

struct ConnTarget: Sendable, CustomTestStringConvertible {
    var name: String
    var engine: DatabaseEngine
    var directPort: Int
    /// Hostname/port of the database as seen from the SSH bastion.
    var remoteHost: String
    var remotePort: Int
    var testDescription: String { name }

    static let mysql8 = ConnTarget(name: "mysql-8.4", engine: .mysql, directPort: 13306, remoteHost: "mysql8", remotePort: 3306)
    static let mariadb = ConnTarget(name: "mariadb-11.4", engine: .mariadb, directPort: 13307, remoteHost: "mariadb11", remotePort: 3306)
    static let postgres = ConnTarget(name: "postgres-16", engine: .postgresql, directPort: 15432, remoteHost: "postgres16", remotePort: 5432)

    func direct() -> ConnectionProfile {
        ConnectionProfile(
            name: name, engine: engine, host: "127.0.0.1", port: directPort, user: "querywell",
            defaultDatabase: "querywell_test", tls: TLSConfig(mode: .disabled))
    }

    func tunnelled(auth: SSHAuthMethod, host: String? = nil) -> ConnectionProfile {
        ConnectionProfile(
            name: name, engine: engine, host: host ?? remoteHost, port: remotePort, user: "querywell",
            defaultDatabase: "querywell_test",
            ssh: SSHTunnelConfig(host: "127.0.0.1", port: 12222, user: "querywell", auth: auth),
            tls: TLSConfig(mode: .preferred))
    }
}

@Suite("Connection integration", .serialized, .enabled(if: integrationEnabled))
struct ConnectionIntegrationTests {
    private func store(for p: ConnectionProfile, dbPassword: String = "querywell_pw", sshPassword: String? = "querywell_ssh_pw") throws -> InMemorySecretStore {
        let s = InMemorySecretStore()
        try s.write(dbPassword, for: SecretKey(ownerID: p.id.uuidString, kind: .databasePassword))
        if let sshPassword { try s.write(sshPassword, for: SecretKey(ownerID: p.id.uuidString, kind: .sshPassword)) }
        return s
    }

    @Test(arguments: [ConnTarget.mysql8, .mariadb, .postgres])
    func directSucceeds(target: ConnTarget) async throws {
        let p = target.direct()
        let report = await ConnectionTester(secretStore: try store(for: p)).test(p)
        #expect(report.succeeded, "\(String(describing: report.error))")
        #expect(report.serverInfo?.engine == target.engine)
        #expect(report.latency != nil)
        #expect(!report.usedTunnel)
    }

    @Test(arguments: [ConnTarget.mysql8, .postgres])
    func tunnelWithPasswordSucceeds(target: ConnTarget) async throws {
        let fx = try SSHFixture()
        let provider = fx.provider()
        let p = target.tunnelled(auth: .password)
        let report = await ConnectionTester(secretStore: try store(for: p), tunnelProvider: provider).test(p)
        #expect(report.succeeded, "\(String(describing: report.error))")
        #expect(report.usedTunnel)
        #expect(report.serverInfo?.engine == target.engine)
        #expect(report.stages.contains { if case .openingTunnel = $0.stage { true } else { false } })
        for t in provider.tunnels { #expect(!(await t.isRunning)) }
    }

    @Test(arguments: [ConnTarget.mysql8, .postgres])
    func tunnelWithKeySucceeds(target: ConnTarget) async throws {
        let fx = try SSHFixture()
        let p = target.tunnelled(auth: .keyFile(path: fx.keyPlain))
        let report = await ConnectionTester(secretStore: try store(for: p, sshPassword: nil), tunnelProvider: fx.provider()).test(p)
        #expect(report.succeeded, "\(String(describing: report.error))")
        #expect(report.usedTunnel)
    }

    @Test func secretsOverrideStoreForUnsavedProfile() async throws {
        let fx = try SSHFixture()
        let p = ConnTarget.mysql8.tunnelled(auth: .password)
        let tester = ConnectionTester(secretStore: InMemorySecretStore(), tunnelProvider: fx.provider())
        let report = await tester.test(p, secrets: ConnectionSecrets(databasePassword: "querywell_pw", sshSecret: "querywell_ssh_pw"))
        #expect(report.succeeded, "\(String(describing: report.error))")
    }

    @Test func wrongDatabasePasswordThroughTunnelClosesTunnel() async throws {
        let fx = try SSHFixture()
        let provider = fx.provider()
        let p = ConnTarget.mysql8.tunnelled(auth: .password)
        let report = await ConnectionTester(secretStore: try store(for: p, dbPassword: "wrong"), tunnelProvider: provider).test(p)
        #expect(!report.succeeded)
        if case .database(.authenticationFailed) = report.error {} else { Issue.record("wrong error \(String(describing: report.error))") }
        #expect(provider.tunnels.count == 1)
        for t in provider.tunnels { #expect(!(await t.isRunning)) }
    }

    @Test func nonexistentDatabaseHostThroughTunnel() async throws {
        let fx = try SSHFixture()
        let provider = fx.provider()
        let p = ConnTarget.mysql8.tunnelled(auth: .password, host: "nosuchhost")
        let start = ContinuousClock.now
        let report = await ConnectionTester(secretStore: try store(for: p), tunnelProvider: provider).test(p)
        #expect(!report.succeeded)
        // Fails fast on ssh's "open failed" instead of waiting out the driver's 15s timeout.
        #expect(ContinuousClock.now - start < .seconds(10))  // not the driver's 15 s timeout
        if case .databaseUnreachableThroughTunnel(let host, let port, let underlying) = report.error {
            #expect(host == "nosuchhost" && port == 3306)
            #expect(underlying == .connectionFailed("connect failed: Name does not resolve"))
        } else {
            Issue.record("wrong error \(String(describing: report.error))")
        }
        for t in provider.tunnels { #expect(!(await t.isRunning)) }
    }
}
