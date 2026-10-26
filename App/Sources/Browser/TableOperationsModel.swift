import Foundation
import Observation
import QuerywellCore

/// State and logic behind a table tab's Operations mode: prefilled option forms, the SQL each section
/// would run (generated in Core), and running it through the write gate. The view only renders this.
@MainActor @Observable
final class TableOperationsModel {
    enum Section: String, Hashable {
        case move, options, copy, maintenance, delete
    }

    /// What a section's form currently produces.
    enum PlanState: Equatable {
        case ready(AlterationPlan)
        /// Nothing differs from the table's current state.
        case unchanged
        case invalid(String)

        var plan: AlterationPlan? { if case .ready(let p) = self { p } else { nil } }
    }

    /// Outcome line under a section.
    struct Status: Equatable {
        var message: String
        var isError: Bool
    }

    /// A maintenance command's result set (CHECK / ANALYZE / CHECKSUM output rows).
    struct MaintenanceOutput: Equatable {
        var sql: String
        var columns: [String]
        var rows: [[String]]
        var duration: Duration
    }

    // MARK: Environment

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
    var hasPendingEdits: Bool { owner?.hasPendingChanges ?? false }
    var info: TableInfo? { owner?.structure?.info }
    var isTable: Bool { (info?.kind ?? .table) == .table }
    /// Databases (MySQL) / schemas (PostgreSQL) the table can move or be copied to.
    var schemas: [String] {
        let known = workspace?.browser.schemas ?? []
        return known.contains(table.schema) ? known : [table.schema] + known
    }

    // MARK: Loaded metadata

    private(set) var current: TableOptions?
    private(set) var engines: [String] = []
    private(set) var collations: [CollationInfo] = []
    private(set) var loadError: String?
    private(set) var isLoading = false
    @ObservationIgnored private var loadedFor: TableRef?

    static let rowFormats = ["DEFAULT", "DYNAMIC", "FIXED", "COMPRESSED", "REDUNDANT", "COMPACT"]

    // MARK: Forms

    // Move / rename
    var targetSchema = ""
    var targetName = ""
    // Table options
    var comment = ""
    var engine = ""
    var collation = ""
    var convertColumns = false
    var autoIncrement = ""
    var rowFormat = ""
    var tablespace = ""
    // Copy
    var copySchema = ""
    var copyName = ""
    var copyMode: CopyMode = .structureAndData
    var dropCopyTarget = false
    var keepAutoIncrement = false
    var addConstraints = false
    var switchToCopy = true
    // Maintenance
    var maintenanceCommand: TableMaintenanceCommand = .analyze

    // MARK: Results

    private(set) var statuses: [Section: Status] = [:]
    private(set) var running: Section?
    private(set) var maintenanceOutput: MaintenanceOutput?

    // MARK: Loading

    /// Reads the current options and prefills every form. Safe to call again after a change.
    func load(force: Bool = false) async {
        guard let owner, let workspace else { return }
        let ref = owner.table
        if !force, loadedFor == ref, current != nil { return }
        guard let session = workspace.live?.session else { loadError = "Not connected."; return }
        let inspector = workspace.browser.inspector ?? SchemaInspectorFactory.inspector(for: session)
        isLoading = true
        defer { isLoading = false }
        do {
            let options = try await inspector.tableOptions(of: ref)
            if engines.isEmpty, let found = try? await inspector.availableEngines() { engines = found }
            if collations.isEmpty, let found = try? await inspector.availableCollations() { collations = found }
            guard ref == owner.table else { return }  // the tab moved on while we were reading
            current = options
            loadedFor = ref
            loadError = nil
            prefill(from: options, ref: ref)
        } catch {
            loadError = SchemaBrowserModel.message(error)
        }
    }

    private func prefill(from options: TableOptions, ref: TableRef) {
        targetSchema = ref.schema
        targetName = ref.name
        comment = options.comment
        engine = options.engine ?? ""
        collation = options.collation ?? ""
        convertColumns = false
        autoIncrement = options.autoIncrement.map(String.init) ?? ""
        rowFormat = (options.rowFormat ?? "").uppercased()
        tablespace = options.tablespace ?? ""
        copySchema = ref.schema
        copyName = ref.name + "_copy"
        keepAutoIncrement = false
    }

    // MARK: Collation lists

    var characterSets: [String] {
        Set(collations.map(\.characterSet)).sorted { a, b in a == "utf8mb4" ? true : (b == "utf8mb4" ? false : a < b) }
    }

    var collationNames: [String] {
        var names = collations.map(\.name).sorted()
        if !collation.isEmpty, !names.contains(collation) { names.insert(collation, at: 0) }
        return names
    }

