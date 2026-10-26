import Foundation

/// How to authenticate to an SSH jump host. Never contains secrets: key passphrases
/// and SSH passwords live in the Keychain (see ``SecretKind``).
public enum SSHAuthMethod: Codable, Sendable, Hashable {
    /// Private key file at `path`. Its passphrase, if any, is stored in the Keychain.
    case keyFile(path: String)
    /// An SSH agent. `nil` socket path means use `SSH_AUTH_SOCK`.
    case agent(socketPath: String?)
    /// Password authentication; the password is stored in the Keychain.
    case password

    /// Socket path of the 1Password SSH agent (tilde-expanded at use time).
    public static let onePasswordAgentSocketPath =
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    private enum CodingKeys: String, CodingKey { case kind, path, socketPath }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "keyFile": self = .keyFile(path: try c.decode(String.self, forKey: .path))
        case "agent": self = .agent(socketPath: try c.decodeIfPresent(String.self, forKey: .socketPath))
        case "password": self = .password
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown SSHAuthMethod kind '\(other)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyFile(let path):
            try c.encode("keyFile", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .agent(let socketPath):
            try c.encode("agent", forKey: .kind)
            try c.encodeIfPresent(socketPath, forKey: .socketPath)
        case .password:
            try c.encode("password", forKey: .kind)
        }
    }
}

/// An SSH tunnel (jump host) through which a database connection is made.
public struct SSHTunnelConfig: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuthMethod

    public init(host: String, port: Int = 22, user: String, auth: SSHAuthMethod) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey { case host, port, user, auth }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decode(String.self, forKey: .user)
        auth = try c.decodeIfPresent(SSHAuthMethod.self, forKey: .auth) ?? .agent(socketPath: nil)
    }
}
