import AppKit
import Foundation
import QuerywellCore
import SwiftUI
import Testing
@testable import Querywell

/// 1M-row table through the real model and grid (needs `scripts/perf-data.sh`). Opt-in:
/// `TEST_RUNNER_QUERYWELL_PERF=1 xcodebuild … -only-testing:QuerywellTests/GridPerfTests test`. Prints `PERF …`.
@MainActor
@Suite("Grid perf (1M rows)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["QUERYWELL_PERF"] == "1"))
struct GridPerfTests {
    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// Longest time the main actor went without running a 5 ms ticker while `body` ran.
    private func maxStall(_ body: () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        var last = clock.now
        var worst = 0.0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = clock.now
                worst = max(worst, ms(now - last) - 5)
                last = now
            }
        }
        try await body()
        ticker.cancel()
        return worst
    }

    private func wait(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("model paging and 10k-row grid", arguments: [(DatabaseEngine.mysql, 13306), (DatabaseEngine.postgresql, 15432)])
    func bigTable(_ target: (DatabaseEngine, Int)) async throws {
        let (engine, port) = target
        let config = ConnectionConfiguration(engine: engine, host: "127.0.0.1", port: port, user: "querywell", password: "querywell_pw",
                                             database: "querywell_test", tls: TLSConfig(mode: .disabled))
        let session = try await DriverRegistry.driver(for: engine).connect(config)
        let aux = { try await DriverRegistry.driver(for: engine).connect(config) }
        let model = TableDataModel(table: TableRef(schema: "qw_perf", name: "big_posts"))
        model.sessionProvider = { session }
        model.auxSessionOpener = { try await aux() }
        let clock = ContinuousClock()
        let tag = engine == .mysql ? "mysql" : "postgres"
        func step(_ label: String, _ action: () -> Void) async throws {
            let t0 = clock.now
            action()
            try await wait { !model.isLoading && model.hasLoaded }
            print("PERF [\(tag)] \(label): \(String(format: "%.0f", ms(clock.now - t0))) ms (\(model.pageInfo.label))")
        }
        // First page: structure + 500 rows, count async.
        let t0 = clock.now
        model.loadIfNeeded(epoch: 1)
        try await wait { model.content != nil && !model.isLoading }
        print("PERF [\(tag)] open table, first page visible: \(String(format: "%.0f", ms(clock.now - t0))) ms")
        try await wait { if case .exact = model.count { true } else { false } }
        print("PERF [\(tag)] exact count arrived after: \(String(format: "%.0f", ms(clock.now - t0))) ms (\(model.count))")
        #expect(model.keysetOrder != nil)
        try await step("next page") { model.nextPage() }
        try await step("last page (keyset)") { model.lastPage() }
        #expect(model.content?.rows.count == 500)
        #expect(model.pageInfo.lastRow == 1_000_000)
        try await step("previous page") { model.previousPage() }
        try await step("first page") { model.firstPage() }
        try await step("sort by indexed post_author") { model.toggleSort(column: "post_author", additive: false) }
        try await step("last page sorted by post_author") { model.lastPage() }
        try await step("sort DESC by ID") {
            model.toggleSort(column: "post_author", additive: false)
            model.toggleSort(column: "post_author", additive: false)
            model.toggleSort(column: "ID", additive: false)
            model.toggleSort(column: "ID", additive: false)
        }
        // Slow sort: stop it.
        model.toggleSort(column: "ID", additive: false)
        try await wait { !model.isLoading }
        let slow = clock.now
        model.toggleSort(column: "post_content", additive: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.isLoading)
        let stallStop = clock.now
        model.stopLoading()
        print("PERF [\(tag)] Stop on slow sort: UI idle again after \(String(format: "%.0f", ms(clock.now - stallStop))) ms (loading \(String(format: "%.0f", ms(clock.now - slow))) ms in)")
        #expect(!model.isLoading && model.sort.isEmpty)
        // Next request right after Stop is not stuck behind the killed statement.
        let after = clock.now
        model.reload()
        try await wait { !model.isLoading && model.hasLoaded }
        print("PERF [\(tag)] page request right after Stop: \(String(format: "%.0f", ms(clock.now - after))) ms")

        // 10,000-row page through the real grid.
        model.pageSize = 10_000
        let host = NSHostingController(rootView: GridHarness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .seconds(1))
        let stall = try await maxStall {
            let t = clock.now
            model.reload()
            try await wait { !model.isLoading && model.content?.rows.count == 10_000 }
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            print("PERF [\(tag)] 10k-row page: network+decode+display \(String(format: "%.0f", ms(clock.now - t))) ms")
        }
        print("PERF [\(tag)] 10k-row page arrival: longest main-thread stall \(String(format: "%.0f", stall)) ms")
        let scroll = try #require(Self.find(NSScrollView.self, in: window.contentView!))
        var worstFrame = 0.0
        for i in 0..<60 {
            let t = clock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i) * 2_000))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.displayIfNeeded()
            worstFrame = max(worstFrame, ms(clock.now - t))
        }
        print("PERF [\(tag)] scrolling 120k px through the 10k-row page: slowest frame \(String(format: "%.1f", worstFrame)) ms")
        window.orderOut(nil)
        await session.close()
    }

    private static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}

private struct GridHarness: View {
    let model: TableDataModel
    var body: some View {
        DataGridView(
            content: model.content, sort: model.sort, filteredColumns: [], nullDisplay: "NULL", showsColumnTypes: true,
            table: model.table, dialect: model.dialect ?? SQLDialect(.mysql), filterRequest: nil,
            filterPopoverContent: { _, _ in nil }, actions: GridActions(), focusToken: 0, editRequest: nil)
    }
}
