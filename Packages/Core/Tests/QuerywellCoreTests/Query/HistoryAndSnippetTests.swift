import Foundation
import Testing
import os

@testable import QuerywellCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("qw-hist-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private final class Clock: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date { lock.withLock { $0 } }
    func advance(days: Double) { lock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    var now: @Sendable () -> Date { { [self] in date } }
}

private func store(_ id: UUID = UUID(), _ dir: URL, _ r: HistoryRetention = .init(), clock: Clock = Clock()) -> QueryHistoryStore {
    QueryHistoryStore(connectionID: id, directory: dir, retention: r, now: clock.now)
}

@Suite("Query history")
struct QueryHistoryTests {
    @Test func defaults() {
        let r = HistoryRetention()
        #expect(r.maxEntries == 1_000 && r.maxAgeDays == 90 && r.maxFileBytes == 2 * 1024 * 1024 && r.maxStatementBytes == 64 * 1024)
    }

    @Test func recordsAndPersistsWithOwnerOnlyPermissions() async throws {
        let dir = tempDir(), id = UUID()
        let s = store(id, dir)
        try await s.record(HistoryEntry(sql: "SELECT 1", durationMs: 4, rowCount: 1, database: "shop"))
        try await s.record(HistoryEntry(sql: "UPDATE t SET a=1 WHERE b=2", affected: 3))
        let reopened = store(id, dir)
        let all = try await reopened.recent()
        #expect(all.map(\.sql) == ["UPDATE t SET a=1 WHERE b=2", "SELECT 1"])
        #expect(all[1].database == "shop" && all[1].rowCount == 1 && all[1].runCount == 1)
        let file = dir.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func countLimit() async throws {
        let dir = tempDir()
        let s = store(UUID(), dir, HistoryRetention(maxEntries: 5, compactEvery: 1_000))
        for i in 0..<12 { try await s.record(HistoryEntry(sql: "SELECT \(i)")) }
        let sqls = try await s.recent().map(\.sql)
        #expect(sqls == (7..<12).reversed().map { "SELECT \($0)" })
    }

    @Test func ageLimitWithInjectedClock() async throws {
        let dir = tempDir(), id = UUID(), clock = Clock()
        let s = store(id, dir, HistoryRetention(maxAgeDays: 90), clock: clock)
        try await s.record(HistoryEntry(sql: "SELECT 'old'", ranAt: clock.date))
        clock.advance(days: 60)
        try await s.record(HistoryEntry(sql: "SELECT 'mid'", ranAt: clock.date))
        clock.advance(days: 40)  // 'old' is now 100 days old, 'mid' 40
        // not compacted yet, but compaction at open applies the limit
        let reopened = store(id, dir, HistoryRetention(maxAgeDays: 90), clock: clock)
        #expect(try await reopened.recent().map(\.sql) == ["SELECT 'mid'"])
        // and so does the periodic compaction on append
        clock.advance(days: 60)  // mid is 100 days old
        try await reopened.updateRetention(HistoryRetention(maxAgeDays: 90))
        #expect(await reopened.count == 0)
    }

    @Test func ageCountsFromTheMostRecentRun() async throws {
        let dir = tempDir(), clock = Clock()
        let s = store(UUID(), dir, HistoryRetention(maxAgeDays: 30), clock: clock)
        try await s.record(HistoryEntry(sql: "SELECT 1", ranAt: clock.date))
        clock.advance(days: 25)
        try await s.record(HistoryEntry(sql: "SELECT 1", ranAt: clock.date))  // merged: lastRunAt bumps
        clock.advance(days: 25)
        try await s.updateRetention(HistoryRetention(maxAgeDays: 30))
        #expect(await s.count == 1)
    }

    @Test func byteSizeLimit() async throws {
        let dir = tempDir(), id = UUID()
        let limit = 8 * 1024
        let s = store(id, dir, HistoryRetention(maxEntries: 10_000, maxFileBytes: limit, maxStatementBytes: 4_096, compactEvery: 1_000))
        for i in 0..<40 { try await s.record(HistoryEntry(sql: "SELECT '\(String(repeating: "x", count: 900))', \(i)")) }
        let file = dir.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size <= limit, "file is \(size) bytes")
        let kept = try await s.recent()
        #expect(kept.count > 0 && kept.count < 40)
        #expect(kept.first!.sql.hasSuffix(", 39"))  // newest survives
        #expect(await s.totalBytes() == size)
    }

    @Test func giantStatementsAreTruncatedAndFlagged() async throws {
        let dir = tempDir()
        let s = store(UUID(), dir, HistoryRetention(maxStatementBytes: 1_024))
        let huge = "INSERT INTO t VALUES " + (0..<5_000).map { "(\($0),'é')" }.joined(separator: ",")
        let stored = try #require(try await s.record(HistoryEntry(sql: huge)))
        #expect(stored.isTruncated)
        #expect(stored.sql.utf8.count <= 1_024)
        #expect(huge.hasPrefix(stored.sql))
        #expect(stored.rerunScript == nil)
        #expect(stored.editorText.hasPrefix(stored.sql) && stored.editorText.contains("truncated"))
        let small = try #require(try await s.record(HistoryEntry(sql: "SELECT 1")))
        #expect(!small.isTruncated && small.rerunScript == "SELECT 1" && small.editorText == "SELECT 1")
        #expect(try await s.recent().first { $0.id == stored.id }?.isTruncated == true)
    }

    @Test func truncationNeverSplitsACharacter() {
        let (cut, did) = QueryHistoryStore.truncate(String(repeating: "😀", count: 100), toBytes: 10)
        #expect(did && cut == "😀😀" && cut.utf8.count == 8)
    }

    @Test func consecutiveDuplicatesBumpRunCount() async throws {
        let dir = tempDir(), clock = Clock()
        let s = store(UUID(), dir, clock: clock)
        let first = try #require(try await s.record(HistoryEntry(sql: "SELECT 1", ranAt: clock.date, durationMs: 5, rowCount: 1)))
        clock.advance(days: 1)
        let second = try #require(try await s.record(HistoryEntry(sql: "SELECT 1  ", ranAt: clock.date, durationMs: 9, rowCount: 2)))
        #expect(second.id == first.id && second.runCount == 2)
        #expect(second.ranAt == first.ranAt && second.lastRunAt == clock.date)
        #expect(second.durationMs == 9 && second.rowCount == 2)
        try await s.record(HistoryEntry(sql: "SELECT 2"))
        try await s.record(HistoryEntry(sql: "SELECT 1"))  // not consecutive: a new entry
        let all = try await s.recent()
        #expect(all.map(\.sql) == ["SELECT 1", "SELECT 2", "SELECT 1"])
        #expect(all.map(\.runCount) == [1, 1, 2])
    }

    @Test func dedupeSurvivesReopen() async throws {
        let dir = tempDir(), id = UUID()
        try await store(id, dir).record(HistoryEntry(sql: "SELECT 1"))
        try await store(id, dir).record(HistoryEntry(sql: "SELECT 1"))
        let all = try await store(id, dir).recent()
        #expect(all.count == 1 && all[0].runCount == 2)
    }

    @Test func secretsAreNeverStored() async throws {
        let dir = tempDir(), id = UUID()
        let s = store(id, dir)
        for sql in ["CREATE USER 'bob'@'%' IDENTIFIED BY 'hunter2'", "SET PASSWORD FOR 'bob' = PASSWORD('hunter2')",
                    "UPDATE wp_users SET user_pass = 'hunter2' WHERE ID = 1", "CREATE ROLE r PASSWORD 'hunter2'",
                    "ALTER USER x IDENTIFIED WITH mysql_native_password BY \"hunter2\""] {
            try await s.record(HistoryEntry(sql: sql, error: "bad PASSWORD('hunter2')"))
        }
        let file = dir.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("hunter2"))
        #expect(raw.contains("***"))
    }

    @Test func redactorKeepsStructure() {
        #expect(SecretRedactor.redact("CREATE USER a IDENTIFIED BY 'p''w'") == "CREATE USER a IDENTIFIED BY '***'")
        #expect(SecretRedactor.redact("select PASSWORD ( 'x' )") == "select PASSWORD ( '***' )")
        #expect(SecretRedactor.redact("SELECT 1 WHERE name = 'password'") == "SELECT 1 WHERE name = 'password'")
        #expect(SecretRedactor.redact("SELECT * FROM t") == "SELECT * FROM t")
    }

    @Test func searchSubstringThenFuzzy() async throws {
        let s = store(UUID(), tempDir())
        for sql in ["SELECT * FROM wp_posts", "SELECT * FROM wp_postmeta WHERE meta_key = 'x'", "SHOW TABLES", "UPDATE wp_options SET autoload='no' WHERE option_name='a'"] {
            try await s.record(HistoryEntry(sql: sql))
        }
        #expect(try await s.search("postmeta").map(\.sql) == ["SELECT * FROM wp_postmeta WHERE meta_key = 'x'"])
        #expect(try await s.search("WP_POSTS").count == 1)
        let fuzzy = try await s.search("upd opt")
        #expect(fuzzy.first?.sql.hasPrefix("UPDATE wp_options") == true)
        #expect(try await s.search("").count == 4)
        #expect(try await s.search("zzzzzz").isEmpty)
    }

    @Test func blankSqlAndDeleteAndClear() async throws {
        let s = store(UUID(), tempDir())
        #expect(try await s.record(HistoryEntry(sql: "  \n ")) == nil)
        let e = try #require(try await s.record(HistoryEntry(sql: "SELECT 1")))
        try await s.record(HistoryEntry(sql: "SELECT 2"))
        try await s.delete(id: e.id)
        #expect(try await s.recent().map(\.sql) == ["SELECT 2"])
        try await s.clear()
        #expect(await s.count == 0)
        try await s.record(HistoryEntry(sql: "SELECT 3"))
        #expect(await s.count == 1)
    }

    @Test func purgeAndClearAllAndTotalBytes() async throws {
        let dir = tempDir()
        let a = UUID(), b = UUID()
        try await store(a, dir).record(HistoryEntry(sql: "SELECT 'a'"))
        try await store(b, dir).record(HistoryEntry(sql: "SELECT 'b'"))
        #expect(QueryHistoryStore.totalBytes(directory: dir) > 10)
        try QueryHistoryStore.purge(connectionID: a, directory: dir)
        #expect(await store(a, dir).count == 0)
        #expect(await store(b, dir).count == 1)
        try QueryHistoryStore.purge(connectionID: UUID(), directory: dir)  // unknown id is fine
        let live = store(b, dir)
        try await live.purge()
        #expect(await live.count == 0)
        try await store(a, dir).record(HistoryEntry(sql: "SELECT 1"))
        try QueryHistoryStore.clearAll(directory: dir)
        #expect(QueryHistoryStore.totalBytes(directory: dir) == 0)
        #expect(await store(a, dir).count == 0)
    }

    @Test func tornLinesAreSkipped() async throws {
        let dir = tempDir(), id = UUID()
        try await store(id, dir).record(HistoryEntry(sql: "SELECT 1"))
        let file = dir.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sql\": \"half".utf8))
        try handle.close()
        #expect(try await store(id, dir).recent().map(\.sql) == ["SELECT 1"])
    }

    @Test func periodicCompactionRunsEveryNAppends() async throws {
        let dir = tempDir(), id = UUID(), clock = Clock()
        let s = store(id, dir, HistoryRetention(maxAgeDays: 10, compactEvery: 3), clock: clock)
        try await s.record(HistoryEntry(sql: "SELECT 'stale'", ranAt: clock.date))
        clock.advance(days: 20)
        try await s.record(HistoryEntry(sql: "SELECT 1", ranAt: clock.date))
        try await s.record(HistoryEntry(sql: "SELECT 2", ranAt: clock.date))  // third append -> compaction
        #expect(try await s.recent().map(\.sql) == ["SELECT 2", "SELECT 1"])
    }

    @Test func settingsCarryRetentionTolerantly() throws {
        #expect(AppSettings().historyRetention == HistoryRetention())
        let json = #"{"historyRetention":{"maxEntries":50,"maxAgeDays":"junk"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.historyRetention.maxEntries == 50 && s.historyRetention.maxAgeDays == 90)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.historyRetention == HistoryRetention())
        let round = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(s))
        #expect(round.historyRetention == s.historyRetention)
    }
}

