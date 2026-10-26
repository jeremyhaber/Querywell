import Foundation
import Testing
@testable import QuerywellCore

private func validDraft() -> ConnectionDraft {
    var d = ConnectionDraft(newFor: .mysql)
    d.name = "Prod"; d.user = "root"
    return d
}

private func dict(_ d: ConnectionDraft) -> [String: String?] {
    Dictionary(uniqueKeysWithValues: d.secretsToSave().map { ($0.0.kind.rawKey, $0.1) })
}

@Suite("ConnectionDraft")
struct ConnectionDraftTests {
    @Test func newDraftDefaults() {
        let d = ConnectionDraft(newFor: .postgresql)
        #expect(d.portText == "5432" && d.host == "127.0.0.1" && !d.useSSH && d.sshPortText == "22")
        #expect(d.validate() == [.emptyName, .emptyUser])
    }

    @Test func makeProfileTrimsAndNormalises() throws {
        var d = validDraft()
        d.name = "  Prod  "; d.host = " db.example.com "; d.portText = " 3307 "
        d.defaultDatabase = "  "; d.notes = ""
        let p = try d.makeProfile()
        #expect(p.name == "Prod" && p.host == "db.example.com" && p.port == 3307)
        #expect(p.defaultDatabase == nil && p.notes == nil && p.ssh == nil)
        #expect(p.id == d.id)
    }

    @Test func portTextValidation() {
        for bad in ["", "abc", "0", "65536", "-1", "33 06", "3306.0", "+3306", "١٢٣", "9999999999999999999999"] {
            var d = validDraft(); d.portText = bad
            #expect(d.validate() == [.invalidPort], "port '\(bad)'")
        }
        for good in ["1", "65535", "3306"] {
            var d = validDraft(); d.portText = good
            #expect(d.validate().isEmpty, "port '\(good)'")
        }
    }

    @Test func sshValidation() {
        var d = validDraft()
        d.useSSH = true
        #expect(d.validate() == [.sshEmptyHost, .sshEmptyUser])
        d.sshHost = "bastion"; d.sshUser = "me"; d.sshPortText = "x"
        #expect(d.validate() == [.sshInvalidPort])
        d.sshPortText = "22"; d.sshAuth = .keyFile
        #expect(d.validate() == [.sshKeyFileEmpty])
        d.sshKeyPath = "~/.ssh/id"
        #expect(d.validate().isEmpty)
        // Hidden SSH fields are not validated when SSH is off.
        d.useSSH = false; d.sshHost = ""
        #expect(d.validate().isEmpty)
    }

    @Test func makeProfileThrowsIssues() {
        let d = ConnectionDraft(newFor: .mysql)
        #expect(throws: ConnectionDraftError(issues: [.emptyName, .emptyUser])) { try d.makeProfile() }
    }

    @Test func sshProfileMapping() throws {
        var d = validDraft()
        d.useSSH = true; d.sshHost = "web01"; d.sshUser = "deploy"
        d.sshAuth = .agent; d.sshAgentSocketPath = SSHAuthMethod.onePasswordAgentSocketPath
        #expect(try d.makeProfile().ssh == SSHTunnelConfig(
            host: "web01", user: "deploy", auth: .agent(socketPath: SSHAuthMethod.onePasswordAgentSocketPath)))
        d.sshAgentSocketPath = " "
        #expect(try d.makeProfile().ssh?.auth == .agent(socketPath: nil))
        d.sshAuth = .password
        #expect(try d.makeProfile().ssh?.auth == .password)
    }

    @Test func profileRoundTripThroughDraft() throws {
        let ssh = SSHTunnelConfig(host: "h", port: 2200, user: "u", auth: .keyFile(path: "/k"))
        var p = ConnectionProfile(
            name: "N", folderID: UUID(), colorTag: .staging, engine: .postgresql, host: "pg", port: 6543, user: "me",
            defaultDatabase: "db", ssh: ssh, tls: TLSConfig(mode: .required), readOnly: true,
            createdAt: Date(timeIntervalSince1970: 5), lastUsedAt: Date(timeIntervalSince1970: 9),
            notes: "n", favourite: true)
        p.colorTag = .custom(name: "x", hex: "#123456")
        let d = ConnectionDraft(profile: p, secrets: ConnectionSecrets(databasePassword: "pw", sshSecret: "pp"))
        #expect(try d.makeProfile() == p)
        #expect(d.databasePassword == "pw" && d.sshSecret == "pp" && d.sshAuth == .keyFile && d.useSSH)
    }

    @Test func engineChangeMovesDefaultPortOnly() {
        var d = ConnectionDraft(newFor: .mysql)
        d.engine = .postgresql
        #expect(d.portText == "5432")
        d.engine = .mariadb
        #expect(d.portText == "3306")
        d.portText = "3399"
        d.engine = .postgresql
        #expect(d.portText == "3399")        // customised: left alone
        d.portText = ""
        d.engine = .mysql
        #expect(d.portText == "")
        d.portText = "5432"                   // equals *old* default of postgres
        d.engine = .postgresql                // unchanged engine: no-op
        #expect(d.portText == "5432")
        // MySQL <-> MariaDB share a port: a no-op either way.
        d.engine = .mysql; d.engine = .mariadb
        #expect(d.portText == "3306")
    }

    @Test func secretsEmptyMeansDelete() {
        var d = validDraft()
        #expect(dict(d) == ["db.password": nil, "ssh.password": nil, "ssh.passphrase": nil])
        d.databasePassword = "pw"
        #expect(dict(d)["db.password"] == "pw")
        let keys = d.secretsToSave().map(\.0)
        #expect(keys.map(\.ownerID) == Array(repeating: d.id.uuidString, count: 3))
        #expect(keys.map(\.kind) == [.databasePassword, .sshPassword, .sshKeyPassphrase])
    }

    @Test func sshSecretFollowsAuthMethod() {
        var d = validDraft()
        d.useSSH = true; d.sshSecret = "s3cret"
        d.sshAuth = .password
        #expect(dict(d)["ssh.password"] == "s3cret" && dict(d)["ssh.passphrase"] == .some(nil))
        // Switching password -> key deletes the old ssh password, stores passphrase.
        d.sshAuth = .keyFile
        #expect(dict(d)["ssh.password"] == .some(nil) && dict(d)["ssh.passphrase"] == "s3cret")
        d.sshSecret = ""
        #expect(dict(d)["ssh.passphrase"] == .some(nil))
        // Agent keeps neither; so does SSH off.
        d.sshSecret = "x"; d.sshAuth = .agent
        #expect(dict(d)["ssh.password"] == .some(nil) && dict(d)["ssh.passphrase"] == .some(nil))
        d.sshAuth = .password; d.useSSH = false
        #expect(dict(d)["ssh.password"] == .some(nil))
    }

    @Test func testSecrets() {
        var d = validDraft()
        #expect(d.testSecrets == ConnectionSecrets())
        d.databasePassword = "pw"; d.sshSecret = "pp"
        #expect(d.testSecrets == ConnectionSecrets(databasePassword: "pw", sshSecret: nil))   // SSH off
        d.useSSH = true; d.sshAuth = .agent
        #expect(d.testSecrets.sshSecret == nil)
        d.sshAuth = .keyFile
        #expect(d.testSecrets == ConnectionSecrets(databasePassword: "pw", sshSecret: "pp"))
    }
}
