import AppKit
import Foundation
import Observation
import QuerywellCore
import SwiftUI

/// An error to show the user: what happened and, if known, what to do about it.
struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var recovery: String?
}

/// App-wide state: the connection library, settings, and the open connection workspaces.
/// Views render this and forward intents; the logic lives here and in `QuerywellCore`.
@MainActor @Observable
final class AppModel {
    @ObservationIgnored let repository: ConnectionRepository
    @ObservationIgnored let secretStore: any SecretStore
    @ObservationIgnored let settingsStore: AppSettingsStore
    @ObservationIgnored let opener: ConnectionOpener
    @ObservationIgnored let tester: ConnectionTester
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?

    private(set) var library = ConnectionLibrary()
    private(set) var settings = AppSettings()
    private(set) var isLoaded = false
    /// Open connection windows, keyed by workspace id (not profile id: one profile may have two windows).
    private(set) var workspaces: [UUID: ConnectionWorkspace] = [:]
    var alert: AppAlert?
    /// Set by File ▸ New Connection…; the launcher consumes it and presents the editor.
    var wantsNewConnection = false

    init(
        repository: ConnectionRepository,
        secretStore: any SecretStore,
        settingsStore: AppSettingsStore,
        opener: ConnectionOpener? = nil
    ) {
        self.repository = repository
        self.secretStore = secretStore
        self.settingsStore = settingsStore
        let opener = opener ?? ConnectionOpener(secretStore: secretStore)
        self.opener = opener
        self.tester = ConnectionTester(opener: opener)
    }

    /// Stores in `directory` (`connections.json`, `settings.json`) with the given secret store.
    convenience init(directory: URL, secretStore: any SecretStore, opener: ConnectionOpener? = nil) {
        self.init(
            repository: ConnectionRepository(
                fileURL: directory.appendingPathComponent(AppDirectories.connectionsFileName), secretStore: secretStore),
            secretStore: secretStore,
            settingsStore: AppSettingsStore(
                fileURL: directory.appendingPathComponent(AppDirectories.settingsFileName)),
            opener: opener)
    }

