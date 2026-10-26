import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// One-statement-at-a-time gate used inside driver actors. Actors only serialize
/// synchronous sections; a statement spans several suspension points, so without this a
/// second caller could interleave its wire traffic with the first.
struct SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Returns true when the gate was free and is now held by the caller.
    mutating func tryEnter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    mutating func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        waiters.append(continuation)
    }

    /// Hands the gate to the next waiter (staying busy) or frees it.
    mutating func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum DriverSupport {
    /// Name used for SNI / hostname verification: the explicit override, else the host,
    /// except that IP literals are never valid in SNI (NIOSSL refuses them).
    static func tlsServerName(for config: ConnectionConfiguration) -> String? {
        if let explicit = config.tlsServerName, !explicit.isEmpty { return explicit }
        var v4 = in_addr(), v6 = in6_addr()
        let isIP = config.host.withCString {
            inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1
        }
        return isIP ? nil : config.host
    }

    static func nanoseconds(_ duration: Duration) -> Int64 {
        let c = duration.components
        let ns = c.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if ns.overflow { return Int64.max }
        return max(0, ns.partialValue + c.attoseconds / 1_000_000_000)
    }

    /// Classifies a transport-level failure (everything that is not a server reply).
    static func mapTransportError(_ error: any Error, host: String, port: Int) -> DatabaseError {
        if let e = error as? DatabaseError { return e }
        let target = "\(host):\(port)"

        if error is NIOSSLError || error is NIOSSLExtraError {
            return .tlsFailed("TLS handshake with \(target) failed: \(describe(error))")
        }
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout: return .timeout
            case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed:
                return .connectionFailed("The connection to \(target) was closed by the server.")
            default: break
            }
        }
        if let io = error as? IOError {
            return .connectionFailed("Could not connect to \(target): \(String(cString: strerror(io.errnoCode))).")
        }
        if let conn = error as? NIOConnectionError {
            if conn.connectionErrors.contains(where: { isTimeout($0.error) }) { return .timeout }
            if let dns = conn.dnsAError ?? conn.dnsAAAAError {
                return .connectionFailed("Could not resolve host \(conn.host): \(describe(dns))")
            }
            if let first = conn.connectionErrors.first {
                return mapTransportError(first.error, host: host, port: port)
            }
            return .connectionFailed("Could not connect to \(target).")
        }
        if error is SocketAddressError || String(describing: type(of: error)).contains("Getaddrinfo") {
            return .connectionFailed("Could not resolve host \(host): \(describe(error))")
        }
        if error is CancellationError { return .timeout }
        return .connectionFailed("Could not connect to \(target): \(describe(error))")
    }

    static func isTimeout(_ error: any Error) -> Bool {
        if let c = error as? ChannelError, case .connectTimeout = c { return true }
        return false
    }

    static func describe(_ error: any Error) -> String {
        if let io = error as? IOError { return String(cString: strerror(io.errnoCode)) }
        if let local = error as? LocalizedError, let d = local.errorDescription { return d }
        return String(describing: error)
    }
}
