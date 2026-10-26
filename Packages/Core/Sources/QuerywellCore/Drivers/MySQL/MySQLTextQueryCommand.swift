import Foundation
import MySQLNIO
import NIOCore

/// A `COM_QUERY` (text protocol) command that keeps everything `MySQLConnection.simpleQuery`
/// throws away: column definitions even when no rows follow, and the OK packet's
/// affected-rows / last-insert-id.
///
/// MySQLNIO's `MySQLCommand` protocol is public, so this plugs into `MySQLConnection.send`.
///
/// `@unchecked Sendable` justification: MySQLNIO requires commands to be handed to the
/// connection's event loop, which then mutates this object exclusively from that loop while
/// the command is in flight. The caller only reads `output` after the future returned by
/// `send` has completed, which establishes the happens-before edge. It is single-use.
final class MySQLTextQueryCommand: MySQLCommand, @unchecked Sendable {
    struct Output {
        var columns: [MySQLColumnMeta] = []
        var rows: [[ByteBuffer?]] = []
        var rowsAffected: UInt64?
        var lastInsertID: UInt64?
    }

    private enum State {
        case ready
        case columns(total: Int)
        case rows
        case done
    }

    private let sql: String
    private var state = State.ready
    private var pendingColumns: [MySQLColumnMeta] = []
    private(set) var output = Output()
    /// Set once a result set has been captured; later result sets (stored procedures,
    /// multi-statements) are drained and discarded.
    private var capturedResultSet = false

    init(sql: String) {
        self.sql = sql
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        MySQLCommandState(response: [
            try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)
        ])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            state = .done
            throw MySQLError.server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities))
        }

        switch state {
        case .ready:
            if packet.isOK {
                let ok = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                if !capturedResultSet {
                    output.rowsAffected = ok.affectedRows
                    output.lastInsertID = ok.lastInsertID.flatMap { $0 == 0 ? nil : $0 }
                }
                return finishOrContinue(ok)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            pendingColumns = []
            state = .columns(total: Int(response.columnCount))
            return MySQLCommandState()

        case .columns(let total):
            let def = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
            pendingColumns.append(MySQLColumnMeta(def))
            if pendingColumns.count == total {
                if !capturedResultSet {
                    output.columns = pendingColumns
                    output.rowsAffected = nil
                    output.lastInsertID = nil
                }
                state = .rows
            }
            return MySQLCommandState()

        case .rows:
            // The result set is terminated by an OK packet with a 0xFE header (CLIENT_DEPRECATE_EOF).
            // A real row can also start with 0xFE only if its first cell is >= 16 MiB, in which
            // case the packet is far longer than any terminator.
            if packet.isEOF && packet.payload.readableBytes < 0xFF_FFFF {
                let ok = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                capturedResultSet = true
                return finishOrContinue(ok)
            }
            let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: pendingColumns.count)
            if !capturedResultSet { output.rows.append(row.values) }
            return MySQLCommandState()

        case .done:
            throw MySQLError.protocolError
        }
    }

    private func finishOrContinue(_ ok: MySQLProtocol.OK_Packet) -> MySQLCommandState {
        if ok.statusFlags.contains(.SERVER_MORE_RESULTS_EXISTS) {
            state = .ready
            return MySQLCommandState()
        }
        state = .done
        return MySQLCommandState(done: true)
    }
}
