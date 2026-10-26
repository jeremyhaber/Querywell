import Foundation

// Trigger model and DDL for the table tab's Triggers mode. Listing lives in the inspectors; this file
// only builds statements (quoted through `SQLDialect`) and validates what the form can express.

public enum TriggerTiming: String, Sendable, CaseIterable, Hashable, Identifiable {
    case before = "BEFORE", after = "AFTER", insteadOf = "INSTEAD OF"
    public var id: String { rawValue }
}

public enum TriggerEvent: String, Sendable, CaseIterable, Hashable, Identifiable {
    case insert = "INSERT", update = "UPDATE", delete = "DELETE", truncate = "TRUNCATE"
    public var id: String { rawValue }
}

/// A trigger as the inspectors report it.
public struct TriggerInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var table: TableRef
    public var timing: TriggerTiming
    /// MySQL: exactly one. PostgreSQL: one or more (`INSERT OR UPDATE`).
    public var events: [TriggerEvent]
    public var forEachRow: Bool
    /// MySQL: the trigger body (`ACTION_STATEMENT`). PostgreSQL: `EXECUTE FUNCTION schema.fn()`.
    public var statement: String
    /// MySQL `DEFINER`.
    public var definer: String?
    /// PostgreSQL: the function the trigger calls.
    public var function: TableRef?
    /// PostgreSQL `WHEN (…)` condition.
    public var whenCondition: String?
    /// PostgreSQL: false when disabled (`tgenabled = 'D'`).
    public var isEnabled: Bool

    public var id: String { name }

    public init(name: String, table: TableRef, timing: TriggerTiming, events: [TriggerEvent], forEachRow: Bool = true,
                statement: String, definer: String? = nil, function: TableRef? = nil, whenCondition: String? = nil,
                isEnabled: Bool = true) {
        self.name = name
        self.table = table
        self.timing = timing
        self.events = events
        self.forEachRow = forEachRow
        self.statement = statement
        self.definer = definer
        self.function = function
        self.whenCondition = whenCondition
        self.isEnabled = isEnabled
    }

    /// "INSERT OR UPDATE"
    public var eventText: String { events.map(\.rawValue).joined(separator: " OR ") }
}

/// What the create / edit form expresses.
public struct TriggerSpec: Sendable, Hashable {
    public enum Body: Sendable, Hashable {
        /// MySQL / MariaDB: the statement or `BEGIN … END` block.
        case statements(String)
        /// PostgreSQL: call an existing trigger function.
        case existingFunction(TableRef)
        /// PostgreSQL: create (or replace) a `plpgsql` trigger function from this body, then use it.
        case newFunction(TableRef, source: String)
    }

    public var name: String
    public var timing: TriggerTiming
    public var events: [TriggerEvent]
    public var forEachRow: Bool
    public var whenCondition: String?
    public var body: Body

    public init(name: String, timing: TriggerTiming, events: [TriggerEvent], forEachRow: Bool = true,
                whenCondition: String? = nil, body: Body) {
        self.name = name
        self.timing = timing
        self.events = events
        self.forEachRow = forEachRow
        self.whenCondition = whenCondition
        self.body = body
    }
}

public enum TriggerError: Error, Sendable, Equatable {
    case invalid(String)
    public var message: String { if case .invalid(let m) = self { m } else { "" } }
}

public enum TriggerDDL {
    /// How an edit replaces an existing trigger.
    public enum ReplaceStrategy: Sendable, Hashable {
        /// One `CREATE OR REPLACE TRIGGER` (MariaDB 10.1+, PostgreSQL 14+): atomic.
        case createOrReplace
        /// `DROP TRIGGER`, then `CREATE TRIGGER`: if the create fails the trigger is gone (MySQL; PostgreSQL < 14).
        case dropAndCreate
    }

    public static func replaceStrategy(for server: ServerInfo) -> ReplaceStrategy {
        switch server.engine {
        case .mysql: .dropAndCreate
        case .mariadb: (server.major, server.minor) >= (10, 1) ? .createOrReplace : .dropAndCreate
        case .postgresql: server.major >= 14 ? .createOrReplace : .dropAndCreate
        }
    }

    // MARK: Create

