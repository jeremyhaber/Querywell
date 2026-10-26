import Foundation
import Observation
import QuerywellCore

/// State and intents behind the Database Health & Doctor tab. All logic lives in Core (`HealthCollector`,
/// `HealthEvaluator`, `DoctorEvaluator`, `SettingApplier`, `HealthStore`); this model wires it to the session and
/// the write gate. Every change to the server is prepared with `QueryRunner` and confirmed through `WriteGate`.
@MainActor @Observable
final class HealthTabModel {
    enum Segment: String, CaseIterable, Identifiable {
        case health = "Health"
        case doctor = "Doctor"
        case history = "History"
        var id: String { rawValue }
    }

    struct Banner: Equatable {
        var text: String
        var isError: Bool
    }

    let profile: ConnectionProfile
    var segment: Segment = .health
    private(set) var facts: ServerFacts?
    private(set) var snapshot: HealthSnapshot?
    private(set) var report: DoctorReport?
    /// Chronological (oldest first); the view shows them newest first.
    private(set) var revisions: [SettingRevision] = []
    private(set) var drift: [SettingDrift] = []
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var loadError: String?
    var banner: Banner?
    /// The server-RAM field (GiB, as typed).
    var ramText = ""
    /// Scope picked per rule id when more than one is offered.
    var scopeChoices: [String: SettingScope] = [:]
    /// Finding whose my.cnf / postgresql.conf snippet is shown.
    var snippetFor: String?
    var showsIgnored = false

    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var gate: WriteGate?
    @ObservationIgnored var store: HealthStore?
    @ObservationIgnored private var data = HealthConnectionData()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(profile: ConnectionProfile) {
        self.profile = profile
    }

    // MARK: Derived

    var inputs: DoctorInputs { DoctorInputs(serverRAMBytes: data.serverRAMBytes) }
    var ignoredIDs: Set<String> { Set(data.ignoredRuleIDs) }
    var engine: DatabaseEngine { facts?.engine ?? profile.engine }
    var revisionsNewestFirst: [SettingRevision] { revisions.reversed() }
    var isReadOnlyConnection: Bool { profile.effectiveReadOnly }

    func scope(for finding: DoctorFinding) -> SettingScope? {
        let chosen = scopeChoices[finding.ruleID]
        if let chosen, finding.scopes.contains(chosen) { return chosen }
        return finding.scopes.first
    }

    func isDrifted(_ variable: String) -> SettingDrift? { drift.first { $0.variable.lowercased() == variable.lowercased() } }

    /// The revision a "Revert" button on `revision` would undo has a usable old value and has not been undone yet.
    func canRevert(_ revision: SettingRevision) -> Bool {
        revision.succeeded && revision.oldValue != nil && !isApplying && facts != nil
    }

    func snippet(for finding: DoctorFinding) -> String? {
        guard let change = finding.change(scope: scope(for: finding)) ?? finding.change() else { return nil }
        return SettingSQL.configSnippet(for: [change], engine: engine)
    }

    // MARK: Loading

