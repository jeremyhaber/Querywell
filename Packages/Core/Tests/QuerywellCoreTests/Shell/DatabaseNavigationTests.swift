import Foundation
import Testing
@testable import QuerywellCore

@Suite("DatabaseList")
struct DatabaseListTests {
    let names = ["wp_site", "information_schema", "analytics", "mysql", "wp_staging", "Zeta"]

    @Test func emptyQueryListsUserDatabasesFirstThenSystem() {
        let rows = DatabaseList.entries(names: names, query: "", engine: .mysql)
        #expect(rows.map(\.name) == ["analytics", "wp_site", "wp_staging", "Zeta", "information_schema", "mysql"])
        #expect(rows.map(\.isSystem) == [false, false, false, false, true, true])
        #expect(rows.allSatisfy { $0.matchedIndices.isEmpty })
    }

    @Test func fuzzyFilterRanksAndReportsMatches() {
        let rows = DatabaseList.entries(names: names, query: "wpst", engine: .mysql)
        #expect(rows.first?.name == "wp_staging")
        #expect(!rows.contains { $0.name == "analytics" })
        #expect(rows.first?.matchedIndices.count == 4)
    }

    @Test func noMatchIsEmpty() {
        #expect(DatabaseList.entries(names: names, query: "qqq", engine: .mysql).isEmpty)
    }

    @Test func postgresTemplatesAreSystem() {
        let rows = DatabaseList.entries(names: ["template1", "app", "postgres"], query: "", engine: .postgresql)
        #expect(rows.map(\.name) == ["app", "postgres", "template1"])
    }

    @Test func whitespaceQueryIsEmptyQuery() {
        #expect(DatabaseList.entries(names: names, query: "  ", engine: .mysql).count == names.count)
    }

    @Test func arrowKeysClampAndStartAtTheEnds() {
        #expect(DatabaseList.move(from: nil, delta: 1, count: 3) == 0)
        #expect(DatabaseList.move(from: nil, delta: -1, count: 3) == 2)
        #expect(DatabaseList.move(from: 0, delta: -1, count: 3) == 0)
        #expect(DatabaseList.move(from: 2, delta: 1, count: 3) == 2)
        #expect(DatabaseList.move(from: 1, delta: 1, count: 3) == 2)
        #expect(DatabaseList.move(from: 1, delta: 1, count: 0) == nil)
    }

    @Test func highlightSurvivesFilteringWhenPossible() {
        let rows = DatabaseList.entries(names: names, query: "wp", engine: .mysql)
        #expect(DatabaseList.reconcile(selected: "wp_site", in: rows) == "wp_site")
        #expect(DatabaseList.reconcile(selected: "analytics", in: rows) == rows.first?.name)
        #expect(DatabaseList.reconcile(selected: nil, in: []) == nil)
    }

    @Test func windowTitle() {
        #expect(DatabaseWindowTitle.make(connection: "Prod", database: "shop") == "Prod · shop")
        #expect(DatabaseWindowTitle.make(connection: "Prod", database: nil) == "Prod")
        #expect(DatabaseWindowTitle.make(connection: "Prod", database: "") == "Prod")
    }
}

@Suite("DatabaseDDL")
struct DatabaseDDLTests {
    let my = SQLDialect(.mysql)
    let pg = SQLDialect(.postgresql)

