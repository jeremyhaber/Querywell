import Foundation

/// How the system `ssh` client is invoked. Shared by tunnels, the Phase 7 terminal and remote dump.
public struct SSHClientOptions: Sendable, Hashable {
    public var sshExecutable: String
    /// Custom known_hosts file (`UserKnownHostsFile`); `nil` = the user's default.
    public var knownHostsFile: String?
    /// `true` honours `~/.ssh/config` (ProxyJump, aliases); `false` passes `-F /dev/null`.
    public var useUserSSHConfig: Bool
    /// Value of `StrictHostKeyChecking` (`accept-new`, `yes`, `ask`, `no`).
    public var strictHostKeyChecking: String
    /// Extra `-o` values (`Key=Value`). Emitted first, so they win over defaults (ssh uses the first value seen).
    public var extraOptions: [String]

    public init(
        sshExecutable: String = "/usr/bin/ssh",
        knownHostsFile: String? = nil,
        useUserSSHConfig: Bool = true,
        strictHostKeyChecking: String = "accept-new",
        extraOptions: [String] = []
    ) {
        self.sshExecutable = sshExecutable
        self.knownHostsFile = knownHostsFile
        self.useUserSSHConfig = useUserSSHConfig
        self.strictHostKeyChecking = strictHostKeyChecking
        self.extraOptions = extraOptions
    }
}

/// Pure argv construction for the system `ssh` client.
public enum SSHCommandBuilder {
    /// Expands a leading `~` / `~/`.
    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Quotes an `-o Key=value` value for ssh's config parser when it contains whitespace or quotes.
    public static func quoteOptionValue(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Base arguments: config file, port, timeouts, host-key policy, authentication. No destination, no forward.
    /// - Parameter hasSecret: whether a password/passphrase will be supplied through askpass. Without one,
    ///   `BatchMode=yes` is set so ssh never blocks on a prompt.
    public static func baseArguments(
        for config: SSHTunnelConfig,
        options: SSHClientOptions = SSHClientOptions(),
        hasSecret: Bool,
        connectTimeoutSeconds: Int = 20
    ) -> [String] {
        var args: [String] = []
        if !options.useUserSSHConfig { args += ["-F", "/dev/null"] }
        args += ["-p", String(config.port)]
        for extra in options.extraOptions { args += ["-o", extra] }
        args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        args += ["-o", "ConnectTimeout=\(max(1, connectTimeoutSeconds))"]
        args += ["-o", "NumberOfPasswordPrompts=1"]
        args += ["-o", "StrictHostKeyChecking=\(options.strictHostKeyChecking)"]
        if let kh = options.knownHostsFile {
            args += ["-o", "UserKnownHostsFile=\(quoteOptionValue(expandTilde(kh)))"]
        }
        args += ["-o", "LogLevel=ERROR"]

        switch config.auth {
        case .keyFile(let path):
            args += ["-i", expandTilde(path), "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none"]
            if !hasSecret { args += ["-o", "BatchMode=yes"] }
        case .agent(let socketPath):
            let agent = socketPath.map(expandTilde) ?? "SSH_AUTH_SOCK"
            args += ["-o", "IdentityAgent=\(quoteOptionValue(agent))", "-o", "BatchMode=yes"]
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no", "-o", "IdentityAgent=none"]
            if !hasSecret { args += ["-o", "BatchMode=yes"] }
        }
        return args
    }

    /// The `-N -L` part (local forward bound to loopback only).
    public static func forwardArguments(localPort: Int, remoteHost: String, remotePort: Int) -> [String] {
        let host = remoteHost.contains(":") && !remoteHost.hasPrefix("[") ? "[\(remoteHost)]" : remoteHost
        return ["-o", "ExitOnForwardFailure=yes", "-N", "-L", "127.0.0.1:\(localPort):\(host):\(remotePort)"]
    }

    public static func destination(for config: SSHTunnelConfig) -> String { "\(config.user)@\(config.host)" }

    /// Full tunnel argv (excluding the executable).
    public static func tunnelArguments(
        for config: SSHTunnelConfig,
        options: SSHClientOptions = SSHClientOptions(),
        hasSecret: Bool,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        connectTimeoutSeconds: Int = 20
    ) -> [String] {
        baseArguments(for: config, options: options, hasSecret: hasSecret, connectTimeoutSeconds: connectTimeoutSeconds)
            + forwardArguments(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
            + [destination(for: config)]
    }
}

/// Maps ssh's stderr + exit status to a user-facing error.
public enum SSHErrorMapper {
    public static func map(status: Int32, stderr: String) -> SSHTunnelError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("remote host identification has changed") || lower.contains("host key verification failed") {
            return .hostKeyMismatch(text)
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return .authenticationFailed(text)
        }
        if lower.contains("could not request local forwarding") || lower.contains("address already in use")
            || lower.contains("cannot listen to port") || lower.contains("port forwarding failed")
            || lower.contains("channel_setup_fwd_listener") {
            return .forwardFailed(text)
        }
        return .exited(status: status, stderr: text)
    }
}
