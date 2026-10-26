import Foundation
import Testing
import QuerywellCore
@testable import Querywell

@MainActor
private struct Fixture {
    let directory: URL
    let secrets = InMemorySecretStore()
    let model: AppModel

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuerywellAppTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(directory: directory, secretStore: secrets)
    }

    /// A second model reading the same files, to prove what reached disk.
    func reopened() -> AppModel {
        AppModel(directory: directory, secretStore: secrets)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func validDraft(name: String = "web01") -> ConnectionDraft {
        var draft = ConnectionDraft(newFor: .mysql)
        draft.name = name
        draft.user = "app"
        draft.databasePassword = "db-secret"
        return draft
    }

    func key(_ id: UUID, _ kind: SecretKind) -> SecretKey { SecretKey(ownerID: id.uuidString, kind: kind) }
}

@MainActor
@Suite("AppModel")
struct AppModelTests {
    @Test("saving a new draft writes the profile and its secrets")
    func saveNewDraft() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()

        var draft = f.validDraft()
        draft.useSSH = true
        draft.sshHost = "bastion"
        draft.sshUser = "deploy"
        draft.sshAuth = .password
        draft.sshSecret = "ssh-secret"
        #expect(await f.model.save(draft))

        let profile = try #require(f.model.library.profiles.first)
        #expect(profile.id == draft.id)
        #expect(profile.ssh?.host == "bastion")
        #expect(try f.secrets.read(f.key(draft.id, .databasePassword)) == "db-secret")
        #expect(try f.secrets.read(f.key(draft.id, .sshPassword)) == "ssh-secret")
        #expect(try f.secrets.read(f.key(draft.id, .sshKeyPassphrase)) == nil)