@Suite("Saved queries and snippets")
struct SavedQueryTests {
    private func file() -> URL { tempDir().appendingPathComponent("saved-queries.json") }

    @Test func listsConnectionPlusGlobal() async throws {
        let s = SavedQueryStore(fileURL: file())
        let a = UUID(), b = UUID()
        try await s.save(name: "Zeta", sql: "SELECT 1", connectionID: a)
        try await s.save(name: "alpha", sql: "SELECT 2", connectionID: nil)
        try await s.save(name: "Beta", sql: "SELECT 3", connectionID: b)
        #expect(try await s.list(for: a).map(\.name) == ["alpha", "Zeta"])
        #expect(try await s.list(for: b).map(\.name) == ["alpha", "Beta"])
        #expect(try await s.list(for: nil).map(\.name) == ["alpha"])
    }

    @Test func updateDuplicateDeleteMarkRun() async throws {
        let clock = Clock()
        let url = file()
        let s = SavedQueryStore(fileURL: url, now: clock.now)
        let q = try await s.save(name: " Top posts ", sql: "SELECT 1", connectionID: nil, notes: "n", tags: ["wp", "WP", " "])
        #expect(q.name == "Top posts" && q.tags == ["wp"] && q.lastRunAt == nil)
        clock.advance(days: 1)
        let u = try await s.update(id: q.id, sql: "SELECT 2", notes: .some(nil))
        #expect(u.sql == "SELECT 2" && u.notes == nil && u.updatedAt > q.updatedAt && u.createdAt == q.createdAt)
        let cid = UUID()
        #expect(try await s.update(id: q.id, connectionID: .some(cid)).connectionID == cid)
        #expect(try await s.update(id: q.id, connectionID: .some(nil)).connectionID == nil)
        clock.advance(days: 1)
        try await s.markRun(id: q.id)
        #expect(try await s.query(id: q.id)?.lastRunAt == clock.date)
        let copy = try await s.duplicate(id: q.id)
        #expect(copy.id != q.id && copy.name == "Top posts copy" && copy.lastRunAt == nil && copy.sql == "SELECT 2")
        try await s.delete(id: q.id)
        #expect(try await s.list(for: nil).map(\.id) == [copy.id])
        await #expect(throws: SnippetError.notFound) { try await s.delete(id: q.id) }
        await #expect(throws: SnippetError.emptyName) { try await s.save(name: " ", sql: "x", connectionID: nil) }
        // persisted and private
        let reopened = SavedQueryStore(fileURL: url)
        #expect(try await reopened.list(for: nil).count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func purgeRemovesOnlyThatConnectionsQueries() async throws {
        let s = SavedQueryStore(fileURL: file())
        let a = UUID(), b = UUID()
        try await s.save(name: "a1", sql: "1", connectionID: a)
        try await s.save(name: "a2", sql: "1", connectionID: a)
        try await s.save(name: "b1", sql: "1", connectionID: b)
        try await s.save(name: "g", sql: "1", connectionID: nil)
        try await s.purge(connectionID: a)
        #expect(try await s.list(for: a).map(\.name) == ["g"])
        #expect(try await s.list(for: b).map(\.name) == ["b1", "g"])
    }

