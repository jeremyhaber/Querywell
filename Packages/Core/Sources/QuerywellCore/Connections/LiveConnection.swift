import Foundation

/// An open database connection plus the SSH tunnel carrying it (if any).
/// Each connection window holds one.
public actor LiveConnection {
    public nonisolated let profile: ConnectionProfile
    public nonisolated let session: any DatabaseSession
    public nonisolated let tunnel: (any SSHTunnel)?
    public nonisolated let openedAt: Date
    /// Opens another session to the same server over the same tunnel (same resolved configuration).
    /// Used for work that must not queue behind the main session: exact row counts, funnel value lists.
    /// nil for connections built without an opener (tests).
    private let auxiliaryOpener: (@Sendable () async throws -> any DatabaseSession)?
    private var closed = false

    public init(
        profile: ConnectionProfile, session: any DatabaseSession, tunnel: (any SSHTunnel)?, openedAt: Date = Date(),
        auxiliaryOpener: (@Sendable () async throws -> any DatabaseSession)? = nil
    ) {
        self.profile = profile
        self.session = session
        self.tunnel = tunnel
        self.openedAt = openedAt
        self.auxiliaryOpener = auxiliaryOpener
    }

    public nonisolated var canOpenAuxiliarySession: Bool { auxiliaryOpener != nil }

    /// A fresh short-lived session; the caller closes it. Throws once the connection is closed.
    public func openAuxiliarySession() async throws -> any DatabaseSession {
        guard !closed, let auxiliaryOpener else { throw DatabaseError.sessionClosed }
        return try await auxiliaryOpener()
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
