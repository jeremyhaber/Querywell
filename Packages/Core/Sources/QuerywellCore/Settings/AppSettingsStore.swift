import Foundation

/// Errors thrown by ``AppSettingsStore``.
public enum AppSettingsStoreError: Error, Equatable, Sendable {
    /// The file exists but is not valid JSON. It is left untouched.
    case corruptFile(String)
    /// The file was written by a newer version of the app. It is left untouched.
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// Loads and saves ``AppSettings`` as `settings.json` (atomic write, mode 0600).
///
/// A missing file yields defaults. A corrupt or too-new file is never overwritten:
/// load and every mutation throw instead.
public actor AppSettingsStore {
    private let fileURL: URL
    private var settings = AppSettings()
    private var isLoaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads the file (defaults if absent) and returns the settings.
    @discardableResult
    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            settings = AppSettings()
            isLoaded = true
            return settings
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let header = try JSONFileStore.makeDecoder().decode(SchemaHeader.self, from: data)
            if let found = header.schemaVersion, found > AppSettings.currentSchemaVersion {
                throw AppSettingsStoreError.unsupportedSchemaVersion(
                    found: found, supported: AppSettings.currentSchemaVersion)
            }
            settings = try JSONFileStore.makeDecoder().decode(AppSettings.self, from: data)
            isLoaded = true
            return settings
        } catch let error as AppSettingsStoreError {
            throw error
        } catch {
            throw AppSettingsStoreError.corruptFile(String(describing: error))
        }
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int?
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        }
        enum CodingKeys: String, CodingKey { case schemaVersion }
    }

    /// The current settings (loading them first if needed).
    public func current() throws -> AppSettings {
        if !isLoaded { try load() }
        return settings
    }

    /// Replaces and persists the settings.
    public func save(_ new: AppSettings) throws {
        if !isLoaded { try load() }
        try write(new)
    }

    /// Applies `transform` to a copy, persists it, and returns the result. Memory is only
    /// updated after the write succeeds.
    @discardableResult
    public func update(_ transform: (inout AppSettings) throws -> Void) throws -> AppSettings {
        if !isLoaded { try load() }
        var copy = settings
        try transform(&copy)
        try write(copy)
        return copy
    }

    private func write(_ new: AppSettings) throws {
        var toWrite = new
        toWrite.schemaVersion = AppSettings.currentSchemaVersion
        let data = try JSONFileStore.makeEncoder().encode(toWrite)
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        settings = toWrite
    }
}
