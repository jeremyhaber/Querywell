import Foundation
import QuerywellCore
import Testing
@testable import Querywell

@MainActor
@Suite("Query data lifecycle")
struct AppModelQueryTests {
    @Test func deletingAConnectionPurgesItsHistorySavedQueriesSnippetsAndAIChoice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QW-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(directory: dir, secretStore: InMemorySecretStore())
        await model.load()
        var draft = ConnectionDraft(newFor: .mysql)
        draft.name = "Doomed"
        draft.user = "u"
        #expect(await model.save(draft))
        var keep = ConnectionDraft(newFor: .mysql)
        keep.name = "Kept"
        keep.user = "u"
        #expect(await model.save(keep))
        let doomed = try #require(model.library.profiles.first { $0.name == "Doomed" })
        let kept = try #require(model.library.profiles.first { $0.name == "Kept" })

        let services = model.queryServices
        try await services.history(for: doomed.id).record(HistoryEntry(sql: "SELECT 1"))
        try await services.history(for: kept.id).record(HistoryEntry(sql: "SELECT 2"))
        _ = try await services.savedQueries.save(name: "mine", sql: "SELECT 1", connectionID: doomed.id)
        _ = try await services.savedQueries.save(name: "shared", sql: "SELECT 1", connectionID: nil)
        _ = try await services.snippets.add(name: "s", sql: "SELECT 1", connectionID: doomed.id)
        model.updateSettings { $0.ai.setIncludesSampleRows(true, for: doomed.id) }
        #expect(services.historyBytes() > 0)

        await model.delete(doomed)

        #expect(try await services.history(for: doomed.id).recent().isEmpty)
        #expect(try await services.history(for: kept.id).recent().count == 1)
        #expect(try await services.savedQueries.list(for: doomed.id).map(\.name) == ["shared"])
        #expect(try await services.snippets.list(for: doomed.id).isEmpty)
        #expect(model.settings.ai.sampleRowsByConnection[doomed.id.uuidString] == nil)
    }

    @Test func historySettingsReachTheStoresAndClearAllEmptiesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QW-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(directory: dir, secretStore: InMemorySecretStore())
        await model.load()
        model.updateSettings { $0.historyRetention.maxEntries = 2 }
        #expect(model.queryServices.retention.maxEntries == 2)
        let id = UUID()
        let store = model.queryServices.history(for: id)
        for i in 0..<5 { try await store.record(HistoryEntry(sql: "SELECT \(i)")) }
        #expect(try await store.recent().count == 2)
        await model.queryServices.clearAllHistory()
        #expect(try await store.recent().isEmpty)
        #expect(model.queryServices.historyBytes() == 0)
    }
}