        // And it is on disk, not just in memory.
        let again = f.reopened()
        await again.load()
        #expect(again.library.profiles.map(\.id) == [draft.id])
    }

    @Test("an invalid draft is rejected with an alert and nothing is stored")
    func saveInvalid() async {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        var draft = f.validDraft()
        draft.name = ""
        #expect(await f.model.save(draft) == false)
        #expect(f.model.library.profiles.isEmpty)
        #expect(f.model.alert != nil)
    }

    @Test("editing a connection to a different SSH auth method deletes the stale secret")
    func switchingSSHAuthDeletesStaleSecret() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()

        var draft = f.validDraft()
        draft.useSSH = true
        draft.sshHost = "bastion"
        draft.sshUser = "deploy"
        draft.sshAuth = .password
        draft.sshSecret = "ssh-secret"
        #expect(await f.model.save(draft))
        #expect(try f.secrets.read(f.key(draft.id, .sshPassword)) == "ssh-secret")

        // Edit: load the draft with its Keychain secrets, switch to agent auth, save.
        let profile = try #require(f.model.library.profiles.first)
        var edit = try #require(f.model.draft(for: profile))
        #expect(edit.sshSecret == "ssh-secret")
        edit.sshAuth = .agent
        #expect(await f.model.save(edit))

        #expect(try f.secrets.read(f.key(draft.id, .sshPassword)) == nil)
        #expect(try f.secrets.read(f.key(draft.id, .sshKeyPassphrase)) == nil)
        #expect(try f.secrets.read(f.key(draft.id, .databasePassword)) == "db-secret")
    }

    @Test("clearing the password field deletes the stored password")
    func clearingPasswordDeletesIt() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        let draft = f.validDraft()
        #expect(await f.model.save(draft))
        let stored = try #require(f.model.library.profiles.first)
        var edit = try #require(f.model.draft(for: stored))
        edit.databasePassword = ""
        #expect(await f.model.save(edit))
        #expect(try f.secrets.read(f.key(draft.id, .databasePassword)) == nil)
    }

    @Test("deleting a profile removes it and every secret")
    func deleteRemovesSecrets() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        var draft = f.validDraft()
        draft.useSSH = true
        draft.sshHost = "bastion"
        draft.sshUser = "deploy"
        draft.sshAuth = .keyFile
        draft.sshKeyPath = "/tmp/key"
        draft.sshSecret = "passphrase"
        #expect(await f.model.save(draft))
        #expect(try f.secrets.read(f.key(draft.id, .sshKeyPassphrase)) == "passphrase")

        let victim = try #require(f.model.library.profiles.first)
        await f.model.delete(victim)
        #expect(f.model.library.profiles.isEmpty)
        #expect(try f.secrets.read(f.key(draft.id, .databasePassword)) == nil)
        #expect(try f.secrets.read(f.key(draft.id, .sshKeyPassphrase)) == nil)
    }

    @Test("duplicate copies the profile and its secrets; favourite and folders work")
    func duplicateFavouriteFolders() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        let draft = f.validDraft()
        #expect(await f.model.save(draft))
        let original = try #require(f.model.library.profiles.first)

        let copyID = try #require(await f.model.duplicate(original))
        #expect(f.model.library.profiles.count == 2)
        #expect(try f.secrets.read(f.key(copyID, .databasePassword)) == "db-secret")

        await f.model.toggleFavourite(original)
        #expect(f.model.profile(id: original.id)?.favourite == true)

        let folderID = try #require(await f.model.addFolder(named: "  Clients  "))
        #expect(f.model.folder(id: folderID)?.name == "Clients")
        await f.model.move(original, toFolder: folderID)
        #expect(f.model.profile(id: original.id)?.folderID == folderID)
        let folder = try #require(f.model.folder(id: folderID))
        await f.model.renameFolder(folder, to: "Sites")
        #expect(f.model.folder(id: folderID)?.name == "Sites")
        let renamed = try #require(f.model.folder(id: folderID))
        await f.model.deleteFolder(renamed)
        #expect(f.model.profile(id: original.id)?.folderID == nil)
        #expect(await f.model.addFolder(named: "   ") == nil)
    }

    @Test("connect(): focusExisting returns nil the second time; a forced new window returns a new id")
    func connectFocusExisting() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.save(f.validDraft()))
        let profileID = try #require(f.model.library.profiles.first?.id)

        let first = try #require(await f.model.connect(profileID: profileID))
        #expect(f.model.workspaces[first]?.profile.id == profileID)
        #expect(await f.model.connect(profileID: profileID) == nil)
        #expect(f.model.workspaces.count == 1)

        let second = try #require(await f.model.connect(profileID: profileID, forceNewWindow: true))
        #expect(second != first)
        #expect(f.model.workspaces.count == 2)

        // Connecting recorded the use.
        #expect(f.model.profile(id: profileID)?.lastUsedAt != nil)
    }

    @Test("connect(): the newWindow setting always opens another window")
    func connectNewWindowSetting() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.save(f.validDraft()))
        let profileID = try #require(f.model.library.profiles.first?.id)
        f.model.updateSettings { $0.general.openConnectionBehaviour = .newWindow }

        let first = try #require(await f.model.connect(profileID: profileID))
        let second = try #require(await f.model.connect(profileID: profileID))
        #expect(first != second)
        #expect(await f.model.connect(profileID: UUID()) == nil)
    }

    @Test("connect(database:): one window per profile and database; asking again focuses it")
    func connectPerDatabase() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.save(f.validDraft()))
        let profileID = try #require(f.model.library.profiles.first?.id)

        let shop = try #require(await f.model.connect(profileID: profileID, database: "shop"))
        #expect(f.model.workspaces[shop]?.boundDatabase == "shop")
        #expect(f.model.workspaces[shop]?.title == "web01 · shop")
        #expect(await f.model.connect(profileID: profileID, database: "shop") == nil)
        let blog = try #require(await f.model.connect(profileID: profileID, database: "blog"))
        #expect(blog != shop && f.model.workspaces.count == 2)
        #expect(f.model.workspace(profileID: profileID, database: "blog")?.id == blog)

        let shopWorkspace = try #require(f.model.workspaces[shop])
        #expect(f.model.isDatabaseOpenElsewhere("blog", besides: shopWorkspace))
        #expect(!f.model.isDatabaseOpenElsewhere("shop", besides: shopWorkspace))

        // Closing the window tears the workspace down, so the database can be opened again.
        await f.model.closeWorkspace(id: shop)
        #expect(f.model.workspace(profileID: profileID, database: "shop") == nil)
        #expect(await f.model.connect(profileID: profileID, database: "shop") != nil)
        await f.model.closeAllWorkspaces()
    }

    @Test("a window can't drop the database it uses, nor read-only connections drop anything")
    func dropGuards() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.save(f.validDraft()))
        let profileID = try #require(f.model.library.profiles.first?.id)
        let id = try #require(await f.model.connect(profileID: profileID, database: "shop"))
        let workspace = try #require(f.model.workspaces[id])
        #expect(workspace.dropBlockedReason(for: "shop", boundElsewhere: false) != nil)
        #expect(workspace.dropBlockedReason(for: "blog", boundElsewhere: true) != nil)
        #expect(workspace.dropBlockedReason(for: "mysql", boundElsewhere: false) != nil)
        #expect(workspace.dropBlockedReason(for: "blog", boundElsewhere: false) == nil)
        await f.model.closeAllWorkspaces()
    }

    @Test("closing a workspace removes it")
    func closeWorkspace() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.save(f.validDraft()))
        let profileID = try #require(f.model.library.profiles.first?.id)
        let id = try #require(await f.model.connect(profileID: profileID))
        await f.model.closeWorkspace(id: id)
        #expect(f.model.workspaces.isEmpty)
        // A fresh connect creates a new workspace again.
        #expect(await f.model.connect(profileID: profileID) != nil)
        await f.model.closeAllWorkspaces()
        #expect(f.model.workspaces.isEmpty)
    }

    @Test("settings persist across a relaunch")
    func settingsPersist() async {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        f.model.updateSettings { $0.editor.fontSize = 15 }
        f.model.updateSettings { $0.dataGrid.nullDisplay = "∅" }
        f.model.updateSettings { $0.ai.provider = .anthropic }
        f.model.updateSettings { $0.editor.fontSize = 100 }  // clamped by Core
        await f.model.flushSettings()

        let again = f.reopened()
        await again.load()
        #expect(again.settings == f.model.settings)
        #expect(again.settings.editor.fontSize == AppSettings.Editor.fontSizeRange.upperBound)
        #expect(again.settings.dataGrid.nullDisplay == "∅")
        #expect(again.settings.ai.provider == .anthropic)
    }

    @Test("the AI API key lives in the secret store, never in settings.json")
    func aiKeyInKeychainOnly() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(f.model.setAIAPIKey("sk-test-123", provider: .openai))
        f.model.updateSettings { $0.ai.provider = .openai }
        await f.model.flushSettings()

        #expect(f.model.aiAPIKey(provider: .openai) == "sk-test-123")
        #expect(f.model.aiAPIKey(provider: .anthropic) == nil)
        let key = SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: "openai"))
        #expect(try f.secrets.read(key) == "sk-test-123")
        let json = try String(contentsOf: f.directory.appendingPathComponent(AppDirectories.settingsFileName), encoding: .utf8)
        #expect(!json.contains("sk-test-123"))

        #expect(f.model.setAIAPIKey("", provider: .openai))
        #expect(f.model.aiAPIKey(provider: .openai) == nil)
    }

    @Test("new drafts take their defaults from the launcher filter and settings")
    func newDraftDefaults() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        let folderID = try #require(await f.model.addFolder(named: "Clients"))
        #expect(f.model.newDraft(filter: .folder(folderID)).folderID == folderID)
        #expect(f.model.newDraft(filter: .favourites).favourite)
        #expect(f.model.newDraft(filter: .tag(.staging)).colorTag == .staging)
        #expect(f.model.newDraft(filter: .tag(.production)).readOnly == false)
        f.model.updateSettings { $0.safety.defaultReadOnlyForNewProductionConnections = true }
        #expect(f.model.newDraft(filter: .tag(.production)).readOnly)
    }

    #if DEBUG
    @Test("Docker test connections are created once, with passwords and a Docker folder")
    func dockerFixtures() async throws {
        let f = Fixture()
        defer { f.cleanUp() }
        await f.model.load()
        #expect(await f.model.addDockerTestConnections() == 4)
        #expect(await f.model.addDockerTestConnections() == 0)

        let names = Set(f.model.library.profiles.map(\.name))
        #expect(names == ["Docker MySQL 8.4", "Docker MariaDB 11.4", "Docker Postgres 16", "Docker MySQL via SSH"])
        #expect(f.model.library.folders.map(\.name) == ["Docker"])
        let ssh = try #require(f.model.library.profiles.first { $0.name == "Docker MySQL via SSH" })
        #expect(ssh.isProduction)
        #expect(ssh.ssh?.port == 12222)
        #expect(ssh.host == "mysql8")
        #expect(try f.secrets.read(f.key(ssh.id, .sshPassword)) == "querywell_ssh_pw")
        #expect(try f.secrets.read(f.key(ssh.id, .databasePassword)) == "querywell_pw")
        let mysql = try #require(f.model.library.profiles.first { $0.name == "Docker MySQL 8.4" })
        #expect(mysql.port == 13306)
        #expect(mysql.colorTag == .local)
    }
    #endif
}
