import Foundation
import Observation
import QuerywellCore

/// State and logic behind the "Table Operations" sheet: choose an operation for the selected tables,
/// see the exact plan, run it through the write gate with per-table progress.
@MainActor @Observable
final class BatchOperationsModel {
    enum Operation: String, CaseIterable, Identifiable {
        case engine = "Change storage engine"
        case convert = "Convert charset & collation"
        var id: String { rawValue }
    }

    enum StepStatus: Equatable {
        case pending
        case running
        case done(Duration)
        case failed(String)
        case skipped(String)
        case notRun(String)
    }

    enum RunState: Equatable {
        case idle
        case running
        case finished(MaintenanceReport)
    }

    let schema: String
    let tables: [TableInfo]
    private let server: ServerInfo

    var operation: Operation = .engine { didSet { recompute() } }
    var engine = "InnoDB" { didSet { recompute() } }
    var charset = "utf8mb4" {
        didSet {
            guard charset != oldValue else { return }
            if !collationsForCharset.contains(where: { $0.name == collation }) { collation = Self.defaultCollation(for: charset, in: collations) }
            recompute()
        }
    }
    var collation = "" { didSet { recompute() } }
    var alsoSetDatabaseDefault = false { didSet { recompute() } }
    var stopOnError = true
    /// Tables the user wants changed (checked rows).
    var included: Set<TableRef> { didSet { recompute() } }

    private(set) var engines: [String] = []
    private(set) var collations: [CollationInfo] = []
    private(set) var structures: [TableRef: TableStructure] = [:]
    private(set) var isLoadingMetadata = false
    private(set) var plan: MaintenancePlan?
    /// Skip reasons for every table, whether checked or not ("Already InnoDB").
    private(set) var skipReasons: [TableRef: String] = [:]
    private(set) var planError: String?
    private(set) var statuses: [Int: StepStatus] = [:]
    private(set) var runState: RunState = .idle {
        didSet {
            if case .finished = runState { Announce.post("Batch operation finished.") }
            else if runState == .running, oldValue != .running { Announce.post("Batch operation started.") }
        }
    }
    private(set) var authorizationDeclined = false

    @ObservationIgnored private let inspector: (any SchemaInspector)?
    @ObservationIgnored private let session: (any DatabaseSession)?
    @ObservationIgnored private let gate: WriteGate?
    @ObservationIgnored private var runner: MaintenanceRunner?
    @ObservationIgnored var onFinished: @MainActor () -> Void = {}

    init(schema: String, tables: [TableInfo], server: ServerInfo, inspector: (any SchemaInspector)?,
         session: (any DatabaseSession)?, gate: WriteGate?) {
        self.schema = schema
        self.tables = tables
        self.server = server
        self.inspector = inspector
        self.session = session
        self.gate = gate
        self.included = Set(tables.map(\.ref))
        recompute()
    }

    /// Why the operations aren't available on this connection (nil when they are).
    static func unsupportedReason(for engine: DatabaseEngine) -> String? {
        engine == .postgresql ? "Storage engines and table character sets are MySQL/MariaDB features; PostgreSQL tables can't be changed this way." : nil
    }

    // MARK: Metadata

    var characterSets: [String] {
        let names = Set(collations.map(\.characterSet))
        return names.sorted { a, b in
            if a == "utf8mb4" { return true }
            if b == "utf8mb4" { return false }
            return a < b
        }
    }

    var collationsForCharset: [CollationInfo] {
        collations.filter { $0.characterSet == charset }.sorted { $0.name < $1.name }
    }

    static func defaultCollation(for charset: String, in all: [CollationInfo]) -> String {
        let mine = all.filter { $0.characterSet == charset }
        return mine.first(where: \.isDefault)?.name ?? mine.map(\.name).sorted().first ?? ""
    }

    func loadMetadata() async {
        guard !isLoadingMetadata, let inspector else { return }
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        if let found = try? await inspector.availableEngines(), !found.isEmpty {
            engines = found
            if !found.contains(engine) { engine = found.first(where: { $0.caseInsensitiveCompare("InnoDB") == .orderedSame }) ?? found[0] }
        }
        if let found = try? await inspector.availableCollations(), !found.isEmpty {
            collations = found
            if !characterSets.contains(charset) { charset = characterSets.first ?? charset }
            collation = Self.defaultCollation(for: charset, in: found)
        }
        recompute()
        // Structures drive the FULLTEXT / foreign-key / index-length warnings; read them in the background.
        for info in tables.prefix(150) where info.kind == .table {
            guard let loaded = try? await inspector.structure(of: info.ref) else { continue }
            structures[info.ref] = loaded
        }
        recompute()
    }