    /// The real app: Application Support + Keychain.
    static func live() -> AppModel {
        let directory: URL
        do {
            directory = try AppDirectories.applicationSupport()
        } catch {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Querywell-\(UUID().uuidString)", isDirectory: true)
        }
        return AppModel(directory: directory, secretStore: KeychainSecretStore())
    }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        do {
            try await repository.load()
            library = try await repository.snapshot()
        } catch {
            present(error, title: "Couldn't load your connections")
        }
        do {
            settings = try await settingsStore.load()
        } catch {
            present(error, title: "Couldn't load your settings")
        }
        isLoaded = true
    }

    private func refreshLibrary() async throws {
        library = try await repository.snapshot()
    }

    // MARK: Errors

    func present(_ error: any Error, title: String) {
        let (message, recovery) = Self.describe(error)
        alert = AppAlert(title: title, message: message, recovery: recovery)
    }

    static func describe(_ error: any Error) -> (message: String, recovery: String?) {
        switch error {
        case let e as ConnectionOpenError:
            return (e.message, e.recoverySuggestion)
        case let e as ConnectionDraftError:
            return (e.issues.map(\.message).joined(separator: " "), "Fix the highlighted fields and try again.")
        case let e as SecretStoreError:
            switch e {
            case .keychain(_, let message):
                return ("The Keychain reported: \(message)", "Allow Querywell to access the Keychain and try again.")
            }
        case let e as ConnectionRepositoryError:
            switch e {
            case .corruptFile(let detail):
                return ("connections.json couldn't be read: \(detail)", "The file was left untouched. Fix or move it, then relaunch Querywell.")
            case .unsupportedSchemaVersion(let found, let supported):
                return ("connections.json was written by a newer version of Querywell (schema \(found), this version reads \(supported)).", "Update Querywell.")
            case .profileNotFound: return ("That connection no longer exists.", nil)
            case .folderNotFound: return ("That folder no longer exists.", nil)
            }
        case let e as AppSettingsStoreError:
            switch e {
            case .corruptFile(let detail):
                return ("settings.json couldn't be read: \(detail)", "The file was left untouched. Fix or move it, then relaunch Querywell.")
            case .unsupportedSchemaVersion:
                return ("settings.json was written by a newer version of Querywell.", "Update Querywell.")
            }
        default:
            return (error.localizedDescription, nil)
        }
    }

    // MARK: Lookup

    func profile(id: UUID) -> ConnectionProfile? {
        library.profiles.first { $0.id == id }
    }

    func folder(id: UUID?) -> ConnectionFolder? {
        guard let id else { return nil }
        return library.folders.first { $0.id == id }
    }

    /// Folders in display order (sort index, then name).
    var sortedFolders: [ConnectionFolder] {
        library.folders.sorted {
            $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Connection editing

    /// A blank draft, pre-filled from what the launcher is currently showing.
    func newDraft(engine: DatabaseEngine = .mysql, filter: FolderFilter = .all) -> ConnectionDraft {
        var draft = ConnectionDraft(newFor: engine)
        switch filter {
        case .folder(let id) where folder(id: id) != nil: draft.folderID = id
        case .favourites: draft.favourite = true
        case .tag(.production): draft.colorTag = .production
        case .tag(.staging): draft.colorTag = .staging
        case .tag(.local): draft.colorTag = .local
        default: break
        }
        if draft.colorTag?.isProduction == true {
            draft.readOnly = settings.safety.defaultReadOnlyForNewProductionConnections
        }
        return draft
    }

    /// The saved secrets of `profile`. The SSH secret is the password or the key passphrase
    /// depending on the profile's SSH auth method.
    func loadSecrets(for profile: ConnectionProfile) throws -> ConnectionSecrets {
        let owner = profile.id.uuidString
        let db = try secretStore.read(SecretKey(ownerID: owner, kind: .databasePassword))
        var ssh: String?
        if let config = profile.ssh {
            switch config.auth {
            case .password: ssh = try secretStore.read(SecretKey(ownerID: owner, kind: .sshPassword))
            case .keyFile: ssh = try secretStore.read(SecretKey(ownerID: owner, kind: .sshKeyPassphrase))
            case .agent: break
            }
        }
        return ConnectionSecrets(databasePassword: db, sshSecret: ssh)
    }

    /// A draft editing `profile` with its Keychain secrets, or `nil` (with an alert) if they
    /// can't be read. Opening an editor without them would make Save delete the stored secrets.
    func draft(for profile: ConnectionProfile) -> ConnectionDraft? {
        do {
            return ConnectionDraft(profile: profile, secrets: try loadSecrets(for: profile))
        } catch {
            present(error, title: "Couldn't read the saved passwords")
            return nil
        }
    }

    /// Validates, saves the profile and applies the draft's secret changes (non-nil written,
    /// nil deleted). Returns `false` and sets ``alert`` on failure.
    @discardableResult
    func save(_ draft: ConnectionDraft) async -> Bool {
        do {
            let profile = try draft.makeProfile()
            try await repository.upsert(profile)
            for (key, value) in draft.secretsToSave() {
                if let value {
                    try secretStore.write(value, for: key)
                } else {
                    try secretStore.delete(key)
                }
            }
            try await refreshLibrary()
            for workspace in workspaces.values where workspace.profile.id == profile.id {
                workspace.updateProfile(profile)
            }
            return true
        } catch {
            present(error, title: "Couldn't save the connection")
            return false
        }
    }

    /// Deletes the profile and its secrets, and closes its windows.
    func delete(_ profile: ConnectionProfile) async {
        for workspace in workspaces.values where workspace.profile.id == profile.id {
            await closeWorkspace(id: workspace.id)
        }
        do {
            try await repository.delete(id: profile.id)
            try await refreshLibrary()
        } catch {
            present(error, title: "Couldn't delete the connection")
        }
    }

    @discardableResult
    func duplicate(_ profile: ConnectionProfile) async -> UUID? {
        do {
            let copy = try await repository.duplicate(id: profile.id)
            try await refreshLibrary()
            return copy.id
        } catch {
            present(error, title: "Couldn't duplicate the connection")
            return nil
        }
    }

    func toggleFavourite(_ profile: ConnectionProfile) async {
        guard var current = self.profile(id: profile.id) else { return }
        current.favourite.toggle()
        do {
            try await repository.upsert(current)
            try await refreshLibrary()
        } catch {
            present(error, title: "Couldn't update the connection")
        }
    }

    func move(_ profile: ConnectionProfile, toFolder folderID: UUID?) async {
        do {
            try await repository.move(profileID: profile.id, toFolder: folderID)
            try await refreshLibrary()
        } catch {
            present(error, title: "Couldn't move the connection")
        }
    }

    @discardableResult
    func addFolder(named name: String) async -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = ConnectionFolder(name: trimmed, sortIndex: (library.folders.map(\.sortIndex).max() ?? -1) + 1)
        do {
            try await repository.upsertFolder(folder)
            try await refreshLibrary()
            return folder.id
        } catch {
            present(error, title: "Couldn't add the folder")
            return nil
        }
    }

    func renameFolder(_ folder: ConnectionFolder, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = self.folder(id: folder.id) else { return }
        var renamed = current
        renamed.name = trimmed
        do {
            try await repository.upsertFolder(renamed)
            try await refreshLibrary()
        } catch {
            present(error, title: "Couldn't rename the folder")
        }
    }

    /// Deletes the folder; its connections become unfiled.
    func deleteFolder(_ folder: ConnectionFolder) async {
        do {
            try await repository.deleteFolder(id: folder.id)
            try await refreshLibrary()
        } catch {
            present(error, title: "Couldn't delete the folder")
        }
    }

    // MARK: Opening connections

    /// Creates a workspace for the profile and returns its id for `openWindow(id: "connection", value:)`.
    ///
    /// With ``OpenConnectionBehaviour/focusExisting`` (and no `forceNewWindow`), an existing
    /// workspace for the profile is brought to the front instead and `nil` is returned.
    func connect(profileID: UUID, forceNewWindow: Bool = false) async -> UUID? {
        guard let profile = profile(id: profileID) else { return nil }
        if !forceNewWindow, settings.general.openConnectionBehaviour == .focusExisting,
           let existing = workspaces.values.filter({ $0.profile.id == profileID }).min(by: { $0.openedAt < $1.openedAt }) {
            existing.bringToFront()
            return nil
        }
        let workspace = ConnectionWorkspace(profile: profile, opener: opener)
        workspaces[workspace.id] = workspace
        do {
            try await repository.markUsed(id: profileID)
            try await refreshLibrary()
        } catch {
            // Not being able to record "last used" must not stop the user connecting.
        }
        return workspace.id
    }

    /// Convenience for views: connect and open the resulting window.
    func openConnection(_ profileID: UUID, newWindow: Bool = false, using openWindow: OpenWindowAction) {
        Task {
            if let id = await connect(profileID: profileID, forceNewWindow: newWindow) {
                openWindow(id: "connection", value: id)
            }
        }
    }

    func closeWorkspace(id: UUID) async {
        guard let workspace = workspaces.removeValue(forKey: id) else { return }
        await workspace.close()
    }

    /// Closes every live connection (and its ssh process) concurrently.
    func closeAllWorkspaces() async {
        let all = Array(workspaces.values)
        workspaces.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for workspace in all {
                group.addTask { await workspace.close() }
            }
        }
    }

    // MARK: Settings

    /// Applies `change`, publishes the result immediately and persists it (writes are serialized).
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        let snapshot = copy
        let previous = settingsSaveTask
        settingsSaveTask = Task { [settingsStore] in
            await previous?.value
            do {
                try await settingsStore.save(snapshot)
            } catch {
                self.present(error, title: "Couldn't save your settings")
            }
        }
    }

    /// Waits until every settings change made so far is on disk.
    func flushSettings() async {
        await settingsSaveTask?.value
    }

    // MARK: AI key (Keychain only, never settings.json)

    func aiAPIKey(provider: AIProviderID) -> String? {
        do {
            return try secretStore.read(Self.aiKey(provider))
        } catch {
            present(error, title: "Couldn't read the API key")
            return nil
        }
    }

    /// Saves the key; an empty string removes it.
    @discardableResult
    func setAIAPIKey(_ key: String, provider: AIProviderID) -> Bool {
        do {
            if key.isEmpty {
                try secretStore.delete(Self.aiKey(provider))
            } else {
                try secretStore.write(key, for: Self.aiKey(provider))
            }
            return true
        } catch {
            present(error, title: "Couldn't save the API key")
            return false
        }
    }

    static func aiKey(_ provider: AIProviderID) -> SecretKey {
        SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: provider.rawValue))
    }
}
