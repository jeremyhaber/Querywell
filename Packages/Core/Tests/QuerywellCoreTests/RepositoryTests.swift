import Foundation
import Testing
@testable import QuerywellCore

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("QuerywellTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sample(_ name: String = "P", folder: UUID? = nil) -> ConnectionProfile {
    ConnectionProfile(name: name, folderID: folder, engine: .postgresql, host: "h", user: "u",
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
}

@Suite("ConnectionRepository")
struct RepositoryTests {
    let dir: URL
    let file: URL
    let secrets = InMemorySecretStore()

    init() throws {
        dir = try makeTempDir()
        file = dir.appendingPathComponent("nested/connections.json")
    }

    private func repo() -> ConnectionRepository {
        ConnectionRepository(fileURL: file, secretStore: secrets)
    }

    @Test func missingFileIsEmptyAndNotCreated() async throws {
        let r = repo()
        try await r.load()
        #expect(try await r.snapshot() == ConnectionLibrary())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func upsertInsertsThenReplaces() async throws {
        let r = repo()
        var p = sample()
        try await r.upsert(p)
        p.name = "Renamed"
        try await r.upsert(p)
        let profiles = try await r.profiles
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Renamed")
    }

    @Test func persistsAcrossInstances() async throws {
        let p = sample()
        let f = ConnectionFolder(name: "F")
        let r1 = repo()
        try await r1.upsertFolder(f)
        try await r1.upsert(p)
        let r2 = repo()
        try await r2.load()
        #expect(try await r2.profiles == [p])
        #expect(try await r2.folders == [f])
    }

    @Test func fileFormat() async throws {
        let r = repo()
        try await r.upsert(sample())
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("2023-11-14T22:13:20Z"))
        #expect(try await r.snapshot().schemaVersion == 1)
    }

    @Test func deleteRemovesProfileAndSecrets() async throws {
        let r = repo()
        let p = sample(), other = sample("Other")
        try await r.upsert(p); try await r.upsert(other)
        let k1 = SecretKey(ownerID: p.id.uuidString, kind: .databasePassword)
        let k2 = SecretKey(ownerID: p.id.uuidString, kind: .sshKeyPassphrase)
        let k3 = SecretKey(ownerID: other.id.uuidString, kind: .databasePassword)
        try secrets.write("a", for: k1); try secrets.write("b", for: k2); try secrets.write("c", for: k3)
        try await r.delete(id: p.id)
        #expect(try await r.profiles == [other])
        #expect(try secrets.read(k1) == nil && secrets.read(k2) == nil)
        #expect(try secrets.read(k3) == "c")
    }

    @Test func duplicateCopiesProfileAndSecrets() async throws {
        let r = repo()
        let p = sample("Prod")
        try await r.upsert(p)
        try secrets.write("pw", for: SecretKey(ownerID: p.id.uuidString, kind: .databasePassword))
        try secrets.write("pp", for: SecretKey(ownerID: p.id.uuidString, kind: .sshKeyPassphrase))
        let copy = try await r.duplicate(id: p.id)
        #expect(copy.id != p.id)
        #expect(copy.name == "Prod copy")
        #expect(copy.host == p.host)
        #expect(try await r.profiles.count == 2)
        #expect(try secrets.read(SecretKey(ownerID: copy.id.uuidString, kind: .databasePassword)) == "pw")
        #expect(try secrets.read(SecretKey(ownerID: copy.id.uuidString, kind: .sshKeyPassphrase)) == "pp")
        #expect(try secrets.read(SecretKey(ownerID: copy.id.uuidString, kind: .sshPassword)) == nil)
        // Original untouched.
        #expect(try secrets.read(SecretKey(ownerID: p.id.uuidString, kind: .databasePassword)) == "pw")
    }

    @Test func duplicateMissingThrows() async throws {
        let id = UUID()
        await #expect(throws: ConnectionRepositoryError.profileNotFound(id)) {
            try await repo().duplicate(id: id)
        }
    }

    @Test func markUsed() async throws {
        let r = repo()
        let p = sample()
        try await r.upsert(p)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try await r.markUsed(id: p.id, at: when)
        #expect(try await r.profiles.first?.lastUsedAt == when)
        await #expect(throws: ConnectionRepositoryError.self) { try await r.markUsed(id: UUID()) }
    }

    @Test func deleteFolderReassignsProfiles() async throws {
        let r = repo()
        let f = ConnectionFolder(name: "F"), g = ConnectionFolder(name: "G")
        try await r.upsertFolder(f); try await r.upsertFolder(g)
        let inF = sample("a", folder: f.id), inG = sample("b", folder: g.id)
        try await r.upsert(inF); try await r.upsert(inG)
        try await r.deleteFolder(id: f.id)
        let snap = try await r.snapshot()
        #expect(snap.folders == [g])
        #expect(snap.profiles.first { $0.id == inF.id }?.folderID == nil)
        #expect(snap.profiles.first { $0.id == inG.id }?.folderID == g.id)
    }

    @Test func moveProfile() async throws {
        let r = repo()
        let f = ConnectionFolder(name: "F")
        let p = sample()
        try await r.upsertFolder(f); try await r.upsert(p)
        try await r.move(profileID: p.id, toFolder: f.id)
        #expect(try await r.profiles.first?.folderID == f.id)
        try await r.move(profileID: p.id, toFolder: nil)
        #expect(try await r.profiles.first?.folderID == nil)
        try await r.deleteFolder(id: f.id)
        await #expect(throws: ConnectionRepositoryError.folderNotFound(f.id)) {
            try await r.move(profileID: p.id, toFolder: f.id)
        }
        await #expect(throws: ConnectionRepositoryError.self) {
            try await r.move(profileID: UUID(), toFolder: nil)
        }
    }

    @Test func corruptFileThrowsAndIsUntouched() async throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: file)
        let r = repo()
        await #expect {
            try await r.load()
        } throws: { error in
            if case ConnectionRepositoryError.corruptFile = error { return true }
            return false
        }
        // A mutation must not clobber the corrupt file either.
        await #expect(throws: ConnectionRepositoryError.self) { try await r.upsert(sample()) }
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test func newerSchemaVersionThrowsAndIsUntouched() async throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion":99,"somethingNew":true}"#.utf8)
        try future.write(to: file)
        let r = repo()
        await #expect(throws: ConnectionRepositoryError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try await r.load()
        }
        await #expect(throws: ConnectionRepositoryError.self) { try await r.upsert(sample()) }
        #expect(try Data(contentsOf: file) == future)
    }

    @Test func filePermissionsAre0600() async throws {
        let r = repo()
        try await r.upsert(sample())
        try await r.upsert(sample("again"))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func mutationBeforeLoadDoesNotLoseExistingData() async throws {
        let p = sample()
        try await repo().upsert(p)
        let fresh = repo()
        try await fresh.upsert(sample("second"))
        #expect(try await fresh.profiles.count == 2)
    }
}

@Suite("AppDirectories & JSONFileStore")
struct PersistenceTests {
    @Test func connectionsFileURLShape() throws {
        let url = try AppDirectories.connectionsFileURL(appName: "QuerywellTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "connections.json")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func atomicWriteCreatesParentsAndPermissions() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a/b/c.json")
        try JSONFileStore.writeAtomically(Data("x".utf8), to: url, permissions: 0o600)
        #expect(try Data(contentsOf: url) == Data("x".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
