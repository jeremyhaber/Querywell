import Foundation

/// Maps an engine to the driver that speaks its protocol. The switch is exhaustive on
/// purpose: adding a ``DatabaseEngine`` case fails to compile until a driver is wired here.
public enum DriverRegistry {
    private static let mysql = MySQLDriver()
    private static let postgres = PostgresDriver()

    public static func driver(for engine: DatabaseEngine) -> any DatabaseDriver {
        switch engine {
        case .mysql, .mariadb: mysql
        case .postgresql: postgres
        }
    }
}
