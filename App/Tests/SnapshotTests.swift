import AppKit
import Foundation
import QuerywellCore
import SwiftUI
import Testing
@testable import Querywell

/// Renders real app screens to PNGs for visual review, and drives a real connection end to end.
///
/// Opt-in: `scripts/snapshots.sh` sets QUERYWELL_SNAPSHOTS=1 (Docker test servers must be up).
/// Output: `QUERYWELL_SNAPSHOT_DIR` (default build/snapshots).
@MainActor
@Suite("Snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOTS"] == "1"))
struct SnapshotTests {
    private let outputDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOT_DIR"]
        let url = URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath + "/build/snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func makeModel() async throws -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuerywellSnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(directory: dir, secretStore: InMemorySecretStore())
        await model.load()
        return (model, dir)
    }

    /// Sample library resembling the design mockup, plus a reachable Docker MySQL tagged PROD.
    private func seed(_ model: AppModel) async throws -> UUID {
        func draft(_ name: String, _ engine: DatabaseEngine, tag: ColorTag?, host: String = "127.0.0.1",
                   port: String? = nil, ssh: (String, SSHAuthChoice)? = nil) -> ConnectionDraft {
            var d = ConnectionDraft(newFor: engine)
            d.name = name
            d.colorTag = tag
            d.host = host
            if let port { d.portText = port }
            d.user = "querywell"
            d.databasePassword = "querywell_pw"
            if let ssh {
                d.useSSH = true
                d.sshHost = ssh.0
                d.sshUser = "deploy"
                d.sshAuth = ssh.1
                d.sshKeyPath = "~/.ssh/id_ed25519"
            }
            return d
        }
        _ = await model.save(draft("sunset-web02", .mariadb, tag: .production, ssh: ("web02", .keyFile)))
        _ = await model.save(draft("brightcart staging", .mysql, tag: .staging, ssh: ("staging", .agent)))
        _ = await model.save(draft("member portal dev", .mariadb, tag: .staging, host: "dev.internal"))
        _ = await model.save(draft("analytics", .postgresql, tag: .local))
        var prod = draft("Docker MySQL (PROD)", .mysql, tag: .production, port: "13306")
        prod.defaultDatabase = "querywell_test"
        _ = await model.save(prod)
        let id = try #require(model.library.profiles.first { $0.name == "Docker MySQL (PROD)" }?.id)
        return id
    }

    private func render<V: View>(
        _ view: V, model: AppModel, size: CGSize, name: String,
        composeChildren: Bool = false,
        prepare: ((NSWindow) async throws -> Void)? = nil,
        extra: ((NSWindow, String) async throws -> Void)? = nil
    ) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingController(rootView: view.environment(model))
            host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = []  // keep the window at its real size from the first layout, as SwiftUI scenes do
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.setContentSize(size)
            window.orderFrontRegardless()
            // Let SwiftUI lay out, run onAppear tasks and settle.
            try await Task.sleep(for: .seconds(2))  // never RunLoop.run: it blocks the main actor, so SwiftUI layout stalls
            if let prepare {
                try await prepare(window)
                try await Task.sleep(for: .seconds(0.8))
            }
            // Real window-server output: cacheDisplay doesn't draw macOS 26 toolbar glass correctly
            // (it produced phantom shapes). Capturing our own window needs no Screen Recording permission.
            var image = try #require(Self.captureWindow(window.windowNumber))
            if composeChildren, let children = window.childWindows, !children.isEmpty {
                image = Self.composite(image, frame: window.frame, children: children) ?? image
            }
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            try await extra?(window, suffix)
            if suffix == "light" { AccessibilityAudit.audit(window, name: name) }
            // Hide, don't close: closing a connection window (correctly) closes its workspace,
            // and these renders reuse one live connection.
            window.orderOut(nil)
        }
    }

    /// Polls `condition` (on the main actor) until it holds or `timeout` passes.
    private func waitUntil(_ timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }

    private static func findView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews { if let found = findView(type, in: sub) { return found } }
        return nil
    }

    /// A WordPress-like fixture in `querywell_test`: idempotent, safe to run on every snapshot run.
    private func createWordPressFixture(_ session: any DatabaseSession) async throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS wp_users (
              ID bigint unsigned NOT NULL AUTO_INCREMENT,
              user_login varchar(60) NOT NULL DEFAULT '',
              user_email varchar(100) NOT NULL DEFAULT '',
              display_name varchar(250) NOT NULL DEFAULT '',
              user_registered datetime NOT NULL DEFAULT '2020-01-01 00:00:00',
              PRIMARY KEY (ID), KEY user_login_key (user_login)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE IF NOT EXISTS wp_posts (
              ID bigint unsigned NOT NULL AUTO_INCREMENT,
              post_author bigint unsigned NOT NULL DEFAULT 0,
              post_date datetime NOT NULL DEFAULT '2020-01-01 00:00:00',
              post_content longtext,
              post_title text,
              post_status varchar(20) NOT NULL DEFAULT 'publish',
              post_name varchar(200) NOT NULL DEFAULT '',
              post_modified datetime NOT NULL DEFAULT '2020-01-01 00:00:00',
              post_type varchar(20) NOT NULL DEFAULT 'post',
              PRIMARY KEY (ID), KEY post_name (post_name(191)),
              KEY type_status_date (post_type, post_status, post_date, ID), KEY post_author (post_author),
              CONSTRAINT fk_posts_author FOREIGN KEY (post_author) REFERENCES wp_users (ID) ON DELETE CASCADE ON UPDATE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE IF NOT EXISTS wp_postmeta (
              meta_id bigint unsigned NOT NULL AUTO_INCREMENT,
              post_id bigint unsigned NOT NULL DEFAULT 0,
              meta_key varchar(255) DEFAULT NULL,
              meta_value longtext,
              PRIMARY KEY (meta_id), KEY post_id (post_id), KEY meta_key (meta_key(191))
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE IF NOT EXISTS qw_legacy_myisam (
              id int NOT NULL AUTO_INCREMENT, body text, PRIMARY KEY (id), FULLTEXT KEY body_ft (body)
            ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3
            """,
            """
            CREATE TABLE IF NOT EXISTS qw_legacy_utf8 (
              id int NOT NULL AUTO_INCREMENT, label varchar(255) DEFAULT NULL, PRIMARY KEY (id), KEY label_idx (label)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3
            """,
            "REPLACE INTO wp_users (ID, user_login, user_email, display_name, user_registered) VALUES "
                + "(1, 'jeremy', 'jeremy@example.com', 'Jeremy Haber', '2019-03-02 10:00:00'), "
                + "(2, 'admin', 'admin@example.com', 'Site Admin', '2018-01-15 09:30:00'), "
                + "(3, 'editor', 'editor@example.com', 'Ed Itor', '2021-07-09 14:12:00')",
        ]
        for sql in statements { _ = try await session.execute(sql) }

        let titles = ["Home", "About", "Services", "Contact", "Privacy Policy", "Pricing", "Case Studies", "Careers", "FAQ",
                      "Book a Call", "Terms", "Thank You", "Our Team", "Press", "Partners", "Blog", "Support", "Docs", "Status", "Roadmap"]
        let statuses = ["publish", "publish", "publish", "draft", "private", "publish", "trash", "publish", "publish", "draft"]
        var posts: [String] = []
        for i in 0..<50 {
            let id = 1038 + i * 2
            let title = titles[i % titles.count] + (i >= titles.count ? " \(i / titles.count + 1)" : "")
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let author = [1, 1, 2, 1, 3][i % 5]
            let day = 1 + (i * 3) % 27
            let month = 5 + (i % 6)
            let type = i % 7 == 0 ? "post" : "page"
            let content = i % 4 == 0 ? "<!-- wp:heading -->\n<h2>What we do</h2>\n<!-- /wp:heading -->" : "Lorem ipsum \(i)"
            posts.append("(\(id), \(author), '2026-\(String(format: "%02d", month))-\(String(format: "%02d", day)) 09:00:00', '\(content)', '\(title)', "
                + "'\(statuses[i % statuses.count])', '\(slug)', '2026-\(String(format: "%02d", month))-\(String(format: "%02d", day)) 12:\(String(format: "%02d", i)):00', '\(type)')")
        }
        _ = try await session.execute(
            "REPLACE INTO wp_posts (ID, post_author, post_date, post_content, post_title, post_status, post_name, post_modified, post_type) VALUES "
                + posts.joined(separator: ", "))
        var meta: [String] = []
        for i in 0..<120 {
            meta.append("(\(i + 1), \(1038 + (i % 50) * 2), '\(["_edit_last", "_wp_page_template", "_thumbnail_id"][i % 3])', 'v\(i)')")
        }
        _ = try await session.execute("REPLACE INTO wp_postmeta (meta_id, post_id, meta_key, meta_value) VALUES " + meta.joined(separator: ", "))
        try await createOptionsFixture(session)
        _ = try await session.execute("ANALYZE TABLE wp_users, wp_posts, wp_postmeta")
    }

    // MARK: wp_options fixture

    static let oldSite = "http://old.example.com"
    static let newSite = "https://new.example.org"

    /// `s:N:"…";` with the byte length PHP would write.
    static func phpString(_ s: String) -> String { "s:\(s.utf8.count):\"\(s)\";" }
    static func phpArray(_ pairs: [(String, String)]) -> String {
        "a:\(pairs.count):{" + pairs.map { phpString($0.0) + $0.1 }.joined() + "}"
    }
    static func phpBools(_ names: [String], _ value: Bool = true) -> String {
        phpArray(names.map { ($0, "b:\(value ? 1 : 0);") })
    }

    /// A `wp_user_roles`-like option value.
    static var userRoles: String {
        func role(_ name: String, _ caps: String) -> String { phpArray([("name", phpString(name)), ("capabilities", caps)]) }
        return phpArray([
            ("administrator", role("Administrator", phpBools(["switch_themes", "edit_themes", "activate_plugins", "edit_plugins", "edit_users", "manage_options"]))),
            ("editor", role("Editor", phpBools(["moderate_comments", "edit_posts", "publish_posts", "edit_others_posts"]))),
            ("author", role("Author", phpBools(["edit_posts", "publish_posts", "upload_files"]))),
            ("subscriber", role("Subscriber", phpBools(["read"]) )),
            ("customer", role("Customer", phpArray([("read", "b:1;"), ("purchase", "b:0;"), ("credit_limit", "d:250.5;"), ("tier", "i:2;"), ("manager", "N;")]))),
        ])
    }

    static var themeJSON: String {
        """
        {
          "version": 2,
          "siteurl": "http:\\/\\/old.example.com",
          "settings": {
            "color": {
              "custom": true,
              "palette": [
                {"slug": "primary", "color": "#2459D6"},
                {"slug": "accent", "color": "#6A3FC2"}
              ]
            },
            "layout": {"contentSize": "720px", "wideSize": "1100px"}
          },
          "logo": "http:\\/\\/old.example.com\\/wp-content\\/logo.svg",
          "tags": ["wordpress", "theme", "json"],
          "enabled": true,
          "ratio": 1.5,
          "parent": null
        }
        """
    }

    /// Serialized widget with the old URL inside, so a replace has to fix `s:N:` lengths.
    static var widgetText: String {
        phpArray([
            ("title", phpString("Visit our old site")),
            ("text", phpString("<a href=\"\(oldSite)/about\">About us at \(oldSite)</a>")),
            ("filter", "b:1;"),
        ])
    }

    /// `s:12:"…"` declared shorter than the bytes: malformed on purpose.
    static var brokenWidget: String {
        "a:2:{s:5:\"title\";s:4:\"Home\";s:3:\"url\";s:12:\"\(oldSite)/home\";}"
    }

    /// `wp_options`, `wp_usermeta` and `wp_links` with serialized, JSON and plain values. Idempotent.
    private func createOptionsFixture(_ session: any DatabaseSession) async throws {
        let q = { (s: String) in SQLDialect(.mysql).quoteString(s) }
        let ddl = [
            """
            CREATE TABLE IF NOT EXISTS wp_options (
              option_id bigint unsigned NOT NULL AUTO_INCREMENT,
              option_name varchar(191) NOT NULL DEFAULT '',
              option_value longtext NOT NULL,
              autoload varchar(20) NOT NULL DEFAULT 'yes',
              PRIMARY KEY (option_id), UNIQUE KEY option_name (option_name)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE IF NOT EXISTS wp_usermeta (
              umeta_id bigint unsigned NOT NULL AUTO_INCREMENT,
              user_id bigint unsigned NOT NULL DEFAULT 0,
              meta_key varchar(255) DEFAULT NULL,
              meta_value longtext,
              PRIMARY KEY (umeta_id), KEY user_id (user_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
            """
            CREATE TABLE IF NOT EXISTS wp_links (
              link_id bigint unsigned NOT NULL AUTO_INCREMENT,
              link_url varchar(255) NOT NULL DEFAULT '',
              link_name varchar(255) NOT NULL DEFAULT '',
              PRIMARY KEY (link_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """,
        ]
        for sql in ddl { _ = try await session.execute(sql) }
        _ = try await session.execute("DELETE FROM wp_options")
        let options: [(Int, String, String, String)] = [
            (1, "siteurl", Self.oldSite, "yes"),
            (2, "home", Self.oldSite, "yes"),
            (3, "blogname", "Old Example Studio", "yes"),
            (4, "wp_user_roles", Self.userRoles, "yes"),
            (5, "widget_text", Self.widgetText, "yes"),
            (6, "theme_mods_json", Self.themeJSON, "yes"),
            (7, "_transient_feed_3f1c", Self.phpArray([("url", Self.phpString(Self.oldSite + "/feed")), ("items", "i:12;")]), "no"),
            (8, "legacy_widget", Self.brokenWidget, "no"),
            (9, "timezone_string", "Europe/Berlin", "yes"),
        ]
        let rows = options.map { "(\($0.0), \(q($0.1)), \(q($0.2)), \(q($0.3)))" }.joined(separator: ", ")
        _ = try await session.execute("REPLACE INTO wp_options (option_id, option_name, option_value, autoload) VALUES " + rows)
        _ = try await session.execute("DELETE FROM wp_usermeta")
        let meta: [(Int, Int, String, String)] = [
            (1, 1, "nickname", "jeremy"),
            (2, 1, "wp_capabilities", Self.phpBools(["administrator"])),
            (3, 1, "dashboard_links", Self.phpArray([("title", Self.phpString("Old website")), ("url", Self.phpString(Self.oldSite))])),
        ]
        _ = try await session.execute("REPLACE INTO wp_usermeta (umeta_id, user_id, meta_key, meta_value) VALUES "
            + meta.map { "(\($0.0), \($0.1), \(q($0.2)), \(q($0.3)))" }.joined(separator: ", "))
        _ = try await session.execute("DELETE FROM wp_links")
        _ = try await session.execute("REPLACE INTO wp_links (link_id, link_url, link_name) VALUES "
            + "(1, \(q(Self.oldSite + "/blog")), 'Blog'), (2, 'https://wordpress.org/', 'WordPress')")
    }

    /// `CGWindowListCreateImage`, resolved at runtime: it's deprecated and warnings are errors.
    private static func captureWindow(_ windowNumber: Int) -> CGImage? {
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let imageOptionBoundsIgnoreFraming: UInt32 = 1 << 0
        return capture(.null, optionIncludingWindow, UInt32(windowNumber), imageOptionBoundsIgnoreFraming)?
            .takeRetainedValue()
    }

    /// Draws child windows (autocomplete popup) onto the window capture at their on-screen positions.
    private static func composite(_ base: CGImage, frame: NSRect, children: [NSWindow]) -> CGImage? {
        let scale = CGFloat(base.width) / frame.width
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for child in children where child.isVisible {
            guard let image = captureWindow(child.windowNumber) else { continue }
            let f = child.frame
            ctx.draw(image, in: CGRect(x: (f.minX - frame.minX) * scale, y: (f.minY - frame.minY) * scale,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return ctx.makeImage()
    }

    /// Hosts `view` in a window of `width` and reports whether the toolbar shows its overflow button.
    private func toolbarOverflows<V: View>(_ view: V, model: AppModel, width: CGFloat) async throws -> Bool {
        let host = NSHostingController(rootView: view.environment(model))
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = []  // keep the window at its real size from the first layout, as SwiftUI scenes do
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 700))
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1.5))  // never RunLoop.run: it blocks the main actor, so SwiftUI layout stalls
        defer { window.orderOut(nil) }  // see render(): don't close, it ends the workspace
        if let image = Self.captureWindow(window.windowNumber),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try png.write(to: outputDirectory.appendingPathComponent("toolbar-\(Int(width)).png"))
        }
        func visibleIndicator(_ v: NSView) -> Bool {
            if String(describing: type(of: v)).contains("ClippedItemsIndicator"), !v.isHiddenOrHasHiddenAncestor, v.alphaValue > 0 {
                return true
            }
            return v.subviews.contains(where: visibleIndicator)
        }
        return visibleIndicator(try #require(window.contentView?.superview))
    }

    @Test func launcher() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await seed(model)
        try await render(LauncherView(), model: model, size: CGSize(width: 1000, height: 660), name: "launcher")
    }

    @Test func connectionEditor() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let profile = try #require(model.profile(id: id))
        let draft = ConnectionDraft(profile: profile, secrets: try model.loadSecrets(for: profile))
        try await render(ConnectionEditorView(draft: draft, isNew: false), model: model,
                   size: CGSize(width: 620, height: 900), name: "editor")
    }

    @Test func connectionWindowConnectsForReal() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        await workspace.connect()
        guard case .connected(let info, _) = workspace.state else {
            Issue.record("expected connected, got \(workspace.state)")
            return
        }
        #expect(info.engine == .mysql)
        #expect(workspace.databases.contains("querywell_test"))
        try await createWordPressFixture(try #require(workspace.live?.session))
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "wp_posts" } == true }
        #expect(workspace.browser.current?.tables.map(\.ref.name).contains("wp_posts") == true)

        workspace.openTable(TableRef(schema: "querywell_test", name: "wp_users"))
        workspace.openTable(TableRef(schema: "querywell_test", name: "wp_postmeta"))
        workspace.tabs.newQuery()
        workspace.openTable(TableRef(schema: "querywell_test", name: "wp_posts"))
        let postsTab = try #require(workspace.tabs.selectedTab)
        let posts = try #require(workspace.tableModel(forTab: postsTab))
        posts.pageSizeChanged(500)
        let size = CGSize(width: 1200, height: 760)

        // Data (light + dark).
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "connection-window")
        try await waitUntil { posts.content != nil }
        #expect(posts.content?.rows.count == 50)
        #expect(posts.pageInfo.label == "Rows 1–50 of 50 (exact)")
        workspace.browser.select("wp_posts", command: false, shift: false, visible: ["wp_posts"])
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "table-data",
                         prepare: { window in
            if let table = Self.findView(GridTableView.self, in: window.contentView!) { table.selectRowIndexes([2], byExtendingSelection: false) }
        })

        // Inspector open on a row, focused on one field.
        posts.inspectorFocusColumn = "post_content"
        posts.inspectorVisible = true
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "table-inspector",
                         prepare: { window in
            if let table = Self.findView(GridTableView.self, in: window.contentView!) { table.selectRowIndexes([0], byExtendingSelection: false) }
        })
        posts.inspectorVisible = false

        // An active chip filter plus the funnel popover for post_status.
        posts.upsertFilter(ColumnFilter(column: "post_status", op: .isAnyOf([.text("publish")])))
        posts.upsertFilter(ColumnFilter(column: "post_type", op: .isAnyOf([.text("page")])))
        try await waitUntil { posts.content != nil && !posts.isLoading }
        #expect(posts.filters.filters.count == 2)
        #expect((posts.content?.rows.count ?? 0) > 0 && (posts.content?.rows.count ?? 0) < 50)
        posts.showSQL = true
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "table-filtered")
        posts.showSQL = false
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "table-funnel",
                         prepare: { _ in posts.requestFilter(column: "post_status") },
                         extra: { window, suffix in
            let popoverWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
            #expect(popoverWindow != nil, "the funnel popover should be showing")
            if let popoverWindow, let image = Self.captureWindow(popoverWindow.windowNumber),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: outputDirectory.appendingPathComponent("table-funnel-popover-\(suffix).png"))
            }
            popoverWindow?.orderOut(nil)
            _ = window
        })
        posts.clearFilters()
        try await waitUntil { posts.content?.rows.count == 50 }

        // Structure, indexes and relations.
        for (mode, name) in [(TableViewMode.structure, "table-structure"), (.indexes, "table-indexes"), (.relations, "table-relations")] {
            posts.mode = mode
            try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: name)
        }
        #expect(posts.structure?.foreignKeys.first?.referenced.name == "wp_users")
        posts.mode = .data
        // Foreign-key navigation opens the referenced table filtered to the key.
        posts.followForeignKey(column: "post_author", row: 0)
        let usersModel = try #require(workspace.tableModel(forTable: TableRef(schema: "querywell_test", name: "wp_users")))
        try await waitUntil { usersModel.content != nil && usersModel.filters.filters.count == 1 && !usersModel.isLoading }
        #expect(usersModel.content?.rows.count == 1)
        workspace.openTable(TableRef(schema: "querywell_test", name: "wp_posts"))
        workspace.tabs.select(id: postsTab.id)
        workspace.tabs.openConsole()
        workspace.tabs.select(id: postsTab.id)
        // The toolbar must fit without AppKit's overflow ("»") button at any supported width.
        for width in [1200.0, 1000, 820] {
            #expect(try await toolbarOverflows(ConnectionWindowView(workspaceID: workspaceID), model: model, width: width) == false,
                    "toolbar overflowed at \(width)pt")
        }
        // focusExisting: a second connect for the same profile focuses instead of opening.
        #expect(await model.connect(profileID: id) == nil)
        await model.closeWorkspace(id: workspaceID)
        #expect(workspace.live == nil || workspace.isClosed)
    }

    // MARK: Editing UI

    /// Hosts `view` in a key window so sheet-style controls render as they do for the user.
    private func renderSheet<V: View>(_ view: V, model: AppModel, size: CGSize, name: String) async throws {
        try await render(view.frame(width: size.width, height: size.height), model: model, size: size, name: name,
                         prepare: { window in window.makeKeyAndOrderFront(nil) })
    }

    @Test func editingScreensAndEndToEndCommit() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        await workspace.connect()
        let session = try #require(workspace.live?.session)
        try await createWordPressFixture(session)
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "qw_legacy_myisam" } == true }
        workspace.gate.confirmationHandler = { _ in true }  // tests bypass the sheet

        // --- End to end: edit, commit, verify in the database. ---
        let schema = "querywell_test"
        workspace.openTable(TableRef(schema: schema, name: "wp_users"))
        let users = try #require(workspace.tableModel(forTable: TableRef(schema: schema, name: "wp_users")))
        users.loadIfNeeded(epoch: workspace.connectionEpoch)
        try await waitUntil { users.content != nil && !users.isLoading }
        let row = try #require(users.content?.rows.firstIndex { $0[0] == .unsignedInteger(3) || $0[0] == .integer(3) })
        let original = try #require(users.content?.rows[row][3])
        _ = try await session.execute("UPDATE wp_users SET display_name = 'Ed Itor' WHERE ID = 3")
        users.reload()
        try await waitUntil { !users.isLoading && users.content?.rows[row][3] == .text("Ed Itor") }
        #expect(users.applyText(displayRow: row, column: "display_name", text: "Edited by Querywell") == nil)
        #expect(users.pendingEditCount == 1)
        let report = await users.commit()
        #expect(report?.isSuccess == true)
        var check = try await session.execute("SELECT display_name FROM wp_users WHERE ID = 3")
        #expect(check.rows.first?.first == .text("Edited by Querywell"))

        // Conflict: someone else changes the row between load and commit.
        try await waitUntil { !users.isLoading && users.content?.rows[row][3] == .text("Edited by Querywell") }
        #expect(users.applyText(displayRow: row, column: "display_name", text: "Mine") == nil)
        _ = try await session.execute("UPDATE wp_users SET display_name = 'Theirs' WHERE ID = 3")
        let conflict = await users.commit()
        #expect(conflict?.status == .conflict)
        #expect(conflict?.headline.contains("was changed by someone else") == true)
        check = try await session.execute("SELECT display_name FROM wp_users WHERE ID = 3")
        #expect(check.rows.first?.first == .text("Theirs"))
        #expect(users.hasPendingChanges)
        users.discardAll()
        _ = try await session.execute("UPDATE wp_users SET display_name = 'Ed Itor' WHERE ID = 3")
        _ = original

        // --- Screens. ---
        workspace.openTable(TableRef(schema: schema, name: "wp_posts"))
        let posts = try #require(workspace.tableModel(forTable: TableRef(schema: schema, name: "wp_posts")))
        posts.loadIfNeeded(epoch: workspace.connectionEpoch)
        try await waitUntil { posts.content?.rows.count == 50 && !posts.isLoading }
        workspace.browser.select("wp_posts", command: false, shift: false, visible: ["wp_posts"])
        let titleRow = 1
        #expect(posts.applyText(displayRow: titleRow, column: "post_title", text: "Services (updated)") == nil)
        #expect(posts.applyText(displayRow: 2, column: "post_status", text: "draft") == nil)
        posts.deleteRows([4])
        posts.addRow()
        #expect(posts.applyText(displayRow: 0, column: "post_title", text: "Brand new page") == nil)
        posts.editRequest = nil
        #expect(posts.pendingEditCount == 4)
        let size = CGSize(width: 1700, height: 760)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "edit-grid", prepare: { window in
            if let table = Self.findView(GridTableView.self, in: window.contentView!) { table.selectRowIndexes([2], byExtendingSelection: false) }
        })

        posts.inspectorFocusColumn = "post_type"
        posts.inspectorVisible = true
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "edit-inspector", prepare: { window in
            if let table = Self.findView(GridTableView.self, in: window.contentView!) { table.selectRowIndexes([2], byExtendingSelection: false) }
        })
        posts.inspectorVisible = false

        try await renderSheet(ReviewChangesSheet(model: posts) {}, model: model, size: CGSize(width: 660, height: 640), name: "edit-review")

        // A failed commit shows the explanation inside the sheet.
        posts.commitReport = CommitReport(
            status: .conflict, headline: "Row ID 1040 was changed by someone else since you loaded it — nothing was saved.",
            detail: "Reload the table to see the current values, or discard your edits. Your pending edits are still here.",
            statement: "UPDATE `querywell_test`.`wp_posts` SET `post_title` = 'Services (updated)' WHERE `ID` = 1040 AND `post_title` = 'About'")
        try await renderSheet(ReviewChangesSheet(model: posts) {}, model: model, size: CGSize(width: 660, height: 700), name: "edit-review-conflict")
        posts.commitReport = nil
        posts.discardAll()

        // Destructive PROD confirmation with real dry-run counts and the typed-name field.
        let decision = try #require(workspace.gate.decision(
            for: ["TRUNCATE TABLE `querywell_test`.`wp_postmeta`", "DELETE FROM `querywell_test`.`wp_posts` WHERE post_status = 'trash'"],
            escalateToDestructive: true, database: schema))
        guard case .confirm(let request) = decision else { Issue.record("expected confirm"); return }
        let results = await DryRunExecutor.run(request.dryRuns, on: session)
        #expect(results.first?.count == 120)
        try await renderSheet(
            WriteConfirmationSheet(request: request, session: session, actionTitle: "Run 2 statements", initialResults: results) { _ in },
            model: model, size: CGSize(width: 560, height: 560), name: "confirm-destructive-prod")

        // Batch operations: MyISAM and utf8mb3 fixtures with a plan and warnings.
        let infos = try await SchemaInspectorFactory.inspector(for: session).listTables(schema: schema)
            .filter { ["qw_legacy_myisam", "qw_legacy_utf8", "wp_users", "wp_posts"].contains($0.ref.name) }
        let batch = BatchOperationsModel(
            schema: schema, tables: infos, server: session.serverInfo,
            inspector: SchemaInspectorFactory.inspector(for: session), session: session, gate: workspace.gate)
        await batch.loadMetadata()
        #expect(batch.skipReasons[TableRef(schema: schema, name: "wp_users")] == "Already InnoDB")
        #expect(batch.statementCount == 1)
        #expect(batch.plan?.warnings.isEmpty == false)
        try await renderSheet(BatchOperationsSheet(model: batch) {}, model: model, size: CGSize(width: 740, height: 680), name: "batch-engine")
        batch.operation = .convert
        try await renderSheet(BatchOperationsSheet(model: batch) {}, model: model, size: CGSize(width: 740, height: 680), name: "batch-convert")
        #expect(batch.plan?.statements.contains { $0.contains("qw_legacy_utf8") } == true)

        await model.closeWorkspace(id: workspaceID)
    }

    // MARK: Query editor

    @Test func queryEditorScreensAgainstDocker() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        await workspace.connect()
        let session = try #require(workspace.live?.session)
        try await createWordPressFixture(session)
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "wp_posts" } == true }
        let schema = "querywell_test"
        let size = CGSize(width: 1200, height: 760)

        // History from "earlier": written before the run so the new statements are newest.
        let history = model.queryServices.history(for: id)
        let day: TimeInterval = 86_400
        for entry in [
            HistoryEntry(sql: "SELECT option_name, LENGTH(option_value) FROM wp_options ORDER BY 2 DESC", ranAt: Date().addingTimeInterval(-day * 3), rowCount: 50),
            HistoryEntry(sql: "DELETE FROM wp_options WHERE option_name LIKE '_transient_%'", ranAt: Date().addingTimeInterval(-day * 1.1), affected: 412),
            HistoryEntry(sql: "SELECT * FROM wp_users", ranAt: Date().addingTimeInterval(-day * 1.05), rowCount: 18),
            HistoryEntry(sql: "SHOW PROCESSLIST", ranAt: Date().addingTimeInterval(-3_600), rowCount: 6),
            HistoryEntry(sql: "SELECT post_titel FROM wp_posts", ranAt: Date().addingTimeInterval(-1_800), error: "Unknown column 'post_titel' in 'field list'"),
            HistoryEntry(sql: "UPDATE wp_options SET option_value = 'x' WHERE option_name = 'blogname'", ranAt: Date().addingTimeInterval(-900), affected: 1),
        ] { try await history.record(entry) }
        _ = try await model.queryServices.savedQueries.save(
            name: "Pages edited this month", sql: "SELECT p.ID, p.post_title FROM wp_posts p WHERE p.post_type = 'page'", connectionID: id,
            notes: "With author", tags: ["wp", "content"])
        _ = try await model.queryServices.savedQueries.save(
            name: "Autoloaded options by size", sql: "SELECT option_name, LENGTH(option_value) AS bytes FROM wp_options WHERE autoload = 'yes' ORDER BY bytes DESC LIMIT 20",
            connectionID: nil, tags: ["perf"])
        _ = try await model.queryServices.snippets.add(name: "Drafts by author", sql: "SELECT * FROM ${1:wp_posts} WHERE post_status = 'draft' AND post_author = ${2:1}$0", tags: ["wp"])

        // --- Two-statement script: results, messages, editable hint. ---
        let script = """
        -- Pages edited this month, with author
        SELECT p.ID, p.post_title, p.post_modified, u.display_name
        FROM wp_posts p
        JOIN wp_users u ON u.ID = p.post_author
        WHERE p.post_type = 'page'
          AND p.post_modified >= NOW() - INTERVAL 30 DAY
        ORDER BY p.post_modified DESC;

        SELECT COUNT(*) FROM wp_posts WHERE post_status = 'draft';
        """
        workspace.tabs.newQuery()
        let q = try #require(workspace.currentQueryModel)
        q.text = script
        q.selection = NSRange(location: (script as NSString).length, length: 0)
        await q.run(.all)
        #expect(q.results.count == 2)
        #expect(q.results[0].title.hasPrefix("Result 1 · "))
        #expect(q.results[1].title == "Result 2 · 1 row")
        #expect(q.guardHint == .none || q.guardHint == .readOnlyQuery)
        try await waitUntil { q.results.allSatisfy { $0.verdict != nil } }
        #expect(q.results[0].verdict?.reason == "Joins two tables")
        workspace.queryLibrary.segment = .history
        await workspace.queryLibrary.reload()
        #expect(workspace.queryLibrary.history.count >= 8)

        q.selected = .result(q.results[0].id)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-results")
        q.selected = .result(q.results[1].id)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-result2")
        q.selected = .messages
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-messages")

        // --- An editable single-table result. ---
        workspace.tabs.newQuery()
        let e = try #require(workspace.currentQueryModel)
        e.text = "SELECT ID, user_login, display_name FROM wp_users ORDER BY ID"
        await e.run(.all)
        try await waitUntil { e.results.first?.editModel?.content != nil && e.results.first?.editModel?.isLoading == false }
        #expect(e.results.first?.verdict?.info?.table == TableRef(schema: schema, name: "wp_users"))
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-editable")
        workspace.tabs.close(id: try #require(workspace.tabs.selectedID))
        workspace.tabs.select(id: try #require(workspace.tabs.tabs.first { $0.id == workspace.tabs.tabs[0].id }?.id))

        // --- Sidebar segments. ---
        workspace.queryLibrary.segment = .saved
        await workspace.queryLibrary.reload()
        #expect(workspace.queryLibrary.saved.count == 2)
        q.selected = .result(q.results[0].id)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-saved")
        workspace.queryLibrary.segment = .snippets
        await workspace.queryLibrary.reload()
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-snippets")
        workspace.queryLibrary.segment = .history

        // --- Explain. ---
        q.selection = NSRange(location: 60, length: 0)
        await q.explain()
        guard case .done(let outcome) = q.explainState else { Issue.record("explain failed: \(q.explainState)"); return }
        #expect(outcome.plan.root.flattened.contains { $0.table != nil })
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-explain")

        // --- Error highlight (squiggle + messages). ---
        workspace.tabs.newQuery()
        let bad = try #require(workspace.currentQueryModel)
        bad.text = "SELECT ID, post_titel\nFROM wp_posts\nWHERE post_status = 'draft'"
        await bad.run(.all)
        #expect(bad.lastError?.message.contains("post_titel") == true)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-error", prepare: { window in
            if let tv = Self.findView(SQLEditorTextView.self, in: window.contentView!) { tv.setDiagnostics(bad.editor.textView == nil ? [] : [EditorDiagnostic(range: NSRange(location: 0, length: (bad.text as NSString).length), message: bad.lastError?.message ?? "")]) }
        })

        // --- Autocomplete after `wp_posts p WHERE p.`. ---
        workspace.tabs.newQuery()
        let c = try #require(workspace.currentQueryModel)
        c.text = "SELECT *\nFROM wp_posts p\nWHERE p."
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-autocomplete", composeChildren: true, prepare: { window in
            window.makeKeyAndOrderFront(nil)
            guard let tv = Self.findView(SQLEditorTextView.self, in: window.contentView!) else { return }
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (c.text as NSString).length, length: 0))
            tv.requestCompletion(force: true)
            try await Task.sleep(for: .seconds(1.5))
        })
        c.editor.textView?.hideCompletion()
        workspace.tabs.close(id: try #require(workspace.tabs.selectedID))
        workspace.tabs.select(id: try #require(workspace.tabs.tabs.first?.id))

        // --- AI panel with a mocked streamed answer. ---
        model.updateSettings { $0.ai.provider = .anthropic }
        #expect(model.setAIAPIKey("sk-test-not-real", provider: .anthropic))
        let answer = [
            "Pages edited in the last 30 days, newest first. ",
            "I joined `wp_users` for the author name.\n\n```sql\nSELECT p.ID, p.post_title, p.post_modified, u.display_name\n",
            "FROM wp_posts p\nJOIN wp_users u ON u.ID = p.post_author\n",
            "WHERE p.post_type = 'page'\n  AND p.post_modified >= NOW() - INTERVAL 30 DAY\nORDER BY p.post_modified DESC\nLIMIT 100;\n```",
        ]
        q.assistantProviderOverride = { MockAIProvider(chunks: answer) }
        q.showsAssistant = true
        q.assistant.providerID = .anthropic
        q.assistant.hasKey = true
        q.assistant.prompt = "Which pages were edited in the last 30 days, with the author's name?"
        // The view wires the assistant on appear; perform after the first render pass wired it.
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-ai-empty")
        await q.assistant.perform(.generate)
        #expect(q.assistant.latestSQL?.hasPrefix("SELECT p.ID") == true)
        #expect(q.assistant.reviewWarnings.isEmpty)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-ai")
        q.assistantProviderOverride = { MockAIProvider(chunks: ["Marks old drafts as trashed. Check the preview first.\n\n```sql\nSELECT ID, post_title FROM wp_posts WHERE post_status = 'draft' AND post_date < NOW() - INTERVAL 1 YEAR;\n\nUPDATE wp_posts SET post_status = 'trash'\nWHERE post_status = 'draft' AND post_date < NOW() - INTERVAL 1 YEAR;\n```"]) }
        q.assistant.prompt = "Trash drafts older than a year"
        await q.assistant.perform(.generate)
        #expect(q.assistant.reviewWarnings.contains { $0.contains("writes") })
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "query-ai-write")
        // Insert never runs: the editor changes, the database does not.
        let before = try await session.execute("SELECT COUNT(*) FROM wp_posts WHERE post_status = 'trash'").rows.first?.first
        q.assistant.insert()
        let after = try await session.execute("SELECT COUNT(*) FROM wp_posts WHERE post_status = 'trash'").rows.first?.first
        #expect(before == after)
        #expect(q.text.contains("UPDATE wp_posts SET post_status = 'trash'"))

        await model.closeWorkspace(id: workspaceID)
    }

    // MARK: Data editors and search & replace

    @Test func dataEditorsAndSearchReplace() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        await workspace.connect()
        let session = try #require(workspace.live?.session)
        try await createWordPressFixture(session)
        workspace.refreshSchema()
        try await waitUntil { workspace.browser.current?.tables.contains { $0.ref.name == "wp_options" } == true }
        workspace.gate.confirmationHandler = { _ in true }  // tests bypass the confirmation sheet
        let schema = "querywell_test"

        func optionValue(_ name: String) async throws -> String {
            let r = try await session.execute("SELECT option_value FROM wp_options WHERE option_name = '\(name)'")
            guard case .text(let s)? = r.rows.first?.first else { return "" }
            return s
        }

        // --- Value editor: JSON tree with an edit (size footer), then Raw with an error banner. ---
        let theme = try await optionValue("theme_mods_json")
        #expect(theme == Self.themeJSON)
        let json = ValueEditorModel(
            title: "wp_options · option_value", subtitle: "option_id 6 · longtext", data: Data(theme.utf8), isReadOnly: false,
            onSave: { _ in nil })
        #expect(json.mode == .json)
        json.json.selection = "0.2"
        #expect(json.json.commitValue(id: "0.0", text: "3") == nil)
        json.json.add(to: "root", type: "string")
        #expect(json.hasChanges && json.canSave)
        try await renderSheet(ValueEditorView(model: json), model: model, size: CGSize(width: 900, height: 640), name: "editor-json-tree")

        let broken = Self.themeJSON.replacingOccurrences(of: "\"wideSize\": \"1100px\"", with: "\"wideSize\": \"1100px\"\n    \"extra\": 1")
        let invalid = ValueEditorModel(
            title: "wp_options · option_value", subtitle: "option_id 6 · longtext", data: Data(broken.utf8), isReadOnly: false,
            onSave: { _ in nil })
        invalid.json.jumpToError()
        #expect(invalid.json.error != nil && !invalid.canSave)
        try await renderSheet(ValueEditorView(model: invalid), model: model, size: CGSize(width: 900, height: 640), name: "editor-json-raw-error")

        // --- Value editor: PHP serialized (wp_user_roles-like), edited. ---
        let roles = try await optionValue("wp_user_roles")
        #expect(roles == Self.userRoles)
        let php = ValueEditorModel(
            title: "wp_options · option_value", subtitle: "option_id 4 · longtext", data: Data(roles.utf8), isReadOnly: false,
            onSave: { _ in nil })
        #expect(php.mode == .php && php.detectedMode == .php)
        php.php.collapseAll()
        php.php.toggle("0")
        php.php.toggle("0.1")
        php.php.toggle("4")
        php.php.toggle("4.1")
        #expect(php.php.commitValue(id: "4.1.2", text: "300.25") == nil)
        php.php.selection = "4.1.2"
        #expect(php.php.footer.hasPrefix("Will save"))
        try await renderSheet(ValueEditorView(model: php), model: model, size: CGSize(width: 900, height: 700), name: "editor-php")

        // Malformed: parser error with byte offset, repair offered with a preview first.
        let malformed = ValueEditorModel(
            title: "wp_options · option_value", subtitle: "option_id 8 · longtext", data: Data(Self.brokenWidget.utf8), isReadOnly: false,
            onSave: { _ in nil })
        #expect(malformed.php.parseError != nil)
        try await renderSheet(ValueEditorView(model: malformed), model: model, size: CGSize(width: 900, height: 560), name: "editor-php-malformed")
        #expect(malformed.php.proposeRepair() == nil)
        let proposal = try #require(malformed.php.repairProposal)
        #expect(!proposal.fixes.isEmpty && !malformed.php.isValid)
        try await renderSheet(PHPRepairPreview(proposal: proposal, accept: {}, cancel: {}), model: model,
                              size: CGSize(width: 600, height: 300), name: "editor-php-repair")

        // --- Search & Replace against the real database. ---
        workspace.browser.select("wp_options", command: false, shift: false, visible: ["wp_options"])
        workspace.presentSearchReplace()
        let sr = try #require(workspace.searchReplace)
        try await waitUntil { !sr.isLoadingTables && sr.tables.contains { $0.name == "wp_options" } }
        await sr.waitForStructures()
        #expect(sr.wordPressPrefix == "wp_")
        #expect(sr.selected.contains(TableRef(schema: schema, name: "wp_options")))
        #expect(!sr.selected.contains(TableRef(schema: schema, name: "qw_legacy_myisam")))
        sr.search = Self.oldSite
        sr.replace = Self.newSite
        let size = CGSize(width: 1060, height: 760)
        try await renderSheet(SearchReplaceSheet(model: sr) {}, model: model, size: size, name: "search-replace-configure")

        await sr.runPreview()
        let preview = try #require(sr.previewReport)
        #expect(preview.mode == .dryRun)
        #expect(preview.rowsChanged == 7)
        #expect(preview.replacements == 9)
        #expect(preview.invalidSerialized.map(\.column) == ["option_value"])
        #expect(preview.invalidSerialized.first?.primaryKey.first?.value == "8")
        #expect(preview.tables.filter { $0.rowsChanged > 0 }.count == 3)
        #expect(try await optionValue("home") == Self.oldSite, "a dry run must not write")
        #expect(sr.previewIsCurrent && sr.canApply)
        #expect(sr.applySummary == "Will update 7 rows in 3 tables")
        try await renderSheet(SearchReplaceSheet(model: sr) {}, model: model, size: size, name: "search-replace-preview")

        // Changing an option invalidates the preview.
        sr.caseSensitive = false
        #expect(!sr.previewIsCurrent && !sr.canApply)
        sr.caseSensitive = true
        #expect(sr.canApply)

        // An invalid serialized value opens in the PHP editor on its table (via the open table tab).
        let location = try #require(preview.invalidSerialized.first)
        workspace.openInvalidSerialized(location)
        let optionsModel = try #require(workspace.tableModel(forTable: TableRef(schema: schema, name: "wp_options")))
        try await waitUntil(.seconds(20)) { optionsModel.valueEditor != nil }
        let handed = try #require(optionsModel.valueEditor)
        #expect(handed.mode == .php && handed.php.parseError != nil)
        #expect(handed.php.proposeRepair() == nil)
        #expect(!handed.canSave, "a repair is only a proposal until accepted")
        handed.php.acceptRepair()
        #expect(handed.canSave && handed.php.isValid)
        #expect(handed.save())
        #expect(optionsModel.pendingEditCount == 1)
        #expect(optionsModel.valueEditor == nil)
        optionsModel.discardAll()
        let untouchedBroken = try await optionValue("legacy_widget")
        #expect(untouchedBroken == Self.brokenWidget, "saving into the grid does not write to the database")
        workspace.searchReplacePresented = false

        // Apply.
        workspace.presentSearchReplace()
        try await waitUntil { !sr.isLoadingTables && sr.tables.contains { $0.name == "wp_options" } }
        await sr.waitForStructures()
        #expect(sr.search == Self.oldSite, "the last pair is remembered for the connection")
        await sr.runPreview()
        sr.beginApply()
        #expect(sr.confirmingApply)
        try await renderSheet(SearchReplaceSheet(model: sr) {}, model: model, size: size, name: "search-replace-confirm")
        await sr.confirmApply()
        let applied = try #require(sr.applyReport)
        #expect(applied.mode == .apply)
        #expect(applied.rowsChanged == 7 && applied.conflicts.isEmpty && applied.failedTables.isEmpty)
        #expect(try await optionValue("home") == Self.newSite)
        let widget = try await optionValue("widget_text")
        let parsed = try PHPSerializedParser.parse(widget)  // throws if any s:N: length is wrong
        #expect(parsed.root.entries.count == 3)
        #expect(widget.contains(Self.newSite + "/about"))
        let themeAfter = try await optionValue("theme_mods_json")
        #expect(themeAfter.contains("https:\\/\\/new.example.org\\/wp-content\\/logo.svg"), "JSON keeps its escaped slashes")
        #expect(try await optionValue("legacy_widget") == Self.brokenWidget, "invalid serialized values are never touched")
        try await renderSheet(SearchReplaceSheet(model: sr) {}, model: model, size: size, name: "search-replace-applied")

        // Put the fixture back for the next run.
        try await createOptionsFixture(session)
        await model.closeWorkspace(id: workspaceID)
    }
}
