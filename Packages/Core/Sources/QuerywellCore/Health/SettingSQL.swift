import Foundation

/// How a setting change reaches the server.
public enum SettingScope: String, Sendable, Hashable, Codable, CaseIterable {
    /// MySQL 8: `SET PERSIST` - applies now and survives restarts (written to `mysqld-auto.cnf`).
    case persist
    /// `SET GLOBAL` - applies now, lost on restart (MariaDB and MySQL 5.7 can only do this).
    case runtime
    /// MySQL 8: `SET PERSIST_ONLY` - written for the next restart, for read-only variables.
    case persistOnly
    /// PostgreSQL: `ALTER SYSTEM SET` + `pg_reload_conf()` (written to `postgresql.auto.conf`).
    case alterSystem

    public var title: String {
        switch self {
        case .persist: "Apply now and persist (SET PERSIST)"
        case .runtime: "Apply now, until restart (SET GLOBAL)"
        case .persistOnly: "Persist for next restart (SET PERSIST_ONLY)"
        case .alterSystem: "ALTER SYSTEM and reload"
        }
    }

    public var shortTitle: String {
        switch self {
        case .persist: "SET PERSIST"
        case .runtime: "SET GLOBAL"
        case .persistOnly: "SET PERSIST_ONLY"
        case .alterSystem: "ALTER SYSTEM"
        }
    }
}

/// One variable to set: the unit of Apply and Revert.
public struct SettingChange: Sendable, Hashable {
    public var variable: String
    /// The value to set, as plain text (no SQL quoting).
    public var value: String
    /// What the server has now (recorded as the revision's old value). Nil when unknown.
    public var currentValue: String?
    /// PostgreSQL: the current value comes from the built-in default, so a revert can `RESET` instead.
    public var currentIsDefault: Bool
    public var scope: SettingScope
    public var restartRequired: Bool
    /// PostgreSQL: `value` is the built-in default, so put it back with `ALTER SYSTEM RESET` instead of pinning it.
    public var resetToDefault: Bool

    public init(variable: String, value: String, currentValue: String? = nil, currentIsDefault: Bool = false,
                scope: SettingScope, restartRequired: Bool = false, resetToDefault: Bool = false) {
        self.resetToDefault = resetToDefault
        self.variable = variable
        self.value = value
        self.currentValue = currentValue
        self.currentIsDefault = currentIsDefault
        self.scope = scope
        self.restartRequired = restartRequired
    }
}

public enum SettingSQLError: Error, Equatable, Sendable {
    case invalidVariableName(String)
    case unsupportedScope(SettingScope, DatabaseEngine)
}

/// Generates the statements for a setting change. Variable names are validated (they can come from a
/// stored revision) and values are quoted through ``SQLDialect``.
public enum SettingSQL {
    public static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_" || $0 == ".") }
    }

    /// The scopes this server version supports, most durable first.
    public static func availableScopes(engine: DatabaseEngine, major: Int, minor: Int, patch: Int = 0, readOnlyVariable: Bool = false) -> [SettingScope] {
        switch engine {
        case .postgresql:
            return [.alterSystem]
        case .mariadb:
            return readOnlyVariable ? [] : [.runtime]
        case .mysql:
            guard major >= 8 else { return readOnlyVariable ? [] : [.runtime] }
            return readOnlyVariable ? [.persistOnly] : [.persist, .runtime]
        }
    }

    public static func statements(for change: SettingChange, engine: DatabaseEngine) throws -> [String] {
        guard isValidVariableName(change.variable) else { throw SettingSQLError.invalidVariableName(change.variable) }
        let dialect = SQLDialect(engine)
        switch (engine, change.scope) {
        case (.postgresql, .alterSystem):
            let set = "ALTER SYSTEM SET \(change.variable) = \(dialect.quoteString(change.value))"
            return [set, "SELECT pg_reload_conf()"]
        case (.mysql, .persist): return ["SET PERSIST \(change.variable) = \(mysqlLiteral(change.value, dialect))"]
        case (.mysql, .persistOnly): return ["SET PERSIST_ONLY \(change.variable) = \(mysqlLiteral(change.value, dialect))"]
        case (.mysql, .runtime), (.mariadb, .runtime): return ["SET GLOBAL \(change.variable) = \(mysqlLiteral(change.value, dialect))"]
        default: throw SettingSQLError.unsupportedScope(change.scope, engine)
        }
    }

    /// Statements that put a PostgreSQL setting back to its built-in default.
    public static func resetStatements(variable: String) throws -> [String] {
        guard isValidVariableName(variable) else { throw SettingSQLError.invalidVariableName(variable) }
        return ["ALTER SYSTEM RESET \(variable)", "SELECT pg_reload_conf()"]
    }

    static func mysqlLiteral(_ value: String, _ dialect: SQLDialect) -> String {
        let t = value.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t == value, Int64(t) != nil || (Double(t) != nil && t.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }) {
            return t
        }
        return dialect.quoteString(value)
    }

    /// The configuration-file lines that make the changes survive a restart (`my.cnf` / `postgresql.conf`).
    public static func configSnippet(for changes: [SettingChange], engine: DatabaseEngine) -> String {
        switch engine {
        case .postgresql:
            return changes.map { "\($0.variable) = '\($0.value.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: "\n")
        case .mysql, .mariadb:
            let lines = changes.map { c -> String in
                let needsQuotes = c.value.contains(" ") || c.value.contains(",") || c.value.contains("#") || c.value.contains(";")
                return "\(c.variable) = \(needsQuotes ? "\"\(c.value)\"" : c.value)"
            }
            return (["[mysqld]"] + lines).joined(separator: "\n")
        }
    }
}