    // MARK: Plans

    var movePlan: PlanState {
        let target = TableRef(schema: targetSchema, name: targetName)
        do {
            if target.schema == table.schema { return .ready(try TableAlterations.rename(table, to: target.name, dialect: dialect)) }
            return .ready(try TableAlterations.move(table, to: target, dialect: dialect))
        } catch { return Self.state(for: error) }
    }

    var optionsPlan: PlanState {
        guard let current else { return .invalid("Reading the current options…") }
        var changes = TableOptionChanges(comment: comment)
        if isPostgres {
            changes.autoIncrement = Self.number(autoIncrement)
            if !tablespace.isEmpty { changes.tablespace = tablespace }
            if !autoIncrement.isEmpty, Self.number(autoIncrement) == nil { return .invalid("The sequence value must be a whole number.") }
        } else {
            changes.engine = engine.isEmpty ? nil : engine
            changes.collation = collation.isEmpty ? nil : collation
            changes.convertColumns = convertColumns
            changes.rowFormat = rowFormat.isEmpty ? nil : rowFormat
            if !autoIncrement.isEmpty {
                guard let n = Self.number(autoIncrement) else { return .invalid("AUTO_INCREMENT must be a whole number.") }
                changes.autoIncrement = n
            }
        }
        do { return .ready(try TableAlterations.options(table, current: current, changes: changes, dialect: dialect)) }
        catch { return Self.state(for: error) }
    }

    var copyPlan: PlanState {
        guard let structure = owner?.structure else { return .invalid("Reading the table structure…") }
        let options = CopyOptions(
            mode: copyMode, dropTargetFirst: dropCopyTarget, keepAutoIncrement: keepAutoIncrement, addConstraints: addConstraints)
        do {
            return .ready(try TableAlterations.copy(
                structure, to: TableRef(schema: copySchema, name: copyName), options: options,
                autoIncrement: current?.autoIncrement, dialect: dialect))
        } catch { return Self.state(for: error) }
    }

    var availableMaintenance: [TableMaintenanceCommand] {
        TableAlterations.availableMaintenance(dialect: dialect, storageEngine: current?.engine ?? info?.engine)
    }

    var maintenanceSQL: String? { try? TableAlterations.maintenance(maintenanceCommand, on: table, dialect: dialect) }
    var truncateSQL: String { TableOperations.truncate([TableInfo(ref: table, kind: .table)], dialect: dialect).first ?? "" }
    var deleteSQL: String { TableAlterations.deleteAllRows(table, dialect: dialect) }
    var dropSQL: String { TableOperations.drop([TableInfo(ref: table, kind: .table)], dialect: dialect).first ?? "" }

    private static func state(for error: any Error) -> PlanState {
        if let e = error as? TableAlterationError {
            return e == .noChange ? .unchanged : .invalid(e.message)
        }
        return .invalid(error.localizedDescription)
    }

