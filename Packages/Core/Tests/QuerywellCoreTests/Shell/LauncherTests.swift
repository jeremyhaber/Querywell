import Foundation
import Testing
@testable import QuerywellCore

private func profile(
    _ name: String, host: String = "db.example.com", user: String = "app", engine: DatabaseEngine = .mysql,
    database: String? = nil, folder: UUID? = nil, tag: ColorTag? = nil, ssh: SSHTunnelConfig? = nil,
    used: Date? = nil, created: Date = Date(timeIntervalSince1970: 1_000), favourite: Bool = false
) -> ConnectionProfile {
    ConnectionProfile(
        name: name, folderID: folder, colorTag: tag, engine: engine, host: host, user: user,
        defaultDatabase: database, ssh: ssh, createdAt: created, lastUsedAt: used, favourite: favourite)
}

private func names(_ ps: [ConnectionProfile]) -> [String] { ps.map(\.name) }

@Suite("ColorTag")
struct ColorTagTests {
    @Test func palette() {
        #expect(ColorTag.presets == [.production, .staging, .local])
        #expect(ColorTag.production.defaultHex == "#C4314B")
        #expect(ColorTag.staging.defaultHex == "#E0A030")
        #expect(ColorTag.local.defaultHex == "#2E9E5B")
    }

    @Test func shortLabels() {
        #expect(ColorTag.production.shortLabel == "PROD")
        #expect(ColorTag.staging.shortLabel == "STAGING")
        #expect(ColorTag.local.shortLabel == "LOCAL")
        #expect(ColorTag.custom(name: "qa", hex: "#000000").shortLabel == "QA")
        #expect(ColorTag.custom(name: "Client Acme Corp", hex: "#000000").shortLabel == "CLIENT A")
        #expect(ColorTag.custom(name: "  ", hex: "#000000").shortLabel == "")
    }

    @Test func kinds() {
        #expect(ColorTag.production.kind == .production)
        #expect(ColorTag.custom(name: "x", hex: "#111111").kind == .custom)
    }
}

@Suite("ConnectionLibraryQuery")
struct LibraryQueryTests {
    let folderA = ConnectionFolder(name: "Clients", sortIndex: 0)

    var library: ConnectionLibrary {
        ConnectionLibrary(folders: [folderA], profiles: [
            profile("Acme Production", host: "10.0.0.5", tag: .production, used: Date(timeIntervalSince1970: 500)),
            profile("Café Staging", host: "cafe.internal", user: "renée", database: "Zoë", folder: folderA.id,
                    tag: .staging, ssh: SSHTunnelConfig(host: "bastion-eu", user: "u", auth: .agent(socketPath: nil)),
                    used: Date(timeIntervalSince1970: 900), favourite: true),
            profile("Local dev", host: "127.0.0.1", engine: .postgresql, tag: .local),
            profile("Dangling", folder: UUID()),
        ])
    }

    @Test func emptyLibrary() {
        let q = ConnectionLibraryQuery(searchText: "x", folder: .favourites)
        #expect(q.apply(to: ConnectionLibrary()).isEmpty)
        let counts = q.folderCounts(in: ConnectionLibrary())
        #expect(counts[.all] == 0 && counts[.unfiled] == 0 && counts[.favourites] == 0)
    }

    @Test func noFilterReturnsAllSortedByLastUsed() {
        let r = ConnectionLibraryQuery().apply(to: library)
        // Used desc, then never-used by name.
        #expect(names(r) == ["Café Staging", "Acme Production", "Dangling", "Local dev"])
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        #expect(names(ConnectionLibraryQuery(searchText: "CAFE").apply(to: library)) == ["Café Staging"])
        #expect(names(ConnectionLibraryQuery(searchText: "café").apply(to: library)) == ["Café Staging"])
        #expect(names(ConnectionLibraryQuery(searchText: "renee").apply(to: library)) == ["Café Staging"])
        #expect(names(ConnectionLibraryQuery(searchText: "zoe").apply(to: library)) == ["Café Staging"])
    }

    @Test func searchFields() {
        func hits(_ t: String) -> [String] { names(ConnectionLibraryQuery(searchText: t).apply(to: library)) }
        #expect(hits("10.0.0") == ["Acme Production"])        // host
        #expect(hits("bastion") == ["Café Staging"])         // ssh host
        #expect(hits("postgres") == ["Local dev"])           // engine
        #expect(hits("staging") == ["Café Staging"])         // tag name + name
        #expect(hits("production") == ["Acme Production"])   // tag
    }

