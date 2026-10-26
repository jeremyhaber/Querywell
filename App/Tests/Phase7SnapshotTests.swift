import AppKit
import Foundation
import QuerywellCore
import SwiftUI
import SwiftTerm
import Testing
@testable import Querywell

/// Phase 7 screens against the Docker servers: console, export dialog (over the SSH bastion), import scan,
/// SSH terminal, and an export → import round trip. Opt-in like the other snapshots (`scripts/snapshots.sh`).
@MainActor
@Suite("Phase 7 snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOTS"] == "1"))
struct Phase7SnapshotTests {
    private let outputDirectory: URL = {
        let env = ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOT_DIR"]
        let url = URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath + "/build/snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Harness

    private func makeModel() async throws -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuerywellP7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Throw-away known_hosts so tests never touch (or break on) the user's.
        let knownHosts = dir.appendingPathComponent("known_hosts").path
        let options = SSHClientOptions(knownHostsFile: knownHosts, useUserSSHConfig: false)
        let store = InMemorySecretStore()
        let opener = ConnectionOpener(secretStore: store, tunnelProvider: SystemSSHTunnelProvider(options: options))
        let model = AppModel(directory: dir, secretStore: store, opener: opener)
        await model.load()
        sshOptions = options
        return (model, dir)
    }

    private var sshOptions: SSHClientOptions {
        get { Self.sharedSSHOptions.value }
        nonmutating set { Self.sharedSSHOptions.value = newValue }
    }

    private final class OptionsBox: @unchecked Sendable {
        // @unchecked Sendable: only touched from the main actor in these tests.
        var value = SSHClientOptions()
    }
    private static let sharedSSHOptions = OptionsBox()

    private func draft(_ name: String, _ engine: DatabaseEngine, port: Int, tag: ColorTag?, user: String = "querywell",
                       password: String = "querywell_pw", database: String? = "querywell_test",
                       ssh: Bool = false) -> ConnectionDraft {
        var d = ConnectionDraft(newFor: engine)
        d.name = name
        d.colorTag = tag
        d.host = "127.0.0.1"
        d.portText = String(port)
        d.user = user
        d.databasePassword = password
        d.defaultDatabase = database ?? ""
        if ssh {
            d.host = "mysql8"
            d.portText = "3306"
            d.useSSH = true
            d.sshHost = "127.0.0.1"
            d.sshPortText = "12222"
            d.sshUser = "querywell"
            d.sshAuth = .password
            d.sshSecret = "querywell_ssh_pw"
        }
        return d
    }

    private func open(_ model: AppModel, _ name: String) async throws -> (UUID, ConnectionWorkspace) {
        let id = try #require(model.library.profiles.first { $0.name == name }?.id)
        let workspaceID = try #require(await model.connect(profileID: id))
        let workspace = try #require(model.workspaces[workspaceID])
        workspace.tools.sshOptions = sshOptions
        await workspace.connect()
        try #require(workspace.isConnected, "connect \(name): \(workspace.state)")
        return (workspaceID, workspace)
    }

    private func render<V: View>(_ view: V, model: AppModel, size: CGSize, name: String,
                                 composeChildren: Bool = false, wait: Duration = .seconds(2),
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
            try await Task.sleep(for: wait)
            if let prepare {
                try await prepare(window)
                try await Task.sleep(for: .seconds(0.8))
            }
            var image = try #require(Self.captureWindow(window.windowNumber))
            if composeChildren, let children = window.childWindows, !children.isEmpty {
                image = Self.composite(image, frame: window.frame, children: children) ?? image
            }
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }

    private func renderSheet<V: View>(_ view: V, model: AppModel, width: CGFloat, height: CGFloat, name: String) async throws {
        try await render(view.frame(width: width, height: height), model: model, size: CGSize(width: width, height: height), name: name)
    }

    private func waitUntil(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }

    private static func captureWindow(_ windowNumber: Int) -> CGImage? {
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        return capture(.null, 1 << 3, UInt32(windowNumber), 1 << 0)?.takeRetainedValue()
    }

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

