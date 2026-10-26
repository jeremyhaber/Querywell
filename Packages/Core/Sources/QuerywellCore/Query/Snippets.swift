import Foundation

/// A saved query. `connectionID == nil` makes it global; otherwise it belongs to one connection.
public struct Snippet: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// May contain placeholders: `${1:name}`, `${2}`, `$3`, `$0` — see ``SnippetTemplate``.
    public var sql: String
    public var tags: [String]
    public var connectionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sql: String, tags: [String] = [], connectionID: UUID? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.sql = sql
        self.tags = tags
        self.connectionID = connectionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

private struct SnippetFile: Codable {
    var schemaVersion = 1
    var snippets: [Snippet] = []
}

public enum SnippetError: Error, Equatable, Sendable {
    case notFound
    case emptyName
}

/// CRUD for snippets in one JSON file (`snippets.json`). Mutations are applied to a copy and
/// committed in memory only after the atomic write succeeds.
public actor SnippetStore {
    private let fileURL: URL
    private var snippets: [Snippet]?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(appName: String = "Querywell") throws -> URL {
        try AppDirectories.applicationSupport(appName: appName).appendingPathComponent("snippets.json", isDirectory: false)
    }

    /// Global snippets plus those of `connectionID`, sorted by name. With `connectionID == nil`, only global ones.
    public func list(for connectionID: UUID? = nil) throws -> [Snippet] {
        try load()
            .filter { $0.connectionID == nil || $0.connectionID == connectionID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func snippet(id: UUID) throws -> Snippet? { try load().first { $0.id == id } }

    @discardableResult
    public func add(name: String, sql: String, tags: [String] = [], connectionID: UUID? = nil) throws -> Snippet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SnippetError.emptyName }
        let s = Snippet(name: trimmed, sql: sql, tags: Self.normalize(tags), connectionID: connectionID)
        var list = try load()
        list.append(s)
        try commit(list)
        return s
    }

    @discardableResult
    public func update(id: UUID, name: String? = nil, sql: String? = nil, tags: [String]? = nil) throws -> Snippet {
        var list = try load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw SnippetError.notFound }
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw SnippetError.emptyName }
            list[i].name = t
        }
        if let sql { list[i].sql = sql }
        if let tags { list[i].tags = Self.normalize(tags) }
        list[i].updatedAt = Date()
        try commit(list)
        return list[i]
    }

    public func delete(id: UUID) throws {
        var list = try load()
        guard list.contains(where: { $0.id == id }) else { throw SnippetError.notFound }
        list.removeAll { $0.id == id }
        try commit(list)
    }

    /// Deletes all of a connection's snippets (when the connection profile is removed).
    public func purge(connectionID: UUID) throws { try deleteAll(connectionID: connectionID) }

    /// Deletes all of a connection's snippets (when the connection is removed).
    public func deleteAll(connectionID: UUID) throws {
        var list = try load()
        list.removeAll { $0.connectionID == connectionID }
        try commit(list)
    }

    /// Fuzzy search over name, tags and SQL among the snippets visible to `connectionID`.
    public func search(_ query: String, for connectionID: UUID? = nil, limit: Int = 50) throws -> [Snippet] {
        let visible = try list(for: connectionID)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Array(visible.prefix(limit)) }
        return FuzzyMatcher.rank(visible, query: q, key: { "\($0.name) \($0.tags.joined(separator: " "))" }, limit: limit).map(\.0)
    }

    private static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func load() throws -> [Snippet] {
        if let snippets { return snippets }
        var list: [Snippet] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            list = try JSONFileStore.makeDecoder().decode(SnippetFile.self, from: data).snippets
        }
        snippets = list
        return list
    }

    private func commit(_ list: [Snippet]) throws {
        let data = try JSONFileStore.makeEncoder().encode(SnippetFile(snippets: list))
        try JSONFileStore.writeAtomically(data, to: fileURL, permissions: 0o600)
        snippets = list
    }
}

// MARK: - Placeholders

