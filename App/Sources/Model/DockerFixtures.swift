#if DEBUG
import Foundation
import QuerywellCore

extension AppModel {
    /// The servers from the repo's `docker-compose.yml`, as saved connections.
    static let dockerFolderName = "Docker"

    /// Adds (when missing, matched by name) profiles for the docker-compose servers into a
    /// "Docker" folder, storing their passwords like any other connection. Returns how many were added.
    @discardableResult
    func addDockerTestConnections() async -> Int {
        let folderID: UUID
        if let existing = library.folders.first(where: { $0.name == Self.dockerFolderName }) {
            folderID = existing.id
        } else if let created = await addFolder(named: Self.dockerFolderName) {
            folderID = created
        } else {
            return 0
        }

        func draft(
            _ name: String, engine: DatabaseEngine, port: Int, tag: ColorTag,
            database: String = "querywell_test"
        ) -> ConnectionDraft {
            var d = ConnectionDraft(newFor: engine)
            d.name = name
            d.folderID = folderID
            d.colorTag = tag
            d.host = "127.0.0.1"
            d.portText = String(port)
            d.user = "querywell"
            d.databasePassword = "querywell_pw"
            d.defaultDatabase = database
            return d
        }

        var drafts = [
            draft("Docker MySQL 8.4", engine: .mysql, port: 13306, tag: .local),
            draft("Docker MariaDB 11.4", engine: .mariadb, port: 13307, tag: .staging),
            draft("Docker Postgres 16", engine: .postgresql, port: 15432, tag: .local),
        ]
        var viaSSH = draft("Docker MySQL via SSH", engine: .mysql, port: 3306, tag: .production)
        viaSSH.host = "mysql8"
        viaSSH.useSSH = true
        viaSSH.sshHost = "127.0.0.1"
        viaSSH.sshPortText = "12222"
        viaSSH.sshUser = "querywell"
        viaSSH.sshAuth = .password
        viaSSH.sshSecret = "querywell_ssh_pw"
        drafts.append(viaSSH)

        var added = 0
        for draft in drafts where !library.profiles.contains(where: { $0.name == draft.name }) {
            if await save(draft) { added += 1 }
        }
        return added
    }
}
#endif
