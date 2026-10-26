import Foundation
import Testing

@testable import QuerywellCore

private let healthIntegrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

@Suite("Health and Doctor against real servers", .serialized, .enabled(if: healthIntegrationEnabled))
struct HealthIntegrationTests {
    @Test("collector reads settings, status and statistics; the page and the Doctor evaluate", arguments: DBTarget.all)
    func collectAndEvaluate(_ target: DBTarget) async throws {
        let session = try await target.connectPrivileged()
        let facts = await HealthCollector().collect(session: session)
        #expect(facts.engine == target.detectedEngine)
        #expect(facts.major > 0)
        #expect(facts.variable("max_connections") != nil)
        #expect((facts.uptimeSeconds ?? 0) > 0)
        if target.isPostgres {
            #expect(facts.variable("shared_buffers")?.hasSuffix("MB") == true || facts.variable("shared_buffers")?.hasSuffix("GB") == true)
            #expect(facts.contexts["shared_buffers"] == "postmaster")
            #expect(facts.activeConnections != nil)
            #expect(facts.postgresStats != nil)
            #expect(facts.deadTupleTables != nil)
            #expect(facts.unusedIndexes != nil)
            #expect(facts.tablesWithoutPrimaryKey != nil)
            #expect(facts.largestTables != nil)
        } else {
            #expect(facts.statusInt("threads_connected") != nil)
            #expect(facts.bytes("innodb_buffer_pool_size") != nil)
            #expect(facts.dataBytes != nil && facts.innodbBytes != nil)
            #expect(facts.tablesWithoutPrimaryKey != nil)
            #expect(facts.nonInnoDBTables != nil)
        }
        #expect(facts.unavailable.isEmpty, "unexpected unavailable sections: \(facts.unavailable)")

        let page = HealthEvaluator().evaluate(facts)
        #expect(page.groups.flatMap(\.metrics).contains { $0.id == "connections" && $0.status != .unavailable })
        let report = DoctorEvaluator().evaluate(facts, inputs: DoctorInputs(serverRAMBytes: 8 * GiBytes))
        #expect(!report.findings.isEmpty)
        for finding in report.recommendations {
            // Every recommendation must produce SQL the dialect accepts syntactically.
            let change = try #require(finding.change())
            _ = try SettingSQL.statements(for: change, engine: target.detectedEngine)
        }
        await session.close()
    }

    @Test("a limited account gets Not available for what it cannot read instead of an error", arguments: DBTarget.all)
    func limitedAccount(_ target: DBTarget) async throws {
        // The plain test role: whatever it may not read must land in `unavailable`, never throw.
        let session = try await target.connect()
        let facts = await HealthCollector().collect(session: session)
        let page = HealthEvaluator().evaluate(facts)
        #expect(!page.groups.isEmpty)
        for (section, reason) in facts.unavailable { #expect(!reason.isEmpty, "\(section)") }
        await session.close()
    }

    @Test("apply then revert round-trips through the guard path and restores the server", arguments: DBTarget.all)
    func applyAndRevert(_ target: DBTarget) async throws {
        let session = try await target.connectPrivileged()
        let engine = target.detectedEngine
        let variable = target.isPostgres ? "log_min_duration_statement" : "long_query_time"
        let newValue = target.isPostgres ? "5000ms" : "7.5"
        let context = GuardContext(isProduction: false, isReadOnly: false, databaseName: nil, connectionName: "test", dialect: SQLDialect(engine))
        let runner = SettingApplier.makeRunner(context: context, safety: AppSettings.Safety())

        let before = await HealthCollector().collect(session: session)
        let original = try #require(before.variable(variable))
        let scope: SettingScope = target.isPostgres ? .alterSystem : .runtime  // never persist on shared servers
        let change = SettingChange(variable: variable, value: newValue, currentValue: original,
                                   currentIsDefault: before.sources[variable] == "default", scope: scope)

        let plan = try SettingApplier.plan([change], engine: engine)
        guard case .ready(let script) = runner.prepare(script: plan.script) else { Issue.record("not runnable"); return }
        let applied = await SettingApplier.run(plan, prepared: script, runner: runner, on: session)
        var restored = false
        do {
            let revision = try #require(applied.first)
            #expect(revision.succeeded, "\(revision.errorMessage ?? "")")
            if target.isPostgres { try await Task.sleep(for: .milliseconds(500)) }  // pg_reload_conf is asynchronous
            let during = await HealthCollector().collect(session: session)
            #expect(SettingValueComparison.equivalent(during.variable(variable) ?? "", newValue))

            let drift = DriftChecker.drift(revisions: applied, current: during.variables)
            #expect(drift.isEmpty)

            let revert = try RevertPlanner.change(reverting: revision, current: during.variables, sources: during.sources, engine: engine)
            let revertPlan = try SettingApplier.plan([revert], engine: engine, origin: .revert, revertedRevisionID: revision.id)
            guard case .ready(let revertScript) = runner.prepare(script: revertPlan.script) else { Issue.record("revert not runnable"); return }
            let reverted = await SettingApplier.run(revertPlan, prepared: revertScript, runner: runner, on: session)
            restored = reverted.first?.succeeded == true
            #expect(restored)
            if target.isPostgres { try await Task.sleep(for: .milliseconds(500)) }
            let after = await HealthCollector().collect(session: session)
            #expect(SettingValueComparison.equivalent(after.variable(variable) ?? "", original))
        } catch {
            if !restored { await Self.bestEffortRestore(session: session, engine: engine, variable: variable, original: original) }
            await session.close()
            throw error
        }
        if !restored { await Self.bestEffortRestore(session: session, engine: engine, variable: variable, original: original) }
        await session.close()
    }

    private static func bestEffortRestore(session: any DatabaseSession, engine: DatabaseEngine, variable: String, original: String) async {
        if engine == .postgresql {
            _ = try? await session.execute("ALTER SYSTEM RESET \(variable)")
            _ = try? await session.execute("SELECT pg_reload_conf()")
        } else if let statements = try? SettingSQL.statements(for: SettingChange(variable: variable, value: original, scope: .runtime), engine: engine) {
            for s in statements { _ = try? await session.execute(s) }
        }
    }

    @Test("a read-only account gets a clear privilege error when applying", arguments: DBTarget.all)
    func privilegeError(_ target: DBTarget) async throws {
        let session = try await target.connect()  // unprivileged test role
        let engine = target.detectedEngine
        let facts = await HealthCollector().collect(session: session)
        let variable = target.isPostgres ? "log_min_duration_statement" : "long_query_time"
        let current = try #require(facts.variable(variable))
        let scope: SettingScope = target.isPostgres ? .alterSystem : .runtime
        let context = GuardContext(isProduction: false, isReadOnly: false, databaseName: nil, connectionName: "test", dialect: SQLDialect(engine))
        let runner = SettingApplier.makeRunner(context: context, safety: AppSettings.Safety())
        let change = SettingChange(variable: variable, value: current, currentValue: current, scope: scope)
        let plan = try SettingApplier.plan([change], engine: engine)
        guard case .ready(let script) = runner.prepare(script: plan.script) else { Issue.record("not runnable"); return }
        let revisions = await SettingApplier.run(plan, prepared: script, runner: runner, on: session)
        // The test role may or may not be privileged; if it is not, the revision is a recorded failure with an explanation.
        if let r = revisions.first, !r.succeeded {
            #expect(r.errorMessage?.contains(variable) == true)
        }
        await session.close()
    }
}