    /// `qw7_options` (WordPress-style, with transients) and `qw7_posts`, idempotent.
    private func createFixture(_ session: any DatabaseSession) async throws {
        _ = try await session.execute("CREATE TABLE IF NOT EXISTS qw7_options (option_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, option_name VARCHAR(191) NOT NULL, option_value LONGTEXT NOT NULL, autoload VARCHAR(20) NOT NULL DEFAULT 'yes') DEFAULT CHARSET=utf8mb4")
        _ = try await session.execute("CREATE TABLE IF NOT EXISTS qw7_posts (ID BIGINT NOT NULL PRIMARY KEY, post_title TEXT NOT NULL, post_status VARCHAR(20) NOT NULL) DEFAULT CHARSET=utf8mb4")
        _ = try await session.execute("DELETE FROM qw7_options")
        _ = try await session.execute("DELETE FROM qw7_posts")
        var rows: [String] = []
        for i in 1...412 { rows.append("(\(i), '_transient_qw7_\(i)', 'v\(i)', 'no')") }
        for (i, name) in ["siteurl", "blogname", "home", "admin_email"].enumerated() { rows.append("(\(1000 + i), '\(name)', 'x\(i)', 'yes')") }
        _ = try await session.execute("INSERT INTO qw7_options (option_id, option_name, option_value, autoload) VALUES " + rows.joined(separator: ","))
        let posts = (1...60).map { "(\($0), 'Post \($0) ünïcode', '\($0 % 3 == 0 ? "draft" : "publish")')" }
        _ = try await session.execute("INSERT INTO qw7_posts (ID, post_title, post_status) VALUES " + posts.joined(separator: ","))
    }

    // MARK: Console

