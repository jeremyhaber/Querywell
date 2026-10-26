import Foundation
import os

/// A non-persistent ``SecretStore`` for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock(initialState: [SecretKey: String]())

    public init() {}

    public func read(_ key: SecretKey) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func write(_ value: String, for key: SecretKey) throws {
        storage.withLock { $0[key] = value }
    }

    public func delete(_ key: SecretKey) throws {
        storage.withLock { $0[key] = nil }
    }

    public func deleteAll(ownerID: String) throws {
        storage.withLock { dict in
            for key in dict.keys where key.ownerID == ownerID { dict[key] = nil }
        }
    }
}