    @Test func snippetStoreCRUDAndPurge() async throws {
        let s = SnippetStore(fileURL: tempDir().appendingPathComponent("snippets.json"))
        let c = UUID()
        let one = try await s.add(name: "sel", sql: "SELECT ${1:cols} FROM ${2:t}", tags: ["a"], connectionID: c)
        try await s.add(name: "global", sql: "SELECT 1")
        #expect(try await s.list(for: c).count == 2)
        #expect(try await s.list(for: nil).count == 1)
        _ = try await s.update(id: one.id, name: "sel2")
        #expect(try await s.search("sel2", for: c).count == 1)
        try await s.purge(connectionID: c)
        #expect(try await s.list(for: c).map(\.name) == ["global"])
    }

    @Test func templatePlaceholders() {
        let t = SnippetTemplate.parse("SELECT ${1:cols} FROM ${2:table} WHERE ${3:col} = $3 AND x = ${4} $0")
        #expect(t.text == "SELECT cols FROM table WHERE col = col AND x =  ")
        #expect(t.stops.map(\.index) == [1, 2, 3, 4, 0])
        #expect(t.stops[2].ranges.count == 2)
        let ns = t.text as NSString
        #expect(ns.substring(with: NSRange(location: t.stops[0].ranges[0].lowerBound, length: t.stops[0].ranges[0].count)) == "cols")
        #expect(SnippetTemplate.parse("a \\${1:x} \\\\ $ b").text == "a ${1:x} \\ $ b")
        #expect(SnippetTemplate.parse("plain").stops.isEmpty)
        let emoji = SnippetTemplate.parse("😀${1:x}")
        #expect(emoji.stops[0].ranges[0] == 2..<3)
        let end = SnippetTemplate.parse("SELECT ${1:a}")
        #expect(end.stops.last?.index == 0 && end.stops.last?.ranges == [8..<8])
    }
}
