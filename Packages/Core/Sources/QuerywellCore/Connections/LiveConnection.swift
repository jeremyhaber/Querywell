import Foundation

/// An open database connection plus the SSH tunnel carrying it (if any).
/// Each connection window holds one.
public actor LiveConnection {
    public nonisolated let profile: ConnectionProfile
    public nonisolated let session: any DatabaseSession
    public nonisolated let tunnel: (any SSHTunnel)?
    public nonisolated let openedAt: Date
    private var closed = false

    public init(profile: ConnectionProfile, session: any DatabaseSession, tunnel: (any SSHTunnel)?, openedAt: Date = Date()) {
        self.profile = profile
        self.session = session
        self.tunnel = tunnel
        self.openedAt = openedAt
    }

    public var isClosed: Bool { closed }

    /// Closes the session, then the tunnel. Idempotent.
    public func close() async {
        guard !closed else { return }
        closed = true
        await session.close()
        await tunnel?.close()
    }
}
