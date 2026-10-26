import Foundation
import QuerywellCore
import Testing
@testable import Querywell

// MARK: - Fixtures

/// Like `FakeInspector`, but `title` is a longtext column so JSON / serialized values fit.
private struct LongTextInspector: SchemaInspector {
    var tables: [TableInfo] = []
    var structures: [String: TableStructure] = [:]

    func listSchemas() async throws -> [String] { ["app"] }
    func listTables(schema: String) async throws -> [TableInfo] { tables }
    func listRoutines(schema: String) async throws -> [RoutineInfo] { [] }
    func structure(of table: TableRef) async throws -> TableStructure {
        if let s = structures[table.name] { return s }
        let cols = [
            ColumnDefinition(name: "ID", ordinal: 1, dataType: "bigint", fullType: "bigint unsigned", isNullable: false, isPrimaryKey: true, isAutoIncrement: true),
            ColumnDefinition(name: "title", ordinal: 2, dataType: "longtext", fullType: "longtext", isNullable: false, defaultExpression: ""),
            ColumnDefinition(name: "status", ordinal: 3, dataType: "varchar", fullType: "varchar(20)", isNullable: true, defaultExpression: "draft"),
        ]
        let info = TableInfo(ref: table, kind: .table, engine: "InnoDB", estimatedRows: 3, collation: "utf8mb4_0900_ai_ci")
        let indexes = [IndexDefinition(name: "PRIMARY", columns: ["ID"], isUnique: true, isPrimary: true)]
        return TableStructure(info: info, columns: cols, indexes: indexes, foreignKeys: [], referencedBy: [])
    }
    func availableCollations() async throws -> [CollationInfo] { [] }
    func availableEngines() async throws -> [String] { [] }
}

@MainActor
private func makeTable(value: String, readOnly: Bool = false) async throws -> (TableDataModel, FakeSession) {
    let session = FakeSession(rows: [[.integer(1), .text(value), .text("publish")], [.integer(2), .text("plain"), .null]])
    let model = TableDataModel(table: TableRef(schema: "app", name: "posts"))
    model.sessionProvider = { session }
    let inspector = LongTextInspector()
    model.inspectorProvider = { inspector }
    let gate = WriteGate()
    var profile = ConnectionProfile(name: "test", engine: .mysql, user: "u")
    profile.readOnly = readOnly
    let final = profile
    gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db) }
    gate.sessionProvider = { session }
    gate.confirmationHandler = { _ in true }
    model.gate = gate
    model.isReadOnlyProvider = { readOnly }
    model.loadIfNeeded(epoch: 1)
    try await waitUntil { model.hasLoaded && !model.isLoading }
    return (model, session)
}

private func phpS(_ s: String) -> String { "s:\(s.utf8.count):\"\(s)\";" }

// MARK: - Value editor

@MainActor
@Suite("Value editor")
struct ValueEditorTests {
    private let json = #"{"a":1,"b":[1,2],"url":"http:\/\/old.test"}"#

    @Test func jsonEditBecomesAPendingEditAndNothingIsWritten() async throws {
        let (table, session) = try await makeTable(value: json)
        let editor = try #require(table.makeValueEditor(displayRow: 0, column: "title"))
        #expect(editor.mode == .json && editor.detectedMode == .json)
        #expect(!editor.isReadOnly && !editor.hasChanges && !editor.canSave)

        #expect(editor.json.commitValue(id: "0", text: "2") == nil)
        #expect(editor.hasChanges && editor.canSave)
        // "Keep original formatting": minified source stays minified, `\/` stays escaped.
        #expect(String(decoding: editor.currentData, as: UTF8.self) == #"{"a":2,"b":[1,2],"url":"http:\/\/old.test"}"#)

        table.valueEditor = editor
        editor.onClose = { table.valueEditor = nil }
        #expect(editor.save())
        #expect(table.valueEditor == nil)
        #expect(table.pendingEditCount == 1)
        #expect(table.content?.rows[0][1] == .text(#"{"a":2,"b":[1,2],"url":"http:\/\/old.test"}"#))
        #expect(table.content?.isEdited(row: 0, column: 1) == true)
        #expect(table.pendingSQL(forDisplayRow: 0)?.contains("UPDATE `app`.`posts` SET `title` = ") == true)
        let executed = await session.executed
        #expect(!executed.contains { $0.uppercased().hasPrefix("UPDATE") }, "saving the editor never writes to the database")
    }

