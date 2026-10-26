import Foundation
import QuerywellCore
import Testing
@testable import Querywell

private struct StubInspector: SchemaInspector {
    var schemas = ["app", "mysql", "other"]
    func listSchemas() async throws -> [String] { schemas }
    func listTables(schema: String) async throws -> [TableInfo] {
        [
            TableInfo(ref: TableRef(schema: schema, name: "wp_posts"), kind: .table, estimatedRows: 2_148),
            TableInfo(ref: TableRef(schema: schema, name: "wp_users"), kind: .table, estimatedRows: 18),
            TableInfo(ref: TableRef(schema: schema, name: "recent"), kind: .view),
        ]
    }
    func listRoutines(schema: String) async throws -> [RoutineInfo] { [RoutineInfo(schema: schema, name: "p", kind: .procedure)] }
    func structure(of table: TableRef) async throws -> TableStructure { throw DatabaseError.unsupported("stub") }
    func availableCollations() async throws -> [CollationInfo] { [] }
    func availableEngines() async throws -> [String] { [] }
}

@MainActor
@Suite("Schema browser model")
struct SchemaBrowserModelTests {
    private func settle(_ model: SchemaBrowserModel) async throws {
        for _ in 0..<100 where model.current == nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func loadsPreferredSchemaAndCaches() async throws {
        let model = SchemaBrowserModel()
        model.attach(inspector: StubInspector(), engine: .mysql, preferred: "other")
        try await settle(model)
        #expect(model.selectedSchema == "other")
        #expect(model.current?.tables.map(\.ref.name) == ["wp_posts", "wp_users"])
        #expect(model.current?.views.map(\.ref.name) == ["recent"])
        #expect(model.current?.summary == "1 view · 1 procedure")
        #expect(model.switcherItems.count == 3)
        model.selectedSchema = "app"
        #expect(model.selectedTables.isEmpty)
        try await settle(model)
        #expect(model.contents.keys.sorted() == ["app", "other"])
        model.detach()
        #expect(model.contents.isEmpty && model.selectedSchema == nil)
    }

    @Test func fuzzyFilterAndSelection() async throws {
        let model = SchemaBrowserModel()
        model.attach(inspector: StubInspector(), engine: .mysql, preferred: "app")
        try await settle(model)
        model.filterText = "wpu"
        #expect(model.filteredTables.map(\.ref.name) == ["wp_users"])
        model.filterText = ""
        let visible = ["wp_posts", "wp_users", "recent"]
        model.select("wp_posts", command: false, shift: false, visible: visible)
        model.select("recent", command: false, shift: true, visible: visible)
        #expect(model.selectedTables == Set(visible))
        model.select("wp_users", command: true, shift: false, visible: visible)
        #expect(model.selectedTables == ["wp_posts", "recent"])
    }

    @Test func postgresPrefersPublic() {
        #expect(SchemaBrowserModel.pick(["audit", "public"], preferred: nil, engine: .postgresql) == "public")
        #expect(SchemaBrowserModel.pick(["a", "b"], preferred: "b", engine: .postgresql) == "b")
        #expect(SchemaBrowserModel.pick(["mysql", "app"], preferred: nil, engine: .mysql) == "app")
    }
}
