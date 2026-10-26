import Foundation

/// What a tunnel provider needs: the SSH hop plus the database endpoint as seen from the SSH host.
public struct SSHTunnelRequest: Sendable, Hashable {
    public var ssh: SSHTunnelConfig
    /// Password (``SSHAuthMethod/password``) or key passphrase (``SSHAuthMethod/keyFile(path:)``), from the Keychain.
    public var secret: String?
    /// Database host/port to forward to, resolved on the SSH server (often 127.0.0.1:3306).
    public var remoteHost: String
    public var remotePort: Int
    public var connectTimeout: Duration

    public init(ssh: SSHTunnelConfig, secret: String? = nil, remoteHost: String, remotePort: Int, connectTimeout: Duration = .seconds(20)) {
        self.ssh = ssh
        self.secret = secret
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.connectTimeout = connectTimeout
    }
}

/// Errors surfaced to the user when a tunnel can't be established.
public enum SSHTunnelError: Error, Sendable, Equatable {
    case sshNotFound(String)
    case authenticationFailed(String)
    /// The server's host key doesn't match known_hosts — possible MITM; never auto-accepted.
    case hostKeyMismatch(String)
    case forwardFailed(String)
    case timeout
    case exited(status: Int32, stderr: String)
}

/// A live local port forward. `localPort` on 127.0.0.1 reaches the remote database.
public protocol SSHTunnel: AnyObject, Sendable {
    var localHost: String { get }
    var localPort: Int { get }
    var isRunning: Bool { get async }
    /// Set once the SSH server reports it couldn't reach the forward target
    /// (e.g. "connect failed: Name does not resolve"); `nil` while healthy.
    var forwardFailure: String? { get async }
    /// Tears the tunnel down. Idempotent.
    func close() async
}

extension SSHTunnel {
    public var forwardFailure: String? { get async { nil } }
}

/// Creates tunnels. Default implementation: ``SystemSSHTunnelProvider`` (OpenSSH `ssh -L`).
public protocol SSHTunnelProvider: Sendable {
    func open(_ request: SSHTunnelRequest) async throws -> any SSHTunnel
}
