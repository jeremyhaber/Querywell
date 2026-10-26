import Foundation
import Security
import Testing
@testable import QuerywellCore

@Suite("SecretKey")
struct SecretKeyTests {
    @Test func rawKeysAndAccount() {
        #expect(SecretKind.databasePassword.rawKey == "db.password")
        #expect(SecretKind.sshPassword.rawKey == "ssh.password")
        #expect(SecretKind.sshKeyPassphrase.rawKey == "ssh.passphrase")
        #expect(SecretKind.aiAPIKey(provider: "anthropic").rawKey == "ai.anthropic")
        let key = SecretKey(ownerID: "abc", kind: .databasePassword)
        #expect(key.account == "abc.db.password")
        #expect(SecretKey(ownerID: SecretKey.globalOwnerID, kind: .aiAPIKey(provider: "x")).account == "global.ai.x")
    }

    @Test func kindCodableRoundTrip() throws {
        for k in [SecretKind.databasePassword, .sshPassword, .sshKeyPassphrase, .aiAPIKey(provider: "p")] {
            let data = try JSONEncoder().encode(k)
            #expect(try JSONDecoder().decode(SecretKind.self, from: data) == k)
        }
    }
}

@Suite("InMemorySecretStore")
struct InMemorySecretStoreTests {
    @Test func readWriteUpdateDelete() throws {
        let s = InMemorySecretStore()
        let k = SecretKey(ownerID: "o", kind: .databasePassword)
        #expect(try s.read(k) == nil)
        try s.write("one", for: k)
        #expect(try s.read(k) == "one")
        try s.write("two", for: k)
        #expect(try s.read(k) == "two")
        try s.delete(k)
        #expect(try s.read(k) == nil)
        try s.delete(k) // missing is fine
    }

    @Test func deleteAllScopedToOwner() throws {
        let s = InMemorySecretStore()
        try s.write("a", for: SecretKey(ownerID: "o", kind: .databasePassword))
        try s.write("b", for: SecretKey(ownerID: "o", kind: .sshPassword))
        try s.write("c", for: SecretKey(ownerID: "o2", kind: .databasePassword))
        try s.deleteAll(ownerID: "o")
        #expect(try s.read(SecretKey(ownerID: "o", kind: .databasePassword)) == nil)
        #expect(try s.read(SecretKey(ownerID: "o", kind: .sshPassword)) == nil)
        #expect(try s.read(SecretKey(ownerID: "o2", kind: .databasePassword)) == "c")
    }

    @Test func concurrentAccess() async throws {
        let s = InMemorySecretStore()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { try? s.write("v\(i)", for: SecretKey(ownerID: "o\(i)", kind: .sshPassword)) }
            }
        }
        for i in 0..<100 { #expect(try s.read(SecretKey(ownerID: "o\(i)", kind: .sshPassword)) == "v\(i)") }
    }
}

private let keychainEnabled = ProcessInfo.processInfo.environment["QUERYWELL_SKIP_KEYCHAIN_TESTS"] != "1"

@Suite("KeychainSecretStore", .enabled(if: keychainEnabled, "QUERYWELL_SKIP_KEYCHAIN_TESTS=1"))
struct KeychainSecretStoreTests {
    private static let unavailable: Set<OSStatus> = [
        errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement,
    ]

    @Test func fullLifecycle() throws {
        let service = "com.jeremyhaber.Querywell.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let owner = UUID().uuidString, other = UUID().uuidString
        defer {
            try? store.deleteAll(ownerID: owner)
            try? store.deleteAll(ownerID: other)
        }
        let dbKey = SecretKey(ownerID: owner, kind: .databasePassword)

        do {
            try store.write("first", for: dbKey)
        } catch SecretStoreError.keychain(let status, let message) where Self.unavailable.contains(status) {
            print("NOTE: Keychain unavailable (\(status): \(message)); skipping KeychainSecretStore test.")
            return
        }

        #expect(try store.read(dbKey) == "first")
        try store.write("second", for: dbKey)
        #expect(try store.read(dbKey) == "second")
        try store.write("päss wörd ✓", for: dbKey)
        #expect(try store.read(dbKey) == "päss wörd ✓")

        let sshKey = SecretKey(ownerID: owner, kind: .sshKeyPassphrase)
        let otherKey = SecretKey(ownerID: other, kind: .databasePassword)
        try store.write("pp", for: sshKey)
        try store.write("other", for: otherKey)

        try store.delete(dbKey)
        #expect(try store.read(dbKey) == nil)
        try store.delete(dbKey) // missing is not an error

        try store.write("again", for: dbKey)
        try store.deleteAll(ownerID: owner)
        #expect(try store.read(dbKey) == nil)
        #expect(try store.read(sshKey) == nil)
        #expect(try store.read(otherKey) == "other")
        try store.deleteAll(ownerID: owner) // nothing left; no error

        try store.deleteAll(ownerID: other)
        #expect(try store.read(otherKey) == nil)
    }

    @Test func servicesAreIsolated() throws {
        let a = KeychainSecretStore(service: "com.jeremyhaber.Querywell.tests.\(UUID().uuidString)")
        let b = KeychainSecretStore(service: "com.jeremyhaber.Querywell.tests.\(UUID().uuidString)")
        let key = SecretKey(ownerID: UUID().uuidString, kind: .sshPassword)
        defer { try? a.delete(key) }
        do {
            try a.write("x", for: key)
        } catch SecretStoreError.keychain(let status, _) where Self.unavailable.contains(status) {
            print("NOTE: Keychain unavailable (\(status)); skipping.")
            return
        }
        #expect(try b.read(key) == nil)
    }

    @Test func defaultService() {
        #expect(KeychainSecretStore().service == "com.jeremyhaber.Querywell.secrets")
    }
}
