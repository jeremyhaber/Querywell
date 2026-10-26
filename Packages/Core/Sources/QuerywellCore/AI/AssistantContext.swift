import Foundation

// What the assistant is told about the database. Schema only by default: table/column/key/index
// definitions. Row data is shared only when the caller passes `allowSampleRows: true`, which
// the app derives from an explicit per-connection opt-in.

/// A few rows of a table, shared with the model only after an explicit opt-in.
public struct SampleRows: Sendable, Hashable {
    public var columns: [String]
    public var rows: [[DatabaseValue]]

    public init(columns: [String], rows: [[DatabaseValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// A detected WordPress installation.
public struct WordPressInfo: Sendable, Hashable {
    /// Table prefix as it appears in the schema (`wp_`, `wp7k_`).
    public var prefix: String
    public var isMultisite: Bool

    public init(prefix: String, isMultisite: Bool = false) {
        self.prefix = prefix
        self.isMultisite = isMultisite
    }
}

public enum WordPressDetector {
    private static let core = ["posts", "options", "postmeta", "users", "usermeta"]

    /// Every WordPress table prefix in a database: `P` such that `Pposts`, `Poptions` and `Pusers` all exist
    /// (names compared case-insensitively; an empty prefix additionally needs a meta table so a plain
    /// `posts`/`options`/`users` app isn't mistaken for WordPress). A live site and a staging copy
    /// (`wp_` + `wpstg0_`) yield two entries. Multisite sub-site tables (`wp_2_posts`) have no `users` of
    /// their own and so are never separate installs. Ordered by how many core tables each has, then the
    /// shorter prefix, then alphabetically.
    public static func detectAll(tableNames: [String]) -> [WordPressInfo] {
        let lowered = Dictionary(tableNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var found: [(info: WordPressInfo, score: Int)] = []
        var seen = Set<String>()
        for name in tableNames where name.lowercased().hasSuffix("posts") && !name.lowercased().hasSuffix("postmeta") {
            let prefix = String(name.dropLast(5))
            let lp = prefix.lowercased()
            guard seen.insert(lp).inserted, lowered[lp + "options"] != nil, lowered[lp + "users"] != nil else { continue }
            if lp.isEmpty, lowered["postmeta"] == nil, lowered["usermeta"] == nil { continue }
            let score = core.filter { lowered[lp + $0] != nil }.count
            found.append((WordPressInfo(prefix: prefix, isMultisite: lowered[lp + "blogs"] != nil && lowered[lp + "site"] != nil), score))
        }
        found.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.info.prefix.count != $1.info.prefix.count { return $0.info.prefix.count < $1.info.prefix.count }
            return $0.info.prefix < $1.info.prefix
        }
        return found.map(\.info)
    }

    /// The tables that belong to `prefix`: those starting with it that no longer detected prefix claims
    /// (so with `wp_` and `wp_stg_`, `wp_stg_posts` belongs to the staging copy only).
    public static func tables(ofPrefix prefix: String, in names: [String], among installs: [WordPressInfo]) -> [String] {
        let longer = installs.map(\.prefix).filter { $0.count > prefix.count && $0.hasPrefix(prefix) }
        return names.filter { name in name.hasPrefix(prefix) && !longer.contains { name.hasPrefix($0) } }
    }

    /// The primary installation: the first of ``detectAll(tableNames:)``.
    public static func detect(tableNames: [String]) -> WordPressInfo? { detectAll(tableNames: tableNames).first }
}

public struct AssistantContext: Sendable {
    public var engine: DatabaseEngine
    /// e.g. "8.4.3", "11.4.2-MariaDB", "16.4".
    public var serverVersion: String?
    public var currentSchema: String?
    /// Compact DDL-ish text of the tables, columns, keys and indexes (size-capped).
    public var schemaSummary: String
    public var wordPress: WordPressInfo?
    /// Every detected WordPress installation in the schema (live + staging copies); `wordPress` is the first.
    public var wordPressInstalls: [WordPressInfo]
    /// Only ever non-nil when the context was built with `allowSampleRows: true`.
    public private(set) var sampleRows: [TableRef: SampleRows]?

    /// - Parameter allowSampleRows: the connection's explicit opt-in. When false, `sampleRows` is
    ///   dropped no matter what was passed — the model sees schema only.
    public init(
        engine: DatabaseEngine, serverVersion: String? = nil, currentSchema: String? = nil, schemaSummary: String,
        wordPress: WordPressInfo? = nil, wordPressInstalls: [WordPressInfo]? = nil,
        allowSampleRows: Bool = false, sampleRows: [TableRef: SampleRows]? = nil
    ) {
        self.wordPressInstalls = wordPressInstalls ?? wordPress.map { [$0] } ?? []
        self.engine = engine
        self.serverVersion = serverVersion
        self.currentSchema = currentSchema
        self.schemaSummary = schemaSummary
        self.wordPress = wordPress
        self.sampleRows = allowSampleRows ? sampleRows : nil
    }

    /// Builds the context from introspected structures: summarises (relevance-ranked against `prompt`,
    /// capped at `maxSchemaChars`) and detects WordPress.
    public static func make(
        engine: DatabaseEngine, serverVersion: String?, currentSchema: String?,
        structures: [TableStructure], otherTables: [TableInfo] = [], prompt: String,
        allowSampleRows: Bool = false, sampleRows: [TableRef: SampleRows]? = nil,
        maxSchemaChars: Int = SchemaSummary.defaultCap
    ) -> AssistantContext {
        let names = structures.map(\.info.ref.name) + otherTables.map(\.ref.name)
        let installs = WordPressDetector.detectAll(tableNames: names)
        let summary = SchemaSummary.build(structures: structures, otherTables: otherTables, currentSchema: currentSchema,
                                          focus: prompt, dialect: SQLDialect(engine), maxChars: maxSchemaChars)
        return AssistantContext(engine: engine, serverVersion: serverVersion, currentSchema: currentSchema,
                                schemaSummary: summary, wordPress: installs.first, wordPressInstalls: installs,
                                allowSampleRows: allowSampleRows, sampleRows: sampleRows)
    }

    /// Loads structures through an inspector for the assistant: all tables of `schema` up to `maxTables`
    /// (the rest become name-only entries), then calls ``make(engine:serverVersion:currentSchema:structures:otherTables:prompt:allowSampleRows:sampleRows:maxSchemaChars:)``.
    public static func load(
        from inspector: any SchemaInspector, engine: DatabaseEngine, serverVersion: String?, schema: String,
        prompt: String, maxTables: Int = 150, allowSampleRows: Bool = false, sampleRows: [TableRef: SampleRows]? = nil
    ) async throws -> AssistantContext {
        let tables = try await inspector.listTables(schema: schema)
        // Detailed structures for the tables most related to the prompt first.
        let ranked = SchemaSummary.rankNames(tables.map(\.ref.name), focus: prompt)
        let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element, $0.offset) })
        let sorted = tables.sorted { (order[$0.ref.name] ?? .max) < (order[$1.ref.name] ?? .max) }
        var structures: [TableStructure] = []
        for t in sorted.prefix(maxTables) {
            if let s = try? await inspector.structure(of: t.ref) { structures.append(s) }
        }
        let loaded = Set(structures.map(\.info.ref))
        let rest = tables.filter { !loaded.contains($0.ref) }
        return make(engine: engine, serverVersion: serverVersion, currentSchema: schema, structures: structures,
                    otherTables: rest, prompt: prompt, allowSampleRows: allowSampleRows, sampleRows: sampleRows)
    }
}

// MARK: - Schema summary

/// Compact schema text for the prompt, most relevant tables first, hard-capped in size.
///
/// Relevance: words of the prompt matched against table-name words (plural-insensitive) and column names,
/// plus a boost for tables one foreign key away from the best matches.
public enum SchemaSummary {
    public static let defaultCap = 12_000

