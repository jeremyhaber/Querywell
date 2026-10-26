import Foundation

/// A query the user saved. `connectionID == nil` means it is available on every connection.
/// Running it goes through QueryRunner / WriteGuard like any other SQL.
public struct SavedQuery: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var connectionID: UUID?
    public var name: String
    public var sql: String
    public var notes: String?
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), connectionID: UUID? = nil, name: String, sql: String, notes: String? = nil,
                tags: [String] = [], createdAt: Date = Date(), updatedAt: Date? = nil, lastRunAt: Date? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.name = name
        self.sql = sql
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastRunAt = lastRunAt
    }
}

private struct SavedQueryFile: Codable {
    var schemaVersion = 1
    var queries: [SavedQuery] = []
}

/// Saved queries for all connections in one `saved-queries.json` (atomic writes, 0600). Mutations are applied
/// to a copy and committed in memory only after the write succeeds.
public actor SavedQueryStore {
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var queries: [SavedQuery]?

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    public static func defaultFileURL(appName: String = "Querywell") throws -> URL {
        try AppDirectories.applicationSupport(appName: appName).appendingPathComponent("saved-queries.json", isDirectory: false)
    }

    /// The connection's queries plus the global ones, by name. With `nil`, only global ones.
    public func list(for connectionID: UUID?) throws -> [SavedQuery] {
        try load().filter { $0.connectionID == nil || $0.connectionID == connectionID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func query(id: UUID) throws -> SavedQuery? { try load().first { $0.id == id } }

    @discardableResult
    public func save(name: String, sql: String, connectionID: UUID?, notes: String? = nil, tags: [String] = []) throws -> SavedQuery {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw SnippetError.emptyName }
        let q = SavedQuery(connectionID: connectionID, name: n, sql: sql, notes: notes, tags: Self.tidy(tags), createdAt: now())
        try commit(try load() + [q])
        return q
    }

    /// `connectionID` is double-optional so callers can move a query to "global" (`.some(nil)`) or leave it (`nil`).
    @discardableResult
    public func update(id: UUID, name: String? = nil, sql: String? = nil, notes: String?? = nil, tags: [String]? = nil,
                       connectionID: UUID?? = nil) throws -> SavedQuery {
        var list = try load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw SnippetError.notFound }
        if let name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw SnippetError.emptyName }
            list[i].name = n
        }
        if let sql { list[i].sql = sql }
        if let notes { list[i].notes = notes }
        if let tags { list[i].tags = Self.tidy(tags) }
        if let connectionID { list[i].connectionID = connectionID }
        list[i].updatedAt = now()
        try commit(list)
        return list[i]
    }

    public func delete(id: UUID) throws {
        var list = try load()
        guard list.contains(where: { $0.id == id }) else { throw SnippetError.notFound }
        list.removeAll { $0.id == id }
        try commit(list)
    }

    /// A copy named "<name> copy" (same connection scope), returned.
    @discardableResult
    public func duplicate(id: UUID) throws -> SavedQuery {
        let list = try load()
        guard let src = list.first(where: { $0.id == id }) else { throw SnippetError.notFound }
        let copy = SavedQuery(connectionID: src.connectionID, name: src.name + " copy", sql: src.sql, notes: src.notes,
                              tags: src.tags, createdAt: now())
        try commit(list + [copy])
        return copy
    }

    /// Stamps `lastRunAt` (does not change `updatedAt`).
    public func markRun(id: UUID) throws {
        var list = try load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw SnippetError.notFound }
        list[i].lastRunAt = now()
        try commit(list)
    }

    /// Removes all of a connection's saved queries (global ones stay). Call when the profile is deleted.
    public func purge(connectionID: UUID) throws {
        let list = try load()
        let kept = list.filter { $0.connectionID != connectionID }
        if kept.count != list.count { try commit(kept) }
    }

    private static func tidy(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func load() throws -> [SavedQuery] {
        if let queries { return queries }
        var list: [SavedQuery] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            list = try JSONFileStore.makeDecoder().decode(SavedQueryFile.self, from: Data(contentsOf: fileURL)).queries
        }
        queries = list
        return list
    }

    private func commit(_ list: [SavedQuery]) throws {
        let data = try JSONFileStore.makeEncoder().encode(SavedQueryFile(queries: list))
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        queries = list
    }
}