    @Test func allTermsMustMatch() {
        func hits(_ t: String) -> [String] { names(ConnectionLibraryQuery(searchText: t).apply(to: library)) }
        #expect(hits("acme prod") == ["Acme Production"])
        #expect(hits("acme  \t staging").isEmpty)
        #expect(hits("   ").count == 4)
    }

    @Test func folderFilters() {
        func hits(_ f: FolderFilter) -> [String] { names(ConnectionLibraryQuery(folder: f).apply(to: library)) }
        #expect(hits(.folder(folderA.id)) == ["Café Staging"])
        #expect(Set(hits(.unfiled)) == ["Acme Production", "Local dev", "Dangling"])  // dangling folder id counts as unfiled
        #expect(hits(.favourites) == ["Café Staging"])
        #expect(hits(.tag(.production)) == ["Acme Production"])
        #expect(hits(.tag(.custom)).isEmpty)
    }

    @Test func filterAndSearchCombine() {
        let q = ConnectionLibraryQuery(searchText: "acme", folder: .favourites)
        #expect(q.apply(to: library).isEmpty)
    }

    @Test func counts() {
        let c = ConnectionLibraryQuery(searchText: "ignored").folderCounts(in: library)
        #expect(c[.all] == 4)
        #expect(c[.unfiled] == 3)
        #expect(c[.favourites] == 1)
        #expect(c[.folder(folderA.id)] == 1)
        #expect(c[.tag(.production)] == 1)
        #expect(c[.tag(.custom)] == 0)
    }

    @Test func sortModes() {
        let old = Date(timeIntervalSince1970: 10), new = Date(timeIntervalSince1970: 20)
        let lib = ConnectionLibrary(profiles: [
            profile("b", used: nil, created: old), profile("a", used: nil, created: new),
            profile("c10", used: old, created: old), profile("c9", used: old, created: old), profile("z", used: new, created: old),
        ])
        #expect(names(ConnectionLibraryQuery(sort: .lastUsed).apply(to: lib)) == ["z", "c9", "c10", "a", "b"])
        #expect(names(ConnectionLibraryQuery(sort: .name).apply(to: lib)) == ["a", "b", "c9", "c10", "z"])
        #expect(names(ConnectionLibraryQuery(sort: .created).apply(to: lib)).first == "a")  // newest first
    }

    @Test func favouriteDecodesTolerantly() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","name":"n","engine":"mysql","host":"h","user":"u"}"#
        let p = try JSONFileStore.makeDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        #expect(p.favourite == false)
        var q = p; q.favourite = true
        let back = try JSONFileStore.makeDecoder().decode(
            ConnectionProfile.self, from: JSONFileStore.makeEncoder().encode(q))
        #expect(back.favourite)
    }
}

@Suite("ConnectionSummary")
struct SummaryTests {
    @Test func engineLabel() {
        let p = profile("x")
        #expect(ConnectionSummary(profile: p).engineLabel == "MySQL")
        let info = ServerInfo(engine: .mariadb, versionString: "11.4.2-MariaDB", major: 11, minor: 4, patch: 2, tlsActive: false)
        #expect(ConnectionSummary(profile: p, serverInfo: info).engineLabel == "MariaDB 11.4")
        #expect(ConnectionSummary(profile: p).title == "x")
    }

    @Test func endpoints() {
        #expect(ConnectionSummary(profile: profile("x", host: "db.local")).endpointLabel == "db.local:3306")
        #expect(ConnectionSummary(profile: profile("x", host: "::1")).endpointLabel == "[::1]:3306")
        #expect(ConnectionSummary(profile: profile("x", host: "[::1]")).endpointLabel == "[::1]:3306")
        let ssh = SSHTunnelConfig(host: "web01", user: "u", auth: .password)
        #expect(ConnectionSummary(profile: profile("x", host: "127.0.0.1", ssh: ssh)).endpointLabel == "web01 · 127.0.0.1:3306")
        let odd = SSHTunnelConfig(host: "web01", port: 2222, user: "u", auth: .password)
        #expect(ConnectionSummary(profile: profile("x", host: "10.0.0.1", ssh: odd)).endpointLabel == "web01:2222 · 10.0.0.1:3306")
    }

