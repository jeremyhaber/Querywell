import Foundation

// Per-connection query history: JSON lines under Application Support/Querywell/history/<uuid>.jsonl,
// owner-only (0600). Appends are cheap; the file is compacted (rewritten atomically, newest entries
// kept) at open, every `compactEvery` appends, and whenever a limit is exceeded. Secrets never reach
// the file: SQL is redacted first (see SecretRedactor).
//
// RE-RUNNING: `HistoryEntry.rerunScript` only yields text. Running it goes through
// QueryRunner.prepare -> WriteGuard -> QueryRunner.run like any other execution, so PROD
// confirmation and read-only blocking apply to history re-runs too.

/// Bounds on what history keeps per connection. Every limit is enforced on append and compaction.
public struct HistoryRetention: Codable, Sendable, Equatable {
    public var maxEntries: Int
    public var maxAgeDays: Int
    public var maxFileBytes: Int
    /// Statements longer than this (UTF-8 bytes) are stored cut off and flagged ``HistoryEntry/isTruncated``.
    public var maxStatementBytes: Int
    /// Compaction also runs every this many appends.
    public var compactEvery: Int

    public init(maxEntries: Int = 1_000, maxAgeDays: Int = 90, maxFileBytes: Int = 2 * 1024 * 1024,
                maxStatementBytes: Int = 64 * 1024, compactEvery: Int = 50) {
        self.maxEntries = max(1, maxEntries)
        self.maxAgeDays = max(1, maxAgeDays)
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.maxStatementBytes = max(256, maxStatementBytes)
        self.compactEvery = max(1, compactEvery)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HistoryRetention()
        self.init(
            maxEntries: ((try? c.decodeIfPresent(Int.self, forKey: .maxEntries)) ?? nil) ?? d.maxEntries,
            maxAgeDays: ((try? c.decodeIfPresent(Int.self, forKey: .maxAgeDays)) ?? nil) ?? d.maxAgeDays,
            maxFileBytes: ((try? c.decodeIfPresent(Int.self, forKey: .maxFileBytes)) ?? nil) ?? d.maxFileBytes,
            maxStatementBytes: ((try? c.decodeIfPresent(Int.self, forKey: .maxStatementBytes)) ?? nil) ?? d.maxStatementBytes,
            compactEvery: ((try? c.decodeIfPresent(Int.self, forKey: .compactEvery)) ?? nil) ?? d.compactEvery)
    }
}

public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sql: String
    /// First run.
    public var ranAt: Date
    /// Most recent run (differs from `ranAt` once `runCount > 1`).
    public var lastRunAt: Date
    /// How many consecutive times this exact SQL ran (consecutive duplicates are merged).
    public var runCount: Int
    /// Duration of the most recent run.
    public var durationMs: Double
    public var rowCount: Int?
    public var affected: Int?
    public var error: String?
    /// Database / schema the statement ran in.
    public var database: String?
    /// `sql` was cut at the retention's statement limit. Such entries can't be re-run, only opened in the editor.
    public var isTruncated: Bool

    public init(id: UUID = UUID(), sql: String, ranAt: Date = Date(), lastRunAt: Date? = nil, runCount: Int = 1,
                durationMs: Double = 0, rowCount: Int? = nil, affected: Int? = nil, error: String? = nil,
                database: String? = nil, isTruncated: Bool = false) {
        self.id = id
        self.sql = sql
        self.ranAt = ranAt
        self.lastRunAt = lastRunAt ?? ranAt
        self.runCount = runCount
        self.durationMs = durationMs
        self.rowCount = rowCount
        self.affected = affected
        self.error = error
        self.database = database
        self.isTruncated = isTruncated
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ran = try c.decode(Date.self, forKey: .ranAt)
        self.init(
            id: (try? c.decode(UUID.self, forKey: .id)) ?? UUID(), sql: try c.decode(String.self, forKey: .sql),
            ranAt: ran, lastRunAt: try c.decodeIfPresent(Date.self, forKey: .lastRunAt),
            runCount: (try c.decodeIfPresent(Int.self, forKey: .runCount)) ?? 1,
            durationMs: (try c.decodeIfPresent(Double.self, forKey: .durationMs)) ?? 0,
            rowCount: try c.decodeIfPresent(Int.self, forKey: .rowCount),
            affected: try c.decodeIfPresent(Int.self, forKey: .affected),
            error: try c.decodeIfPresent(String.self, forKey: .error),
            database: try c.decodeIfPresent(String.self, forKey: .database),
            isTruncated: (try c.decodeIfPresent(Bool.self, forKey: .isTruncated)) ?? false)
    }

    public var failed: Bool { error != nil }

    /// The text to feed `QueryRunner.prepare(script:)`, or nil when the entry was truncated and so would
    /// run an incomplete statement. Use ``editorText`` to show it instead.
    public var rerunScript: String? { isTruncated ? nil : sql }

    /// What "open in editor" inserts (truncated entries get a marker comment so the cut is visible).
    public var editorText: String {
        isTruncated ? sql + "\n-- [truncated by Querywell history: the statement was too long to keep in full]" : sql
    }
}

