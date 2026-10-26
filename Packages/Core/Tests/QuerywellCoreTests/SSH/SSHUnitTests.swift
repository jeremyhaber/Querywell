import Foundation
import Testing
@testable import QuerywellCore

@Suite("SSH command builder")
struct SSHCommandBuilderTests {
    let noConfig = SSHClientOptions(useUserSSHConfig: false)

    private func pairs(_ args: [String]) -> [String] {
        // Collect "-o X" values for easy membership checks.
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-o", i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 }
        }
        return out
    }

    @Test func passwordAuth() {
        let cfg = SSHTunnelConfig(host: "bastion", port: 2222, user: "me", auth: .password)
        let args = SSHCommandBuilder.tunnelArguments(
            for: cfg, options: noConfig, hasSecret: true, localPort: 5555, remoteHost: "db", remotePort: 3306)
        #expect(Array(args.prefix(4)) == ["-F", "/dev/null", "-p", "2222"])
        let o = pairs(args)
        #expect(o.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(o.contains("PubkeyAuthentication=no"))
        #expect(o.contains("IdentityAgent=none"))
        #expect(!o.contains("BatchMode=yes"))
        #expect(o.contains("ExitOnForwardFailure=yes"))
        #expect(o.contains("ServerAliveInterval=30"))
        #expect(o.contains("ServerAliveCountMax=3"))
        #expect(o.contains("NumberOfPasswordPrompts=1"))
        #expect(o.contains("StrictHostKeyChecking=accept-new"))
        #expect(o.contains("LogLevel=INFO"))
        #expect(args.suffix(4) == ["-N", "-L", "127.0.0.1:5555:db:3306", "me@bastion"])
    }

    @Test func passwordWithoutSecretIsBatch() {
        let cfg = SSHTunnelConfig(host: "h", user: "u", auth: .password)
        #expect(pairs(SSHCommandBuilder.baseArguments(for: cfg, hasSecret: false)).contains("BatchMode=yes"))
    }

    @Test func keyFileAuthWithAndWithoutPassphrase() {
        let cfg = SSHTunnelConfig(host: "h", user: "u", auth: .keyFile(path: "~/keys/id"))
        let withPass = SSHCommandBuilder.baseArguments(for: cfg, options: noConfig, hasSecret: true)
        let expanded = NSHomeDirectory() + "/keys/id"
        let idx = withPass.firstIndex(of: "-i")
        #expect(idx != nil)
        #expect(withPass[idx! + 1] == expanded)
        #expect(pairs(withPass).contains("IdentitiesOnly=yes"))
        #expect(pairs(withPass).contains("IdentityAgent=none"))
        #expect(!pairs(withPass).contains("BatchMode=yes"))
        let noPass = SSHCommandBuilder.baseArguments(for: cfg, options: noConfig, hasSecret: false)
        #expect(pairs(noPass).contains("BatchMode=yes"))
    }

    @Test func agentAuth() {
        let def = SSHTunnelConfig(host: "h", user: "u", auth: .agent(socketPath: nil))
        let o1 = pairs(SSHCommandBuilder.baseArguments(for: def, options: noConfig, hasSecret: false))
        #expect(o1.contains("IdentityAgent=SSH_AUTH_SOCK"))
        #expect(o1.contains("BatchMode=yes"))

        let op = SSHTunnelConfig(host: "h", user: "u", auth: .agent(socketPath: SSHAuthMethod.onePasswordAgentSocketPath))
        let o2 = pairs(SSHCommandBuilder.baseArguments(for: op, options: noConfig, hasSecret: false))
        let home = NSHomeDirectory()
        // Path contains spaces, so it must be quoted for ssh's config parser.
        #expect(o2.contains("IdentityAgent=\"\(home)/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\""))
    }

    @Test func userConfigToggle() {
        let cfg = SSHTunnelConfig(host: "h", user: "u", auth: .password)
        let on = SSHCommandBuilder.baseArguments(for: cfg, options: SSHClientOptions(useUserSSHConfig: true), hasSecret: true)
        #expect(!on.contains("-F"))
        let off = SSHCommandBuilder.baseArguments(for: cfg, options: noConfig, hasSecret: true)
        #expect(Array(off.prefix(2)) == ["-F", "/dev/null"])
    }

    @Test func knownHostsStrictAndExtras() {
        let cfg = SSHTunnelConfig(host: "h", user: "u", auth: .password)
        let opts = SSHClientOptions(
            knownHostsFile: "~/kh dir/known_hosts", useUserSSHConfig: false,
            strictHostKeyChecking: "yes", extraOptions: ["Compression=yes"])
        let o = pairs(SSHCommandBuilder.baseArguments(for: cfg, options: opts, hasSecret: true))
        #expect(o.contains("UserKnownHostsFile=\"\(NSHomeDirectory())/kh dir/known_hosts\""))
        #expect(o.contains("StrictHostKeyChecking=yes"))
        #expect(o.firstIndex(of: "Compression=yes")! < o.firstIndex(of: "ServerAliveInterval=30")!)
    }

    @Test func forwardArgumentsBracketIPv6() {
        let f = SSHCommandBuilder.forwardArguments(localPort: 1, remoteHost: "::1", remotePort: 5432)
        #expect(f.last == "127.0.0.1:1:[::1]:5432")
    }
}

