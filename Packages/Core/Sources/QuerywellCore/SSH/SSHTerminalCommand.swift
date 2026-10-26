import Foundation

/// The `ssh` invocation behind the SSH terminal tab: the same client options as tunnels and remote dumps
/// (user's ssh config, host-key policy, key / agent / password authentication) with a forced pseudo-terminal
/// and without `BatchMode`, so ssh can still ask for anything the Keychain doesn't hold (a key passphrase,
/// a keyboard-interactive code) right in the terminal.
public struct SSHTerminalCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public static func make(
        for config: SSHTunnelConfig, options: SSHClientOptions = SSHClientOptions(), hasSecret: Bool
    ) -> SSHTerminalCommand {
        // `extraOptions` come first and ssh keeps the first value it sees: quiet the "Permanently added" notice.
        var o = options
        o.extraOptions = ["LogLevel=ERROR"] + o.extraOptions
        var args = SSHCommandBuilder.baseArguments(for: config, options: o, hasSecret: hasSecret)
        args = removingOption("BatchMode=yes", from: args)
        // A person is at the keyboard: allow a few password attempts instead of the tunnel's single try.
        args = removingOption("NumberOfPasswordPrompts=1", from: args)
        args += ["-o", "NumberOfPasswordPrompts=3", "-t", SSHCommandBuilder.destination(for: config)]
        return SSHTerminalCommand(executable: options.sshExecutable, arguments: args)
    }

    private static func removingOption(_ option: String, from args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-o", i + 1 < args.count, args[i + 1] == option { i += 2; continue }
            out.append(args[i])
            i += 1
        }
        return out
    }
}