/// History for one connection. An actor: all file access happens here.
public actor QueryHistoryStore {
    private let fileURL: URL
    private var retention: HistoryRetention
    private let now: @Sendable () -> Date
    private var entries: [HistoryEntry]?  // oldest first; loaded (and compacted) lazily
    private var appendsSinceCompaction = 0
    private var fileBytes = 0

    public init(connectionID: UUID, directory: URL, retention: HistoryRetention = HistoryRetention(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        fileURL = Self.fileURL(connectionID: connectionID, directory: directory)
        self.retention = retention
        self.now = now
    }

    static func fileURL(connectionID: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(connectionID.uuidString.lowercased()).jsonl", isDirectory: false)
    }

    /// `~/Library/Application Support/Querywell/history`.
    public static func defaultDirectory(appName: String = "Querywell") throws -> URL {
        try AppDirectories.applicationSupport(appName: appName).appendingPathComponent("history", isDirectory: true)
    }

    /// Applies new limits (e.g. after a settings change) and compacts immediately.
    public func updateRetention(_ r: HistoryRetention) throws {
        retention = r
        _ = try load()
        try compact()
    }

    // MARK: Writing

    /// Records a run. SQL is redacted and, if over the statement limit, truncated. If it equals the
    /// previous entry's SQL, that entry's `runCount`/`lastRunAt`/outcome are updated instead of adding a
    /// new one. Returns the stored (or updated) entry; nil for blank SQL.
    @discardableResult
    public func record(_ entry: HistoryEntry) throws -> HistoryEntry? {
        var e = entry
        let redacted = SecretRedactor.redact(entry.sql.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !redacted.isEmpty else { return nil }
        let (sql, cut) = Self.truncate(redacted, toBytes: retention.maxStatementBytes)
        e.sql = sql
        e.isTruncated = entry.isTruncated || cut
        if let err = e.error { e.error = String(SecretRedactor.redact(err).prefix(2_000)) }

        var list = try load()
        if let last = list.last, last.sql == e.sql, last.isTruncated == e.isTruncated {
            var merged = last
            merged.runCount += 1
            merged.lastRunAt = e.lastRunAt
            merged.durationMs = e.durationMs
            merged.rowCount = e.rowCount
            merged.affected = e.affected
            merged.error = e.error
            merged.database = e.database ?? last.database
            list[list.count - 1] = merged
            entries = list
            try rewrite(list)
            return merged
        }

        list.append(e)
        entries = list
        appendsSinceCompaction += 1
        let line = try Self.encode(e).count + 1
        if list.count > retention.maxEntries || fileBytes + line > retention.maxFileBytes
            || appendsSinceCompaction >= retention.compactEvery {
            try compact()
        } else {
            try append(e)
        }
        return e
    }

    /// Deletes the entry with `id`.
    public func delete(id: UUID) throws {
        var list = try load()
        list.removeAll { $0.id == id }
        entries = list
        try rewrite(list)
    }

    /// Empties this connection's history (keeps the connection).
    public func clear() throws {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
        fileBytes = 0
    }

    /// Removes the history file entirely — call when the connection profile is deleted.
    public func purge() throws { try clear() }

    // MARK: Directory-level operations (no store instance needed)

    /// Deletes one connection's history file, if any.
    public static func purge(connectionID: UUID, directory: URL) throws {
        try removeIfExists(fileURL(connectionID: connectionID, directory: directory))
    }

    public static func clear(connectionID: UUID, directory: URL) throws { try purge(connectionID: connectionID, directory: directory) }

    /// Deletes every connection's history ("Clear all history" in Settings).
    public static func clearAll(directory: URL) throws {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "jsonl" { try removeIfExists(f) }
    }

    /// Bytes used by all history files, for a Settings readout.
    public static func totalBytes(directory: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.filter { $0.pathExtension == "jsonl" }.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    // MARK: Reading

    public var count: Int { (try? load().count) ?? 0 }

    /// Size of this connection's history file.
    public func totalBytes() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    /// Newest first (by most recent run).
    public func recent(limit: Int = 200, offset: Int = 0) throws -> [HistoryEntry] {
        Array(try load().reversed().dropFirst(offset).prefix(limit))
    }

    /// Substring matches (case-insensitive, newest first) followed by fuzzy matches (best first).
    /// An empty query returns the newest entries.
    public func search(_ query: String, limit: Int = 100) throws -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let newestFirst = try load().reversed()
        if q.isEmpty { return Array(newestFirst.prefix(limit)) }
        var exact: [HistoryEntry] = []
        var rest: [HistoryEntry] = []
        for e in newestFirst {
            if e.sql.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { exact.append(e) } else { rest.append(e) }
        }
        let fuzzy = FuzzyMatcher.rank(rest, query: q, key: { String($0.sql.prefix(300)) }, limit: limit).map(\.0)
        return Array((exact + fuzzy).prefix(limit))
    }

    // MARK: Retention

    /// Cuts `s` to at most `bytes` UTF-8 bytes on a character boundary.
    static func truncate(_ s: String, toBytes bytes: Int) -> (String, Bool) {
        guard s.utf8.count > bytes else { return (s, false) }
        var end = s.utf8.index(s.utf8.startIndex, offsetBy: bytes)
        while end > s.utf8.startIndex, String(s.utf8[..<end]) == nil { end = s.utf8.index(before: end) }
        return (String(s.utf8[..<end]) ?? "", true)
    }

    /// Drops entries older than the age limit, then the oldest ones until both the count and byte limits hold,
    /// and rewrites the file atomically.
    private func compact() throws {
        var list = try load()
        let cutoff = now().addingTimeInterval(-Double(retention.maxAgeDays) * 86_400)
        list.removeAll { $0.lastRunAt < cutoff }
        if list.count > retention.maxEntries { list = Array(list.suffix(retention.maxEntries)) }
        var sizes = try list.map { try Self.encode($0).count + 1 }
        var total = sizes.reduce(0, +)
        var drop = 0
        while total > retention.maxFileBytes, drop < list.count - 1 {  // always keep the newest entry
            total -= sizes[drop]
            drop += 1
        }
        if drop > 0 { list.removeFirst(drop); sizes.removeFirst(drop) }
        entries = list
        appendsSinceCompaction = 0
        try rewrite(list)
    }

    // MARK: File handling

    private func load() throws -> [HistoryEntry] {
        if let entries { return entries }
        var list: [HistoryEntry] = []
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            let decoder = JSONFileStore.makeDecoder()
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let e = try? decoder.decode(HistoryEntry.self, from: Data(line)) { list.append(e) }  // torn lines are skipped
            }
            fileBytes = data.count
        }
        entries = list
        // Compaction at open: limits may have changed, or the app may have been closed for months.
        try compact()
        return entries ?? list
    }

    private static func encode(_ entry: HistoryEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entry)  // control characters are escaped: one line per entry
    }

    private func append(_ entry: HistoryEntry) throws {
        let fm = FileManager.default
        try ensureDirectory()
        var line = try Self.encode(entry)
        line.append(0x0A)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        fileBytes += line.count
    }

    private func rewrite(_ list: [HistoryEntry]) throws {
        if list.isEmpty, !FileManager.default.fileExists(atPath: fileURL.path) { fileBytes = 0; return }
        try ensureDirectory()
        var data = Data()
        for e in list {
            data.append(try Self.encode(e))
            data.append(0x0A)
        }
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        fileBytes = data.count
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
