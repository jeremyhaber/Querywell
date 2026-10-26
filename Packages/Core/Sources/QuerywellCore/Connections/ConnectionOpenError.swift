import Foundation

/// Why opening a connection failed. Every case has a user-presentable ``message`` and, where
/// there's something the user can do about it, a ``recoverySuggestion``.
public enum ConnectionOpenError: Error, Sendable, Equatable {
    case invalidProfile([ValidationIssue])
    /// A secret couldn't be read from the secret store (e.g. Keychain access denied).
    case secretUnavailable(String)
    case tunnel(SSHTunnelError)
    case database(DatabaseError)
    /// The SSH tunnel is up but the database behind it didn't answer. `ssh` only dials the
    /// target on first use, so an unreachable database behind a bastion surfaces here.
    case databaseUnreachableThroughTunnel(host: String, port: Int, underlying: DatabaseError)

    public var message: String {
        switch self {
        case .invalidProfile(let issues):
            return issues.map(\.message).joined(separator: " ")
        case .secretUnavailable(let detail):
            return "Couldn't read a saved password from the Keychain. \(detail)"
        case .tunnel(let error):
            switch error {
            case .sshNotFound(let detail): return "The ssh command-line tool couldn't be found. \(detail)"
            case .authenticationFailed: return "The SSH server rejected the credentials."
            case .hostKeyMismatch: return "The SSH server's host key doesn't match the one on record."
            case .forwardFailed(let detail): return "The SSH tunnel couldn't be set up. \(detail)"
            case .timeout: return "Timed out while opening the SSH tunnel."
            case .exited(let status, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "The ssh process exited with status \(status)." : "The ssh process exited with status \(status): \(detail)"
            }
        case .database(let error):
            return Self.describe(error)
        case .databaseUnreachableThroughTunnel(let host, let port, let underlying):
            return "The SSH tunnel is open, but the database server couldn't be reached at \(host):\(port) from the SSH host. \(Self.describe(underlying))"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidProfile:
            return "Fix the highlighted fields and try again."
        case .secretUnavailable:
            return "Allow Querywell to access the Keychain, or re-enter the password in the connection settings."
        case .tunnel(let error):
            switch error {
            case .sshNotFound:
                return "Make sure OpenSSH is installed at /usr/bin/ssh."
            case .authenticationFailed:
                return "Check the SSH user and the saved SSH password, key file or passphrase, or that your SSH agent has the key loaded."
            case .hostKeyMismatch:
                return "The server's host key has changed since you last connected. This can mean the server was reinstalled, or that someone is intercepting the connection. "
                    + "If you're sure it's expected, verify the new fingerprint with the server's administrator and remove the old entry with `ssh-keygen -R <ssh-host>` (use the SSH host name, or `[host]:port` for a non-standard port), then try again."
            case .forwardFailed:
                return "Check that the SSH host allows TCP forwarding (AllowTcpForwarding) and that the database host and port are correct."
            case .timeout:
                return "Check the SSH host and port, and your network connection."
            case .exited:
                return "Check the SSH host, port and credentials."
            }
        case .database(let error):
            switch error {
            case .authenticationFailed:
                return "Check the password saved for this connection."
            case .connectionFailed:
                return "Check the host and port, and that the server is running and accepting connections."
            case .tlsFailed:
                return "Check the TLS mode and certificate files, or switch the TLS mode in the connection settings."
            case .timeout:
                return "Check the host and port, and your network connection or firewall."
            case .query, .sessionClosed, .unsupported:
                return nil
            }
        case .databaseUnreachableThroughTunnel(let host, let port, _):
            return "From the SSH host, \(host):\(port) must be reachable. Check the database host and port, which are resolved on the SSH server (often 127.0.0.1 or an internal hostname)."
        }
    }

    private static func describe(_ error: DatabaseError) -> String {
        switch error {
        case .connectionFailed(let m): return m
        case .authenticationFailed(let m): return m.isEmpty ? "Authentication failed." : m
        case .tlsFailed(let m): return "Secure connection failed. \(m)"
        case .timeout: return "The connection timed out."
        case .query(let m, _): return m
        case .sessionClosed: return "The connection was closed."
        case .unsupported(let m): return m
        }
    }
}

extension ConnectionOpenError: LocalizedError {
    public var errorDescription: String? { message }
}
