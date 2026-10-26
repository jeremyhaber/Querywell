import Foundation

/// Picks which database a new connection window shows first.
public enum DatabaseSelection {
    /// Server-internal schemas users rarely mean to browse.
    public static func isSystemDatabase(_ name: String, engine: DatabaseEngine) -> Bool {
        switch engine {
        case .mysql, .mariadb:
            ["information_schema", "mysql", "performance_schema", "sys"].contains(name.lowercased())
        case .postgresql:
            name.hasPrefix("template")
        }
    }

    /// The profile's default database if present, else the session's current one if it isn't a
    /// system schema, else the first user database, else the first database at all.
    public static func preferred(
        among names: [String], defaultDatabase: String?, current: String?, engine: DatabaseEngine
    ) -> String? {
        if let defaultDatabase, names.contains(defaultDatabase) { return defaultDatabase }
        if let current, names.contains(current), !isSystemDatabase(current, engine: engine) { return current }
        return names.first { !isSystemDatabase($0, engine: engine) } ?? names.first
    }
}
