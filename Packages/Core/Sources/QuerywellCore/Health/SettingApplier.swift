import Foundation

/// The statements for a batch of setting changes, ready to go through the write guard.
public struct SettingApplyPlan: Sendable, Equatable {
    public var changes: [SettingChange]
    /// Statements per change (same order as `changes`).
    public var statementGroups: [[String]]
    public var engine: DatabaseEngine
    public var origin: RevisionOrigin
    /// The revision being undone, for a single revert.
    public var revertedRevisionID: UUID?

    public var statements: [String] { statementGroups.flatMap { $0 } }
    /// One script, which `QueryRunner.prepare(script:)` splits and classifies again.
    public var script: String { statements.map { $0 + ";" }.joined(separator: "\n") }
}

public enum SettingApplier {
    /// Builds the plan. A PostgreSQL revert to a built-in default becomes `ALTER SYSTEM RESET`.
    public static func plan(_ changes: [SettingChange], engine: DatabaseEngine, origin: RevisionOrigin = .doctor,
                            revertedRevisionID: UUID? = nil) throws -> SettingApplyPlan {
        var groups: [[String]] = []
        for change in changes {
            if engine == .postgresql, change.resetToDefault {
                groups.append(try SettingSQL.resetStatements(variable: change.variable))
            } else {
                groups.append(try SettingSQL.statements(for: change, engine: engine))
            }
        }
        return SettingApplyPlan(changes: changes, statementGroups: groups, engine: engine, origin: origin, revertedRevisionID: revertedRevisionID)
    }

    /// A runner that keeps going after a failing statement, so one rejected setting does not stop the rest.
    /// Every statement still passes `WriteGuard` (read-only connections, Production confirmation) via `prepare`.
    public static func makeRunner(context: GuardContext, safety: AppSettings.Safety) -> QueryRunner {
        QueryRunner(guardContext: context, safety: safety, options: QueryRunOptions(stopOnError: false))
    }

    /// Runs a prepared (guard-approved) script and turns the per-statement results into revisions.
    /// Nothing is recorded for statements that were skipped because the run was cancelled.
    public static func run(_ plan: SettingApplyPlan, prepared: PreparedScript, runner: QueryRunner,
                           on session: any DatabaseSession, date: Date = Date()) async -> [SettingRevision] {
        let result = await runner.run(prepared, on: session)
        var revisions: [SettingRevision] = []
        var cursor = 0
        for (index, change) in plan.changes.enumerated() {
            let group = plan.statementGroups[index]
            let slice = result.results.dropFirst(cursor).prefix(group.count)
            cursor += group.count
            guard slice.count == group.count else { continue }
            if slice.allSatisfy({ $0.outcome == .skipped }) { continue }
            // The first statement is the SET; a failed pg_reload_conf() after a successful ALTER SYSTEM still left the file written.
            let setResult = slice.first!
            var error: String?
            if case .error(let e) = setResult.outcome { error = describe(e, engine: plan.engine, variable: change.variable) }
            revisions.append(SettingRevision(
                date: date, variable: change.variable, oldValue: change.currentValue, newValue: change.value,
                scope: change.scope, statements: group, outcome: error == nil ? .succeeded : .failed, errorMessage: error,
                origin: plan.origin, revertedRevisionID: plan.revertedRevisionID, restartRequired: change.restartRequired,
                oldWasDefault: change.currentIsDefault))
        }
        return revisions
    }

    /// A message a person can act on, with privilege problems called out explicitly.
    public static func describe(_ error: DatabaseError, engine: DatabaseEngine, variable: String) -> String {
        let raw = QueryRunner.describe(error)
        let lower = raw.lowercased()
        if case .query(_, let code) = error {
            switch engine {
            case .postgresql:
                if code == "42501" || lower.contains("permission denied") || lower.contains("must be superuser") {
                    return "Your PostgreSQL role isn't allowed to change \(variable). ALTER SYSTEM needs a superuser, or a role granted ALTER SYSTEM on this parameter (PostgreSQL 15+). (\(raw))"
                }
                if code == "55P02" { return "\(variable) can't be changed while the server runs. Edit postgresql.conf and restart. (\(raw))" }
            case .mysql, .mariadb:
                if code == "1227" || lower.contains("super") || lower.contains("system_variables_admin") || lower.contains("access denied") {
                    return engine == .mariadb
                        ? "Your account needs the SUPER privilege to change \(variable). Ask an administrator to grant it, or change it in my.cnf. (\(raw))"
                        : "Your account needs the SUPER or SYSTEM_VARIABLES_ADMIN privilege (and PERSIST_RO_VARIABLES_ADMIN for read-only variables) to change \(variable). (\(raw))"
                }
                if code == "1238" || lower.contains("read only variable") {
                    return "\(variable) is read-only while the server runs. Set it in my.cnf and restart" + (engine == .mysql ? ", or use SET PERSIST_ONLY." : ".") + " (\(raw))"
                }
                if code == "1193" || lower.contains("unknown system variable") {
                    return "This server doesn't have a variable named \(variable). (\(raw))"
                }
            }
        }
        return raw
    }
}
