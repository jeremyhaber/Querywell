import Foundation

/// A supported database server family.
public enum DatabaseEngine: String, Codable, Sendable, CaseIterable {
    case mysql
    case mariadb
    case postgresql

    /// Human-readable product name.
    public var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        }
    }

    /// The engine's standard TCP port.
    public var defaultPort: Int {
        switch self {
        case .mysql, .mariadb: 3306
        case .postgresql: 5432
        }
    }
}
