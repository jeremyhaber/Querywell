import Foundation
import Observation
import QuerywellCore

/// State behind a table tab's Triggers mode: the table's triggers, the create / edit form, and running
/// the DDL through the write gate. SQL generation is `TriggerDDL` in Core.
@MainActor @Observable
final class TableTriggersModel {
    enum EditorMode: Identifiable, Equatable {
        case create
        case edit(TriggerInfo)

        var id: String {
            switch self {
            case .create: "create"
            case .edit(let t): "edit-" + t.name
            }
        }
    }

    enum FunctionSource: String, CaseIterable, Identifiable {
        case existing = "Existing function", new = "New function"
        var id: String { rawValue }
    }

    struct DefinitionSheet: Identifiable {
        var title: String
        var text: String
        var id: String { title }
    }

    struct Status: Equatable {
        var message: String
        var isError: Bool
    }

    @ObservationIgnored private weak var owner: TableDataModel?
    @ObservationIgnored private weak var workspace: ConnectionWorkspace?

    func attach(owner: TableDataModel, workspace: ConnectionWorkspace) {
        self.owner = owner
        self.workspace = workspace
    }

    var table: TableRef { owner?.table ?? TableRef(schema: "", name: "") }
    var dialect: SQLDialect { SQLDialect(workspace?.profile.engine ?? .mysql) }
    var isPostgres: Bool { dialect.family == .postgres }
    var isReadOnly: Bool { workspace?.profile.effectiveReadOnly ?? false }
    var isTable: Bool { (owner?.structure?.info.kind ?? .table) == .table }

    // MARK: List

    private(set) var triggers: [TriggerInfo] = []
    private(set) var functions: [TableRef] = []
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var status: Status?
    private(set) var isRunning = false
    var definition: DefinitionSheet?

