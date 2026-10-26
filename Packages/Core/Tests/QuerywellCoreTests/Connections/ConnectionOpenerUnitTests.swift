import Foundation
import Testing
import os

@testable import QuerywellCore

// MARK: Fakes

final class FakeSession: DatabaseSession {
    let engine: DatabaseEngine
    let serverInfo: ServerInfo
    private let state = OSAllocatedUnfairLock(initialState: (closes: 0, statements: [String]()))
    var closeCount: Int { state.withLock { $0.closes } }
    var statements: [String] { state.withLock { $0.statements } }
    let order: OSAllocatedUnfairLock<[String]>?

    init(info: ServerInfo, order: OSAllocatedUnfairLock<[String]>? = nil) {
        self.order = order
        self.engine = info.engine
        self.serverInfo = info
    }

    func execute(_ sql: String) async throws -> QueryResult {
        state.withLock { $0.statements.append(sql) }
        return QueryResult(columns: [ColumnInfo(name: "1", typeName: "int")], rows: [[.integer(1)]])
    }
    func listDatabases() async throws -> [String] { [] }
    func currentDatabase() async throws -> String? { nil }
    func close() async {
        state.withLock { $0.closes += 1 }
        order?.withLock { $0.append("session") }
    }
}

final class FakeDriver: DatabaseDriver {
    let engines: Set<DatabaseEngine> = Set(DatabaseEngine.allCases)
    let info: ServerInfo
    let failure: DatabaseError?
    private let configs = OSAllocatedUnfairLock(initialState: [ConnectionConfiguration]())
    let order: OSAllocatedUnfairLock<[String]>?
    private let sessions = OSAllocatedUnfairLock(initialState: [FakeSession]())

    init(info: ServerInfo = .fake(.mysql), failure: DatabaseError? = nil, order: OSAllocatedUnfairLock<[String]>? = nil) {
        self.info = info
        self.failure = failure
        self.order = order
    }

    var configurations: [ConnectionConfiguration] { configs.withLock { $0 } }
    var openedSessions: [FakeSession] { sessions.withLock { $0 } }

    func connect(_ configuration: ConnectionConfiguration) async throws -> any DatabaseSession {
        configs.withLock { $0.append(configuration) }
        if let failure { throw failure }
        let s = FakeSession(info: info, order: order)
        sessions.withLock { $0.append(s) }
        return s
    }
}

extension ServerInfo {
    static func fake(_ engine: DatabaseEngine, tls: Bool = false) -> ServerInfo {
        ServerInfo(engine: engine, versionString: "1.2.3", major: 1, minor: 2, patch: 3, tlsActive: tls)
    }
}

final class FakeTunnel: SSHTunnel {
    let localHost = "127.0.0.1"
    let localPort: Int
    private let state = OSAllocatedUnfairLock(initialState: 0)
    let order: OSAllocatedUnfairLock<[String]>?
    init(localPort: Int, order: OSAllocatedUnfairLock<[String]>? = nil) {
        self.localPort = localPort
        self.order = order
    }
    var closeCount: Int { state.withLock { $0 } }
    var isRunning: Bool { get async { closeCount == 0 } }
    func close() async {
        state.withLock { $0 += 1 }
        order?.withLock { $0.append("tunnel") }
    }
}

final class FakeTunnelProvider: SSHTunnelProvider {
    private let requests = OSAllocatedUnfairLock(initialState: [SSHTunnelRequest]())
    private let tunnels = OSAllocatedUnfairLock(initialState: [FakeTunnel]())
    let failure: SSHTunnelError?
    init(failure: SSHTunnelError? = nil) { self.failure = failure }
    var receivedRequests: [SSHTunnelRequest] { requests.withLock { $0 } }
    var openedTunnels: [FakeTunnel] { tunnels.withLock { $0 } }

    func open(_ request: SSHTunnelRequest) async throws -> any SSHTunnel {
        requests.withLock { $0.append(request) }
        if let failure { throw failure }
        let t = FakeTunnel(localPort: 40_000 + tunnels.withLock { $0.count })
        tunnels.withLock { $0.append(t) }
        return t
    }
}

struct ThrowingSecretStore: SecretStore {
    func read(_ key: SecretKey) throws -> String? { throw SecretStoreError.keychain(status: -25293, message: "denied") }
    func write(_ value: String, for key: SecretKey) throws {}
    func delete(_ key: SecretKey) throws {}
    func deleteAll(ownerID: String) throws {}
}

