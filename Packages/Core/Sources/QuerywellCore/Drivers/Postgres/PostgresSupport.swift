import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// A parsed command tag ("INSERT 0 3", "UPDATE 2", "SELECT 5", "CREATE TABLE").
struct PostgresCommandTag: Sendable, Equatable {
    var command: String
    var rows: UInt64?

    static func parse(_ tag: String) -> PostgresCommandTag {
        let parts = tag.split(separator: " ").map(String.init)
        guard let first = parts.first else { return PostgresCommandTag(command: "", rows: nil) }
        switch first {
        case "INSERT":
            // INSERT <oid> <rows>
            return PostgresCommandTag(command: first, rows: parts.count == 3 ? UInt64(parts[2]) : nil)
        case "SELECT", "UPDATE", "DELETE", "MERGE", "MOVE", "FETCH", "COPY":
            return PostgresCommandTag(command: first, rows: parts.count == 2 ? UInt64(parts[1]) : nil)
        default:
            // DDL and utility commands ("CREATE TABLE", "BEGIN") carry no count.
            return PostgresCommandTag(command: tag, rows: nil)
        }
    }

    /// PostgresNIO parses the tag for us but doesn't hand the raw string back, so rebuild it.
    init(metadata: PostgresQueryMetadata) {
        let raw: String
        if metadata.command == "INSERT", let rows = metadata.rows {
            raw = "INSERT \(metadata.oid ?? 0) \(rows)"
        } else if let rows = metadata.rows {
            raw = "\(metadata.command) \(rows)"
        } else {
            raw = metadata.command
        }
        self = Self.parse(raw)
    }

    init(command: String, rows: UInt64?) {
        self.command = command
        self.rows = rows
    }

    /// Row count for statements that *change* rows (SELECT's count is the result size, not an effect).
    var rowsAffected: UInt64? {
        switch command {
        case "INSERT", "UPDATE", "DELETE", "MERGE", "COPY": rows
        default: nil
        }
    }
}

enum PostgresErrorMapping {
    static func map(_ error: any Error, host: String, port: Int, connecting: Bool) -> DatabaseError {
        if let db = error as? DatabaseError { return db }
        guard let e = error as? PSQLError else {
            return DriverSupport.mapTransportError(error, host: host, port: port)
        }

        switch e.code {
        case .server:
            let state = e.serverInfo?[.sqlState]
            var message = e.serverInfo?[.message] ?? "The server reported an error."
            if let detail = e.serverInfo?[.detail] { message += "\nDetail: \(detail)" }
            if let hint = e.serverInfo?[.hint] { message += "\nHint: \(hint)" }
            return map(sqlState: state, message: message, connecting: connecting)
        case .sslUnsupported:
            return .tlsFailed("The server at \(host):\(port) does not support TLS.")
        case .failedToAddSSLHandler:
            let why = e.underlying.map { DriverSupport.describe($0) } ?? "unknown error"
            return .tlsFailed("TLS handshake with \(host):\(port) failed: \(why)")
        case .receivedUnencryptedDataAfterSSLRequest:
            return .tlsFailed("The server at \(host):\(port) answered a TLS request with unencrypted data.")
        case .authMechanismRequiresPassword:
            return .authenticationFailed("The server requires a password for this user.")
        case .unsupportedAuthMechanism, .saslError:
            return .authenticationFailed("Authentication with the server failed (unsupported or invalid credentials exchange).")
        case .connectionError:
            if let underlying = e.underlying {
                return DriverSupport.mapTransportError(underlying, host: host, port: port)
            }
            return .connectionFailed("Could not connect to \(host):\(port).")
        case .clientClosedConnection, .serverClosedConnection, .uncleanShutdown:
            return .connectionFailed(connecting
                ? "The server at \(host):\(port) closed the connection during startup."
                : "The connection to the server was lost.")
        case .queryCancelled:
            return .query(message: "The query was cancelled.", code: "57014")
        default:
            return .connectionFailed("Unexpected response from the server (\(e.code)).")
        }
    }

    static func map(sqlState: String?, message: String, connecting: Bool) -> DatabaseError {
        if let s = sqlState {
            if s == "28P01" || s == "28000" { return .authenticationFailed(message) }
            if connecting && s.hasPrefix("28") { return .authenticationFailed(message) }
            if connecting && (s == "3D000" || s == "57P03" || s == "53300") { return .connectionFailed(message) }
        }
        return .query(message: message, code: sqlState)
    }
}
