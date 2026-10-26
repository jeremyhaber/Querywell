import Foundation
import Testing

@testable import QuerywellCore

@Suite("SSH terminal command")
struct SSHTerminalCommandTests {
    private let password = SSHTunnelConfig(host: "web01.example.com", port: 2222, user: "deploy", auth: .password)

    @Test func forcesATTYAndEndsWithTheDestination() {
        let cmd = SSHTerminalCommand.make(for: password, hasSecret: true)
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments.suffix(2) == ["-t", "deploy@web01.example.com"])
        #expect(cmd.arguments.contains("2222"))
    }

    @Test func neverRunsInBatchModeSoSshCanPrompt() {
        let cmd = SSHTerminalCommand.make(for: password, hasSecret: false)
        #expect(!cmd.arguments.contains("BatchMode=yes"))
        let key = SSHTunnelConfig(host: "h", user: "u", auth: .keyFile(path: "/tmp/k"))
        #expect(!SSHTerminalCommand.make(for: key, hasSecret: false).arguments.contains("BatchMode=yes"))
        // The tunnel builder would have used it.
        #expect(SSHCommandBuilder.baseArguments(for: key, hasSecret: false).contains("BatchMode=yes"))
    }

    @Test func keepsTheHostKeyPolicyAndConfigOfTunnels() {
        let cmd = SSHTerminalCommand.make(for: password, options: SSHClientOptions(useUserSSHConfig: true), hasSecret: true)
        #expect(cmd.arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(!cmd.arguments.contains("-F"))
        let isolated = SSHTerminalCommand.make(for: password, options: SSHClientOptions(useUserSSHConfig: false), hasSecret: true)
        #expect(isolated.arguments.starts(with: ["-F", "/dev/null"]))
    }

    @Test func allowsSeveralPasswordAttemptsAndQuietsNotices() {
        let args = SSHTerminalCommand.make(for: password, hasSecret: true).arguments
        #expect(args.contains("NumberOfPasswordPrompts=3"))
        #expect(!args.contains("NumberOfPasswordPrompts=1"))
        let log = args.firstIndex(of: "LogLevel=ERROR")
        let info = args.firstIndex(of: "LogLevel=INFO")
        #expect(log != nil && info != nil && log! < info!)  // ssh keeps the first value
    }
}
