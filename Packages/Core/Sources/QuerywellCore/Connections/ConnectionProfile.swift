import Foundation

/// A saved database connection. Contains no secrets; see ``SecretStore``.
public struct ConnectionProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var folderID: UUID?
    public var colorTag: ColorTag?
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var user: String
    public var defaultDatabase: String?
    public var ssh: SSHTunnelConfig?
    public var tls: TLSConfig
    public var readOnly: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var notes: String?
    /// Whether the user starred this connection (shown under "Favourites" in the launcher).
    public var favourite: Bool

    /// Creates a profile; `port` defaults to the engine's standard port.
    public init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID? = nil,
        colorTag: ColorTag? = nil,
        engine: DatabaseEngine,
        host: String = "127.0.0.1",
        port: Int? = nil,
        user: String,
        defaultDatabase: String? = nil,
        ssh: SSHTunnelConfig? = nil,
        tls: TLSConfig = TLSConfig(),
        readOnly: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        notes: String? = nil,
        favourite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.colorTag = colorTag
        self.engine = engine
        self.host = host
        self.port = port ?? engine.defaultPort
        self.user = user
        self.defaultDatabase = defaultDatabase
        self.ssh = ssh
        self.tls = tls
        self.readOnly = readOnly
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.notes = notes
        self.favourite = favourite
    }

    /// Tagged as production.
    public var isProduction: Bool { colorTag?.isProduction ?? false }

    /// Whether write statements must be confirmed by the user before running.
    public var requiresWriteConfirmation: Bool { isProduction }

    /// Whether the session must reject writes. Single place for future policy.
    public var effectiveReadOnly: Bool { readOnly }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, colorTag, engine, host, port, user, defaultDatabase
        case ssh, tls, readOnly, createdAt, lastUsedAt, notes, favourite
    }

    /// Tolerant decoding: only `id`, `name`, `engine`, `host` and `user` are required.
    /// A missing `createdAt` becomes the Unix epoch so decoding stays deterministic.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(DatabaseEngine.self, forKey: .engine)
        host = try c.decode(String.self, forKey: .host)
        user = try c.decode(String.self, forKey: .user)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        colorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? engine.defaultPort
        defaultDatabase = try c.decodeIfPresent(String.self, forKey: .defaultDatabase)
        ssh = try c.decodeIfPresent(SSHTunnelConfig.self, forKey: .ssh)
        tls = try c.decodeIfPresent(TLSConfig.self, forKey: .tls) ?? TLSConfig()
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        favourite = try c.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
    }
}

/// A user-defined group of connections in the sidebar.
public struct ConnectionFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}