    public static func build(
        structures: [TableStructure], otherTables: [TableInfo] = [], currentSchema: String?, focus: String,
        dialect: SQLDialect, maxChars: Int = defaultCap
    ) -> String {
        struct Entry {
            var ref: TableRef
            var line: String
            var score: Double
            var neighbours: Set<TableRef>
            var hasDetail: Bool
        }
        let words = focusWords(focus)
        var entries: [Entry] = []
        for s in structures {
            let ref = s.info.ref
            let neighbours = Set(s.foreignKeys.map(\.referenced) + s.referencedBy.compactMap(\.table))
            entries.append(Entry(ref: ref, line: describe(s, currentSchema: currentSchema), score: score(ref.name, columns: s.columns.map(\.name), words: words),
                                 neighbours: neighbours, hasDetail: true))
        }
        for t in otherTables where !structures.contains(where: { $0.info.ref == t.ref }) {
            entries.append(Entry(ref: t.ref, line: qualifiedName(t.ref, currentSchema) + (t.kind == .table ? "" : " [view]"),
                                 score: score(t.ref.name, columns: [], words: words), neighbours: [], hasDetail: false))
        }

        // FK neighbourhood of the best matches.
        let seeds = entries.filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(5)
        var boost: [TableRef: Double] = [:]
        for seed in seeds {
            for n in seed.neighbours { boost[n, default: 0] += 3 }
            for e in entries where e.neighbours.contains(seed.ref) { boost[e.ref, default: 0] += 3 }
        }
        for i in entries.indices { entries[i].score += min(boost[entries[i].ref] ?? 0, 6) }

        entries.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.hasDetail != b.hasDetail { return a.hasDetail }
            return a.ref.name.localizedStandardCompare(b.ref.name) == .orderedAscending
        }