    // MARK: Plan

    private var change: MaintenanceChange {
        switch operation {
        case .engine: .engine(engine)
        case .convert: .convert(charset: charset, collation: collation)
        }
    }

    private var isReady: Bool {
        switch operation {
        case .engine: !engine.isEmpty
        case .convert: !charset.isEmpty && !collation.isEmpty
        }
    }

    func recompute() {
        guard runState == .idle, isReady else { return }
        planError = nil
        do {
            let all = try TableMaintenancePlanner.plan(tables: tables, structures: structures, change: change, server: server)
            skipReasons = Dictionary(uniqueKeysWithValues: all.steps.compactMap { step in
                step.table.flatMap { ref in step.skipped.map { (ref, $0) } }
            })
            let chosen = tables.filter { included.contains($0.ref) && skipReasons[$0.ref] == nil }
            plan = try TableMaintenancePlanner.plan(
                tables: chosen, structures: structures, change: change,
                alsoSetDatabaseDefault: operation == .convert && alsoSetDatabaseDefault, server: server)
        } catch {
            plan = nil
            planError = Self.describe(error)
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case MaintenanceError.unsupported(let m): m
        case MaintenanceError.invalidName(let n): "“\(n)” isn't a valid name."
        case MaintenanceError.collationDoesNotBelongToCharset(let c, let k): "Collation \(k) doesn't belong to character set \(c)."
        default: error.localizedDescription
        }
    }

    var statementCount: Int { plan?.statements.count ?? 0 }
    var previewSQL: String { (plan?.statements ?? []).map { $0 + ";" }.joined(separator: "\n") }
    var canRun: Bool { runState == .idle && statementCount > 0 && planError == nil }
    var isRunning: Bool { runState == .running }

    func toggle(_ ref: TableRef) {
        guard runState == .idle, skipReasons[ref] == nil else { return }
        if included.contains(ref) { included.remove(ref) } else { included.insert(ref) }
    }

    // MARK: Run

    func run() async {
        guard canRun, let plan, let session, let gate else { return }
        authorizationDeclined = false
        let verb = operation == .engine ? "Change engine" : "Convert"
        let allowed = await gate.authorize(
            statements: plan.statements, escalateToDestructive: true, database: schema,
            actionTitle: "\(verb) (\(plan.statements.count))")
        guard allowed else {
            authorizationDeclined = true
            return
        }
        runState = .running
        statuses = [:]
        for step in plan.steps { statuses[step.id] = step.skipped.map(StepStatus.skipped) ?? .pending }
        let runner = MaintenanceRunner(session: session)
        self.runner = runner
        let events = await runner.run(plan, stopOnError: stopOnError)
        for await event in events {
            switch event {
            case .started(let step): statuses[step.id] = .running
            case .finished(let step, let d): statuses[step.id] = .done(d)
            case .failed(let step, let message): statuses[step.id] = .failed(message)
            case .skipped(let step, let reason): statuses[step.id] = .skipped(reason)
            case .completed(let report):
                for entry in report.entries {
                    if case .notRun(let why) = entry.outcome {
                        statuses[entry.step.id] = .notRun(why == .cancelled ? "Cancelled" : "Not run after the error")
                    }
                }
                runState = .finished(report)
            }
        }
        self.runner = nil
        onFinished()
    }

    /// Stops after the table in flight; the rest are reported as not run.
    func cancel() {
        guard let runner else { return }
        Task { await runner.cancel() }
    }

    var completedStepCount: Int {
        statuses.values.filter { if case .pending = $0 { false } else if case .running = $0 { false } else { true } }.count
    }

    var totalStepCount: Int { plan?.steps.count ?? 0 }

    var summary: String? {
        guard case .finished(let r) = runState else { return nil }
        var parts: [String] = []
        if r.succeededCount > 0 { parts.append("\(r.succeededCount) changed") }
        if r.failedCount > 0 { parts.append("\(r.failedCount) failed") }
        if r.skippedCount > 0 { parts.append("\(r.skippedCount) skipped") }
        if r.notRunCount > 0 { parts.append("\(r.notRunCount) not run") }
        let took = LatencyFormatter.string(for: r.duration)
        return parts.joined(separator: " · ") + " · \(took)"
    }
}
