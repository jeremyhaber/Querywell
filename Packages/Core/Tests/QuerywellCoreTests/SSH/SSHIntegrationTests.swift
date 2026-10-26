import Foundation
import Testing
@testable import QuerywellCore

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

/// Fixture: private key copies (0600), a throwaway known_hosts, and helpers for raw socket I/O.
private final class Fixture: @unchecked Sendable {
    // @unchecked Sendable: immutable after init.
    let dir: URL
    let keyPlain: String
    let keyEnc: String
    let passphrase: String
    let knownHosts: String

    init() throws {
        guard let src = ProcessInfo.processInfo.environment["QUERYWELL_TEST_SSH_DIR"] else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "QUERYWELL_TEST_SSH_DIR not set"])
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["id_ed25519", "id_ed25519_enc"] {
            let dst = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(atPath: src + "/" + name, toPath: dst.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        keyPlain = dir.appendingPathComponent("id_ed25519").path
        keyEnc = dir.appendingPathComponent("id_ed25519_enc").path
        passphrase = try String(contentsOfFile: src + "/passphrase", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        knownHosts = dir.appendingPathComponent("known_hosts").path
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func provider() -> SystemSSHTunnelProvider {
        SystemSSHTunnelProvider(options: SSHClientOptions(knownHostsFile: knownHosts, useUserSSHConfig: false))
    }

    func request(auth: SSHAuthMethod, secret: String?, host: String = "mysql8", port: Int = 3306) -> SSHTunnelRequest {
        SSHTunnelRequest(
            ssh: SSHTunnelConfig(host: "127.0.0.1", port: 12222, user: "querywell", auth: auth),
            secret: secret, remoteHost: host, remotePort: port, connectTimeout: .seconds(15))
    }
}

/// Connects to 127.0.0.1:port, optionally sends bytes, reads up to `max` bytes (5 s timeout).
private func exchange(port: Int, send: [UInt8] = [], max: Int = 256) throws -> [UInt8] {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
    if !send.isEmpty { _ = send.withUnsafeBytes { write(fd, $0.baseAddress, send.count) } }
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, 5000) > 0 else { throw POSIXError(.ETIMEDOUT) }
    var buf = [UInt8](repeating: 0, count: max)
    let n = read(fd, &buf, max)
    guard n > 0 else { return [] }
    return Array(buf.prefix(n))
}

private func mysqlGreeting(port: Int) throws -> String {
    let bytes = try exchange(port: port)
    // 4-byte header, protocol version 10, then NUL-terminated server version.
    #expect(bytes.count > 6)
    #expect(bytes[4] == 10)
    let version = bytes.dropFirst(5).prefix { $0 != 0 }
    return String(decoding: version, as: UTF8.self)
}

@Suite("SSH tunnel integration", .serialized, .enabled(if: integrationEnabled))
struct SSHIntegrationTests {
    @Test func passwordAuthReachesMySQL() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw"))
        #expect(tunnel.localHost == "127.0.0.1")
        #expect(await tunnel.isRunning)
        let version = try mysqlGreeting(port: tunnel.localPort)
        #expect(version.contains("8.4"), "greeting version: \(version)")
        await tunnel.close()
    }

    @Test func mariaDBThroughTunnel() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw", host: "mariadb11"))
        let version = try mysqlGreeting(port: tunnel.localPort)
        #expect(version.contains("11.4"), "greeting version: \(version)")
        await tunnel.close()
    }

    @Test func keyFileAuth() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .keyFile(path: fx.keyPlain), secret: nil))
        #expect(try mysqlGreeting(port: tunnel.localPort).contains("8.4"))
        await tunnel.close()
    }

    @Test func encryptedKeyWithPassphrase() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .keyFile(path: fx.keyEnc), secret: fx.passphrase))
        #expect(try mysqlGreeting(port: tunnel.localPort).contains("8.4"))
        await tunnel.close()
    }

    @Test func encryptedKeyWithoutPassphraseFails() async throws {
        let fx = try Fixture()
        do {
            _ = try await fx.provider().open(fx.request(auth: .keyFile(path: fx.keyEnc), secret: nil))
            Issue.record("expected failure")
        } catch let e as SSHTunnelError {
            if case .authenticationFailed = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func agentAuth() async throws {
        let fx = try Fixture()
        // Unix socket paths are limited to ~104 bytes, so use a short /tmp directory.
        let sockDir = "/tmp/qw-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: sockDir) }
        let sock = sockDir + "/a"

        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", sock]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: sock) { try await Task.sleep(for: .milliseconds(100)) }

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = [fx.keyPlain]
        add.environment = ["SSH_AUTH_SOCK": sock]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()
        #expect(add.terminationStatus == 0)

        let tunnel = try await fx.provider().open(fx.request(auth: .agent(socketPath: sock), secret: nil))
        #expect(try mysqlGreeting(port: tunnel.localPort).contains("8.4"))
        await tunnel.close()
    }

    @Test func agentWithoutKeysFails() async throws {
        let fx = try Fixture()
        let sockDir = "/tmp/qw-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: sockDir) }
        let sock = sockDir + "/a"
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", sock]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: sock) { try await Task.sleep(for: .milliseconds(100)) }
        do {
            _ = try await fx.provider().open(fx.request(auth: .agent(socketPath: sock), secret: nil))
            Issue.record("expected failure")
        } catch let e as SSHTunnelError {
            if case .authenticationFailed = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func wrongPassword() async throws {
        let fx = try Fixture()
        do {
            _ = try await fx.provider().open(fx.request(auth: .password, secret: "definitely-wrong"))
            Issue.record("expected failure")
        } catch let e as SSHTunnelError {
            if case .authenticationFailed = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func postgresSSLRequestThroughTunnel() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw", host: "postgres16", port: 5432))
        let reply = try exchange(port: tunnel.localPort, send: [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F], max: 1)
        #expect(reply == [UInt8(ascii: "S")])  // the compose Postgres has ssl=on
        await tunnel.close()
    }

    @Test func closeRefusesConnectionsAndIsIdempotent() async throws {
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw"))
        let port = tunnel.localPort
        #expect(await tunnel.isRunning)
        await tunnel.close()
        await tunnel.close()
        #expect(!(await tunnel.isRunning))
        #expect(throws: POSIXError.self) { _ = try exchange(port: port) }
    }

    @Test func hostKeyMismatch() async throws {
        let fx = try Fixture()
        // A freshly generated, unrelated ed25519 key recorded for the bastion.
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        let bogus = fx.dir.appendingPathComponent("bogus").path
        gen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", bogus]
        try gen.run()
        gen.waitUntilExit()
        let pub = try String(contentsOfFile: bogus + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:12222 \(pub)\n".write(toFile: fx.knownHosts, atomically: true, encoding: .utf8)
        do {
            _ = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw"))
            Issue.record("expected failure")
        } catch let e as SSHTunnelError {
            if case .hostKeyMismatch = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func forwardToUnreachableHostStillOpensTunnel() async throws {
        // ssh only opens the channel on first use, so the tunnel itself comes up; connecting yields EOF.
        let fx = try Fixture()
        let tunnel = try await fx.provider().open(fx.request(auth: .password, secret: "querywell_ssh_pw", host: "nonexistent-host", port: 1))
        #expect(await tunnel.isRunning)
        await tunnel.close()
    }
}