    @Test func saveFormatsAndSizes() async throws {
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(json.utf8), isReadOnly: false, onSave: { _ in nil })
        #expect(editor.json.saveFormat == .keep)
        editor.json.saveFormat = .pretty
        let pretty = String(decoding: editor.currentData, as: UTF8.self)
        #expect(pretty.contains("\n  \"a\": 1") && pretty.contains(#"http:\/\/old.test"#))
        #expect(editor.hasChanges)
        editor.json.saveFormat = .minified
        #expect(String(decoding: editor.currentData, as: UTF8.self) == json)
        #expect(!editor.hasChanges)
        editor.json.saveFormat = .keep
        #expect(editor.sizeSummary == "\(json.utf8.count) B")
        editor.json.add(to: "root", type: "string")
        #expect(editor.sizeSummary.contains("→"))
    }

    @Test func invalidJSONReportsLineAndColumnAndBlocksSaving() {
        let text = "{\n  \"a\": 1\n  \"b\": 2\n}"
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(text.utf8), isReadOnly: false, onSave: { _ in nil })
        #expect(editor.mode == .json)
        let error = editor.json.error
        #expect(error?.line == 3)
        #expect(!editor.canSave)
        #expect(editor.saveBlockedReason == "Fix the JSON error before saving.")
        editor.json.jumpToError()
        #expect(editor.json.pane == .raw)
        editor.json.setRaw("{\n  \"a\": 1,\n  \"b\": 2\n}")
        #expect(editor.json.isValid && editor.json.error == nil)
        #expect(editor.json.rows().count == 3)
        #expect(editor.hasChanges)
    }

    @Test func treeEditsCoverKeysTypesAndOrder() {
        let editor = JSONEditorModel(text: #"{"a":1,"list":[10,20,30],"flag":true}"#, isReadOnly: false)
        #expect(editor.renameKey(id: "0", to: "flag") != nil, "duplicate keys are refused")
        #expect(editor.renameKey(id: "0", to: "count") == nil)
        editor.move(id: "1.2", by: -1)
        #expect(editor.rawText == #"{"count":1,"list":[10,30,20],"flag":true}"#)
        editor.setBool(id: "2", false)
        editor.changeType(id: "0", to: "string")
        #expect(editor.rawText == #"{"count":"1","list":[10,30,20],"flag":false}"#)
        #expect(editor.commitValue(id: "1.0", text: "1e") != nil, "numbers are validated")
        editor.remove(id: "1.0")
        editor.undo()
        #expect(editor.rawText == #"{"count":"1","list":[10,30,20],"flag":false}"#)
        // Raw edits flow back into the tree.
        editor.setRaw(#"{"x":null}"#)
        #expect(editor.rows().map(\.key) == ["", "x"])
    }

    @Test func phpEditProducesRecalculatedBytes() throws {
        let original = "a:2:{" + phpS("a") + phpS("hello") + phpS("b") + "i:3;}"
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(original.utf8), isReadOnly: false, onSave: { _ in nil })
        #expect(editor.mode == .php)
        #expect(editor.php.footer == "No changes (original bytes kept)")
        #expect(!editor.canSave)

        #expect(editor.php.commitValue(id: "0", text: "hello wide world") == nil)
        let edited = "a:2:{" + phpS("a") + phpS("hello wide world") + phpS("b") + "i:3;}"
        #expect(String(decoding: editor.currentData, as: UTF8.self) == edited)
        #expect(editor.php.footer == "Will save \(edited.utf8.count) bytes · lengths recalculated automatically")
        #expect(editor.canSave)

        #expect(editor.php.renameKey(id: "1", to: "count") == nil)
        #expect(editor.php.commitValue(id: "1", text: "x") != nil, "ints are validated")
        #expect(editor.php.commitValue(id: "1", text: "9") == nil)
        editor.php.add(to: "root", type: "bool")
        let rows = editor.php.rows()
        #expect(rows.map(\.key) == ["", "a", "count", "new_key"])
        #expect(rows.last?.badge == "bool")
        // Reverting to the original value restores the original bytes exactly.
        let again = PHPEditorModel(data: Data(original.utf8), isReadOnly: false)
        _ = again.commitValue(id: "0", text: "x")
        _ = again.commitValue(id: "0", text: "hello")
        #expect(again.currentData == Data(original.utf8))
        #expect(!again.hasChanges)
    }

    @Test func phpShowsLockedValuesAndRefusesToEditThem() {
        let text = "a:3:{i:0;O:3:\"Foo\":1:{s:4:\"\u{0}*\u{0}x\";i:1;}i:1;E:8:\"Suit:Ace\";i:2;C:3:\"Bar\":2:{ab}}"
        let model = PHPEditorModel(data: Data(text.utf8), isReadOnly: false)
        model.expandAll()
        let rows = model.rows()
        #expect(rows.first(where: { $0.badge == "Foo" })?.tone == .className)
        let prop = rows.first { $0.key == "x" }
        #expect(prop?.keyNote == "protected")
        let enumRow = rows.first { $0.badge == "enum" }
        #expect(enumRow?.lockNote != nil && enumRow?.field == TreeValueField.none)
        let custom = rows.first { $0.badge == "C: Bar" }
        #expect(custom?.lockNote != nil)
        #expect(model.commitValue(id: enumRow?.id ?? "", text: "x") == nil && !model.hasChanges)
        #expect(model.lockNote(for: enumRow?.id ?? "") != nil)
    }

    @Test func invalidUTF8StringsAreHexAndReadOnly() {
        let bytes = Data("a:1:{i:0;s:3:\"".utf8) + Data([0xFF, 0xFE, 0x41]) + Data("\";}".utf8)
        let model = PHPEditorModel(data: bytes, isReadOnly: false)
        #expect(model.isValid)
        let row = model.rows().last
        #expect(row?.value.hasPrefix("0xFFFE41") == true)
        #expect(row?.lockNote != nil && row?.field == TreeValueField.none)
        #expect(model.currentData == bytes)
    }

    @Test func repairIsAProposalUntilAccepted() throws {
        let malformed = "a:1:{" + "s:1:\"a\";s:3:\"hello\";}"
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(malformed.utf8), isReadOnly: false, onSave: { _ in nil })
        #expect(editor.mode == .php && editor.php.parseError != nil)
        #expect(editor.php.errorDescription?.contains("byte") == true)
        #expect(!editor.canSave)

        #expect(editor.php.proposeRepair() == nil)
        let proposal = try #require(editor.php.repairProposal)
        #expect(proposal.fixes == [PHPLengthFix(offset: 13, declared: 3, actual: 5, preview: "hello")])
        // Nothing changed yet: still malformed, still unsaveable, original bytes untouched.
        #expect(!editor.php.isValid && !editor.canSave && editor.currentData == Data(malformed.utf8))

        editor.php.cancelRepair()
        #expect(editor.php.repairProposal == nil && !editor.php.isValid)

        _ = editor.php.proposeRepair()
        editor.php.acceptRepair()
        #expect(editor.php.isValid && editor.canSave)
        #expect(String(decoding: editor.currentData, as: UTF8.self) == "a:1:{s:1:\"a\";s:5:\"hello\";}")
    }

    @Test func unrepairableDataGivesAnExplanationAndNoProposal() {
        let editor = PHPEditorModel(data: Data("a:1:{i:0;".utf8), isReadOnly: false)
        #expect(editor.proposeRepair() != nil)
        #expect(editor.repairProposal == nil)
    }

    @Test func readOnlyBlocksSaving() async throws {
        let (table, _) = try await makeTable(value: json, readOnly: true)
        let editor = try #require(table.makeValueEditor(displayRow: 0, column: "title"))
        #expect(editor.isReadOnly)
        #expect(editor.readOnlyReason == EditBlock.readOnlyConnection.message)
        #expect(!editor.canSave && !editor.save())
        #expect(editor.json.commitValue(id: "0", text: "5") == nil)
        #expect(!editor.json.canUndo && editor.json.rawText == json)
        #expect(editor.json.rows().allSatisfy { $0.typeChoices.isEmpty && !$0.canRemove && !$0.canAdd })
        #expect(table.pendingEditCount == 0)
    }

    @Test func modeSwitchingCarriesTheContent() {
        let text = "a:1:{" + phpS("k") + phpS("v") + "}"
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(text.utf8), isReadOnly: false, onSave: { _ in nil })
        editor.setMode(.text)
        #expect(editor.plainText == text)
        editor.plainText = text.replacingOccurrences(of: "\"v\"", with: "\"w\"")
        editor.setMode(.php)
        #expect(editor.php.rows().last?.value == "\"w\"")
        editor.setMode(.json)
        #expect(!editor.json.isValid, "serialized text isn't JSON")
        #expect(editor.availableModes.count == 3)
    }

    @Test func nestedValuesOpenInTheirOwnEditorAndWriteBack() throws {
        let inner = #"{"n":1}"#
        let outer = "a:1:{" + phpS("opts") + phpS(inner) + "}"
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data(outer.utf8), isReadOnly: false, onSave: { _ in nil })
        let row = try #require(editor.php.rows().last)
        #expect(row.nestedLabel == "JSON")
        editor.php.openNested(id: row.id)
        let child = try #require(editor.nested)
        #expect(child.mode == .json)
        #expect(child.json.commitValue(id: "0", text: "2") == nil)
        #expect(child.save())
        #expect(String(decoding: editor.php.currentData, as: UTF8.self) == "a:1:{" + phpS("opts") + phpS(#"{"n":2}"#) + "}")
        #expect(editor.hasChanges)
    }

    @Test func plainTextAndBinaryCells() async throws {
        let text = ValueEditorModel(title: "t", subtitle: "", data: Data("just words".utf8), isReadOnly: false, onSave: { _ in nil })
        #expect(text.mode == .text && text.detectedMode == .text)
        let binary = ValueEditorModel(title: "t", subtitle: "", data: Data([0x00, 0xFF, 0x10]), isReadOnly: false, onSave: { _ in nil })
        #expect(binary.isBinaryData && binary.mode == .text)
        #expect(binary.availableModes == [.php, .text])
        #expect(!binary.canSave)
        #expect(binary.plainText.contains("00 FF 10"))
    }

    @Test func closingAsksBeforeDiscardingChanges() {
        var closed = 0
        let editor = ValueEditorModel(title: "t", subtitle: "", data: Data("x".utf8), isReadOnly: false, onSave: { _ in nil })
        editor.onClose = { closed += 1 }
        editor.requestClose()
        #expect(closed == 1 && !editor.confirmingDiscard)
        editor.plainText = "y"
        editor.requestClose()
        #expect(closed == 1 && editor.confirmingDiscard)
        editor.discardAndClose()
        #expect(closed == 2)
    }

    @Test func saveErrorsComeFromTheTableAndKeepTheEditorOpen() async throws {
        let (table, _) = try await makeTable(value: "plain")
        let editor = try #require(table.makeValueEditor(displayRow: 1, column: "status"))
        editor.plainText = String(repeating: "x", count: 30)  // varchar(20)
        #expect(!editor.save())
        #expect(editor.saveError?.contains("at most 20") == true)
        #expect(table.pendingEditCount == 0)
    }
}