    /// Statements that create the trigger (the function first on PostgreSQL when the body is new).
    /// - Parameter replacing: use `CREATE OR REPLACE TRIGGER` (see ``ReplaceStrategy``).
    public static func create(
        _ spec: TriggerSpec, on table: TableRef, replacing: Bool = false, dialect: SQLDialect
    ) throws -> [String] {
        try validate(spec, dialect: dialect)
        let create = replacing ? "CREATE OR REPLACE TRIGGER" : "CREATE TRIGGER"
        switch dialect.family {
        case .mysql:
            guard case .statements(let raw) = spec.body else { throw TriggerError.invalid("MySQL triggers contain statements, not a function.") }
            let body = cleanedBody(raw)
            return ["\(create) \(dialect.qualified(TableRef(schema: table.schema, name: spec.name))) \(spec.timing.rawValue) \(spec.events[0].rawValue) "
                + "ON \(dialect.qualified(table)) FOR EACH ROW \(body)"]
        case .postgres:
            var statements: [String] = []
            let function: TableRef
            switch spec.body {
            case .statements:
                throw TriggerError.invalid("PostgreSQL triggers call a function.")
            case .existingFunction(let ref):
                function = ref
            case .newFunction(let ref, let source):
                function = ref
                let tag = dollarTag(avoiding: source)
                statements.append(
                    "CREATE OR REPLACE FUNCTION \(dialect.qualified(ref))() RETURNS trigger LANGUAGE plpgsql AS \(tag)\n"
                        + source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\(tag)")
            }
            var sql = "\(create) \(dialect.quoteIdentifier(spec.name)) \(spec.timing.rawValue) \(spec.events.map(\.rawValue).joined(separator: " OR ")) "
            sql += "ON \(dialect.qualified(table)) FOR EACH \(spec.forEachRow ? "ROW" : "STATEMENT")"
            if let condition = spec.whenCondition?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty {
                sql += " WHEN (\(condition))"
            }
            sql += " EXECUTE FUNCTION \(dialect.qualified(function))()"
            statements.append(sql)
            return statements
        }
    }

    /// Statements that turn `original` into `spec`. A rename always drops the old name first.
    public static func replace(
        original: TriggerInfo, with spec: TriggerSpec, strategy: ReplaceStrategy, dialect: SQLDialect
    ) throws -> [String] {
        let renamed = spec.name != original.name
        if strategy == .createOrReplace, !renamed {
            return try create(spec, on: original.table, replacing: true, dialect: dialect)
        }
        let created = try create(spec, on: original.table, dialect: dialect)
        // Functions first (they don't depend on the old trigger), then swap the trigger itself.
        let functions = created.filter { $0.hasPrefix("CREATE OR REPLACE FUNCTION") }
        let triggers = created.filter { !$0.hasPrefix("CREATE OR REPLACE FUNCTION") }
        return functions + [drop(original, dialect: dialect)] + triggers
    }

    // MARK: Drop / inspect

    public static func drop(_ trigger: TriggerInfo, dialect: SQLDialect) -> String {
        switch dialect.family {
        case .mysql: "DROP TRIGGER \(dialect.qualified(TableRef(schema: trigger.table.schema, name: trigger.name)))"
        case .postgres: "DROP TRIGGER \(dialect.quoteIdentifier(trigger.name)) ON \(dialect.qualified(trigger.table))"
        }
    }

    /// The statement that re-creates a MySQL trigger as it is now (used to restore it when an edit's
    /// `CREATE` fails after the `DROP`). `definition` is the `SHOW CREATE TRIGGER` text.
    public static func restoreStatement(definition: String) -> String {
        cleanedBody(definition)
    }

    public static func showCreate(_ trigger: TriggerInfo, dialect: SQLDialect) -> String? {
        dialect.family == .mysql ? "SHOW CREATE TRIGGER \(dialect.qualified(TableRef(schema: trigger.table.schema, name: trigger.name)))" : nil
    }

    /// A starting point for the PostgreSQL function body field.
    public static func functionTemplate(for timing: TriggerTiming, events: [TriggerEvent]) -> String {
        let result = events == [.delete] ? "OLD" : "NEW"
        let ret = timing == .after ? "RETURN NULL;  -- the result of an AFTER trigger is ignored" : "RETURN \(result);"
        return "BEGIN\n  -- your logic here\n  \(ret)\nEND;"
    }

    // MARK: Validation and helpers

    private static func validate(_ spec: TriggerSpec, dialect: SQLDialect) throws {
        guard !spec.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw TriggerError.invalid("Give the trigger a name.") }
        guard !spec.events.isEmpty else { throw TriggerError.invalid("Choose at least one event.") }
        switch dialect.family {
        case .mysql:
            guard spec.events.count == 1, spec.events[0] != .truncate else {
                throw TriggerError.invalid("MySQL triggers fire on exactly one of INSERT, UPDATE or DELETE.")
            }
            guard spec.timing != .insteadOf else { throw TriggerError.invalid("MySQL has no INSTEAD OF triggers.") }
            guard case .statements(let body) = spec.body, !cleanedBody(body).isEmpty else {
                throw TriggerError.invalid("The trigger body is empty.")
            }
        case .postgres:
            if spec.events.contains(.truncate), spec.forEachRow || spec.timing == .insteadOf || spec.events.count > 1 {
                throw TriggerError.invalid("TRUNCATE triggers must be FOR EACH STATEMENT and can't be INSTEAD OF.")
            }
            if spec.timing == .insteadOf, !spec.forEachRow { throw TriggerError.invalid("INSTEAD OF triggers are FOR EACH ROW.") }
            switch spec.body {
            case .statements: throw TriggerError.invalid("PostgreSQL triggers call a function.")
            case .existingFunction(let ref):
                guard !ref.name.isEmpty else { throw TriggerError.invalid("Choose a trigger function.") }
            case .newFunction(let ref, let source):
                guard !ref.name.isEmpty else { throw TriggerError.invalid("Name the new function.") }
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TriggerError.invalid("The function body is empty.") }
            }
        }
    }

    /// Trims whitespace and trailing semicolons: the protocol takes one statement and `BEGIN … END;` is
    /// only valid inside the block.
    static func cleanedBody(_ body: String) -> String {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// A dollar-quote delimiter that doesn't occur in `body`.
    static func dollarTag(avoiding body: String) -> String {
        var tag = "$qw$"
        var n = 0
        while body.contains(tag) {
            n += 1
            tag = "$qw\(n)$"
        }
        return tag
    }
}
