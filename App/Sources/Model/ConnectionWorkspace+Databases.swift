import Foundation
import QuerywellCore

/// How a create / drop database request ended.
enum DatabaseActionOutcome: Equatable {
    case done
    /// The write gate said no (read-only) or the user cancelled the confirmation.
    case declined
    case failed(String)
}

/// Create and drop database. Both go through ``WriteGate`` like every other write, so Production
/// confirmations (typed database name for a drop) and read-only connections are respected.
extension ConnectionWorkspace {
    /// Create / drop are off on read-only connections and while disconnected.
    var canModifyDatabases: Bool { isConnected && !profile.effectiveReadOnly }

    /// Why Drop is unavailable for `name`, or `nil`. `elsewhere` is true when another window of this
    /// connection is bound to it.
    ///
    /// A window can't drop its own database: Postgres refuses to drop the database you are connected
    /// to, and on MySQL it would leave the window browsing a database that no longer exists. Another
    /// window bound to it has the same problem, so it has to be closed first.
    func dropBlockedReason(for name: String, boundElsewhere elsewhere: Bool) -> String? {
        if profile.effectiveReadOnly { return "This connection is read-only." }
        if name == boundDatabase { return "This window is using “\(name)”. Open another database to drop it." }
        if elsewhere { return "“\(name)” is open in another window. Close that window first." }
        if DatabaseSelection.isSystemDatabase(name, engine: profile.engine) { return "“\(name)” is a system database." }
        return nil
    }

    func loadCreationOptions() async -> DatabaseCreationOptions? {
        guard let session = live?.session, let inspector = browser.inspector else { return nil }
        return try? await DatabaseCreationOptionsLoader.load(session: session, inspector: inspector)
    }

    func createDatabase(_ spec: NewDatabaseSpec) async -> DatabaseActionOutcome {
        guard let session = live?.session else { return .declined }
        let name = DatabaseDDL.normalizedName(spec.name)
        let sql = DatabaseDDL.create(spec, dialect: SQLDialect(session.engine))
        guard await gate.authorize(statements: [sql], database: name, actionTitle: "Create") else { return .declined }
        do {
            _ = try await session.execute(sql)
        } catch {
            return .failed(SchemaBrowserModel.message(error))
        }
        await refreshDatabases()
        browser.refresh()
        return .done
    }

    func dropDatabase(_ name: String) async -> DatabaseActionOutcome {
        guard let session = live?.session else { return .declined }
        let sql = DatabaseDDL.drop(name, dialect: SQLDialect(session.engine))
        guard await gate.authorize(
            statements: [sql], escalateToDestructive: true, database: name, actionTitle: "Drop") else { return .declined }
        do {
            _ = try await session.execute(sql)
        } catch {
            return .failed(SchemaBrowserModel.message(error))
        }
        await refreshDatabases()
        browser.refresh()
        return .done
    }
}