    func startIfNeeded() async {
        if let store { data = await store.data(for: profile.id); revisions = data.revisions }
        ramText = data.serverRAMBytes.map(Self.gibText) ?? ""
        if facts == nil { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        guard let session = sessionProvider() else {
            loadError = "Not connected."
            return
        }
        isLoading = true
        loadError = nil
        let collected = await HealthCollector().collect(session: session)
        if let store { data = await store.data(for: profile.id); revisions = data.revisions }
        facts = collected
        recompute()
        isLoading = false
        Announce.post("Health refreshed. \(snapshot?.warningCount ?? 0) warnings, \(report?.recommendations.count ?? 0) recommendations.")
    }

    private func recompute() {
        guard let facts else { return }
        snapshot = HealthEvaluator().evaluate(facts)
        report = DoctorEvaluator().evaluate(facts, inputs: inputs, ignoredRuleIDs: ignoredIDs)
        drift = DriftChecker.drift(revisions: revisions, current: facts.variables)
    }

    // MARK: Doctor inputs

    /// Stores the entered RAM (GiB). Empty clears it; anything unparseable is rejected with a message.
    func commitRAM() async {
        let trimmed = ramText.trimmingCharacters(in: .whitespaces)
        var bytes: Int64?
        if !trimmed.isEmpty {
            guard let gib = Double(trimmed.replacingOccurrences(of: ",", with: ".")), gib >= 0.25, gib <= 16_384 else {
                banner = Banner(text: "Enter the server's RAM in GiB, for example 16.", isError: true)
                return
            }
            bytes = Int64(gib * Double(1 << 30))
        }
        do {
            try await store?.setServerRAM(bytes, for: profile.id)
            data.serverRAMBytes = bytes
            banner = nil
            recompute()
        } catch {
            banner = Banner(text: "Couldn't save the RAM value: \(error.localizedDescription)", isError: true)
        }
    }

    func setIgnored(_ finding: DoctorFinding, _ ignored: Bool) async {
        do {
            try await store?.setIgnored(finding.ruleID, ignored, for: profile.id)
            data.ignoredRuleIDs.removeAll { $0 == finding.ruleID }
            if ignored { data.ignoredRuleIDs.append(finding.ruleID) }
            recompute()
            Announce.post(ignored ? "Ignoring \(finding.title)." : "No longer ignoring \(finding.title).")
        } catch {
            banner = Banner(text: "Couldn't save: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Apply and revert

    func apply(_ finding: DoctorFinding) async {
        guard let change = finding.change(scope: scope(for: finding)) else { return }
        await execute([change], origin: .doctor, revertedID: nil, actionTitle: "Apply", subject: finding.title)
    }

    func revert(_ revision: SettingRevision) async {
        guard let facts else { return }
        do {
            let change = try RevertPlanner.change(reverting: revision, current: facts.variables, sources: facts.sources, engine: facts.engine)
            await execute([change], origin: .revert, revertedID: revision.id, actionTitle: "Revert", subject: revision.variable)
        } catch {
            banner = Banner(text: "This change can't be reverted: its previous value wasn't recorded.", isError: true)
        }
    }

    /// Everything from `revision` on goes back to how it was before.
    func revertAll(from revision: SettingRevision) async {
        guard let facts else { return }
        do {
            let changes = try RevertPlanner.changes(
                revertingFrom: revision, in: revisions, current: facts.variables, sources: facts.sources, engine: facts.engine)
            guard !changes.isEmpty else {
                banner = Banner(text: "Nothing to revert: those settings already have their earlier values.", isError: false)
                return
            }
            await execute(changes, origin: .revertAll, revertedID: nil, actionTitle: "Revert \(changes.count)", subject: "\(changes.count) settings")
        } catch {
            banner = Banner(text: "Couldn't work out what to revert.", isError: true)
        }
    }

    /// How many settings "Revert all to before this" would change right now.
    func revertAllCount(from revision: SettingRevision) -> Int {
        guard let facts else { return 0 }
        return (try? RevertPlanner.changes(revertingFrom: revision, in: revisions, current: facts.variables,
                                           sources: facts.sources, engine: facts.engine).count) ?? 0
    }

    private func execute(_ changes: [SettingChange], origin: RevisionOrigin, revertedID: UUID?, actionTitle: String, subject: String) async {
        guard !isApplying else { return }
        guard let session = sessionProvider(), let gate, let facts, let context = gate.contextProvider(nil) else {
            banner = Banner(text: "Not connected.", isError: true)
            return
        }
        let plan: SettingApplyPlan
        do {
            plan = try SettingApplier.plan(changes, engine: facts.engine, origin: origin, revertedRevisionID: revertedID)
        } catch {
            banner = Banner(text: "Couldn't build the SQL for this change.", isError: true)
            return
        }
        let runner = SettingApplier.makeRunner(context: context, safety: gate.settingsProvider())
        let prepared: PreparedScript
        switch runner.prepare(script: plan.script) {
        case .empty:
            return
        case .blocked(let reason):
            banner = Banner(text: reason, isError: true)
            await gate.reportBlocked(reason)
            return
        case .ready(let script):
            prepared = script
        case .needsConfirmation(let pending):
            guard await gate.confirm(pending.request, actionTitle: actionTitle) else { return }
            guard let script = pending.confirm(typed: pending.request.requiresTypedName ?? "") else { return }
            prepared = script
        }

        isApplying = true
        banner = nil
        let made = await SettingApplier.run(plan, prepared: prepared, runner: runner, on: session)
        do {
            try await store?.append(made, for: profile.id)
        } catch {
            banner = Banner(text: "The change ran but the history couldn't be saved: \(error.localizedDescription)", isError: true)
        }
        if let store { data = await store.data(for: profile.id); revisions = data.revisions } else { revisions += made }
        isApplying = false
        announce(made, subject: subject)
        // PostgreSQL applies a reload asynchronously; give it a moment before re-reading.
        if facts.isPostgres { try? await Task.sleep(for: .milliseconds(400)) }
        await refresh()
    }

    private func announce(_ made: [SettingRevision], subject: String) {
        let failed = made.filter { !$0.succeeded }
        if made.isEmpty {
            banner = Banner(text: "Nothing was changed.", isError: true)
        } else if let first = failed.first {
            let more = failed.count > 1 ? " (\(failed.count) of \(made.count) failed)" : ""
            banner = Banner(text: (first.errorMessage ?? "The server rejected the change.") + more, isError: true)
        } else {
            let restart = made.contains { $0.restartRequired } ? " A server restart is needed before it takes effect." : ""
            let persist = made.contains { $0.scope == .runtime } && engine != .postgresql
                ? " This lasts until the server restarts; add it to my.cnf to keep it." : ""
            banner = Banner(text: "Changed \(subject).\(restart)\(persist)", isError: false)
        }
        Announce.post(banner?.text ?? "", important: banner?.isError == true)
    }

    // MARK: Formatting

    static func gibText(_ bytes: Int64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        return gib == gib.rounded() ? String(Int(gib)) : String(format: "%.1f", gib)
    }
}
