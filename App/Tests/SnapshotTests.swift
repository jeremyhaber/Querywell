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
            let image = try #require(Self.captureWindow(window.windowNumber))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            try await extra?(window, suffix)
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
        _ = try await session.execute("ANALYZE TABLE wp_users, wp_posts, wp_postmeta")
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
}
