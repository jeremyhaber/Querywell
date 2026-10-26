import Foundation
import QuerywellCore

/// The stores behind query history, saved queries and snippets (one set per app, shared by all
/// connection windows). History is one `QueryHistoryStore` per connection, created on demand.
@MainActor
final class QueryServices {
    let historyDirectory: URL
    let savedQueries: SavedQueryStore
    let snippets: SnippetStore
    private(set) var retention: HistoryRetention
    private var histories: [UUID: QueryHistoryStore] = [:]

    init(directory: URL, retention: HistoryRetention = HistoryRetention()) {
        historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        savedQueries = SavedQueryStore(fileURL: directory.appendingPathComponent("saved-queries.json"))
        snippets = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        self.retention = retention
    }

    /// Stores in a throw-away temp directory (previews, tests that don't care).
    convenience init() {
        self.init(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("QuerywellQuery-\(UUID().uuidString)", isDirectory: true))
    }

    func history(for connectionID: UUID) -> QueryHistoryStore {
        if let existing = histories[connectionID] { return existing }
        let store = QueryHistoryStore(connectionID: connectionID, directory: historyDirectory, retention: retention)
        histories[connectionID] = store
        return store
    }

    func updateRetention(_ new: HistoryRetention) {
        guard new != retention else { return }
        retention = new
        for store in histories.values {
            Task { try? await store.updateRetention(new) }
        }
    }

    /// Everything stored for a deleted connection.
    func purge(connectionID: UUID) async {
        histories[connectionID] = nil
        try? QueryHistoryStore.purge(connectionID: connectionID, directory: historyDirectory)
        try? await savedQueries.purge(connectionID: connectionID)
        try? await snippets.purge(connectionID: connectionID)
    }

    func clearHistory(connectionID: UUID) async {
        if let store = histories[connectionID] {
            try? await store.clear()
        } else {
            try? QueryHistoryStore.clear(connectionID: connectionID, directory: historyDirectory)
        }
    }

    func clearAllHistory() async {
        for store in histories.values { try? await store.clear() }
        try? QueryHistoryStore.clearAll(directory: historyDirectory)
    }

    func historyBytes() -> Int { QueryHistoryStore.totalBytes(directory: historyDirectory) }
}