    func load() async {
        guard let owner, let workspace, let session = workspace.live?.session else { return }
        let ref = owner.table
        let inspector = workspace.browser.inspector ?? SchemaInspectorFactory.inspector(for: session)
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await inspector.triggers(on: ref)
            if isPostgres { functions = (try? await inspector.triggerFunctions(schema: ref.schema)) ?? [] }
            guard ref == owner.table else { return }
            triggers = found
            loadError = nil
            hasLoaded = true
        } catch {
            loadError = SchemaBrowserModel.message(error)
        }
    }

    // MARK: Form

    var editor: EditorMode?
    var name = ""
    var timing: TriggerTiming = .before
    /// MySQL: exactly one is used (`mysqlEvent`); PostgreSQL: any non-empty set.
    var events: Set<TriggerEvent> = [.insert]
    var forEachRow = true
    var whenCondition = ""
    var functionSource: FunctionSource = .existing
    /// `schema.name` of the chosen existing function.
    var functionChoice = ""
    var newFunctionName = ""
    /// MySQL: the trigger body; PostgreSQL: the new function's `plpgsql` body.
    var bodyText = ""
    @ObservationIgnored let bodyEditor = SQLEditorController()
    /// What the SQL editor starts with when the sheet opens.
    private(set) var initialBody = ""
    private(set) var editorError: String?

    var mysqlEvent: TriggerEvent {
        get { events.first ?? .insert }
        set { events = [newValue] }
    }

    var isEditing: Bool { if case .edit = editor { true } else { false } }
    var original: TriggerInfo? { if case .edit(let t) = editor { t } else { nil } }

    func beginCreate() {
        name = ""
        timing = .before
        events = [.insert]
        forEachRow = true
        whenCondition = ""
        functionSource = functions.isEmpty ? .new : .existing
        functionChoice = functions.first.map(Self.key) ?? ""
        newFunctionName = table.name + "_trigger_fn"
        setBody(isPostgres ? TriggerDDL.functionTemplate(for: .before, events: [.insert]) : "BEGIN\n  \nEND")
        editorError = nil
        editor = .create
    }

    func beginEdit(_ trigger: TriggerInfo) {
        name = trigger.name
        timing = trigger.timing
        events = Set(trigger.events)
        forEachRow = trigger.forEachRow
        whenCondition = trigger.whenCondition ?? ""
        if let function = trigger.function {
            functionSource = .existing
            functionChoice = Self.key(function)
            if !functions.contains(function) { functions.append(function) }
        } else {
            functionSource = .new
            functionChoice = functions.first.map(Self.key) ?? ""
        }
        newFunctionName = table.name + "_trigger_fn"
        setBody(isPostgres ? TriggerDDL.functionTemplate(for: trigger.timing, events: trigger.events) : trigger.statement)
        editorError = nil
        editor = .edit(trigger)
    }

    private func setBody(_ text: String) {
        initialBody = text
        bodyText = text
    }

    static func key(_ ref: TableRef) -> String { ref.schema + "." + ref.name }

    var chosenFunction: TableRef? { functions.first { Self.key($0) == functionChoice } }

    // MARK: Plan

    var spec: TriggerSpec {
        let orderedEvents = TriggerEvent.allCases.filter { events.contains($0) }
        if isPostgres {
            let body: TriggerSpec.Body = functionSource == .existing
                ? .existingFunction(chosenFunction ?? TableRef(schema: table.schema, name: ""))
                : .newFunction(TableRef(schema: table.schema, name: newFunctionName), source: bodyText)
            return TriggerSpec(name: name, timing: timing, events: orderedEvents, forEachRow: forEachRow,
                               whenCondition: whenCondition, body: body)
        }
        return TriggerSpec(name: name, timing: timing, events: [mysqlEvent], forEachRow: true, body: .statements(bodyText))
    }

    var strategy: TriggerDDL.ReplaceStrategy {
        workspace?.serverInfo.map(TriggerDDL.replaceStrategy(for:)) ?? .dropAndCreate
    }

    enum PlanState {
        case ready([String])
        case invalid(String)
    }

    var plan: PlanState {
        do {
            if let original {
                return .ready(try TriggerDDL.replace(original: original, with: spec, strategy: strategy, dialect: dialect))
            }
            return .ready(try TriggerDDL.create(spec, on: table, dialect: dialect))
        } catch let error as TriggerError {
            return .invalid(error.message)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// Plain-English note about how an edit is carried out.
    var editExplanation: String? {
        guard let original, case .ready(let statements) = plan else { return nil }
        let drops = statements.contains { $0.hasPrefix("DROP TRIGGER") }
        if !drops { return "The trigger is replaced in one statement (CREATE OR REPLACE TRIGGER), so it is never missing." }
        let target = isPostgres ? "PostgreSQL before 14 has" : (workspace?.profile.engine == .mariadb ? "This MariaDB version has" : "MySQL has")
        return "\(target) no way to change a trigger in place, so “\(original.name)” is dropped and created again. If the new definition is rejected, Querywell puts the original back."
    }

    // MARK: Actions

    /// Creates or replaces the trigger; true when the sheet can close.
    func save() async -> Bool {
        guard case .ready(let statements) = plan, let workspace, let session = workspace.live?.session, !isRunning else { return false }
        editorError = nil
        let inspector = workspace.browser.inspector ?? SchemaInspectorFactory.inspector(for: session)
        let original = self.original
        // What to put back if the new definition is refused after the old trigger was dropped.
        var restore: String?
        if let original, statements.contains(where: { $0.hasPrefix("DROP TRIGGER") }),
           let text = try? await inspector.triggerDefinition(original), !text.isEmpty {
            restore = TriggerDDL.restoreStatement(definition: text)
        }
        guard await workspace.gate.authorize(
            statements: statements, escalateToDestructive: original != nil, database: table.schema,
            actionTitle: original == nil ? "Create trigger" : "Save trigger")
        else {
            if let reason = workspace.gate.lastBlockedReason { editorError = reason }
            return false
        }
        isRunning = true
        defer { isRunning = false }
        var dropped = false
        for sql in statements {
            do {
                _ = try await session.execute(sql)
                if sql.hasPrefix("DROP TRIGGER") { dropped = true }
            } catch {
                var message = SchemaBrowserModel.message(error)
                if dropped, let restore {
                    do {
                        _ = try await session.execute(restore)
                        message += " The original trigger was restored."
                    } catch {
                        message += " Restoring the original failed too (\(SchemaBrowserModel.message(error))); its definition is in the SQL above."
                    }
                }
                editorError = message
                Announce.post("Trigger not saved. \(message)", important: true)
                await load()
                return false
            }
        }
        let verb = original == nil ? "created" : "saved"
        setStatus("Trigger \(name) \(verb).", isError: false)
        await load()
        return true
    }

    func drop(_ trigger: TriggerInfo) async {
        guard let workspace, let session = workspace.live?.session, !isRunning else { return }
        let sql = TriggerDDL.drop(trigger, dialect: dialect)
        guard await workspace.gate.authorize(
            statements: [sql], escalateToDestructive: true, database: table.schema, actionTitle: "Drop trigger")
        else {
            if let reason = workspace.gate.lastBlockedReason { setStatus(reason, isError: true) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await session.execute(sql)
            setStatus("Trigger \(trigger.name) dropped.", isError: false)
        } catch {
            setStatus(SchemaBrowserModel.message(error), isError: true)
        }
        await load()
    }

    /// SHOW CREATE TRIGGER / pg_get_triggerdef (plus the function's source on PostgreSQL).
    func showDefinition(_ trigger: TriggerInfo) async {
        guard let workspace, let session = workspace.live?.session else { return }
        let inspector = workspace.browser.inspector ?? SchemaInspectorFactory.inspector(for: session)
        do {
            var text = try await inspector.triggerDefinition(trigger)
            if let function = trigger.function, let source = try await inspector.functionDefinition(function) {
                text += ";\n\n" + source
            }
            definition = DefinitionSheet(title: trigger.name, text: text)
        } catch {
            setStatus(SchemaBrowserModel.message(error), isError: true)
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        status = Status(message: message, isError: isError)
        Announce.post(message, important: isError)
    }
}
