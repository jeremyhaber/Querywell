import AppKit
import QuerywellCore
import SwiftUI
import Testing
@testable import Querywell

/// Docker-free accessibility audit: hosts real screens in a window and walks the NSAccessibility tree,
/// failing on any button, image, checkbox, field or popup without a label. (The Docker-backed snapshot
/// suites run the same audit on the connection window, editors, sheets and tabs.)
@MainActor
@Suite("Accessibility", .serialized)
struct AccessibilityTests {
    private func makeModel() async throws -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuerywellA11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(directory: dir, secretStore: InMemorySecretStore())
        await model.load()
        return (model, dir)
    }

    private func seed(_ model: AppModel) async {
        for (name, engine, tag) in [("prod web", DatabaseEngine.mariadb, ColorTag.production), ("staging", .mysql, .staging), ("local pg", .postgresql, .local)] {
            var d = ConnectionDraft(newFor: engine)
            d.name = name; d.colorTag = tag; d.host = "127.0.0.1"; d.user = "u"; d.databasePassword = "p"
            _ = await model.save(d)
        }
    }

    /// Hosts `view`, lets SwiftUI settle, audits, and returns the stats.
    private func audit<V: View>(_ view: V, model: AppModel, size: CGSize, name: String, expectElements: Int = 5) async throws {
        NSApp.setAccessibilityEnabled(true)  // SwiftUI only builds its accessibility tree once an AX client is active
        let host = NSHostingController(rootView: view.environment(model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1.5))
        var stats = AccessibilityAudit.Stats()
        let found = AccessibilityAudit.findings(in: try #require(window.contentView), stats: &stats, dump: ProcessInfo.processInfo.environment["QUERYWELL_A11Y_DUMP"] != nil)
        window.orderOut(nil)
        #expect(stats.elements >= expectElements, "\(name): the walk found only \(stats.elements) elements, so the audit isn't seeing the tree")
        #expect(found.isEmpty, Comment(rawValue: "\(name):\n" + found.joined(separator: "\n")))
    }

    @Test func launcher() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        await seed(model)
        try await audit(LauncherView(), model: model, size: CGSize(width: 1000, height: 660), name: "launcher")
    }

    @Test func connectionEditor() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let draft = ConnectionDraft(newFor: .mysql)
        try await audit(ConnectionEditorView(draft: draft, isNew: true), model: model, size: CGSize(width: 620, height: 900), name: "editor")
    }

    @Test func settings() async throws {
        let (model, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await audit(SettingsView().frame(width: 520, height: 420), model: model, size: CGSize(width: 520, height: 420), name: "settings")
    }
}