/// Parses editor-style placeholders into tab stops. Pure.
///
/// Syntax: `${1:default}`, `${1}`, `$1` (stop 1, optionally with default text), `$0` (final caret
/// position). The same index may appear several times (mirrors). `\$`, `\}` and `\\` are literal.
/// Stops are visited in ascending index order with `$0` last; offsets are UTF-16 in the expanded text.
public struct SnippetTemplate: Sendable, Equatable {
    public struct TabStop: Sendable, Equatable {
        public var index: Int
        /// Text that the editor selects at this stop (the default, possibly empty).
        public var placeholder: String
        /// Every occurrence of this index in `text` (UTF-16 ranges).
        public var ranges: [Range<Int>]
    }

    /// The snippet with placeholders replaced by their default text.
    public var text: String
    /// Ordered by visit order; `$0` (if present) is last, and a final caret stop is synthesised at the
    /// end of the text when the template has none and has at least one stop.
    public var stops: [TabStop]

    public static func parse(_ template: String) -> SnippetTemplate {
        enum Piece { case literal(String), stop(Int, String) }
        let chars = Array(template)
        var pieces: [Piece] = []
        var literal = ""

        func flush() { if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" } }
        func isEscapable(_ c: Character) -> Bool { c == "$" || c == "}" || c == "\\" }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isEscapable(chars[i + 1]) {
                literal.append(chars[i + 1])
                i += 2
                continue
            }
            guard c == "$", i + 1 < chars.count else { literal.append(c); i += 1; continue }
            // $N
            if chars[i + 1].isASCII, chars[i + 1].isNumber {
                var j = i + 1
                var n = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { n.append(chars[j]); j += 1 }
                flush()
                pieces.append(.stop(Int(n) ?? 0, ""))
                i = j
                continue
            }
            // ${N} / ${N:default}
            if chars[i + 1] == "{" {
                var j = i + 2
                var n = ""
                while j < chars.count, chars[j].isASCII, chars[j].isNumber { n.append(chars[j]); j += 1 }
                if !n.isEmpty, j < chars.count, chars[j] == "}" {
                    flush()
                    pieces.append(.stop(Int(n) ?? 0, ""))
                    i = j + 1
                    continue
                }
                if !n.isEmpty, j < chars.count, chars[j] == ":" {
                    var k = j + 1
                    var def = ""
                    var closed = false
                    while k < chars.count {
                        if chars[k] == "\\", k + 1 < chars.count, isEscapable(chars[k + 1]) {
                            def.append(chars[k + 1]); k += 2; continue
                        }
                        if chars[k] == "}" { closed = true; break }
                        def.append(chars[k]); k += 1
                    }
                    if closed {
                        flush()
                        pieces.append(.stop(Int(n) ?? 0, def))
                        i = k + 1
                        continue
                    }
                }
            }
            literal.append("$")
            i += 1
        }
        flush()

        // Mirrors show the default text of the first occurrence that has one.
        var defaults: [Int: String] = [:]
        for case .stop(let index, let def) in pieces where !def.isEmpty && defaults[index] == nil { defaults[index] = def }

        var out = ""
        var length = 0
        var order: [Int] = []
        var ranges: [Int: [Range<Int>]] = [:]
        for piece in pieces {
            switch piece {
            case .literal(let s):
                out += s
                length += s.utf16.count
            case .stop(let index, _):
                let text = defaults[index] ?? ""
                ranges[index, default: []].append(length..<(length + text.utf16.count))
                out += text
                length += text.utf16.count
                if !order.contains(index) { order.append(index) }
            }
        }

        var stops = order.filter { $0 != 0 }.sorted().map {
            TabStop(index: $0, placeholder: defaults[$0] ?? "", ranges: ranges[$0] ?? [])
        }
        if order.contains(0) {
            stops.append(TabStop(index: 0, placeholder: "", ranges: ranges[0] ?? []))
        } else if !stops.isEmpty {
            stops.append(TabStop(index: 0, placeholder: "", ranges: [length..<length]))
        }
        return SnippetTemplate(text: out, stops: stops)
    }
}