    @Test func accessLabels() {
        func label(_ auth: SSHAuthMethod) -> String {
            ConnectionSummary(profile: profile("x", ssh: SSHTunnelConfig(host: "h", user: "u", auth: auth))).accessLabel
        }
        #expect(label(.keyFile(path: "/k")) == "SSH key")
        #expect(label(.agent(socketPath: nil)) == "SSH agent")
        #expect(label(.agent(socketPath: "/tmp/agent.sock")) == "SSH agent")
        #expect(label(.agent(socketPath: SSHAuthMethod.onePasswordAgentSocketPath)) == "1Password agent")
        #expect(label(.password) == "SSH password")

        var p = profile("x")
        #expect(ConnectionSummary(profile: p).accessLabel == "Password")
        p.tls.mode = .required
        #expect(ConnectionSummary(profile: p).accessLabel == "Password + TLS")
        p = profile("x", host: "localhost")
        #expect(ConnectionSummary(profile: p).accessLabel == "Direct")
        p.tls.mode = .verifyCA
        #expect(ConnectionSummary(profile: p).accessLabel == "Password + TLS")
    }

    // Fixed clock: 2026-10-26 12:00:00 UTC (Monday).
    static let now = Date(timeIntervalSince1970: 1_793_016_000)
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let posix = Locale(identifier: "en_US_POSIX")

    func label(secondsAgo: Double?) -> String {
        var p = profile("x")
        p.lastUsedAt = secondsAgo.map { Self.now.addingTimeInterval(-$0) }
        return ConnectionSummary(profile: p).lastUsedLabel(relativeTo: Self.now, calendar: Self.calendar, locale: Self.posix)
    }

    @Test func nowIsAsAssumed() {
        #expect(Self.calendar.component(.hour, from: Self.now) == 12)
        #expect(Self.calendar.component(.month, from: Self.now) == 10)
    }

    @Test func relativeLabels() {
        #expect(label(secondsAgo: nil) == "Never")
        #expect(label(secondsAgo: -30) == "Just now")        // slightly in the future
        #expect(label(secondsAgo: 0) == "Just now")
        #expect(label(secondsAgo: 59) == "Just now")
        #expect(label(secondsAgo: 60) == "1 min ago")
        #expect(label(secondsAgo: 120) == "2 min ago")
        #expect(label(secondsAgo: 3599) == "59 min ago")
        #expect(label(secondsAgo: 3600) == "1 hr ago")
        #expect(label(secondsAgo: 11.9 * 3600) == "11 hr ago")     // 00:06 today
        #expect(label(secondsAgo: 12 * 3600 + 1) == "Yesterday")    // 23:59:59 yesterday
        #expect(label(secondsAgo: 36 * 3600) == "Yesterday")
        #expect(label(secondsAgo: 2 * 86_400) == "2 days ago")
        #expect(label(secondsAgo: 3 * 86_400) == "3 days ago")
        #expect(label(secondsAgo: 6 * 86_400) == "6 days ago")
        #expect(label(secondsAgo: 7 * 86_400) == "Last week")
        #expect(label(secondsAgo: 13 * 86_400) == "Last week")
        #expect(label(secondsAgo: 14 * 86_400) == "Oct 12")
        #expect(label(secondsAgo: 200 * 86_400) == "Apr 9")
    }

    @Test func olderYearIncludesYear() {
        let text = label(secondsAgo: 400 * 86_400)
        #expect(text.contains("2025"))
    }

    @Test func calendarTimeZoneDecidesDayBoundary() {
        // 00:30 UTC "now"; used 23:30 UTC the previous day = 1h ago in the same-hour sense,
        // but in Tokyo (+9) both are the same calendar day.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_793_016_000 - 12 * 3600 + 1800)  // 00:30 UTC
        var p = profile("x"); p.lastUsedAt = now.addingTimeInterval(-3600 * 1.5)  // 23:00 UTC prev day
        let s = ConnectionSummary(profile: p)
        #expect(s.lastUsedLabel(relativeTo: now, calendar: tokyo, locale: Self.posix) == "1 hr ago")
        #expect(s.lastUsedLabel(relativeTo: now, calendar: Self.calendar, locale: Self.posix) == "Yesterday")
    }
}
