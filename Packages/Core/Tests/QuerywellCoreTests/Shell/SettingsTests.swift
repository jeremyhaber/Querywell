import Foundation
import Testing
@testable import QuerywellCore

private func decode(_ json: String) throws -> AppSettings {
    try JSONFileStore.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("qw-settings-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json")
}

@Suite("AppSettings")
struct AppSettingsTests {
    @Test func defaults() {
        let s = AppSettings()
        #expect(s.schemaVersion == 1)
        #expect(s.general.reopenLastSession && s.general.confirmBeforeClosingConnectionWindow)
        #expect(s.general.openConnectionBehaviour == .focusExisting)
        #expect(s.safety.confirmWritesOnProduction && s.safety.requireTypingDatabaseNameForDestructive)
        #expect(!s.safety.defaultReadOnlyForNewProductionConnections)
        #expect(s.editor.fontSize == 12 && s.editor.showLineNumbers)
        #expect(s.dataGrid.pageSize == 500 && s.dataGrid.showColumnTypes && s.dataGrid.nullDisplay == "NULL")
        #expect(s.ai.provider == nil && s.ai.model == nil && !s.ai.includeSampleRowsByDefault)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        #expect(try decode("{}") == AppSettings())
    }

    @Test func partialJSON() throws {
        let s = try decode(#"""
        {"general":{"openConnectionBehaviour":"newWindow"},
         "dataGrid":{"pageSize":1000,"nullDisplay":"∅"},
         "ai":{"provider":"anthropic","model":"m"}}
        """#)
        #expect(s.general.openConnectionBehaviour == .newWindow)
        #expect(s.general.reopenLastSession)            // default retained
        #expect(s.dataGrid.pageSize == 1000 && s.dataGrid.nullDisplay == "∅" && s.dataGrid.showColumnTypes)
        #expect(s.ai.provider == .anthropic && s.ai.model == "m")
        #expect(s.safety == AppSettings.Safety())
    }

    @Test func malformedValuesFallBack() throws {
        let s = try decode(#"""
        {"general":{"openConnectionBehaviour":"sideways","reopenLastSession":"yes"},
         "ai":{"provider":"skynet"}, "editor":"oops", "safety":{"confirmWritesOnProduction":false}}
        """#)
        #expect(s.general == AppSettings.General())
        #expect(s.ai.provider == nil)
        #expect(s.editor == AppSettings.Editor())
        #expect(s.safety.confirmWritesOnProduction == false)   // stored value is preserved
    }

    @Test func pageSizeIsClamped() throws {
        #expect(try decode(#"{"dataGrid":{"pageSize":1}}"#).dataGrid.pageSize == 50)
        #expect(try decode(#"{"dataGrid":{"pageSize":50}}"#).dataGrid.pageSize == 50)
        #expect(try decode(#"{"dataGrid":{"pageSize":10000}}"#).dataGrid.pageSize == 10_000)
        #expect(try decode(#"{"dataGrid":{"pageSize":99999999}}"#).dataGrid.pageSize == 10_000)
        #expect(AppSettings.DataGrid(pageSize: -5).pageSize == 50)
        var g = AppSettings.DataGrid()
        g.pageSize = 20_000
        #expect(g.pageSize == 10_000)
    }

    @Test func fontSizeIsClamped() throws {
        #expect(try decode(#"{"editor":{"fontSize":2}}"#).editor.fontSize == 8)
        #expect(try decode(#"{"editor":{"fontSize":14.5}}"#).editor.fontSize == 14.5)
        var e = AppSettings.Editor()
        e.fontSize = 500
        #expect(e.fontSize == 36)
    }

    @Test func roundTrip() throws {
        var s = AppSettings()
        s.ai = .init(provider: .openrouter, model: "x/y", includeSampleRowsByDefault: true)
        s.general.openConnectionBehaviour = .newWindow
        s.dataGrid.pageSize = 250
        let data = try JSONFileStore.makeEncoder().encode(s)
        #expect(try JSONFileStore.makeDecoder().decode(AppSettings.self, from: data) == s)
    }
}

@Suite("AppSettingsStore")
struct AppSettingsStoreTests {
    @Test func missingFileGivesDefaultsAndWritesNothing() async throws {
        let url = tempFile()
        let store = AppSettingsStore(fileURL: url)
        #expect(try await store.current() == AppSettings())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func updatePersistsWithOwnerOnlyPermissions() async throws {
        let url = tempFile()
        let store = AppSettingsStore(fileURL: url)
        let result = try await store.update { $0.editor.fontSize = 15 }
        #expect(result.editor.fontSize == 15)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let reopened = AppSettingsStore(fileURL: url)
        #expect(try await reopened.load().editor.fontSize == 15)
    }

    @Test func saveReplaces() async throws {
        let url = tempFile()
        let store = AppSettingsStore(fileURL: url)
        var s = AppSettings(); s.general.reopenLastSession = false
        try await store.save(s)
        #expect(try await AppSettingsStore(fileURL: url).current().general.reopenLastSession == false)
    }

    @Test func failedTransformChangesNothing() async throws {
        struct Boom: Error {}
        let store = AppSettingsStore(fileURL: tempFile())
        try await store.update { $0.editor.fontSize = 20 }
        await #expect(throws: Boom.self) {
            try await store.update { $0.editor.fontSize = 30; throw Boom() }
        }
        #expect(try await store.current().editor.fontSize == 20)
    }

    @Test func corruptFileIsNeverOverwritten() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = AppSettingsStore(fileURL: url)
        await #expect(throws: AppSettingsStoreError.self) { try await store.load() }
        await #expect(throws: AppSettingsStoreError.self) { try await store.update { $0.editor.fontSize = 9 } }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test func newerSchemaRejected() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99}"#.utf8).write(to: url)
        let store = AppSettingsStore(fileURL: url)
        await #expect(throws: AppSettingsStoreError.unsupportedSchemaVersion(found: 99, supported: 1)) {
            try await store.load()
        }
    }

    @Test func partialFileLoads() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        #expect(try await AppSettingsStore(fileURL: url).load() == AppSettings())
    }

    @Test func settingsFileLivesBesideConnections() throws {
        let s = try AppDirectories.settingsFileURL(appName: "QuerywellTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent()) }
        #expect(s.lastPathComponent == "settings.json")
        #expect(s.deletingLastPathComponent().lastPathComponent.hasPrefix("QuerywellTest-"))
    }
}

@Suite("AI sample rows per connection")
struct SampleRowsPreferenceTests {
    @Test func defaultsOffAndOverridesPerConnection() throws {
        var ai = AppSettings.AI()
        let a = UUID(), b = UUID()
        #expect(!ai.includesSampleRows(for: a))
        ai.setIncludesSampleRows(true, for: a)
        #expect(ai.includesSampleRows(for: a) && !ai.includesSampleRows(for: b))
        ai.includeSampleRowsByDefault = true
        #expect(ai.includesSampleRows(for: b))
        ai.setIncludesSampleRows(false, for: b)
        #expect(!ai.includesSampleRows(for: b))
        ai.forgetConnection(a)
        #expect(ai.includesSampleRows(for: a))  // falls back to the default
        let back = try JSONDecoder().decode(AppSettings.AI.self, from: JSONEncoder().encode(ai))
        #expect(back == ai)
    }

    @Test func oldSettingsWithoutTheFieldDecode() throws {
        let ai = try JSONDecoder().decode(AppSettings.AI.self, from: Data(#"{"includeSampleRowsByDefault":true}"#.utf8))
        #expect(ai.sampleRowsByConnection.isEmpty && ai.includeSampleRowsByDefault)
    }
}