@Suite("SSH error mapping")
struct SSHErrorMapperTests {
    @Test func mapping() {
        func m(_ s: String, _ st: Int32 = 255) -> SSHTunnelError { SSHErrorMapper.map(status: st, stderr: s) }
        #expect(m("u@h: Permission denied (publickey,password).") == .authenticationFailed("u@h: Permission denied (publickey,password)."))
        if case .hostKeyMismatch = m("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@") {} else { Issue.record("expected hostKeyMismatch") }
        if case .hostKeyMismatch = m("Host key verification failed.") {} else { Issue.record("expected hostKeyMismatch") }
        if case .forwardFailed = m("bind [127.0.0.1]:5: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 5\nCould not request local forwarding.") {} else { Issue.record("expected forwardFailed") }
        #expect(m("ssh: Could not resolve hostname nope", 255) == .exited(status: 255, stderr: "ssh: Could not resolve hostname nope"))
        // Host key wins over permission denied when both appear.
        if case .hostKeyMismatch = m("Host key verification failed.\nPermission denied") {} else { Issue.record("expected hostKeyMismatch") }
    }

    @Test func missingSSHBinary() async {
        let provider = SystemSSHTunnelProvider(options: SSHClientOptions(sshExecutable: "/nonexistent/ssh"))
        let req = SSHTunnelRequest(ssh: SSHTunnelConfig(host: "h", user: "u", auth: .password), remoteHost: "x", remotePort: 1)
        do {
            _ = try await provider.open(req)
            Issue.record("expected throw")
        } catch let e as SSHTunnelError {
            if case .sshNotFound = e {} else { Issue.record("wrong error \(e)") }
        } catch { Issue.record("wrong error \(error)") }
    }
}

@Suite("SSH askpass and ports")
struct SSHAskpassTests {
    private func perms(_ url: URL) throws -> Int {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return (a[.posixPermissions] as! NSNumber).intValue
    }

    @Test func permissionsContentAndCleanup() throws {
        let askpass = try SSHAskpass.create(secret: "s3cr'et pw")
        #expect(try perms(askpass.directory) == 0o700)
        #expect(try perms(askpass.secretURL) == 0o600)
        #expect(try perms(askpass.scriptURL) == 0o700)
        #expect(askpass.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(try String(contentsOf: askpass.secretURL, encoding: .utf8) == "s3cr'et pw")
        #expect(askpass.environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(askpass.environment.values.allSatisfy { !$0.contains("s3cr") })

        // The script really prints the secret.
        let p = Process()
        p.executableURL = askpass.scriptURL
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "s3cr'et pw")

        askpass.cleanup()
        #expect(!FileManager.default.fileExists(atPath: askpass.directory.path))
    }

    @Test func freePortsAreDistinct() throws {
        let ports = try (0..<20).map { _ in try LoopbackPort.findFree() }
        #expect(Set(ports).count == ports.count)
    }

    @Test func freePortIsBindable() throws {
        // Other tests open sockets concurrently and may grab a just-probed port (that's why the
        // provider retries); hold the first one we can actually bind.
        var port = 0
        var fd: Int32 = -1
        var b: Int32 = -1
        for _ in 0..<10 {
            port = try LoopbackPort.findFree()
            #expect(port > 0 && port < 65536)
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port)).bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            b = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if b == 0 { break }
            close(fd)
        }
        defer { close(fd) }
        #expect(b == 0)
        listen(fd, 1)
        // Held, so it must read as in use.
        #expect(LoopbackPort.isInUse(port))
    }
}

@Suite("SSH forward failure parsing")
struct SSHForwardFailureTests {
    @Test func extractsReason() {
        let err = "Warning: Permanently added '[127.0.0.1]:12222' (ED25519) to the list of known hosts.\nchannel 1: open failed: connect failed: Name does not resolve\n"
        #expect(SSHErrorMapper.forwardFailure(in: err) == "connect failed: Name does not resolve")
    }

    @Test func nilWhenHealthy() {
        #expect(SSHErrorMapper.forwardFailure(in: "") == nil)
        #expect(SSHErrorMapper.forwardFailure(in: "Warning: Permanently added host.\n") == nil)
    }
}