private func profile(
    engine: DatabaseEngine = .mysql, ssh: SSHTunnelConfig? = nil, tls: TLSConfig = TLSConfig(mode: .disabled),
    tag: ColorTag? = nil
) -> ConnectionProfile {
    ConnectionProfile(
        name: "Test", colorTag: tag, engine: engine, host: "db.internal", port: 3306, user: "app",
        defaultDatabase: "main", ssh: ssh, tls: tls)
}

private let sshConfig = SSHTunnelConfig(host: "bastion", port: 22, user: "me", auth: .password)

private func opener(
    _ driver: FakeDriver, _ tunnels: FakeTunnelProvider = FakeTunnelProvider(), store: any SecretStore = InMemorySecretStore()
) -> ConnectionOpener {
    ConnectionOpener(secretStore: store, tunnelProvider: tunnels, driverForEngine: { _ in driver })
}

// MARK: Opener

@Suite("ConnectionOpener")
struct ConnectionOpenerUnitTests {
    @Test func directPath() async throws {
        let p = profile()
        let store = InMemorySecretStore()
        try store.write("pw", for: SecretKey(ownerID: p.id.uuidString, kind: .databasePassword))
        let driver = FakeDriver()
        let tunnels = FakeTunnelProvider()
        let live = try await opener(driver, tunnels, store: store).open(p)
        let cfg = try #require(driver.configurations.first)
        #expect(cfg.host == "db.internal" && cfg.port == 3306)
        #expect(cfg.password == "pw")
        #expect(cfg.database == "main")
        #expect(cfg.tlsServerName == nil)
        #expect(tunnels.receivedRequests.isEmpty)
        #expect(live.tunnel == nil)
    }

    @Test func databaseOverride() async throws {
        let driver = FakeDriver()
        _ = try await opener(driver).open(profile(), database: "other")
        #expect(driver.configurations.first?.database == "other")
    }

    @Test func tunnelPath() async throws {
        let p = profile(ssh: sshConfig)
        let store = InMemorySecretStore()
        try store.write("sshpw", for: SecretKey(ownerID: p.id.uuidString, kind: .sshPassword))
        let driver = FakeDriver()
        let tunnels = FakeTunnelProvider()
        let live = try await opener(driver, tunnels, store: store).open(p)
        let req = try #require(tunnels.receivedRequests.first)
        #expect(req.remoteHost == "db.internal" && req.remotePort == 3306)
        #expect(req.secret == "sshpw")
        let tunnel = try #require(tunnels.openedTunnels.first)
        let cfg = try #require(driver.configurations.first)
        #expect(cfg.host == "127.0.0.1" && cfg.port == tunnel.localPort)
        #expect(cfg.tlsServerName == "db.internal")
        #expect(live.tunnel != nil)
    }

    @Test func keyPassphraseIsReadForKeyAuth() async throws {
        let p = profile(ssh: SSHTunnelConfig(host: "b", user: "me", auth: .keyFile(path: "/k")))
        let store = InMemorySecretStore()
        try store.write("phrase", for: SecretKey(ownerID: p.id.uuidString, kind: .sshKeyPassphrase))
        let tunnels = FakeTunnelProvider()
        _ = try await opener(FakeDriver(), tunnels, store: store).open(p)
        #expect(tunnels.receivedRequests.first?.secret == "phrase")
    }