    @Test func mysqlCreate() {
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "shop"), dialect: my) == "CREATE DATABASE `shop`")
        #expect(DatabaseDDL.create(
            NewDatabaseSpec(name: " we`ird ", characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci"), dialect: my)
            == "CREATE DATABASE `we``ird` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci")
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "a", collation: "latin1_swedish_ci"), dialect: my)
            == "CREATE DATABASE `a` COLLATE latin1_swedish_ci")
    }

    @Test func mysqlIgnoresPostgresFields() {
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "a", owner: "bob", encoding: "UTF8", template: "t"), dialect: my)
            == "CREATE DATABASE `a`")
    }

    @Test func postgresCreate() {
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "shop"), dialect: pg) == "CREATE DATABASE \"shop\"")
        #expect(DatabaseDDL.create(
            NewDatabaseSpec(name: "My \"DB\"", characterSet: "ignored", owner: "app", encoding: "UTF8", template: "template0"),
            dialect: pg) == "CREATE DATABASE \"My \"\"DB\"\"\" OWNER \"app\" TEMPLATE \"template0\" ENCODING 'UTF8'")
    }

    @Test func blankOptionalFieldsAreOmitted() {
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "a", characterSet: " ", collation: "", owner: "", encoding: " "), dialect: my)
            == "CREATE DATABASE `a`")
        #expect(DatabaseDDL.create(NewDatabaseSpec(name: "a", owner: "", encoding: "", template: ""), dialect: pg)
            == "CREATE DATABASE \"a\"")
    }

    @Test func drop() {
        #expect(DatabaseDDL.drop("old`db", dialect: my) == "DROP DATABASE `old``db`")
        #expect(DatabaseDDL.drop("old\"db", dialect: pg) == "DROP DATABASE \"old\"\"db\"")
    }

    @Test func validation() {
        #expect(DatabaseDDL.problems(NewDatabaseSpec(name: "ok"), dialect: my, existing: ["a"]).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: "  "), dialect: my, existing: []).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: "SHOP"), dialect: my, existing: ["shop"]).isEmpty)
        #expect(DatabaseDDL.problems(NewDatabaseSpec(name: "SHOP"), dialect: pg, existing: ["shop"]).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: "a/b"), dialect: my, existing: []).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: String(repeating: "x", count: 65)), dialect: my, existing: []).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: String(repeating: "é", count: 40)), dialect: pg, existing: []).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: "a", characterSet: "utf8; DROP"), dialect: my, existing: []).isEmpty)
        #expect(!DatabaseDDL.problems(NewDatabaseSpec(name: "a", collation: "x y"), dialect: my, existing: []).isEmpty)
    }

    @Test func mysqlOptionsGroupCollationsByCharset() {
        let rows = [
            CollationInfo(name: "utf8mb4_bin", characterSet: "utf8mb4", isDefault: false),
            CollationInfo(name: "utf8mb4_0900_ai_ci", characterSet: "utf8mb4", isDefault: true),
            CollationInfo(name: "latin1_swedish_ci", characterSet: "latin1", isDefault: true),
        ]
        let o = DatabaseCreationOptions.mysql(collations: rows, serverCharset: "utf8mb4", serverCollation: "utf8mb4_0900_ai_ci")
        #expect(o.charsets.map(\.name) == ["latin1", "utf8mb4"])
        #expect(o.collations(for: "utf8mb4") == ["utf8mb4_0900_ai_ci", "utf8mb4_bin"])
        #expect(o.charsets.last?.defaultCollation == "utf8mb4_0900_ai_ci")
        #expect(o.defaultCharset == "utf8mb4" && o.defaultCollation == "utf8mb4_0900_ai_ci")
        #expect(o.collations(for: nil).isEmpty && o.collations(for: "nope").isEmpty)
    }

    @Test func generatedCreateIsClassifiedAsDDLWrite() {
        let c = StatementClassifier(dialect: my).classify(text: DatabaseDDL.create(NewDatabaseSpec(name: "x"), dialect: my))
        #expect(c.kind == .ddl)
        let d = StatementClassifier(dialect: pg).classify(text: DatabaseDDL.drop("x", dialect: pg))
        #expect(d.kind == .ddl && d.isDestructive)
    }
}

@Suite("DatabaseSelectionBehaviour")
struct DatabaseSelectionBehaviourTests {
    @Test func defaultsToOwnWindowAndInverts() {
        #expect(AppSettings().general.databaseSelectionBehaviour == .opensOwnWindow)
        #expect(DatabaseSelectionBehaviour.opensOwnWindow.inverted == .switchesWindow)
        #expect(DatabaseSelectionBehaviour.switchesWindow.inverted == .opensOwnWindow)
    }

    @Test func decodingIsTolerant() throws {
        let decoder = JSONFileStore.makeDecoder()
        let old = try decoder.decode(AppSettings.self, from: Data(#"{"general":{"reopenLastSession":false}}"#.utf8))
        #expect(old.general.databaseSelectionBehaviour == .opensOwnWindow)
        let switching = try decoder.decode(
            AppSettings.self, from: Data(#"{"general":{"databaseSelectionBehaviour":"switchesWindow"}}"#.utf8))
        #expect(switching.general.databaseSelectionBehaviour == .switchesWindow)
        let junk = try decoder.decode(AppSettings.self, from: Data(#"{"general":{"databaseSelectionBehaviour":"teleport"}}"#.utf8))
        #expect(junk.general.databaseSelectionBehaviour == .opensOwnWindow)
    }

    @Test func roundTrips() throws {
        var s = AppSettings()
        s.general.databaseSelectionBehaviour = .switchesWindow
        let data = try JSONFileStore.makeEncoder().encode(s)
        #expect(try JSONFileStore.makeDecoder().decode(AppSettings.self, from: data) == s)
    }
}
