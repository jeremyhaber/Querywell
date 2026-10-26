import Foundation

/// Loopback port helpers (POSIX sockets).
public enum LoopbackPort {
    private static func makeAddr(_ port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        return addr
    }

    /// Binds 127.0.0.1:0, reads the assigned port and closes the socket.
    public static func findFree() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var addr = makeAddr(0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// True if something is listening on 127.0.0.1:`port`. Probes by trying to *bind* (EADDRINUSE), not by
    /// connecting, so the remote database never sees a bogus half-open connection (which MySQL counts
    /// towards `max_connect_errors`).
    public static func isInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = makeAddr(port)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r != 0 && errno == EADDRINUSE
    }
}
