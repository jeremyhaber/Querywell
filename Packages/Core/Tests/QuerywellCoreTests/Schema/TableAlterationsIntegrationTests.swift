import Foundation
import Testing

@testable import QuerywellCore

// Runs the generated SQL against the docker servers (skipped unless QUERYWELL_INTEGRATION=1).

@Suite("Table alterations integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct TableAlterationsIntegrationTests {
    private func columnsDDL(_ target: DBTarget) -> String {
        target.isPostgres ? "id serial PRIMARY KEY, name text NOT NULL DEFAULT ''" : "id int NOT NULL AUTO_INCREMENT PRIMARY KEY, name varchar(50) NOT NULL DEFAULT ''"
    }

    @Test(arguments: DBTarget.all)
    func optionsRoundTrip(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let t = f.ref("t")
            try await f.run("CREATE TABLE \(f.dialect.qualified(t)) (\(columnsDDL(target)))")
            try await f.run("INSERT INTO \(f.dialect.qualified(t)) (name) VALUES ('a'), ('b')")
            var options = try await f.inspector.tableOptions(of: t)
            #expect(options.comment == "")
            #expect(options.autoIncrement == 3)

            let changes = target.isPostgres
                ? TableOptionChanges(comment: "it's here", autoIncrement: 50)
                : TableOptionChanges(comment: "it's here", autoIncrement: 50, rowFormat: "COMPACT")
            let plan = try TableAlterations.options(t, current: options, changes: changes, dialect: f.dialect)
            for sql in plan.statements { try await f.run(sql) }
            options = try await f.inspector.tableOptions(of: t)
            #expect(options.comment == "it's here")
            #expect(options.autoIncrement == 50)
            if !target.isPostgres { #expect(options.rowFormat?.lowercased() == "compact") }
        }
    }

    @Test(arguments: DBTarget.all)
    func renameCopyAndMove(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let t = f.ref("t")
            try await f.run("CREATE TABLE \(f.dialect.qualified(t)) (\(columnsDDL(target)))")
            try await f.run("INSERT INTO \(f.dialect.qualified(t)) (name) VALUES ('a'), ('b')")

            let copy = f.ref("t_copy")
            let structure = try await f.inspector.structure(of: t)
            let plan = try TableAlterations.copy(structure, to: copy, options: CopyOptions(mode: .structureAndData), dialect: f.dialect)
            for sql in plan.statements { try await f.run(sql) }
            let count = try await f.session.execute("SELECT COUNT(*) AS n FROM \(f.dialect.qualified(copy))")
            #expect(count.records.first?.int("n") == 2)

            for sql in try TableAlterations.rename(copy, to: "t`2", dialect: f.dialect).statements { try await f.run(sql) }
            let names = try await f.inspector.listTables(schema: f.schema).map(\.ref.name)
            #expect(names.contains("t`2") && !names.contains("t_copy"))

            let otherSchema = f.schema + "_b"
            try await f.run(target.isPostgres ? "CREATE SCHEMA \(f.dialect.quoteIdentifier(otherSchema))" : "CREATE DATABASE \(f.dialect.quoteIdentifier(otherSchema))")
            let moved = TableRef(schema: otherSchema, name: "t`2")
            do {
                for sql in try TableAlterations.move(f.ref("t`2"), to: moved, dialect: f.dialect).statements { try await f.run(sql) }
                #expect(try await f.inspector.listTables(schema: otherSchema).map(\.ref.name) == ["t`2"])
            } catch {
                _ = try? await f.session.execute(target.isPostgres ? "DROP SCHEMA \(f.dialect.quoteIdentifier(otherSchema)) CASCADE" : "DROP DATABASE \(f.dialect.quoteIdentifier(otherSchema))")
                throw error
            }
            _ = try? await f.session.execute(target.isPostgres ? "DROP SCHEMA \(f.dialect.quoteIdentifier(otherSchema)) CASCADE" : "DROP DATABASE \(f.dialect.quoteIdentifier(otherSchema))")
        }
    }

    @Test(arguments: DBTarget.all)
    func maintenanceCommandsRun(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let t = f.ref("t")
            try await f.run("CREATE TABLE \(f.dialect.qualified(t)) (\(columnsDDL(target)))")
            let commands = TableAlterations.availableMaintenance(dialect: f.dialect, storageEngine: target.isPostgres ? nil : "InnoDB")
            for command in commands {
                let sql = try TableAlterations.maintenance(command, on: t, dialect: f.dialect)
                let result = try await f.session.execute(sql)
                if !target.isPostgres, command != .flush { #expect(!result.rows.isEmpty, "\(sql)") }
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func triggerLifecycle(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let t = f.ref("t")
            try await f.run("CREATE TABLE \(f.dialect.qualified(t)) (\(columnsDDL(target)), touched int NOT NULL DEFAULT 0)")
            let body: TriggerSpec.Body = target.isPostgres
                ? .newFunction(f.ref("t_touch"), source: "BEGIN\n  NEW.touched := 1;\n  RETURN NEW;\nEND;")
                : .statements("SET NEW.touched = 1")
            let spec = TriggerSpec(name: "t_bi", timing: .before, events: [.insert], body: body)
            for sql in try TriggerDDL.create(spec, on: t, dialect: f.dialect) { try await f.run(sql) }

            var triggers = try await f.inspector.triggers(on: t)
            #expect(triggers.map(\.name) == ["t_bi"])
            let trigger = try #require(triggers.first)
            #expect(trigger.timing == .before && trigger.events == [.insert])
            if target.isPostgres {
                #expect(trigger.function == f.ref("t_touch"))
                #expect(try await f.inspector.triggerFunctions(schema: f.schema).contains(f.ref("t_touch")))
                #expect(try await f.inspector.functionDefinition(f.ref("t_touch"))?.contains("NEW.touched") == true)
            } else {
                #expect(trigger.statement.contains("NEW.touched"))
            }
            #expect(try await f.inspector.triggerDefinition(trigger).localizedCaseInsensitiveContains("t_bi"))

            try await f.run("INSERT INTO \(f.dialect.qualified(t)) (name) VALUES ('x')")
            let row = try await f.session.execute("SELECT touched FROM \(f.dialect.qualified(t))")
            #expect(row.records.first?.int("touched") == 1)

            // Edit: AFTER UPDATE through the server's own replace strategy.
            let strategy = TriggerDDL.replaceStrategy(for: f.session.serverInfo)
            let edited = TriggerSpec(name: "t_bi", timing: .after, events: [.update], body: target.isPostgres ? .existingFunction(f.ref("t_touch")) : .statements("SET @qw_x = 1"))
            for sql in try TriggerDDL.replace(original: trigger, with: edited, strategy: strategy, dialect: f.dialect) { try await f.run(sql) }
            triggers = try await f.inspector.triggers(on: t)
            #expect(triggers.count == 1)
            #expect(triggers.first?.timing == .after && triggers.first?.events == [.update])

            try await f.run(TriggerDDL.drop(try #require(triggers.first), dialect: f.dialect))
            #expect(try await f.inspector.triggers(on: t).isEmpty)
        }
    }
}
