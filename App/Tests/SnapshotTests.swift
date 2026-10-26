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
@Suite("Snapshots", .enabled(if: ProcessInfo.processInfo.environment["QUERYWELL_SNAPSHOTS"] == "1"))
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

    private func render<V: View>(_ view: V, model: AppModel, size: CGSize, name: String) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingController(rootView: view.environment(model))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.setContentSize(size)
            window.orderFrontRegardless()
            // Let SwiftUI lay out, run onAppear tasks and settle.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let target = window.contentView?.superview ?? window.contentView!
            let rep = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func launcher() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await seed(model)
        try render(LauncherView(), model: model, size: CGSize(width: 1000, height: 660), name: "launcher")
    }

    @Test func connectionEditor() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try await seed(model)
        let profile = try #require(model.profile(id: id))
        let draft = ConnectionDraft(profile: profile, secrets: try model.loadSecrets(for: profile))
        try render(ConnectionEditorView(draft: draft, isNew: false), model: model,
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
        try render(ConnectionWindowView(workspaceID: workspaceID), model: model,
                   size: CGSize(width: 1200, height: 760), name: "connection-window")
        // focusExisting: a second connect for the same profile focuses instead of opening.
        #expect(await model.connect(profileID: id) == nil)
        await model.closeWorkspace(id: workspaceID)
        #expect(workspace.live == nil || workspace.isClosed)
    }
}