// MARK: - Search & replace model

@MainActor
@Suite("Search & replace model")
struct SearchReplaceModelTests {
    private func table(_ name: String, engine: String = "InnoDB", kind: TableKind = .table) -> TableInfo {
        TableInfo(ref: TableRef(schema: "app", name: name), kind: kind, engine: kind == .view ? nil : engine, estimatedRows: 10)
    }

    private func model(tables: [TableInfo], noPK: Set<String> = [], readOnly: Bool = false, connection: UUID = UUID()) -> SearchReplaceModel {
        var inspector = LongTextInspector(tables: tables)
        for name in noPK {
            let cols = [ColumnDefinition(name: "body", ordinal: 1, dataType: "text", fullType: "text", isNullable: true)]
            inspector.structures[name] = TableStructure(
                info: tables.first { $0.ref.name == name }!, columns: cols, indexes: [], foreignKeys: [], referencedBy: [])
        }
        let final = inspector
        let m = SearchReplaceModel(connectionID: connection, schema: "app", engine: .mysql, isReadOnly: readOnly, isProduction: false)
        m.inspectorProvider = { final }
        m.sessionProvider = { FakeSession() }
        return m
    }

    @Test func wordPressTablesArePreselectedAndOthersAreNot() async {
        let m = model(tables: ["wp_posts", "wp_users", "wp_options", "wp_postmeta", "audit_log"].map { table($0) })
        await m.loadTables()
        await m.waitForStructures()
        #expect(m.wordPressPrefix == "wp_")
        #expect(m.selected.map(\.name).sorted() == ["wp_options", "wp_postmeta", "wp_posts", "wp_users"])
    }

