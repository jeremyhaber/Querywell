import Foundation

/// What a stored secret is for.
public enum SecretKind: Codable, Sendable, Hashable {
    case databasePassword
    case sshPassword
    case sshKeyPassphrase
    case aiAPIKey(provider: String)

    /// Stable string used in Keychain account names.
    public var rawKey: String {
        switch self {
        case .databasePassword: "db.password"
        case .sshPassword: "ssh.password"
        case .sshKeyPassphrase: "ssh.passphrase"
        case .aiAPIKey(let provider): "ai.\(provider)"
        }
    }
}

/// Address of a secret: who owns it and what it is.
public struct SecretKey: Sendable, Hashable {
    /// Owner used for app-level secrets such as AI keys.
    public static let globalOwnerID = "global"

    /// A connection UUID string, or ``globalOwnerID``.
    public var ownerID: String
    public var kind: SecretKind

    public init(ownerID: String, kind: SecretKind) {
        self.ownerID = ownerID
        self.kind = kind
    }

    /// Keychain account name: `"<ownerID>.<kind.rawKey>"`.
    public var account: String { "\(ownerID).\(kind.rawKey)" }
}

/// Storage for secrets. Implementations must be thread-safe.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func write(_ value: String, for key: SecretKey) throws
    /// Deleting a missing secret is not an error.
    func delete(_ key: SecretKey) throws
    /// Deletes every secret whose owner is `ownerID`.
    func deleteAll(ownerID: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(status: OSStatus, message: String)
}
