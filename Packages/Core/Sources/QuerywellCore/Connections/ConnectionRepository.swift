import Foundation

/// The on-disk (and snapshot) representation of all saved connections.
public struct ConnectionLibrary: Codable, Sendable, Equatable {
    /// Highest schema version this build understands.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var folders: [ConnectionFolder]
    public var profiles: [ConnectionProfile]

    public init(
        schemaVersion: Int = ConnectionLibrary.currentSchemaVersion,
        folders: [ConnectionFolder] = [],
        profiles: [ConnectionProfile] = []
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, folders, profiles }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        folders = try c.decodeIfPresent([ConnectionFolder].self, forKey: .folders) ?? []
        profiles = try c.decodeIfPresent([ConnectionProfile].self, forKey: .profiles) ?? []
    }
}

/// Errors thrown by ``ConnectionRepository``.
public enum ConnectionRepositoryError: Error, Equatable, Sendable {
    /// The file exists but could not be decoded. It is left untouched.
    case corruptFile(String)
    /// The file was written by a newer version of the app.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case profileNotFound(UUID)
    case folderNotFound(UUID)
}

/// Persists connection profiles and folders to a JSON file; secrets go to a ``SecretStore``.
///
/// Call ``load()`` once at startup. Mutations lazily load first and refuse to run
/// (rather than overwrite) if the existing file is unreadable.
public actor ConnectionRepository {
    private let fileURL: URL
    private let secretStore: any SecretStore
    private var library = ConnectionLibrary()
    private var isLoaded = false

    public init(fileURL: URL, secretStore: any SecretStore) {
        self.fileURL = fileURL
        self.secretStore = secretStore
    }

    /// Reads the file. A missing file yields an empty library.
    /// - Throws: ``ConnectionRepositoryError`` for corrupt or too-new files; the file is never modified.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            library = ConnectionLibrary()
            isLoaded = true
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONFileStore.makeDecoder()
        do {
            let header = try decoder.decode(SchemaHeader.self, from: data)
            guard header.schemaVersion <= ConnectionLibrary.currentSchemaVersion else {
                throw ConnectionRepositoryError.unsupportedSchemaVersion(
                    found: header.schemaVersion, supported: ConnectionLibrary.currentSchemaVersion)
            }
            library = try decoder.decode(ConnectionLibrary.self, from: data)
            isLoaded = true
        } catch let error as ConnectionRepositoryError {
            throw error
        } catch {
            throw ConnectionRepositoryError.corruptFile(String(describing: error))
        }
    }

    private struct SchemaHeader: Decodable { let schemaVersion: Int }

    /// A consistent copy of the current state.
    public func snapshot() throws -> ConnectionLibrary {
        try loadIfNeeded()
        return library
    }

    public var profiles: [ConnectionProfile] {
        get throws { try snapshot().profiles }
    }

    public var folders: [ConnectionFolder] {
        get throws { try snapshot().folders }
    }

    /// Inserts or replaces a profile (matched by `id`).
    public func upsert(_ profile: ConnectionProfile) throws {
        try mutate { lib in
            if let i = lib.profiles.firstIndex(where: { $0.id == profile.id }) {
                lib.profiles[i] = profile
            } else {
                lib.profiles.append(profile)
            }
        }
    }

    /// Removes a profile and every secret stored for it.
    public func delete(id: UUID) throws {
        try mutate { $0.profiles.removeAll { $0.id == id } }
        try secretStore.deleteAll(ownerID: id.uuidString)
    }

    /// Copies a profile (new id, name suffixed " copy") along with its secrets.
    @discardableResult
    public func duplicate(id: UUID) throws -> ConnectionProfile {
        let copy = try mutate { lib in
            guard let original = lib.profiles.first(where: { $0.id == id }) else {
                throw ConnectionRepositoryError.profileNotFound(id)
            }
            var copy = original
            copy.id = UUID()
            copy.name = original.name + " copy"
            copy.createdAt = Date()
            copy.lastUsedAt = nil
            lib.profiles.append(copy)
            return copy
        }
        let kinds: [SecretKind] = [.databasePassword, .sshPassword, .sshKeyPassphrase]
        for kind in kinds {
            let source = SecretKey(ownerID: id.uuidString, kind: kind)
            if let value = try secretStore.read(source) {
                try secretStore.write(value, for: SecretKey(ownerID: copy.id.uuidString, kind: kind))
            }
        }
        return copy
    }

    /// Records that the profile was just used.
    public func markUsed(id: UUID, at date: Date = Date()) throws {
        try mutate { lib in
            guard let i = lib.profiles.firstIndex(where: { $0.id == id }) else {
                throw ConnectionRepositoryError.profileNotFound(id)
            }
            lib.profiles[i].lastUsedAt = date
        }
    }

    /// Inserts or replaces a folder (matched by `id`).
    public func upsertFolder(_ folder: ConnectionFolder) throws {
        try mutate { lib in
            if let i = lib.folders.firstIndex(where: { $0.id == folder.id }) {
                lib.folders[i] = folder
            } else {
                lib.folders.append(folder)
            }
        }
    }

    /// Removes a folder; its profiles move to the top level.
    public func deleteFolder(id: UUID) throws {
        try mutate { lib in
            lib.folders.removeAll { $0.id == id }
            for i in lib.profiles.indices where lib.profiles[i].folderID == id {
                lib.profiles[i].folderID = nil
            }
        }
    }

    /// Moves a profile into a folder, or to the top level when `folderID` is `nil`.
    public func move(profileID: UUID, toFolder folderID: UUID?) throws {
        try mutate { lib in
            guard let i = lib.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw ConnectionRepositoryError.profileNotFound(profileID)
            }
            if let folderID, !lib.folders.contains(where: { $0.id == folderID }) {
                throw ConnectionRepositoryError.folderNotFound(folderID)
            }
            lib.profiles[i].folderID = folderID
        }
    }

    private func loadIfNeeded() throws {
        if !isLoaded { try load() }
    }

    /// Applies `change` to a copy and commits it to memory only after it is written to disk.
    @discardableResult
    private func mutate<T>(_ change: (inout ConnectionLibrary) throws -> T) throws -> T {
        try loadIfNeeded()
        var draft = library
        let result = try change(&draft)
        let data = try JSONFileStore.makeEncoder().encode(draft)
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        library = draft
        return result
    }
}