    private static func number(_ text: String) -> Int64? {
        Int64(text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Running

    /// Authorizes through the write gate, then runs each statement; stops at the first failure.
    /// - Returns: true when every statement ran.
    private func execute(_ statements: [String], section: Section, title: String, destructive: Bool) async -> Bool {
        guard let workspace, let session = workspace.live?.session, running == nil else { return false }
        statuses[section] = nil
        guard await workspace.gate.authorize(
            statements: statements, escalateToDestructive: destructive, database: table.schema, actionTitle: title)
        else {
            if let reason = workspace.gate.lastBlockedReason { statuses[section] = Status(message: reason, isError: true) }
            return false
        }
        running = section
        defer { running = nil }
        var ran = 0
        for sql in statements {
            do {
                _ = try await session.execute(sql)
                ran += 1
            } catch {
                let note = ran > 0 ? " \(ran) earlier statement\(ran == 1 ? "" : "s") already ran." : ""
                fail(section, "\(SchemaBrowserModel.message(error))\(note)")
                return false
            }
        }
        return true
    }

    private func succeed(_ section: Section, _ message: String) {
        statuses[section] = Status(message: message, isError: false)
        Announce.post(message)
    }

    private func fail(_ section: Section, _ message: String) {
        statuses[section] = Status(message: message, isError: true)
        Announce.post(message, important: true)
    }

    /// Rename / move: the open tab follows the table.
    func applyMove() async {
        guard let plan = movePlan.plan, let workspace else { return }
        let old = table
        let new = TableRef(schema: targetSchema, name: targetName)
        guard await execute(plan.statements, section: .move, title: old.schema == new.schema ? "Rename" : "Move", destructive: true) else { return }
        succeed(.move, "Table is now \(new.schema).\(new.name).")
        current = nil
        workspace.tableRelocated(from: old, to: new)
        await load(force: true)
    }

    func applyOptions() async {
        guard let plan = optionsPlan.plan, let workspace else { return }
        guard await execute(plan.statements, section: .options, title: "Apply", destructive: true) else { return }
        succeed(.options, "Table options updated.")
        owner?.invalidateStructure()
        owner?.reload()
        workspace.browser.reloadCurrent()
        await load(force: true)
    }

    func applyCopy() async {
        guard let plan = copyPlan.plan, let workspace else { return }
        let copy = TableRef(schema: copySchema, name: copyName)
        guard await execute(plan.statements, section: .copy, title: "Copy", destructive: dropCopyTarget) else { return }
        succeed(.copy, "Copied to \(copy.schema).\(copy.name).")
        workspace.refreshSchema()
        if switchToCopy { workspace.openTable(copy) }
    }

    func runMaintenance() async {
        guard let sql = maintenanceSQL, let workspace, let session = workspace.live?.session, running == nil else { return }
        statuses[.maintenance] = nil
        guard await workspace.gate.authorize(
            statements: [sql], escalateToDestructive: maintenanceCommand == .vacuumFull, database: table.schema,
            actionTitle: maintenanceCommand.title)
        else {
            if let reason = workspace.gate.lastBlockedReason { statuses[.maintenance] = Status(message: reason, isError: true) }
            return
        }
        running = .maintenance
        defer { running = nil }
        do {
            let result = try await session.execute(sql)
            maintenanceOutput = MaintenanceOutput(
                sql: sql, columns: result.columns.map(\.name),
                rows: result.rows.map { $0.map { Self.display($0) } }, duration: result.duration)
            let problems = maintenanceOutput.map(Self.problemCount) ?? 0
            if problems > 0 {
                fail(.maintenance, "\(maintenanceCommand.title) reported \(problems) problem\(problems == 1 ? "" : "s").")
            } else {
                succeed(.maintenance, "\(maintenanceCommand.title) finished in \(LatencyFormatter.string(for: result.duration)).")
            }
            if maintenanceCommand == .analyze || maintenanceCommand == .optimize || maintenanceCommand == .vacuum
                || maintenanceCommand == .vacuumFull {
                owner?.invalidateStructure()
                await load(force: true)
            }
        } catch {
            maintenanceOutput = nil
            fail(.maintenance, SchemaBrowserModel.message(error))
        }
    }

    /// Rows whose `Msg_type` is `error` or `warning`.
    static func problemCount(_ output: MaintenanceOutput) -> Int {
        guard let index = output.columns.firstIndex(where: { $0.caseInsensitiveCompare("Msg_type") == .orderedSame }) else { return 0 }
        return output.rows.filter { $0.indices.contains(index) && ["error", "warning"].contains($0[index].lowercased()) }.count
    }

    private static func display(_ value: DatabaseValue) -> String {
        switch value {
        case .null: "NULL"
        case .text(let s): s
        case .bytes(let d): String(data: d, encoding: .utf8) ?? "\(d.count) bytes"
        case .integer(let i): String(i)
        case .unsignedInteger(let u): String(u)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        }
    }

    /// Empty (TRUNCATE) and Drop reuse the sidebar's guarded paths (typed confirmation on production).
    func truncate() async {
        guard let workspace else { return }
        statuses[.delete] = nil
        let outcome = await workspace.truncate([TableInfo(ref: table, kind: .table)])
        if let failure = outcome.failure { fail(.delete, failure.message) }
        else if !outcome.declined {
            succeed(.delete, "Table emptied.")
            await load(force: true)
        } else if let reason = workspace.gate.lastBlockedReason { fail(.delete, reason) }
    }

    func deleteAllRows() async {
        guard let owner else { return }
        guard await execute([deleteSQL], section: .delete, title: "Delete all rows", destructive: true) else { return }
        succeed(.delete, "All rows deleted.")
        owner.discardAll()
        owner.reload()
        workspace?.browser.reloadCurrent()
    }

    /// The tab closes when the drop succeeds, so only failures are reported here.
    func drop() async {
        guard let workspace else { return }
        statuses[.delete] = nil
        let outcome = await workspace.drop([TableInfo(ref: table, kind: .table)])
        if let failure = outcome.failure { fail(.delete, failure.message) }
        else if outcome.declined, let reason = workspace.gate.lastBlockedReason { fail(.delete, reason) }
    }
}
