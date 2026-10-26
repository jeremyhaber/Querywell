import Foundation
import Testing
@testable import QuerywellCore

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONFileStore.makeEncoder().encode(value)
    return try JSONFileStore.makeDecoder().decode(T.self, from: data)
}

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONFileStore.makeEncoder().encode(value), as: UTF8.self)
}

@Suite("Models")
struct ModelTests {
    @Test func engineDefaults() throws {
        #expect(DatabaseEngine.mysql.defaultPort == 3306)
        #expect(DatabaseEngine.mariadb.defaultPort == 3306)
        #expect(DatabaseEngine.postgresql.defaultPort == 5432)
        #expect(DatabaseEngine.postgresql.displayName == "PostgreSQL")
        #expect(DatabaseEngine.allCases.count == 3)
        for e in DatabaseEngine.allCases { #expect(try roundTrip(e) == e) }
    }

    @Test(arguments: [
        ColorTag.production, .staging, .local, .custom(name: "Client A", hex: "#123456"),
    ])
    func colorTagRoundTrip(tag: ColorTag) throws {
        #expect(try roundTrip(tag) == tag)
    }

    @Test func colorTagEncodingIsExplicit() throws {
        #expect(try json(ColorTag.production).contains("\"kind\" : \"production\""))
        let custom = try json(ColorTag.custom(name: "X", hex: "#000000"))
        #expect(custom.contains("\"kind\" : \"custom\""))
        #expect(custom.contains("\"name\" : \"X\""))
        #expect(custom.contains("\"hex\" : \"#000000\""))
    }

    @Test func colorTagProperties() {
        #expect(ColorTag.production.isProduction)
        #expect(!ColorTag.staging.isProduction)
        #expect(!ColorTag.local.isProduction)
        #expect(!ColorTag.custom(name: "Production", hex: "#FF0000").isProduction)
        #expect(ColorTag.production.defaultHex == "#FF3B30")
        #expect(ColorTag.staging.defaultHex == "#FF9F0A")
        #expect(ColorTag.local.defaultHex == "#34C759")
        #expect(ColorTag.custom(name: "A", hex: "#ABCDEF").defaultHex == "#ABCDEF")
        #expect(ColorTag.custom(name: "A", hex: "#ABCDEF").displayName == "A")
        #expect(ColorTag.staging.displayName == "Staging")
    }

    @Test func colorTagUnknownKindThrows() {
        let data = Data(#"{"kind":"purple"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ColorTag.self, from: data) }
    }

    @Test(arguments: [
        SSHAuthMethod.keyFile(path: "/Users/me/.ssh/id_ed25519"),
        .agent(socketPath: nil),
        .agent(socketPath: SSHAuthMethod.onePasswordAgentSocketPath),
        .password,
    ])
    func sshAuthRoundTrip(auth: SSHAuthMethod) throws {
        #expect(try roundTrip(auth) == auth)
    }

    @Test func sshAuthEncoding() throws {
        #expect(try json(SSHAuthMethod.password).contains("\"kind\" : \"password\""))
        #expect(!(try json(SSHAuthMethod.agent(socketPath: nil))).contains("socketPath"))
        #expect(SSHAuthMethod.onePasswordAgentSocketPath.hasSuffix("2BUA8C4S2C.com.1password/t/agent.sock"))
        let data = Data(#"{"kind":"carrierPigeon"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SSHAuthMethod.self, from: data) }
    }

    @Test func sshTunnelDefaultsAndRoundTrip() throws {
        let t = SSHTunnelConfig(host: "bastion", user: "me", auth: .password)
        #expect(t.port == 22)
        #expect(try roundTrip(t) == t)
        let minimal = try JSONDecoder().decode(
            SSHTunnelConfig.self, from: Data(#"{"host":"h","user":"u"}"#.utf8))
        #expect(minimal.port == 22)
        #expect(minimal.auth == .agent(socketPath: nil))
    }

    @Test func tlsDefaultsAndRoundTrip() throws {
        #expect(TLSConfig().mode == .preferred)
        let full = TLSConfig(mode: .verifyIdentity, caCertificatePath: "/ca.pem",
                             clientCertificatePath: "/c.pem", clientKeyPath: "/k.pem")
        #expect(try roundTrip(full) == full)
        #expect(try JSONDecoder().decode(TLSConfig.self, from: Data("{}".utf8)) == TLSConfig())
        for m in TLSMode.allCases { #expect(try roundTrip(m) == m) }
    }

    @Test func profileInitDefaults() {
        let p = ConnectionProfile(name: "x", engine: .postgresql, user: "u")
        #expect(p.port == 5432)
        #expect(p.host == "127.0.0.1")
        #expect(p.tls.mode == .preferred)
        #expect(!p.readOnly)
        #expect(ConnectionProfile(name: "x", engine: .mysql, port: 3307, user: "u").port == 3307)
    }

    @Test func profileFullRoundTrip() throws {
        let p = ConnectionProfile(
            name: "Prod", folderID: UUID(), colorTag: .custom(name: "N", hex: "#111111"),
            engine: .mariadb, host: "db.example.com", port: 3307, user: "root",
            defaultDatabase: "app",
            ssh: SSHTunnelConfig(host: "j", port: 2222, user: "me", auth: .keyFile(path: "/k")),
            tls: TLSConfig(mode: .verifyCA, caCertificatePath: "/ca.pem"),
            readOnly: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000), notes: "hi")
        #expect(try roundTrip(p) == p)
    }

    @Test func legacyMinimalProfileDecodesWithDefaults() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","name":"Old","engine":"postgresql","host":"h","user":"u"}
        """.utf8)
        let p = try JSONFileStore.makeDecoder().decode(ConnectionProfile.self, from: data)
        #expect(p.id == id)
        #expect(p.port == 5432)
        #expect(p.tls == TLSConfig())
        #expect(!p.readOnly)
        #expect(p.folderID == nil && p.colorTag == nil && p.ssh == nil)
        #expect(p.defaultDatabase == nil && p.lastUsedAt == nil && p.notes == nil)
        #expect(p.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test func productionFlags() {
        var p = ConnectionProfile(name: "x", engine: .mysql, user: "u")
        #expect(!p.isProduction && !p.requiresWriteConfirmation && !p.effectiveReadOnly)
        p.colorTag = .production
        #expect(p.isProduction && p.requiresWriteConfirmation)
        p.colorTag = .staging
        #expect(!p.requiresWriteConfirmation)
        p.readOnly = true
        #expect(p.effectiveReadOnly)
    }

    @Test func encodedProfileHasNoSecrets() throws {
        let p = ConnectionProfile(
            name: "x", engine: .mysql, user: "u",
            ssh: SSHTunnelConfig(host: "j", user: "me", auth: .password))
        let text = try json(p).lowercased()
        #expect(!text.contains("password\" :") && !text.contains("passphrase"))
        #expect(!text.contains("secret"))
    }

    @Test func folderRoundTrip() throws {
        let f = ConnectionFolder(name: "Work", sortIndex: 3)
        #expect(try roundTrip(f) == f)
    }

    @Test func libraryRoundTripAndDefaults() throws {
        let lib = ConnectionLibrary(
            folders: [ConnectionFolder(name: "F")],
            profiles: [ConnectionProfile(name: "P", engine: .mysql, user: "u",
                                         createdAt: Date(timeIntervalSince1970: 100))])
        #expect(try roundTrip(lib) == lib)
        let empty = try JSONDecoder().decode(ConnectionLibrary.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(empty.profiles.isEmpty && empty.folders.isEmpty)
    }

    @Test func encoderOutputIsSortedAndPretty() throws {
        let text = try json(ConnectionFolder(id: UUID(), name: "F", sortIndex: 1))
        #expect(text.contains("\n"))
        let idPos = try #require(text.range(of: "\"id\""))
        let namePos = try #require(text.range(of: "\"name\""))
        let sortPos = try #require(text.range(of: "\"sortIndex\""))
        #expect(idPos.lowerBound < namePos.lowerBound && namePos.lowerBound < sortPos.lowerBound)
    }
}

@Suite("Validator")
struct ValidatorTests {
    private func valid() -> ConnectionProfile {
        ConnectionProfile(name: "n", engine: .mysql, host: "h", user: "u")
    }

    @Test func validProfileHasNoIssues() {
        #expect(ConnectionValidator.validate(valid()).isEmpty)
    }

    @Test func basicFields() {
        var p = valid()
        p.name = "  "; p.host = ""; p.user = "\n"; p.port = 0
        #expect(ConnectionValidator.validate(p) == [.emptyName, .emptyHost, .invalidPort, .emptyUser])
        p = valid()
        p.port = 65536
        #expect(ConnectionValidator.validate(p) == [.invalidPort])
        p.port = 65535
        #expect(ConnectionValidator.validate(p).isEmpty)
    }

    @Test func sshFields() {
        var p = valid()
        p.ssh = SSHTunnelConfig(host: "", port: 70000, user: " ", auth: .keyFile(path: ""))
        #expect(ConnectionValidator.validate(p) ==
                [.sshEmptyHost, .sshInvalidPort, .sshEmptyUser, .sshKeyFileEmpty])
        p.ssh = SSHTunnelConfig(host: "j", user: "u", auth: .agent(socketPath: nil))
        #expect(ConnectionValidator.validate(p).isEmpty)
    }

    @Test func tlsCA() {
        var p = valid()
        for mode in [TLSMode.verifyCA, .verifyIdentity] {
            p.tls = TLSConfig(mode: mode)
            #expect(ConnectionValidator.validate(p) == [.tlsMissingCA])
            p.tls.caCertificatePath = "/ca.pem"
            #expect(ConnectionValidator.validate(p).isEmpty)
        }
        for mode in [TLSMode.disabled, .preferred, .required] {
            p.tls = TLSConfig(mode: mode)
            #expect(ConnectionValidator.validate(p).isEmpty)
        }
    }

    @Test func messagesAreNonEmpty() {
        let all: [ValidationIssue] = [.emptyName, .emptyHost, .invalidPort, .emptyUser, .sshEmptyHost,
                                      .sshInvalidPort, .sshEmptyUser, .sshKeyFileEmpty, .tlsMissingCA]
        for i in all { #expect(!i.message.isEmpty) }
    }
}
