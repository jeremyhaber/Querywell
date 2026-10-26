import Foundation
import Testing

@testable import QuerywellCore

/// 1M-row measurements against `qw_perf.big_posts` (create it with `scripts/perf-data.sh`).
/// Run with `QUERYWELL_PERF=1 swift test --filter PerfTests`; prints `PERF …` lines. Not part of CI.
private let perfEnabled = ProcessInfo.processInfo.environment["QUERYWELL_PERF"] == "1"

private func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // macOS reports bytes
}

private func currentRSSMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

private func timed<T>(_ label: String, _ target: DBTarget, _ body: () async throws -> T) async rethrows -> T {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    print("PERF [\(target.name)] \(label): \(String(format: "%.0f", ms(clock.now - start))) ms")
    return value
}

@Suite("Perf (1M rows)", .serialized, .enabled(if: perfEnabled))
struct PerfTests {
    static let targets: [DBTarget] = [.mysql8, .postgres16]

    private func table(_ target: DBTarget) -> TableRef { TableRef(schema: "qw_perf", name: "big_posts") }
    private func pk(_ target: DBTarget) -> [String] { [target.isPostgres ? "ID" : "ID"] }

    @Test("Open, count, paging, sort", arguments: targets)
    func paging(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let dialect = SQLDialect(session.engine)
        let inspector = SchemaInspectorFactory.inspector(for: session)
        let ref = table(target)
        let structure = try await timed("structure", target) { try await inspector.structure(of: ref) }
        let primaryKey = structure.primaryKey
        func q(sort: [SortKey] = [], offset: Int = 0, limit: Int = 500) -> TableQuery {
            TableQuery(table: ref, sort: sort, limit: limit, offset: offset, primaryKey: primaryKey)
        }
        _ = try await timed("page 1 (500 rows, ORDER BY PK)", target) { try await session.execute(q().sql(dialect: dialect)) }
        _ = try await timed("COUNT(*) exact", target) { try await session.execute(q().countSQL(dialect: dialect)) }
        _ = try await timed("page OFFSET 500", target) { try await session.execute(q(offset: 500).sql(dialect: dialect)) }
        _ = try await timed("page OFFSET 990000", target) { try await session.execute(q(offset: 990_000).sql(dialect: dialect)) }
        _ = try await timed("sort DESC by PK (first page)", target) {
            try await session.execute(q(sort: [SortKey(column: primaryKey[0], ascending: false)]).sql(dialect: dialect))
        }
        _ = try await timed("sort by indexed post_author", target) {
            try await session.execute(q(sort: [SortKey(column: "post_author")]).sql(dialect: dialect))
        }
        _ = try await timed("sort by NON-indexed post_name", target) {
            try await session.execute(q(sort: [SortKey(column: "post_name")]).sql(dialect: dialect))
        }
        _ = try await timed("page 10000 rows", target) { try await session.execute(q(limit: 10_000).sql(dialect: dialect)) }
        _ = try await timed("distinct post_status (low cardinality, unindexed)", target) {
            try await DistinctValuesQuery(table: ref, column: "post_status").run(on: session)
        }
        _ = try await timed("distinct post_name (high cardinality, unindexed)", target) {
            try await DistinctValuesQuery(table: ref, column: "post_name").run(on: session)
        }
        // Does a running COUNT(*) delay the next page on the same session?
        let clock = ContinuousClock()
        let countTask = Task { try await session.execute(q().countSQL(dialect: dialect)) }
        try await Task.sleep(for: .milliseconds(20))
        let t0 = clock.now
        _ = try await session.execute(q(offset: 500).sql(dialect: dialect))
        print("PERF [\(target.name)] next page while COUNT(*) in flight: \(String(format: "%.0f", ms(clock.now - t0))) ms")
        _ = try await countTask.value
        await session.close()
    }

