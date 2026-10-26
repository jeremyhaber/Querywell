import Testing
@testable import QuerywellCore

@Suite("DatabaseSelection")
struct DatabaseSelectionTests {
    let mysql = ["information_schema", "mysql", "performance_schema", "querywell_test", "sys", "wp_site"]

    @Test func defaultDatabaseWins() {
        #expect(DatabaseSelection.preferred(among: mysql, defaultDatabase: "wp_site", current: "querywell_test", engine: .mysql) == "wp_site")
    }

    @Test func missingDefaultFallsBackToCurrent() {
        #expect(DatabaseSelection.preferred(among: mysql, defaultDatabase: "gone", current: "wp_site", engine: .mysql) == "wp_site")
    }

    @Test func systemSchemasAreSkipped() {
        #expect(DatabaseSelection.preferred(among: mysql, defaultDatabase: nil, current: nil, engine: .mariadb) == "querywell_test")
        #expect(DatabaseSelection.preferred(among: mysql, defaultDatabase: nil, current: "information_schema", engine: .mysql) == "querywell_test")
    }

    @Test func onlySystemSchemasStillPicksOne() {
        #expect(DatabaseSelection.preferred(among: ["information_schema", "mysql"], defaultDatabase: nil, current: nil, engine: .mysql) == "information_schema")
        #expect(DatabaseSelection.preferred(among: [], defaultDatabase: nil, current: nil, engine: .mysql) == nil)
    }

    @Test func postgresTemplatesAreSystem() {
        #expect(DatabaseSelection.preferred(among: ["postgres", "template0", "app"], defaultDatabase: nil, current: "postgres", engine: .postgresql) == "postgres")
        #expect(DatabaseSelection.isSystemDatabase("template1", engine: .postgresql))
        #expect(!DatabaseSelection.isSystemDatabase("information_schema", engine: .postgresql))
    }
}