        var header = "-- \(dialect.family == .mysql ? "MySQL/MariaDB" : "PostgreSQL") schema"
        if let currentSchema { header += " `\(currentSchema)`" }
        header += " — columns: name type [PK] [AI=auto-increment]; FK = foreign key; IDX = secondary index"
        var out = header + "\n"
        var omitted: [String] = []
        var nameOnly: [String] = []
        for e in entries {
            let cost = e.line.count + 1
            if e.hasDetail {
                if out.count + cost <= maxChars - 200 {  // keep room for the trailer
                    out += e.line + "\n"
                } else if out.count + e.ref.name.count + 2 <= maxChars - 120 {
                    nameOnly.append(qualifiedName(e.ref, currentSchema))
                } else {
                    omitted.append(e.ref.name)
                }
            } else {
                nameOnly.append(qualifiedName(e.ref, currentSchema))
            }
        }
        if !nameOnly.isEmpty {
            var line = "-- Other tables (columns omitted): "
            var used = out.count + line.count
            var shown = 0
            for n in nameOnly {
                if used + n.count + 2 > maxChars - 60 { break }
                line += (shown == 0 ? "" : ", ") + n
                used += n.count + 2
                shown += 1
            }
            omitted += nameOnly.dropFirst(shown)
            if shown > 0 { out += line + "\n" }
        }
        if !omitted.isEmpty { out += "-- … and \(omitted.count) more tables not shown\n" }
        if out.count > maxChars { out = String(out.prefix(maxChars)) }
        return out
    }

    /// Names ordered by relevance to `focus` (stable for ties).
    public static func rankNames(_ names: [String], focus: String) -> [String] {
        let words = focusWords(focus)
        guard !words.isEmpty else { return names }
        return names.enumerated().sorted { a, b in
            let sa = score(a.element, columns: [], words: words), sb = score(b.element, columns: [], words: words)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Pieces

    private static func qualifiedName(_ ref: TableRef, _ current: String?) -> String {
        ref.schema == current || current == nil ? ref.name : "\(ref.schema).\(ref.name)"
    }

    private static func describe(_ s: TableStructure, currentSchema: String?) -> String {
        let maxColumns = 80
        var cols: [String] = []
        for c in s.columns.prefix(maxColumns) {
            var part = "\(c.name) \(String(c.fullType.prefix(120)))"
            if c.isPrimaryKey { part += " PK" }
            if c.isAutoIncrement { part += " AI" }
            cols.append(part)
        }
        if s.columns.count > maxColumns { cols.append("… +\(s.columns.count - maxColumns) more") }
        var line = "\(qualifiedName(s.info.ref, currentSchema))\(s.info.kind == .table ? "" : " [view]") (\(cols.joined(separator: ", ")))"
        if let c = s.info.comment, !c.isEmpty { line += " -- \(String(c.prefix(60)))" }
        for fk in s.foreignKeys.prefix(10) {
            line += "\n  FK (\(fk.columns.joined(separator: ", "))) -> \(qualifiedName(fk.referenced, currentSchema))(\(fk.referencedColumns.joined(separator: ", ")))"
        }
        let idx = s.indexes.filter { !$0.isPrimary }.prefix(6)
        if !idx.isEmpty {
            line += "\n  IDX " + idx.map { "\($0.isUnique ? "unique " : "")\($0.name)(\($0.columns.joined(separator: ", ")))" }.joined(separator: "; ")
        }
        return line
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "all", "with", "from", "that", "this", "show", "give", "list", "find", "get", "how", "many",
        "what", "which", "who", "are", "was", "were", "has", "have", "where", "when", "each", "per", "any", "into",
        "select", "table", "tables", "rows", "row", "count", "total", "number", "query", "sql", "please", "than", "not",
        "their", "them", "its", "about", "last", "first", "most", "top", "order", "group", "name", "names",
    ]

    private static func stem(_ w: String) -> String {
        if w.hasSuffix("ies"), w.count > 4 { return String(w.dropLast(3)) + "y" }
        if w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { return String(w.dropLast()) }
        return w
    }

    /// Lowercased, stemmed, de-duplicated meaningful words of the prompt.
    static func focusWords(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            guard w.count >= 3, !stopwords.contains(w) else { continue }
            let s = stem(w)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    private static func nameWords(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var prev: Character?
        for ch in name {
            if ch == "_" || ch == "-" || ch == "." || ch == " " {
                if !current.isEmpty { parts.append(current); current = "" }
            } else {
                if let p = prev, p.isLowercase, ch.isUppercase, !current.isEmpty { parts.append(current); current = "" }
                current.append(ch)
            }
            prev = ch
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { stem($0.lowercased()) }
    }

    private static func score(_ table: String, columns: [String], words: [String]) -> Double {
        guard !words.isEmpty else { return 0 }
        let tableWords = nameWords(table)
        let joined = tableWords.joined()
        var s = 0.0
        for w in words {
            if tableWords.contains(w) { s += 10 }
            else if w.count >= 4, joined.contains(w) || tableWords.contains(where: { $0.hasPrefix(w) || (w.hasPrefix($0) && $0.count >= 4) }) { s += 5 }
        }
        var columnHits = 0.0
        for c in columns {
            let cw = nameWords(c)
            if words.contains(where: { cw.contains($0) }) { columnHits += 2 }
        }
        return s + min(columnHits, 6)
    }
}
