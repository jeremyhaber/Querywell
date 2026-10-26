import Foundation

/// What is stored for one connection.
public struct HealthConnectionData: Sendable, Hashable, Codable {
    /// Oldest first.
    public var revisions: [SettingRevision] = []
    /// RAM the user entered for memory recommendations.
    public var serverRAMBytes: Int64?
    /// Baseline rule ids the user chose to ignore.
    public var ignoredRuleIDs: [String] = []

    public init(revisions: [SettingRevision] = [], serverRAMBytes: Int64? = nil, ignoredRuleIDs: [String] = []) {
        self.revisions = revisions
        self.serverRAMBytes = serverRAMBytes
        self.ignoredRuleIDs = ignoredRuleIDs
    }

    var isEmpty: Bool { revisions.isEmpty && serverRAMBytes == nil && ignoredRuleIDs.isEmpty }

    private enum CodingKeys: String, CodingKey { case revisions, serverRAMBytes, ignoredRuleIDs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One unreadable revision must not lose the whole history.
        revisions = (try c.decodeIfPresent([Lossy<SettingRevision>].self, forKey: .revisions) ?? []).compactMap(\.value)
        serverRAMBytes = try c.decodeIfPresent(Int64.self, forKey: .serverRAMBytes)
        ignoredRuleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredRuleIDs) ?? []
    }
}

private struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
    var value: T?
    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

private struct HealthFile: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion = HealthFile.currentSchemaVersion
    var connections: [String: HealthConnectionData] = [:]

    private enum CodingKeys: String, CodingKey { case schemaVersion, connections }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        connections = try c.decodeIfPresent([String: Lossy<HealthConnectionData>].self, forKey: .connections)?.compactMapValues(\.value) ?? [:]
    }
}

public enum HealthStoreError: Error, Equatable, Sendable {
    /// The file was written by a newer Querywell; writing would lose data.
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// `health.json` (0600, atomic, versioned): per connection, the Doctor's settings revisions, the entered server
/// RAM and the ignored recommendations. Purged with the connection. Mutations commit in memory only after the
/// write succeeded. Revisions are capped so the file cannot grow without bound.
public actor HealthStore {
    public static let maxRevisionsPerConnection = 1_000

    private let fileURL: URL
    private var file: HealthFile?
    private var newerVersion: Int?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(appName: String = "Querywell") throws -> URL {
        try AppDirectories.applicationSupport(appName: appName).appendingPathComponent(AppDirectories.healthFileName, isDirectory: false)
    }

    public func data(for connectionID: UUID) -> HealthConnectionData {
        load().connections[connectionID.uuidString] ?? HealthConnectionData()
    }

    /// Chronological (oldest first).
    public func revisions(for connectionID: UUID) -> [SettingRevision] { data(for: connectionID).revisions }

    public func append(_ revisions: [SettingRevision], for connectionID: UUID) throws {
        guard !revisions.isEmpty else { return }
        try update(connectionID) { data in
            data.revisions.append(contentsOf: revisions)
            if data.revisions.count > Self.maxRevisionsPerConnection {
                data.revisions.removeFirst(data.revisions.count - Self.maxRevisionsPerConnection)
            }
        }
    }

    public func setServerRAM(_ bytes: Int64?, for connectionID: UUID) throws {
        try update(connectionID) { $0.serverRAMBytes = bytes }
    }

    public func setIgnored(_ ruleID: String, _ ignored: Bool, for connectionID: UUID) throws {
        try update(connectionID) { data in
            data.ignoredRuleIDs.removeAll { $0 == ruleID }
            if ignored { data.ignoredRuleIDs.append(ruleID) }
        }
    }

    /// Forgets a deleted connection's health data.
    public func purge(connectionID: UUID) throws {
        var copy = load()
        guard copy.connections.removeValue(forKey: connectionID.uuidString) != nil else { return }
        try write(copy)
    }

    private func update(_ connectionID: UUID, _ change: (inout HealthConnectionData) -> Void) throws {
        var copy = load()
        var data = copy.connections[connectionID.uuidString] ?? HealthConnectionData()
        change(&data)
        copy.connections[connectionID.uuidString] = data.isEmpty ? nil : data
        try write(copy)
    }

    private func load() -> HealthFile {
        if let file { return file }
        var loaded = HealthFile()
        if let bytes = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONFileStore.makeDecoder().decode(HealthFile.self, from: bytes) {
                loaded = decoded
                if decoded.schemaVersion > HealthFile.currentSchemaVersion { newerVersion = decoded.schemaVersion }
            } else {
                // Unreadable: keep it for inspection instead of overwriting it on the next write.
                let aside = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.copyItem(at: fileURL, to: aside)
            }
        }
        file = loaded
        return loaded
    }

    private func write(_ new: HealthFile) throws {
        if let newerVersion {
            throw HealthStoreError.unsupportedSchemaVersion(found: newerVersion, supported: HealthFile.currentSchemaVersion)
        }
        var out = new
        out.schemaVersion = HealthFile.currentSchemaVersion
        try JSONFileStore.writeAtomically(try JSONFileStore.makeEncoder().encode(out), to: fileURL, permissions: 0o600)
        file = out
    }
}