    @Test func nothingIsPreselectedOutsideWordPress() async {
        let m = model(tables: ["orders", "customers"].map { table($0) })
        await m.loadTables()
        #expect(m.wordPressPrefix == nil && m.selected.isEmpty)
        #expect(m.previewBlocker == "Enter something to search for.")
        m.search = "x"
        #expect(m.previewBlocker == "Select at least one table.")
        m.selectAll()
        #expect(m.selectedCount == 2 && m.previewBlocker == nil)
        m.selectNone()
        #expect(m.selected.isEmpty)
    }

    @Test func sidebarSelectionWinsOverWordPressDetection() async {
        let m = model(tables: ["wp_posts", "wp_users", "wp_options", "extra"].map { table($0) })
        await m.loadTables(preselect: ["extra"])
        #expect(m.selected.map(\.name) == ["extra"])
    }

    @Test func tablesWithoutAKeyViewsAndMyISAMAreFlagged() async {
        let m = model(
            tables: [table("notes"), table("keyless"), table("legacy", engine: "MyISAM"), table("v_report", kind: .view)], noPK: ["keyless"])
        await m.loadTables()
        await m.waitForStructures()
        let byName = Dictionary(uniqueKeysWithValues: m.tables.map { ($0.name, $0) })
        #expect(byName["keyless"]?.ineligibleReason?.contains("No primary key") == true)
        #expect(byName["v_report"]?.ineligibleReason != nil)
        #expect(byName["legacy"]?.isNonTransactional == true && byName["legacy"]?.ineligibleReason == nil)
        #expect(byName["notes"]?.isNonTransactional == false)
        m.selectAll()
        #expect(m.selected.map(\.name).sorted() == ["legacy", "notes"], "greyed tables can't be ticked")
        m.toggle(TableRef(schema: "app", name: "keyless"))
        #expect(!m.selected.contains(TableRef(schema: "app", name: "keyless")))
        m.filter = "leg"
        #expect(m.visibleTables.map(\.name) == ["legacy"])
    }