    @Test func consoleScreens() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft("Docker MySQL (PROD)", .mysql, port: 13306, tag: .production))
        let (workspaceID, workspace) = try await open(model, "Docker MySQL (PROD)")
        let session = try #require(workspace.live?.session)
        try await createFixture(session)
        workspace.tabs.openConsole()
        let tab = try #require(workspace.tabs.selectedTab)
        let console = try #require(workspace.consoleModel(forTab: tab))
        await console.startIfNeeded()
        // The confirmation sheet is its own test; here the user cancels, as in the "Cancelled." path.
        workspace.gate.confirmationHandler = { request in
            #expect(request.requiresTypedName == "querywell_test")
            return false
        }
        await console.submit("SELECT table_name, engine, table_rows FROM information_schema.tables WHERE table_name LIKE 'qw7%';")
        await console.submit("SELECT COUNT(*) FROM qw7_options WHERE option_name LIKE '\\_transient\\_%';")
        await console.submit("SELECT option_nam FROM qw7_options;")
        await console.submit("DELETE FROM qw7_options WHERE option_name LIKE '\\_transient\\_%';")
        #expect(console.scrollback.contains { $0.plainText == "Cancelled." })
        let remaining = try await session.execute("SELECT COUNT(*) FROM qw7_options WHERE option_name LIKE '\\_transient\\_%'")
        #expect(remaining.rows.first?.first == .integer(412), "cancelled writes must not run")
        console.edit { $0.insert("DELETE FROM qw7_options WHERE option_name LIKE '_transient_%';") }
        let size = CGSize(width: 1200, height: 760)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: size, name: "console", wait: .seconds(3))
        await model.closeWorkspace(id: workspaceID)
    }

    // MARK: Export

    @Test func exportDialogOverSSHAndRoundTrip() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft("Docker MySQL via SSH", .mysql, port: 3306, tag: .production, ssh: true))
        _ = await model.save(draft("Docker MySQL root", .mysql, port: 13306, tag: nil, user: "root", password: "root_pw", database: "querywell_test"))
        let (viaSSHID, viaSSH) = try await open(model, "Docker MySQL via SSH")
        let (rootID, root) = try await open(model, "Docker MySQL root")
        let rootSession = try #require(root.live?.session)
        try await createFixture(rootSession)
        viaSSH.refreshSchema()
        try await waitUntil { viaSSH.browser.current?.tables.contains { $0.ref.name == "qw7_options" } == true }

        await viaSSH.presentExport()
        let sheet = try #require(viaSSH.tools.exportSheet)
        await sheet.load(inspector: viaSSH.browser.inspector)
        #expect(sheet.location == .remoteOverSSH)
        #expect(sheet.isWordPress, "qw7_options looks like a WordPress options table")
        #expect(sheet.commandPreview.contains("ssh"))
        #expect(!sheet.commandPreview.contains("querywell_pw"))
        sheet.selectedTables = ["qw7_options", "qw7_posts"]
        sheet.skipTransients = true
        sheet.collationChoice = .mysql57

        try await renderSheet(ExportSheetView(model: sheet, onClose: {}), model: model, width: 760, height: 720, name: "export-dialog")
        sheet.location = .localThroughTunnel
        try await renderSheet(ExportSheetView(model: sheet, onClose: {}), model: model, width: 760, height: 720, name: "export-dialog-local")
        sheet.location = .remoteOverSSH
        sheet.previewRunning(.init(currentTable: "qw7_posts", tableIndex: 1, tableTotal: 2, bytes: 41_000_000))
        try await renderSheet(ExportSheetView(model: sheet, onClose: {}), model: model, width: 760, height: 720, name: "export-progress")
        sheet.endPreview()

        // Real run: export over SSH (the dump runs on the bastion), then import into a fresh schema.
        let out = dir.appendingPathComponent("round-trip.sql.gz")
        sheet.chooseDestination(out)
        sheet.skipTransients = false
        sheet.collationChoice = .keep
        await sheet.run()
        guard case .finished(let summary) = sheet.runState else { Issue.record("export: \(sheet.runState)"); return }
        #expect(summary.tables.contains("qw7_options") && summary.bytesWritten > 0)
        try await renderSheet(ExportSheetView(model: sheet, onClose: {}), model: model, width: 760, height: 720, name: "export-done")

        _ = try await rootSession.execute("DROP DATABASE IF EXISTS qw7_import_target")
        _ = try await rootSession.execute("CREATE DATABASE qw7_import_target")
        root.refreshSchema()
        root.gate.confirmationHandler = { _ in true }
        root.presentImport(file: out)
        let imp = try #require(root.tools.importSheet)
        imp.targetSchema = "qw7_import_target"
        await imp.loadAndScan()
        await imp.start()
        #expect(imp.phase == .finished, "import: \(imp.phase) \(imp.errors.first?.message ?? "")")
        #expect(imp.report?.succeeded == true)
        for table in ["qw7_options", "qw7_posts"] {
            let a = try await rootSession.execute("SELECT COUNT(*) FROM querywell_test.\(table)")
            let b = try await rootSession.execute("SELECT COUNT(*) FROM qw7_import_target.\(table)")
            #expect(a.rows.first?.first == b.rows.first?.first, "\(table) row counts match")
            #expect(a.rows.first?.first != .integer(0))
        }
        let unicode = try await rootSession.execute("SELECT post_title FROM qw7_import_target.qw7_posts WHERE ID = 1")
        #expect(unicode.rows.first?.first == .text("Post 1 ünïcode"))
        _ = try await rootSession.execute("DROP DATABASE IF EXISTS qw7_import_target")
        _ = viaSSHID; _ = rootID
        await model.closeWorkspace(id: viaSSHID)
        await model.closeWorkspace(id: rootID)
    }

    // MARK: Import scan against MariaDB

    @Test func importSheetShowsUnsupportedCollationScan() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft("Docker MySQL 8.4", .mysql, port: 13306, tag: .local))
        let (workspaceID, workspace) = try await open(model, "Docker MySQL 8.4")
        let sql = """
        -- MariaDB dump 10.19  Distrib 11.4.2-MariaDB, for debian-linux-gnu (x86_64)
        DROP TABLE IF EXISTS `qw7_imported`;
        CREATE TABLE `qw7_imported` (
          `id` int(11) NOT NULL,
          `title` varchar(100) COLLATE utf8mb4_uca1400_ai_ci DEFAULT NULL,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;
        INSERT INTO `qw7_imported` VALUES (1,'one'),(2,'two'),(3,'utf8mb4_uca1400_ai_ci in data stays');
        """
        let file = dir.appendingPathComponent("site-backup.sql")
        try sql.write(to: file, atomically: true, encoding: .utf8)
        workspace.gate.confirmationHandler = { _ in true }
        workspace.presentImport(file: file)
        let imp = try #require(workspace.tools.importSheet)
        await imp.loadAndScan()
        guard case .done(let scan) = imp.scan else { Issue.record("scan: \(imp.scan)"); return }
        #expect(scan.unsupportedCollations.contains("utf8mb4_uca1400_ai_ci"), "MySQL 8.4 has no MariaDB uca1400 collations (MariaDB 11.4.5+ does accept the MySQL 0900 names)")
        #expect(imp.collationChoice == .suggested)
        try await renderSheet(ImportSheetView(model: imp, onClose: {}), model: model, width: 680, height: 640, name: "import-scan")
        await imp.start()
        #expect(imp.phase == .finished && imp.report?.succeeded == true, "\(imp.phase) \(imp.errors.first?.message ?? "")")
        #expect(imp.report?.collationRewrites ?? 0 > 0)
        let session = try #require(workspace.live?.session)
        let count = try await session.execute("SELECT COUNT(*) FROM qw7_imported")
        #expect(count.rows.first?.first == .integer(3))
        let data = try await session.execute("SELECT title FROM qw7_imported WHERE id = 3")
        #expect(data.rows.first?.first == .text("utf8mb4_uca1400_ai_ci in data stays"), "data is never rewritten")
        try await renderSheet(ImportSheetView(model: imp, onClose: {}), model: model, width: 680, height: 640, name: "import-done")
        _ = try await session.execute("DROP TABLE IF EXISTS qw7_imported")
        await model.closeWorkspace(id: workspaceID)
    }

    // MARK: Terminal

    @Test func sshTerminalShowsAShellPrompt() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft("Docker MySQL via SSH", .mysql, port: 3306, tag: .production, ssh: true))
        let (workspaceID, workspace) = try await open(model, "Docker MySQL via SSH")
        workspace.openTerminal()
        let tab = try #require(workspace.tabs.selectedTab)
        let terminal = try #require(workspace.terminalModel(forTab: tab))
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: CGSize(width: 1200, height: 760),
                         name: "terminal", wait: .seconds(2), prepare: { _ in
            try await waitUntil { terminal.isRunning }
            try await Task.sleep(for: .seconds(4))
            terminal.terminalView.send(txt: "uname -a; echo $0\n")
            try await Task.sleep(for: .seconds(1.5))
            let text = String(decoding: terminal.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
            #expect(text.contains("Linux"), "terminal output: \(text.prefix(300))")
        })
        terminal.close()
        await model.closeWorkspace(id: workspaceID)
    }

    @Test func terminalUnavailableWithoutSSH() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await model.save(draft("Docker MySQL 8.4", .mysql, port: 13306, tag: .local))
        let (workspaceID, workspace) = try await open(model, "Docker MySQL 8.4")
        workspace.openTerminal()
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model, size: CGSize(width: 1200, height: 760), name: "terminal-unavailable")
        await model.closeWorkspace(id: workspaceID)
    }

    // MARK: Result export

    @Test func resultExportSheet() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = QueryResult(columns: [ColumnInfo(name: "ID", typeName: "bigint"), ColumnInfo(name: "post_title", typeName: "varchar")],
                                 rows: (1...24).map { [.integer(Int64($0)), .text("Post \($0)")] })
        let export = ResultExportModel(source: .result(result), name: "Result 1", engine: .mysql, schema: "wp", tableName: "wp_posts")
        try await renderSheet(ResultExportSheet(model: export, onClose: {}), model: model, width: 480, height: 340, name: "result-export")
    }
}
