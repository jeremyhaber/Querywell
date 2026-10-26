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

    private func render<V: View>(_ view: V, model: AppModel, size: CGSize, name: String) async throws {
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
            // Real window-server output: cacheDisplay doesn't draw macOS 26 toolbar glass correctly
            // (it produced phantom shapes). Capturing our own window needs no Screen Recording permission.
            let image = try #require(Self.captureWindow(window.windowNumber))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            // Hide, don't close: closing a connection window (correctly) closes its workspace,
            // and these renders reuse one live connection.
            window.orderOut(nil)
        }
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
        workspace.tabs.newQuery()
        workspace.tabs.openTable(database: "querywell_test", name: "wp_posts")
        workspace.tabs.openConsole()
        workspace.tabs.select(id: workspace.tabs.tabs[1].id)
        try await render(ConnectionWindowView(workspaceID: workspaceID), model: model,
                   size: CGSize(width: 1200, height: 760), name: "connection-window")
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
}