    @Test func invalidRegexIsReportedBeforeAnythingRuns() async {
        let m = model(tables: [table("notes")])
        await m.loadTables(preselect: ["notes"])
        m.search = "(unclosed"
        m.regex = true
        await m.runPreview()
        #expect(m.inputError?.hasPrefix("Invalid regular expression") == true)
        #expect(m.previewReport == nil && m.stage == .configuring)
    }

    @Test func readOnlyConnectionsCanPreviewButNotApply() async {
        let m = model(tables: [table("notes")], readOnly: true)
        await m.loadTables(preselect: ["notes"])
        m.search = "a"
        #expect(m.canPreview)
        #expect(m.applyBlocker == "This connection is read-only.")
        m.beginApply()
        #expect(!m.confirmingApply)
    }

    @Test func theLastPairIsRememberedInMemoryPerConnection() {
        let connection = UUID()
        let first = model(tables: [], connection: connection)
        first.search = "old.test"
        first.replace = "new.test"
        let again = model(tables: [], connection: connection)
        #expect(again.search == "old.test" && again.replace == "new.test")
        let other = model(tables: [])
        #expect(other.search.isEmpty && other.replace.isEmpty)
        SearchReplaceMemory.forget(connection: connection)
        #expect(model(tables: [], connection: connection).search.isEmpty)
    }

    @Test func nonTransactionalEnginesAreRecognised() {
        #expect(SearchReplaceModel.isNonTransactional("MyISAM", family: .mysql))
        #expect(SearchReplaceModel.isNonTransactional("MEMORY", family: .mysql))
        #expect(!SearchReplaceModel.isNonTransactional("InnoDB", family: .mysql))
        #expect(!SearchReplaceModel.isNonTransactional(nil, family: .postgres))
    }

    @Test func excerptDiffMarksOnlyWhatChanged() {
        let (before, after) = ExcerptDiff.highlight(before: "see http://old.test/a end", after: "see https://new.test/a end")
        let marked = { (s: AttributedString) in s.runs.filter { $0.backgroundColor != nil }.map { String(s[$0.range].characters) }.joined() }
        #expect(marked(before).contains("old"))
        #expect(marked(after).contains("new"))
        #expect(!marked(before).contains("see") && !marked(after).contains("end"))
    }

    @Test func wordPressDetectionNeedsTheCoreTables() {
        #expect(WordPressDetection.prefix(in: ["wp_posts", "wp_users", "wp_options"]) == "wp_")
        #expect(WordPressDetection.prefix(in: ["site2_posts", "site2_users", "site2_options", "wp_options"]) == "site2_")
        #expect(WordPressDetection.prefix(in: ["posts", "users", "options"]) == "")
        #expect(WordPressDetection.prefix(in: ["wp_options", "wp_posts"]) == nil)
    }
}
