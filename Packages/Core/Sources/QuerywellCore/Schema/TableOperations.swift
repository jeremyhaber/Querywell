import Foundation

// SQL for the sidebar's destructive actions. Everything is quoted through `SQLDialect`; one statement
// per table so dry-run counts and failures are per table.

public enum TableOperations {
    /// `TRUNCATE TABLE …` for each real table (views are skipped: they hold no rows).
    public static func truncate(_ tables: [TableInfo], dialect: SQLDialect) -> [String] {
        tables.filter { $0.kind == .table }.map { "TRUNCATE TABLE \(dialect.qualified($0.ref))" }
    }

    /// `DROP TABLE` / `DROP VIEW` / `DROP MATERIALIZED VIEW` per object, matching its kind.
    public static func drop(_ tables: [TableInfo], dialect: SQLDialect) -> [String] {
        tables.map { info in
            switch info.kind {
            case .table: "DROP TABLE \(dialect.qualified(info.ref))"
            case .view: "DROP VIEW \(dialect.qualified(info.ref))"
            case .materializedView: "DROP MATERIALIZED VIEW \(dialect.qualified(info.ref))"
            }
        }
    }
}