    @Test func tunnelClosedWhenDriverFails() async throws {
        let tunnels = FakeTunnelProvider()
        let driver = FakeDriver(failure: .authenticationFailed("bad"))
        await #expect(throws: ConnectionOpenError.database(.authenticationFailed("bad"))) {
            _ = try await opener(driver, tunnels).open(profile(ssh: sshConfig))
        }
        #expect(tunnels.openedTunnels.first?.closeCount == 1)
    }

    @Test func unreachableThroughTunnel() async throws {
        let tunnels = FakeTunnelProvider()
        let driver = FakeDriver(failure: .connectionFailed("closed"))
        await #expect(throws: ConnectionOpenError.databaseUnreachableThroughTunnel(host: "db.internal", port: 3306, underlying: .connectionFailed("closed"))) {
            _ = try await opener(driver, tunnels).open(profile(ssh: sshConfig))
        }
        #expect(tunnels.openedTunnels.first?.closeCount == 1)
    }

    @Test func timeoutThroughTunnelIsUnreachable() async {
        let driver = FakeDriver(failure: .timeout)
        await #expect(throws: ConnectionOpenError.databaseUnreachableThroughTunnel(host: "db.internal", port: 3306, underlying: .timeout)) {
            _ = try await opener(driver).open(profile(ssh: sshConfig))
        }
    }

    @Test func connectionFailedDirectStaysDatabaseError() async {
        let driver = FakeDriver(failure: .connectionFailed("refused"))
        await #expect(throws: ConnectionOpenError.database(.connectionFailed("refused"))) {
            _ = try await opener(driver).open(profile())
        }
    }

    @Test func tunnelErrorWrapped() async {
        let tunnels = FakeTunnelProvider(failure: .timeout)
        await #expect(throws: ConnectionOpenError.tunnel(.timeout)) {
            _ = try await opener(FakeDriver(), tunnels).open(profile(ssh: sshConfig))
        }
    }

    @Test func invalidProfile() async {
        var p = profile()
        p.host = " "
        let driver = FakeDriver()
        await #expect(throws: ConnectionOpenError.invalidProfile([.emptyHost])) {
            _ = try await opener(driver).open(p)
        }
        #expect(driver.configurations.isEmpty)
    }

    @Test func missingPasswordIsFine() async throws {
        let driver = FakeDriver()
        _ = try await opener(driver).open(profile())
        #expect(driver.configurations.first?.password == nil)
    }

    @Test func secretReadFailure() async {
        let o = opener(FakeDriver(), store: ThrowingSecretStore())
        do {
            _ = try await o.open(profile())
            Issue.record("expected failure")
        } catch let e as ConnectionOpenError {
            if case .secretUnavailable(let m) = e { #expect(m == "denied") } else { Issue.record("wrong error \(e)") }
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func stageOrderDirect() async throws {
        let stages = OSAllocatedUnfairLock(initialState: [ConnectionStage]())
        _ = try await opener(FakeDriver()).open(profile(), progress: { s in stages.withLock { $0.append(s) } })
        #expect(stages.withLock { $0 } == [.validating, .readingSecrets, .connecting(host: "db.internal", port: 3306), .connected])
    }

    @Test func stageOrderTunnel() async throws {
        let stages = OSAllocatedUnfairLock(initialState: [ConnectionStage]())
        _ = try await opener(FakeDriver()).open(profile(ssh: sshConfig), progress: { s in stages.withLock { $0.append(s) } })
        #expect(stages.withLock { $0 } == [
            .validating, .readingSecrets, .openingTunnel(host: "bastion"),
            .connecting(host: "db.internal", port: 3306), .connected,
        ])
    }

    @Test func everyErrorHasMessage() {
        let errors: [ConnectionOpenError] = [
            .invalidProfile([.emptyName]), .secretUnavailable("x"), .tunnel(.timeout),
            .tunnel(.hostKeyMismatch("x")), .tunnel(.authenticationFailed("x")),
            .database(.authenticationFailed("x")), .databaseUnreachableThroughTunnel(host: "h", port: 1, underlying: .connectionFailed("x")),
        ]
        for e in errors { #expect(!e.message.isEmpty); #expect(e.recoverySuggestion != nil) }
        #expect(ConnectionOpenError.database(.authenticationFailed("x")).recoverySuggestion == "Check the password saved for this connection.")
        #expect(ConnectionOpenError.tunnel(.hostKeyMismatch("x")).recoverySuggestion?.contains("ssh-keygen -R") == true)
    }
}

// MARK: LiveConnection

@Suite("LiveConnection")
struct LiveConnectionTests {
    @Test func closeIsIdempotentAndClosesBothInOrder() async {
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let session = FakeSession(info: .fake(.mysql), order: order)
        let tunnel = FakeTunnel(localPort: 1, order: order)
        let live = LiveConnection(profile: profile(), session: session, tunnel: tunnel)
        await live.close()
        await live.close()
        #expect(session.closeCount == 1)
        #expect(tunnel.closeCount == 1)
        #expect(order.withLock { $0 } == ["session", "tunnel"])
        #expect(await live.isClosed)
    }
}

// MARK: Tester

@Suite("ConnectionTester")
struct ConnectionTesterUnitTests {
    private func tester(_ driver: FakeDriver, _ tunnels: FakeTunnelProvider = FakeTunnelProvider(), store: any SecretStore = InMemorySecretStore()) -> ConnectionTester {
        ConnectionTester(opener: opener(driver, tunnels, store: store))
    }

    @Test func successReport() async throws {
        let driver = FakeDriver(info: .fake(.mysql, tls: true))
        let report = await tester(driver).test(profile())
        #expect(report.succeeded)
        #expect(report.error == nil)
        #expect(report.latency != nil)
        #expect(report.serverInfo?.engine == .mysql)
        #expect(report.tlsActive)
        #expect(!report.usedTunnel)
        #expect(report.stages.map(\.stage).last == .connected)
        #expect(driver.openedSessions.first?.statements == ["SELECT 1", "SELECT 1", "SELECT 1"])
        #expect(driver.openedSessions.first?.closeCount == 1)
    }

    @Test func tunnelReport() async {
        let tunnels = FakeTunnelProvider()
        let report = await tester(FakeDriver(), tunnels).test(profile(ssh: sshConfig))
        #expect(report.succeeded && report.usedTunnel)
        #expect(tunnels.openedTunnels.first?.closeCount == 1)
    }

    @Test func failureReportCarriesStage() async {
        let driver = FakeDriver(failure: .authenticationFailed("nope"))
        let report = await tester(driver).test(profile())
        #expect(!report.succeeded)
        #expect(report.error == .database(.authenticationFailed("nope")))
        #expect(report.failedStage == .connecting(host: "db.internal", port: 3306))
    }

    @Test func invalidProfileFailsAtValidating() async {
        var p = profile()
        p.user = ""
        let report = await tester(FakeDriver()).test(p)
        #expect(report.error == .invalidProfile([.emptyUser]))
        #expect(report.failedStage == .validating)
    }

    @Test func engineMismatchWarning() async {
        let report = await tester(FakeDriver(info: .fake(.mariadb))).test(profile(engine: .mysql))
        #expect(report.succeeded)
        #expect(report.warnings.contains { $0.contains("MariaDB") && $0.contains("MySQL") })
    }

    @Test func notEncryptedWarning() async {
        let report = await tester(FakeDriver(info: .fake(.mysql, tls: false))).test(profile(tls: TLSConfig(mode: .preferred)))
        #expect(report.warnings.contains { $0.contains("not encrypted") })
        let ok = await tester(FakeDriver(info: .fake(.mysql, tls: true))).test(profile(tls: TLSConfig(mode: .preferred)))
        #expect(ok.warnings.isEmpty)
    }

    @Test func productionWithoutTLSOrSSHWarning() async {
        let prod = profile(tag: .production)
        #expect(prod.isProduction)
        let report = await tester(FakeDriver()).test(prod)
        #expect(report.warnings.contains { $0.contains("production") })
        let tunnelled = await tester(FakeDriver()).test(profile(ssh: sshConfig, tag: .production))
        #expect(!tunnelled.warnings.contains { $0.contains("production") })
    }

    @Test func secretOverlayPrecedence() async throws {
        let p = profile(ssh: sshConfig)
        let store = InMemorySecretStore()
        try store.write("stored-db", for: SecretKey(ownerID: p.id.uuidString, kind: .databasePassword))
        try store.write("stored-ssh", for: SecretKey(ownerID: p.id.uuidString, kind: .sshPassword))
        let driver = FakeDriver()
        let tunnels = FakeTunnelProvider()
        let t = tester(driver, tunnels, store: store)

        _ = await t.test(p, secrets: ConnectionSecrets(databasePassword: "typed-db", sshSecret: "typed-ssh"))
        #expect(driver.configurations.last?.password == "typed-db")
        #expect(tunnels.receivedRequests.last?.secret == "typed-ssh")

        // Unprovided values fall through to the store.
        _ = await t.test(p, secrets: ConnectionSecrets(databasePassword: "typed-db"))
        #expect(tunnels.receivedRequests.last?.secret == "stored-ssh")

        // The store itself is untouched.
        #expect(try store.read(SecretKey(ownerID: p.id.uuidString, kind: .databasePassword)) == "stored-db")
    }

    @Test func progressIsForwarded() async {
        let stages = OSAllocatedUnfairLock(initialState: [ConnectionStage]())
        let report = await tester(FakeDriver()).test(profile(), progress: { s in stages.withLock { $0.append(s) } })
        #expect(stages.withLock { $0 } == report.stages.map(\.stage))
    }
}