    @Test("After: keyset paging, sampled distinct values, cancel, aux count", arguments: targets)
    func optimised(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let dialect = SQLDialect(session.engine)
        let inspector = SchemaInspectorFactory.inspector(for: session)
        let ref = table(target)
        let structure = try await inspector.structure(of: ref)
        let pk = structure.primaryKey
        func page(_ sort: [SortKey], _ keyset: KeysetPage) -> String {
            TableQuery(table: ref, sort: sort, limit: 500, primaryKey: pk, keyset: keyset).sql(dialect: dialect)
        }
        // Deep keyset page by PK: boundary = row 990,000.
        let order = try #require(structure.keysetOrder(for: []))
        _ = try await timed("keyset page after ID 990000 (was OFFSET 990000)", target) {
            try await session.execute(page([], KeysetPage(order: order, boundary: [.integer(990_000)])))
        }
        _ = try await timed("keyset LAST page (reverse order)", target) { try await session.execute(page([], KeysetPage(order: order, direction: .backward))) }
        let byAuthor = [SortKey(column: "post_author")]
        let authorOrder = try #require(structure.keysetOrder(for: byAuthor))
        _ = try await timed("keyset first page sorted by indexed post_author", target) { try await session.execute(page(byAuthor, KeysetPage(order: authorOrder))) }
        _ = try await timed("keyset page deep in post_author order (author 499)", target) {
            try await session.execute(page(byAuthor, KeysetPage(order: authorOrder, boundary: [.integer(499), .integer(999_000)])))
        }
        _ = try await timed("keyset LAST page sorted by post_author", target) {
            try await session.execute(page(byAuthor, KeysetPage(order: authorOrder, direction: .backward)))
        }
        // Distinct values with a 1.5 s limit and sample fallback, on their own session.
        let aux = try await target.connect()
        let distinct = try await timed("distinct post_name (limit 1.5 s, sample fallback)", target) {
            try await DistinctValuesQuery(table: ref, column: "post_name").run(
                on: aux, policy: DistinctValuesPolicy(estimatedRows: structure.info.estimatedRows))
        }
        print("PERF [\(target.name)]   -> sampledRows=\(String(describing: distinct.sampledRows)) values=\(distinct.values.count)")
        // A COUNT(*) on a second session does not delay the next page on the first.
        let clock = ContinuousClock()
        let countSession = try await target.connect()
        let countTask = Task { try await countSession.execute(TableQuery(table: ref).countSQL(dialect: dialect), interruptible: true) }
        try await Task.sleep(for: .milliseconds(20))
        let t0 = clock.now
        _ = try await session.execute(page([], KeysetPage(order: order, boundary: [.integer(500)])))
        print("PERF [\(target.name)] next page while COUNT(*) runs on the aux session: \(String(format: "%.0f", ms(clock.now - t0))) ms")
        _ = try await countTask.value
        // Stop on the slow non-indexed sort: statement aborted on the server.
        let slow = Task { try await session.execute(TableQuery(table: ref, sort: [SortKey(column: "post_content")], limit: 500, primaryKey: pk).sql(dialect: dialect), interruptible: true) }
        try await Task.sleep(for: .milliseconds(300))
        let t1 = clock.now
        slow.cancel()
        let outcome = await slow.result
        print("PERF [\(target.name)] Stop on ORDER BY post_content: \(String(format: "%.0f", ms(clock.now - t1))) ms to abort (\(outcome))")
        _ = try await session.execute("SELECT 1")
        await aux.close(); await countSession.close(); await session.close()
    }

    @Test("Query editor: 200k rows buffered", arguments: targets)
    func bigResult(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let before = currentRSSMegabytes()
        let result = try await timed("SELECT * LIMIT 200000", target) {
            try await session.execute("SELECT * FROM qw_perf.big_posts LIMIT 200000")
        }
        print("PERF [\(target.name)] 200k rows: \(result.rows.count) rows, RSS \(Int(before)) -> \(Int(currentRSSMegabytes())) MB")
        await session.close()
    }

    @Test("Export 1M rows to CSV", arguments: targets)
    func export(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let inspector = SchemaInspectorFactory.inspector(for: session)
        let ref = table(target)
        let structure = try await inspector.structure(of: ref)
        let query = TableQuery(table: ref, primaryKey: structure.primaryKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qw_perf_\(target.name).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try FileHandleSink(url: url)
        let before = currentRSSMegabytes()
        let progress = ProgressTicks()
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await ResultExporter.exportTable(
            query, session: session, format: .csv(CSVOptions()), to: sink, pageSize: 1000,
            onProgress: { progress.record($0, rss: currentRSSMegabytes()) })
        let seconds = Double(ms(clock.now - start)) / 1000
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        print("PERF [\(target.name)] export \(rows) rows: \(String(format: "%.1f", seconds)) s, \(size / 1_048_576) MB file, RSS \(Int(before)) MB -> max during run \(Int(progress.maxRSS)) MB, \(progress.count) progress callbacks")
        #expect(rows == 1_000_000)
        await session.close()
    }
}

final class ProgressTicks: @unchecked Sendable {  // test helper; guarded by a lock
    private let lock = NSLock()
    private var _max = 0.0, _count = 0
    func record(_ rows: Int, rss: Double) { lock.lock(); _max = max(_max, rss); _count += 1; lock.unlock() }
    var maxRSS: Double { lock.lock(); defer { lock.unlock() }; return _max }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}
