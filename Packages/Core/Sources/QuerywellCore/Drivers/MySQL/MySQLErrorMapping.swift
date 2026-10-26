import Foundation
import MySQLNIO

enum MySQLErrorMapping {
    /// MySQL / MariaDB errnos that mean "your credentials were refused".
    private static let authErrnos: Set<Int> = [
        1045, // ER_ACCESS_DENIED_ERROR
        1698, // ER_ACCESS_DENIED_NO_PASSWORD_ERROR (MariaDB unix_socket etc.)
        1044, // ER_DBACCESS_DENIED_ERROR (connecting to a schema the user can't use)
    ]

    /// Maps a server error packet. `connecting` distinguishes handshake-time failures
    /// (auth) from statement errors.
    static func map(errno: Int, message: String, connecting: Bool) -> DatabaseError {
        if connecting, authErrnos.contains(errno) {
            return .authenticationFailed(message)
        }
        if !connecting, errno == 1045 {
            return .authenticationFailed(message)
        }
        if connecting, errno == 1049 {
            // ER_BAD_DB_ERROR: unknown database. Not an auth problem, not a statement either.
            return .connectionFailed(message)
        }
        return .query(message: message, code: String(errno))
    }

    static func map(_ error: any Error, host: String, port: Int, connecting: Bool) -> DatabaseError {
        if let db = error as? DatabaseError { return db }
        if let my = error as? MySQLError {
            switch my {
            case .server(let packet):
                return map(errno: Int(packet.errorCode.rawValue), message: packet.errorMessage, connecting: connecting)
            case .duplicateEntry(let m):
                return .query(message: m, code: "1062")
            case .invalidSyntax(let m):
                return .query(message: m, code: "1064")
            case .secureConnectionRequired:
                return .tlsFailed("The server requires an encrypted connection to authenticate. Enable TLS for this connection.")
            case .unsupportedAuthPlugin(let name):
                return .authenticationFailed("The server uses an authentication plugin that isn't supported (\(name)).")
            case .closed:
                return .connectionFailed("The connection to \(host):\(port) was closed.")
            default:
                return .connectionFailed(my.message)
            }
        }
        return DriverSupport.mapTransportError(error, host: host, port: port)
    }
}
