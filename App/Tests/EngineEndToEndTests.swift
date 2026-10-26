import AppKit
import Foundation
import QuerywellCore
import SwiftUI
import Testing
@testable import Querywell

/// The main UI flows against MariaDB 11.4 and PostgreSQL 16 (the other snapshot suites only use MySQL):
/// sidebar, table data (sort, chips, funnel), structure, inline edit + conflict, query tab, console, export
/// (Postgres: local pg_dump; MariaDB: over the Docker ssh bastion), import into a fresh schema, search & replace.
///
/// Opt-in like the snapshots (`scripts/snapshots.sh`, QUERYWELL_SNAPSHOTS=1; Docker servers must be up).
/// Fixtures live in their own schemas (`qw_e2e_*`) which the tests drop and recreate.
@MainActor
@Suite("Engine end-to-end", .serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOTS"] == "1"))
struct EngineEndToEndTests {
    struct Engine: Sendable, CustomTestStringConvertible {
        var name: String
        var engine: DatabaseEngine
        var port: Int
        var user: String
        var password: String
        var database: String?
        /// Host of the database as the ssh bastion sees it.
        var bastionHost: String
        var bastionPort: Int
        var schema: String
        var importSchema: String
        var testDescription: String { name }
        var isPostgres: Bool { engine == .postgresql }

        static let mariadb = Engine(
            name: "mariadb", engine: .mariadb, port: 13307, user: "root", password: "root_pw", database: nil,
            bastionHost: "mariadb11", bastionPort: 3306, schema: "qw_e2e_mdb", importSchema: "qw_e2e_mdb_import")
        static let postgres = Engine(
            name: "postgres", engine: .postgresql, port: 15432, user: "querywell", password: "querywell_pw", database: "querywell_test",
            bastionHost: "postgres16", bastionPort: 5432, schema: "qw_e2e_pg", importSchema: "qw_e2e_pg_import")
        static let all = [mariadb, postgres]
    }

    private let outputDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOT_DIR"]
        let url = URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath + "/build/snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Harness

    private func makeModel() async throws -> (AppModel, URL, SSHClientOptions) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuerywellE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let options = SSHClientOptions(knownHostsFile: dir.appendingPathComponent("known_hosts").path, useUserSSHConfig: false)
        let store = InMemorySecretStore()
        let opener = ConnectionOpener(secretStore: store, tunnelProvider: SystemSSHTunnelProvider(options: options))
        let model = AppModel(directory: dir, secretStore: store, opener: opener)
        await model.load()
        return (model, dir, options)
    }

    private func draft(_ e: Engine, name: String, bastion: Bool = false) -> ConnectionDraft {
        var d = ConnectionDraft(newFor: e.engine)
        d.name = name
        d.host = "127.0.0.1"
        d.portText = String(e.port)
        d.user = e.user
        d.databasePassword = e.password
        d.defaultDatabase = e.database ?? ""
        if bastion {
            d.host = e.bastionHost
            d.portText = String(e.bastionPort)
            d.useSSH = true
            d.sshHost = "127.0.0.1"
            d.sshPortText = "12222"
            d.sshUser = "querywell"
            d.sshAuth = .password
            d.sshSecret = "querywell_ssh_pw"
        }
        return d
    }

    private func open(_ model: AppModel, _ name: String, ssh: SSHClientOptions) async throws -> (UUID, ConnectionWorkspace) {
        let id = try #require(model.library.profiles.first { $0.name == name }?.id)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        workspace.tools.sshOptions = ssh
        await workspace.connect()
        try #require(workspace.isConnected, "connect \(name): \(workspace.state)")
        return (workspaceID, workspace)
    }

    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func loaded(_ m: TableDataModel) async throws {
        try await waitUntil { m.content != nil && !m.isLoading }
    }

    private func render<V: View>(_ view: V, model: AppModel, size: CGSize, name: String,
                                 prepare: ((NSWindow) async throws -> Void)? = nil) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingController(rootView: view.environment(model))
            host.sceneBridgingOptions = [.toolbars, .title]
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(2))  // never RunLoop.run: it starves the main actor
            if let prepare {
                try await prepare(window)
                try await Task.sleep(for: .seconds(0.8))
            }
            let image = try #require(Self.captureWindow(window.windowNumber))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }

    private static func captureWindow(_ windowNumber: Int) -> CGImage? {
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        return capture(.null, 1 << 3, UInt32(windowNumber), 1 << 0)?.takeRetainedValue()
    }

    // MARK: Fixture

    static let oldSite = "http://old.example.com"
    static let newSite = "https://new.example.com"
    static func phpString(_ s: String) -> String { "s:\(s.utf8.count):\"\(s)\";" }
    /// `a:2:{s:3:"url";s:22:"http://old.example.com";s:4:"path";s:5:"/blog";}`
    static var serializedSite: String { "a:2:{" + phpString("url") + phpString(oldSite) + phpString("path") + phpString("/blog") + "}" }
    static var jsonOption: String { "{\"home\":\"http:\\/\\/old.example.com\\/x\",\"n\":1}" }

    /// WordPress-like tables in `e.schema`: users, posts (enum status + JSON column), postmeta, options.
    private func createFixture(_ e: Engine, _ session: any DatabaseSession) async throws {
        let q = SQLDialect(e.engine).quoteIdentifier(e.schema)
        func run(_ sql: String) async throws { _ = try await session.execute(sql) }
        if e.isPostgres {
            try await run("DROP SCHEMA IF EXISTS \(q) CASCADE")
            try await run("DROP SCHEMA IF EXISTS \"\(e.importSchema)\" CASCADE")
            try await run("DROP SCHEMA IF EXISTS \"\(e.importSchema)_orig\" CASCADE")
            try await run("CREATE SCHEMA \(q)")
            try await run("CREATE TYPE \(q).post_status AS ENUM ('publish','draft','pending','private','trash')")
            try await run("""
                CREATE TABLE \(q).wp_users (
                  "ID" bigserial PRIMARY KEY, user_login varchar(60) NOT NULL UNIQUE, display_name varchar(250) NOT NULL DEFAULT '',
                  user_registered timestamp NOT NULL DEFAULT now())
                """)
            try await run("""
                CREATE TABLE \(q).wp_posts (
                  "ID" bigserial PRIMARY KEY, post_author bigint NOT NULL REFERENCES \(q).wp_users("ID") ON DELETE CASCADE,
                  post_title varchar(255) NOT NULL DEFAULT '', post_content text NOT NULL DEFAULT '',
                  post_status \(q).post_status NOT NULL DEFAULT 'draft', post_date timestamp NOT NULL, post_data jsonb)
                """)
            try await run("CREATE INDEX wp_posts_status_date ON \(q).wp_posts (post_status, post_date)")
            try await run("""
                CREATE TABLE \(q).wp_postmeta (
                  meta_id bigserial PRIMARY KEY, post_id bigint NOT NULL REFERENCES \(q).wp_posts("ID") ON DELETE CASCADE,
                  meta_key varchar(255), meta_value text)
                """)
            try await run("""
                CREATE TABLE \(q).wp_options (
                  option_id bigserial PRIMARY KEY, option_name varchar(191) NOT NULL UNIQUE, option_value text NOT NULL, autoload varchar(20) NOT NULL DEFAULT 'yes')
                """)
            try await run("INSERT INTO \(q).wp_users (user_login, display_name, user_registered) SELECT 'user' || i, 'User ' || i, timestamp '2024-01-01' + i * interval '1 day' FROM generate_series(1, 5) i")
            try await run("""
                INSERT INTO \(q).wp_posts (post_author, post_title, post_content, post_status, post_date, post_data)
                SELECT 1 + i % 5, 'Post ' || lpad(i::text, 3, '0'), 'Body ' || i || ' it''s <a href="\(Self.oldSite)/p/' || i || '">link</a>',
                       (ARRAY['publish','publish','draft','pending','trash'])[1 + i % 5]::\(q).post_status,
                       timestamp '2024-02-01' + i * interval '1 hour',
                       CASE WHEN i % 10 = 0 THEN jsonb_build_object('link', '\(Self.oldSite)/a/' || i, 'n', i) END
                FROM generate_series(1, 60) i
                """)
            try await run("INSERT INTO \(q).wp_postmeta (post_id, meta_key, meta_value) SELECT 1 + i % 60, 'k' || i % 3, '\(Self.serializedSite.replacingOccurrences(of: "'", with: "''"))' FROM generate_series(1, 30) i")
        } else {
            try await run("DROP DATABASE IF EXISTS \(q)")
            try await run("DROP DATABASE IF EXISTS `\(e.importSchema)`")
            try await run("CREATE DATABASE \(q) DEFAULT CHARACTER SET utf8mb4")
            try await run("""
                CREATE TABLE \(q).wp_users (
                  ID bigint unsigned NOT NULL AUTO_INCREMENT, user_login varchar(60) NOT NULL DEFAULT '', display_name varchar(250) NOT NULL DEFAULT '',
                  user_registered datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (ID), UNIQUE KEY user_login_key (user_login)) ENGINE=InnoDB
                """)
            try await run("""
                CREATE TABLE \(q).wp_posts (
                  ID bigint unsigned NOT NULL AUTO_INCREMENT, post_author bigint unsigned NOT NULL, post_title varchar(255) NOT NULL DEFAULT '',
                  post_content longtext NOT NULL, post_status enum('publish','draft','pending','private','trash') NOT NULL DEFAULT 'draft',
                  post_date datetime NOT NULL, post_data JSON DEFAULT NULL, PRIMARY KEY (ID), KEY status_date (post_status, post_date),
                  CONSTRAINT fk_post_author FOREIGN KEY (post_author) REFERENCES \(q).wp_users (ID) ON DELETE CASCADE) ENGINE=InnoDB
                """)
            try await run("""
                CREATE TABLE \(q).wp_postmeta (
                  meta_id bigint unsigned NOT NULL AUTO_INCREMENT, post_id bigint unsigned NOT NULL, meta_key varchar(255) DEFAULT NULL,
                  meta_value longtext, PRIMARY KEY (meta_id), KEY post_id (post_id),
                  CONSTRAINT fk_meta_post FOREIGN KEY (post_id) REFERENCES \(q).wp_posts (ID) ON DELETE CASCADE) ENGINE=InnoDB
                """)
            try await run("""
                CREATE TABLE \(q).wp_options (
                  option_id bigint unsigned NOT NULL AUTO_INCREMENT, option_name varchar(191) NOT NULL DEFAULT '', option_value longtext NOT NULL,
                  autoload varchar(20) NOT NULL DEFAULT 'yes', PRIMARY KEY (option_id), UNIQUE KEY option_name (option_name)) ENGINE=InnoDB
                """)
            let users = (1...5).map { "('user\($0)', 'User \($0)', '2024-01-0\($0) 00:00:00')" }.joined(separator: ",")
            try await run("INSERT INTO \(q).wp_users (user_login, display_name, user_registered) VALUES \(users)")
            let statuses = ["publish", "publish", "draft", "pending", "trash"]
            var rows: [String] = []
            for i in 1...60 {
                let data = i % 10 == 0 ? "'{\"link\": \"\(Self.oldSite)/a/\(i)\", \"n\": \(i)}'" : "NULL"
                let content = "Body \(i) it\\'s <a href=\"\(Self.oldSite)/p/\(i)\">link</a>"
                rows.append("(\(1 + i % 5), 'Post \(String(format: "%03d", i))', '\(content)', '\(statuses[i % 5])', '2024-02-01 00:00:00' + INTERVAL \(i) HOUR, \(data))")
            }
            try await run("INSERT INTO \(q).wp_posts (post_author, post_title, post_content, post_status, post_date, post_data) VALUES \(rows.joined(separator: ","))")
            let meta = (1...30).map { "(\(1 + $0 % 60), 'k\($0 % 3)', '\(Self.serializedSite)')" }.joined(separator: ",")
            try await run("INSERT INTO \(q).wp_postmeta (post_id, meta_key, meta_value) VALUES \(meta)")
        }
        let escaped = { (s: String) in SQLDialect(e.engine).quoteString(s) }
        try await run("""
            INSERT INTO \(q).wp_options (option_name, option_value, autoload) VALUES
            ('home', \(escaped(Self.oldSite)), 'yes'), ('siteurl', \(escaped(Self.oldSite)), 'yes'),
            ('widget_site', \(escaped(Self.serializedSite)), 'yes'), ('theme_json', \(escaped(Self.jsonOption)), 'no'),
            ('blogname', 'Unrelated', 'yes'), ('_transient_foo', 'cached', 'no'), ('_site_transient_bar', 'cached', 'no')
            """)
    }

    private func count(_ session: any DatabaseSession, _ e: Engine, schema: String, _ table: String) async throws -> Int64 {
        let d = SQLDialect(e.engine)
        let r = try await session.execute("SELECT COUNT(*) FROM \(d.quoteIdentifier(schema)).\(d.quoteIdentifier(table))")
        return r.rows.first?.first.flatMap { TableDataModel.int($0) } ?? -1
    }

    // MARK: The flows

    @Test("main flows", arguments: Engine.all)
    func mainFlows(_ e: Engine) async throws {
        let (model, dir, ssh) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft(e, name: "E2E \(e.name)"))
        _ = await model.save(draft(e, name: "E2E \(e.name) via ssh", bastion: true))
        let (workspaceID, workspace) = try await open(model, "E2E \(e.name)", ssh: ssh)
        let session = try #require(workspace.live?.session)
        #expect(session.engine == e.engine)
        try await createFixture(e, session)
        workspace.gate.confirmationHandler = { _ in true }  // tests bypass the confirmation sheet
        let dialect = SQLDialect(e.engine)
        let S = e.schema

        // 1. Sidebar: the database picker shows the schema; Postgres defaults to public.
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.selectedSchema != nil && workspace.browser.current != nil }
        if e.isPostgres { #expect(workspace.browser.selectedSchema == "public", "Postgres defaults to public") }
        #expect(workspace.browser.schemas.contains(S), "schema list contains the fixture schema \(S): \(workspace.browser.schemas)")
        workspace.browser.selectedSchema = S
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "wp_posts" } == true }
        let names = (workspace.browser.current?.tables.map(\.ref.name) ?? []).sorted()
        #expect(names == ["wp_options", "wp_postmeta", "wp_posts", "wp_users"], "sidebar tables: \(names)")

        // 2. Table data: first page, sort, chip filter, funnel distinct values.
        let postsRef = TableRef(schema: S, name: "wp_posts")
        workspace.openTable(postsRef)
        let posts = try #require(workspace.tableModel(forTable: postsRef))
        posts.loadIfNeeded(epoch: workspace.connectionEpoch)
        try await loaded(posts)
        #expect(posts.failure == nil, "load failure: \(posts.failure?.message ?? "")")
        #expect(posts.content?.rows.count == 60)
        #expect(posts.pageInfo.label == "Rows 1–60 of 60 (exact)", Comment(rawValue: posts.pageInfo.label))
        #expect(posts.structure?.primaryKey == ["ID"])
        let titleIndex = try #require(posts.content?.columns.firstIndex { $0.name == "post_title" })
        posts.toggleSort(column: "post_title", additive: false)
        posts.toggleSort(column: "post_title", additive: false)  // descending
        try await waitUntil { posts.sort.first?.ascending == false && !posts.isLoading }
        try await loaded(posts)
        #expect(posts.content?.rows.first?[titleIndex] == .text("Post 060"), "sorted descending: \(String(describing: posts.content?.rows.first?[titleIndex]))")
        posts.toggleSort(column: "post_title", additive: false)  // cleared
        try await waitUntil { posts.sort.isEmpty && !posts.isLoading }

        posts.upsertFilter(ColumnFilter(column: "post_status", op: .isAnyOf([.text("publish")])))
        try await waitUntil { posts.filters.filters.count == 1 && !posts.isLoading }
        try await loaded(posts)
        #expect(posts.failure == nil, "enum filter: \(posts.failure?.message ?? "") \(posts.failure?.sql ?? "")")
        #expect(posts.content?.rows.count == 24, "publish rows: \(posts.content?.rows.count ?? -1)")
        let editor = try #require(posts.makeFilterEditor(column: "post_status"))
        await editor.load()
        #expect(editor.loadError == nil, "funnel: \(editor.loadError ?? "")")
        let counts = Dictionary(uniqueKeysWithValues: editor.values.map { ($0.value.displayString, $0.count) })
        #expect(counts["publish"] == 24 && counts["draft"] == 12 && counts["trash"] == 12 && counts["pending"] == 12, "distinct values \(counts)")
        #expect(editor.sampledRows == nil)
        // Raw WHERE bar.
        posts.clearFilters()
        try await loaded(posts)
        posts.whereDraft = e.isPostgres ? "\"ID\" <= 10" : "ID <= 10"
        posts.applyWhere()
        try await waitUntil { posts.appliedWhere.isEmpty == false && !posts.isLoading }
        try await loaded(posts)
        #expect(posts.content?.rows.count == 10, "raw where")
        posts.clearFilters()
        try await waitUntil { posts.content?.rows.count == 60 && !posts.isLoading }

        // JSON column: shown as text, never as bytes.
        let dataIndex = try #require(posts.content?.columns.firstIndex { $0.name == "post_data" })
        let jsonCell = try #require(posts.content?.rows.first { $0[dataIndex] != .null }?[dataIndex])
        if case .text(let json) = jsonCell { #expect(json.contains("old.example.com")) } else { Issue.record("post_data decoded as \(jsonCell)") }
        #expect(posts.content?.columns[dataIndex].presentation.kind == .json, "json column kind: \(String(describing: posts.content?.columns[dataIndex].presentation.kind)) type \(posts.content?.columns[dataIndex].fullType ?? "")")

        // 3. Structure, indexes, relations.
        let structure = try #require(posts.structure)
        #expect(structure.columns.map(\.name) == ["ID", "post_author", "post_title", "post_content", "post_status", "post_date", "post_data"])
        #expect(structure.columns.first { $0.name == "post_status" }?.enumValues == ["publish", "draft", "pending", "private", "trash"],
                "enum values: \(String(describing: structure.columns.first { $0.name == "post_status" }?.enumValues))")
        #expect(structure.indexes.contains { $0.isPrimary && $0.columns == ["ID"] })
        #expect(structure.indexes.contains { $0.columns == ["post_status", "post_date"] }, "indexes: \(structure.indexes)")
        #expect(structure.foreignKeys.first?.referenced.name == "wp_users")
        #expect(structure.referencedBy.contains { $0.table?.name == "wp_postmeta" || $0.referenced.name == "wp_posts" })
        #expect(structure.createStatement?.contains("wp_posts") == true)

        // 4. Inline edit + commit + conflict (wp_users).
        let usersRef = TableRef(schema: S, name: "wp_users")
        workspace.openTable(usersRef)
        let users = try #require(workspace.tableModel(forTable: usersRef))
        users.loadIfNeeded(epoch: workspace.connectionEpoch)
        try await loaded(users)
        let nameIndex = try #require(users.content?.columns.firstIndex { $0.name == "display_name" })
        let row = try #require(users.content?.rows.firstIndex { TableDataModel.int($0[0]) == 3 })
        let users3 = "\(dialect.quoteIdentifier(S)).\(dialect.quoteIdentifier("wp_users"))"
        let idCol = dialect.quoteIdentifier("ID")
        #expect(users.applyText(displayRow: row, column: "display_name", text: "Edited by Querywell") == nil)
        #expect(users.pendingEditCount == 1)
        let report = await users.commit()
        #expect(report?.isSuccess == true, "commit: \(String(describing: report?.headline)) \(String(describing: report?.detail)) \(String(describing: report?.statement))")
        var check = try await session.execute("SELECT display_name FROM \(users3) WHERE \(idCol) = 3")
        #expect(check.rows.first?.first == .text("Edited by Querywell"))
        try await waitUntil { !users.isLoading && users.content?.rows[row][nameIndex] == .text("Edited by Querywell") }
        #expect(users.applyText(displayRow: row, column: "display_name", text: "Mine") == nil)
        _ = try await session.execute("UPDATE \(users3) SET display_name = 'Theirs' WHERE \(idCol) = 3")
        let conflict = await users.commit()
        #expect(conflict?.status == .conflict, "expected a conflict, got \(String(describing: conflict?.status)) \(String(describing: conflict?.headline))")
        check = try await session.execute("SELECT display_name FROM \(users3) WHERE \(idCol) = 3")
        #expect(check.rows.first?.first == .text("Theirs"))
        users.discardAll()
        // Insert + delete in one commit.
        users.addRow()
        users.editRequest = nil
        #expect(users.applyText(displayRow: 0, column: "user_login", text: "newbie") == nil)
        #expect(users.applyText(displayRow: 0, column: "display_name", text: "Newbie") == nil)
        let insert = await users.commit()
        #expect(insert?.isSuccess == true, "insert: \(String(describing: insert?.headline)) \(String(describing: insert?.detail)) \(String(describing: insert?.statement))")
        #expect(try await count(session, e, schema: S, "wp_users") == 6)

        // 5. Query tab: multi-statement run and an editable result.
        workspace.tabs.newQuery()
        let q = try #require(workspace.currentQueryModel)
        let postsQ = "\(dialect.quoteIdentifier(S)).wp_posts"
        let usersQ = "\(dialect.quoteIdentifier(S)).wp_users"
        q.text = """
        SELECT p.post_title, u.display_name FROM \(postsQ) p JOIN \(usersQ) u ON u.\(idCol) = p.post_author ORDER BY p.\(idCol) LIMIT 5;
        SELECT COUNT(*) AS n FROM \(postsQ);
        """
        q.selection = NSRange(location: (q.text as NSString).length, length: 0)
        await q.run(.all)
        #expect(q.results.count == 2, "query results: \(q.results.count), error \(String(describing: q.lastError?.1))")
        #expect(q.results.first?.title.hasPrefix("Result 1 · 5 rows") == true, Comment(rawValue: q.results.first?.title ?? ""))
        let resultSelected = q.results.first?.id
        if let resultSelected { q.selected = .result(resultSelected) }
        workspace.tabs.newQuery()
        let editable = try #require(workspace.currentQueryModel)
        editable.text = "SELECT \(idCol), user_login, display_name FROM \(usersQ) ORDER BY \(idCol)"
        await editable.run(.all)
        try await waitUntil { editable.results.first?.editModel?.content != nil && editable.results.first?.editModel?.isLoading == false }
        let editModel = editable.results.first?.editModel
        #expect(editModel != nil, "single-table result should be editable (error: \(String(describing: editable.lastError?.1)))")
        if let editModel {
            #expect(editModel.applyText(displayRow: 0, column: "display_name", text: "Via query") == nil)
            let r = await editModel.commit()
            #expect(r?.isSuccess == true, "editable result commit: \(String(describing: r?.headline)) \(String(describing: r?.detail))")
            let v = try await session.execute("SELECT display_name FROM \(users3) WHERE \(idCol) = 1")
            #expect(v.rows.first?.first == .text("Via query"))
        }
        // Two statements where the second fails: first result kept, error reported.
        workspace.tabs.newQuery()
        let failing = try #require(workspace.currentQueryModel)
        failing.text = "SELECT 1 AS one; SELECT nope FROM \(postsQ);"
        await failing.run(.all)
        #expect(failing.lastRun?.hasErrors == true && failing.results.count == 1)

        // 6. Console: SELECT and an error.
        workspace.tabs.openConsole()
        let consoleTab = try #require(workspace.tabs.selectedTab)
        let console = try #require(workspace.consoleModel(forTab: consoleTab))
        await console.startIfNeeded()
        await console.submit("SELECT COUNT(*) FROM \(postsQ);")
        await console.submit("SELECT nope FROM \(postsQ);")
        let text = console.scrollback.map(\.plainText).joined(separator: "\n")
        #expect(text.contains("60"), "console output: \(text)")
        #expect(text.localizedCaseInsensitiveContains("error"), "console error output: \(text)")

        // 7. Screens.
        workspace.tabs.select(id: try #require(workspace.tabs.tabs.first { $0.title == "wp_posts" }?.id))
        workspace.browser.select("wp_posts", command: false, shift: false, visible: ["wp_posts"])
        let size = CGSize(width: 1200, height: 760)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "e2e-\(e.name)-table-data")
        if let resultSelected, let queryTab = workspace.tabs.tabs.first(where: { if case .query = $0.kind { true } else { false } }) {
            workspace.tabs.select(id: queryTab.id)
            q.selected = .result(resultSelected)
            try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "e2e-\(e.name)-query-results")
        }

        // 8. Export, then import into a fresh schema, row counts match.
        let (viaID, via) = try await open(model, "E2E \(e.name) via ssh", ssh: ssh)
        via.refreshSchema()
        try await waitUntil { via.browser.selectedSchema != nil }
        via.browser.selectedSchema = S
        try await waitUntil { via.browser.current?.tables.contains { $0.ref.name == "wp_posts" } == true }
        await via.presentExport()
        let sheet = try #require(via.tools.exportSheet)
        await sheet.load(inspector: via.browser.inspector)
        if e.isPostgres { sheet.location = .localThroughTunnel }  // pg_dump runs locally (no pg_dump on the bastion)
        #expect(sheet.isWordPress || e.isPostgres)
        let out = dir.appendingPathComponent("e2e-\(e.name).sql" + (e.isPostgres ? "" : ".gz"))
        sheet.chooseDestination(out)
        sheet.gzip = !e.isPostgres
        sheet.skipTransients = !e.isPostgres
        await sheet.run()
        guard case .finished(let summary) = sheet.runState else { Issue.record("export: \(sheet.runState) \(sheet.logLines.suffix(5))"); return }
        #expect(summary.bytesWritten > 0 && summary.tables.contains { $0.hasSuffix("wp_posts") }, "export summary \(summary)")
        await model.closeWorkspace(id: viaID)

        workspace.refreshSchema()
        workspace.presentImport(file: out)
        let imp = try #require(workspace.tools.importSheet)
        if e.isPostgres {
            // A pg_dump names its schema; import into a fresh copy by renaming it in the stream is not offered, so
            // create the target and let the dump's own CREATE SCHEMA recreate the source after dropping it.
            _ = try await session.execute("ALTER SCHEMA \(dialect.quoteIdentifier(S)) RENAME TO \(dialect.quoteIdentifier(e.importSchema + "_orig"))")
        } else {
            _ = try await session.execute("CREATE DATABASE \(dialect.quoteIdentifier(e.importSchema))")
            imp.targetSchema = e.importSchema
        }
        await imp.loadAndScan()
        await imp.start()
        #expect(imp.phase == .finished, "import: \(imp.phase) \(imp.errors.first?.message ?? "")")
        #expect(imp.report?.succeeded == true, Comment(rawValue: "import report: \(String(describing: imp.report)) errors: \(imp.errors.map(\.message))"))
        let source = e.isPostgres ? e.importSchema + "_orig" : S
        let target = e.isPostgres ? S : e.importSchema
        for table in ["wp_users", "wp_posts", "wp_postmeta", "wp_options"] {
            let a = try await count(session, e, schema: source, table)
            let b = try await count(session, e, schema: target, table)
            // The MariaDB export skips the two WordPress transients in wp_options.
            let expected = (table == "wp_options" && !e.isPostgres) ? a - 2 : a
            #expect(expected == b && a > 0, "\(table): source \(a) vs imported \(b)")
        }
        if e.isPostgres {
            _ = try await session.execute("DROP SCHEMA \(dialect.quoteIdentifier(S)) CASCADE")
            _ = try await session.execute("ALTER SCHEMA \(dialect.quoteIdentifier(e.importSchema + "_orig")) RENAME TO \(dialect.quoteIdentifier(S))")
        } else {
            _ = try await session.execute("DROP DATABASE \(dialect.quoteIdentifier(e.importSchema))")
        }
        let transient = try await session.execute("SELECT COUNT(*) FROM \(dialect.quoteIdentifier(S)).wp_options")
        #expect(transient.rows.first?.first != nil)

        // 9. Search & replace on serialized and JSON values (dry run writes nothing, apply fixes lengths).
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "wp_options" } == true }
        workspace.browser.selectedSchema = S
        workspace.presentSearchReplace()
        let sr = try #require(workspace.searchReplace)
        try await waitUntil { !sr.isLoadingTables && sr.tables.contains { $0.name == "wp_options" } }
        await sr.waitForStructures()
        #expect(sr.wordPressPrefix == "wp_")
        #expect(sr.selected.count == 4, "selected: \(sr.selected.map(\.name))")
        sr.search = Self.oldSite
        sr.replace = Self.newSite
        await sr.runPreview()
        let preview = try #require(sr.previewReport)
        #expect(preview.mode == .dryRun)
        #expect(sr.runError == nil, "preview error: \(sr.runError ?? "")")
        // options: home, siteurl, widget_site, theme_json = 4; posts: 60 content rows; post_data JSON: 6; postmeta: 30
        let byTable = Dictionary(uniqueKeysWithValues: preview.tables.map { ($0.table.name, $0.rowsChanged) })
        #expect(byTable["wp_options"] == 4 && byTable["wp_posts"] == 60 && byTable["wp_postmeta"] == 30, "dry-run counts: \(byTable)")
        func option(_ name: String) async throws -> String {
            let r = try await session.execute("SELECT option_value FROM \(dialect.quoteIdentifier(S)).wp_options WHERE option_name = '\(name)'")
            if case .text(let s)? = r.rows.first?.first { return s }
            return ""
        }
        #expect(try await option("home") == Self.oldSite, "a dry run must not write")
        sr.beginApply()
        await sr.confirmApply()
        #expect(try await option("home") == Self.newSite)
        let widget = try await option("widget_site")
        #expect(widget == "a:2:{" + Self.phpString("url") + Self.phpString(Self.newSite) + Self.phpString("path") + Self.phpString("/blog") + "}", "serialized: \(widget)")
        let jsonValue = try await option("theme_json")
        #expect(jsonValue.contains("https:\\/\\/new.example.com\\/x") || jsonValue.contains("https://new.example.com/x"), "json option: \(jsonValue)")
        #expect(!jsonValue.contains("old.example.com"))
        #expect(try await option("blogname") == "Unrelated")
        let postData = try await session.execute("SELECT post_data FROM \(dialect.quoteIdentifier(S)).wp_posts WHERE \(idCol) = 10")
        if case .text(let pd)? = postData.rows.first?.first { #expect(pd.contains("https://new.example.com/a/10") && !pd.contains("old.example.com"), "post_data: \(pd)") } else { Issue.record("post_data: \(String(describing: postData.rows.first?.first))") }
        let metaRow = try await session.execute("SELECT meta_value FROM \(dialect.quoteIdentifier(S)).wp_postmeta ORDER BY meta_id LIMIT 1")
        if case .text(let m)? = metaRow.rows.first?.first { #expect(m.contains("s:23:\"\(Self.newSite)\""), "postmeta: \(m)") }

        // Cleanup.
        _ = try? await session.execute(e.isPostgres ? "DROP SCHEMA IF EXISTS \(dialect.quoteIdentifier(S)) CASCADE" : "DROP DATABASE IF EXISTS \(dialect.quoteIdentifier(S))")
        await model.closeWorkspace(id: workspaceID)
    }
}
