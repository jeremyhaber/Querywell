import Foundation
import Testing

@testable import QuerywellCore

// MARK: - Unit

@Suite("Search & replace (unit)")
struct SearchReplaceUnitTests {
    @Test func excerptShowsContextAroundChange() {
        let before = String(repeating: "a", count: 100) + "OLD" + String(repeating: "b", count: 100)
        let after = String(repeating: "a", count: 100) + "NEWER" + String(repeating: "b", count: 100)
        let (b, a) = DatabaseSearchReplace.excerpts(before: .text(before), after: .text(after), radius: 10)
        #expect(b == "…" + String(repeating: "a", count: 10) + "OLD" + String(repeating: "b", count: 10) + "…")
        #expect(a == "…" + String(repeating: "a", count: 10) + "NEWER" + String(repeating: "b", count: 10) + "…")
    }

    @Test func excerptOfShortValuesIsWholeValue() {
        let (b, a) = DatabaseSearchReplace.excerpts(before: .text("see old.test"), after: .text("see new.test"), radius: 40)
        #expect(b == "see old.test")
        #expect(a == "see new.test")
    }

    @Test func columnClassification() {
        #expect(DatabaseSearchReplace.classify("longtext", family: .mysql)?.isBinary == false)
        #expect(DatabaseSearchReplace.classify("json", family: .mysql)?.isJSON == true)
        #expect(DatabaseSearchReplace.classify("blob", family: .mysql)?.isBinary == true)
        #expect(DatabaseSearchReplace.classify("enum", family: .mysql) == nil)
        #expect(DatabaseSearchReplace.classify("set", family: .mysql) == nil)
        #expect(DatabaseSearchReplace.classify("int", family: .mysql) == nil)
        #expect(DatabaseSearchReplace.classify("jsonb", family: .postgres)?.isJSON == true)
        #expect(DatabaseSearchReplace.classify("bpchar", family: .postgres) != nil)
        #expect(DatabaseSearchReplace.classify("bytea", family: .postgres)?.isBinary == true)
        #expect(DatabaseSearchReplace.classify("_text", family: .postgres) == nil)
    }

    @Test func regexMetacharacterDetection() {
        #expect(!DatabaseSearchReplace.hasRegexMetacharacters("plain text"))
        #expect(!DatabaseSearchReplace.hasRegexMetacharacters(#"example\.com"#))
        #expect(DatabaseSearchReplace.hasRegexMetacharacters(#"ex.mple"#))
        #expect(DatabaseSearchReplace.hasRegexMetacharacters(#"\d+"#))
        #expect(DatabaseSearchReplace.unescapeRegexLiteral(#"example\.com"#) == "example.com")
    }

    @Test func replaceAllCountsAndHonoursCase() {
        let (t, n) = DatabaseSearchReplace.replaceAll(in: #"a\/b A\/B"#, search: #"a\/b"#, replace: "X", caseSensitive: false)
        #expect(t == "X X")
        #expect(n == 2)
        let (t2, n2) = DatabaseSearchReplace.replaceAll(in: #"a\/b A\/B"#, search: #"a\/b"#, replace: "X", caseSensitive: true)
        #expect(t2 == #"X A\/B"#)
        #expect(n2 == 1)
    }

    @Test func keysetConditionExpandsCompositeKeys() {
        let d = SQLDialect(.mysql)
        let c = KeysetPagination.condition(primaryKey: ["a", "b"], after: [.integer(3), .text("x")], dialect: d)
        #expect(c == "((`a` > 3) OR (`a` = 3 AND `b` > 'x'))")
        #expect(KeysetPagination.condition(primaryKey: [], after: [], dialect: d) == nil)
    }
}

// MARK: - Fixture

private let oldURL = "http://old.example.com"
private let newURL = "https://new.example.org/blog"

private func phpString(_ s: String) -> String { "s:\(s.utf8.count):\"\(s)\";" }
private func phpArray(_ pairs: [(String, String)]) -> String {
    "a:\(pairs.count):{" + pairs.map { phpString($0.0) + $0.1 }.joined() + "}"
}

private let gutenberg =
    ##"<!-- wp:image {"url":"http:\/\/old.example.com\/wp-content\/a.png","id":7} --><figure><img src="http://old.example.com/wp-content/a.png"/></figure><!-- /wp:image -->"##

private struct SRFixture {
    let f: SchemaFixture
    var d: SQLDialect { f.dialect }
    var pg: Bool { f.target.isPostgres }

    func create(fillerPosts: Int = 0) async throws {
        let big = pg ? "text" : "longtext"
        let json = pg ? "jsonb" : "json"
        let q = f.q
        try await f.run("CREATE TABLE \(q).wp_posts (ID bigint NOT NULL PRIMARY KEY, post_title varchar(255) NOT NULL, post_content \(big) NOT NULL, guid varchar(255) NOT NULL)")
        try await f.run("CREATE TABLE \(q).wp_options (option_id bigint NOT NULL PRIMARY KEY, option_name varchar(191) NOT NULL, option_value \(big) NOT NULL)")
        try await f.run("CREATE TABLE \(q).wp_postmeta (meta_id bigint NOT NULL PRIMARY KEY, post_id bigint NOT NULL, meta_key varchar(255), meta_value \(big))")
        try await f.run("CREATE TABLE \(q).wp_docs (id int NOT NULL PRIMARY KEY, doc \(json) NOT NULL)")
        try await f.run("CREATE TABLE \(q).no_pk (note varchar(100))")
        try await f.run("CREATE TABLE \(q).comp_key (a int NOT NULL, b varchar(10) NOT NULL, txt varchar(100), PRIMARY KEY (a, b))")
        try await f.run("CREATE TABLE \(q).legacy_myisam (id int NOT NULL PRIMARY KEY, txt varchar(100))" + (pg ? "" : " ENGINE=MyISAM"))

        func ins(_ table: String, _ cols: String, _ values: [String]) async throws {
            try await f.run("INSERT INTO \(q).\(table) (\(cols)) VALUES (\(values.joined(separator: ", ")))")
        }
        func s(_ v: String) -> String { d.quoteString(v) }

        try await ins("wp_posts", "ID, post_title, post_content, guid",
                      ["1", s("Hello"), s("Visit \(oldURL)/page now"), s("\(oldURL)/?p=1")])
        try await ins("wp_posts", "ID, post_title, post_content, guid", ["2", s("Block"), s(gutenberg), s("\(oldURL)/?p=2")])
        try await ins("wp_posts", "ID, post_title, post_content, guid", ["3", s("Nothing"), s("no links here"), s("other://guid/3")])
        try await ins("wp_posts", "ID, post_title, post_content, guid", ["4", s("Ünï \(oldURL)"), s("Zażółć gęślą jaźń \(oldURL)/ü 🙂"), s("g4")])
        for i in 0..<fillerPosts {
            try await ins("wp_posts", "ID, post_title, post_content, guid",
                          ["\(100 + i)", s("f\(i)"), s("filler \(i) \(oldURL)/f\(i)"), s("fg\(i)")])
        }

        let siteOptions = phpArray([
            ("siteurl", phpString("\(oldURL)/")),
            ("title", phpString("Héllo wörld \(oldURL)/ ünï")),
            ("nested", phpArray([("a", phpString("\(oldURL)/n")), ("n", "i:5;")])),
            ("count", "i:3;"),
        ])
        try await ins("wp_options", "option_id, option_name, option_value", ["1", s("siteurl"), s(oldURL)])
        try await ins("wp_options", "option_id, option_name, option_value", ["2", s("widget_text"), s(siteOptions)])
        try await ins("wp_options", "option_id, option_name, option_value",
                      ["3", s("double_encoded"), s(phpArray([("inner", phpString(phpArray([("u", phpString("\(oldURL)/deep"))])))]))])
        try await ins("wp_options", "option_id, option_name, option_value", ["4", s("untouched"), s(phpArray([("k", phpString("v"))]))])
        // Looks serialized but the length is wrong -> reported, never changed.
        try await ins("wp_options", "option_id, option_name, option_value", ["5", s("broken"), s("a:1:{s:1:\"k\";s:99:\"\(oldURL)/broken\";}")])
        try await ins("wp_postmeta", "meta_id, post_id, meta_key, meta_value", ["1", "1", s("_links"), s(phpArray([("l", phpString("\(oldURL)/m"))]))])
        try await ins("wp_postmeta", "meta_id, post_id, meta_key, meta_value", ["2", "1", s("_null"), "NULL"])
        try await ins("wp_docs", "id, doc",
                      ["1", s(#"{"homepage":"http:\/\/old.example.com\/","n":[1,2,3],"name":"Ünï old.example.com","nested":{"u":"http://old.example.com/x"}}"#)])
        try await ins("wp_docs", "id, doc", ["2", s(#"{"k":"nothing"}"#)])
        try await ins("no_pk", "note", [s("\(oldURL)/nopk")])
        try await ins("comp_key", "a, b, txt", ["1", s("x"), s("\(oldURL)/1x")])
        try await ins("comp_key", "a, b, txt", ["1", s("y"), s("\(oldURL)/1y")])
        try await ins("comp_key", "a, b, txt", ["2", s("x"), s("\(oldURL)/2x")])
        try await ins("comp_key", "a, b, txt", ["2", s("y"), s("untouched")])
        try await ins("legacy_myisam", "id, txt", ["1", s("\(oldURL)/myisam")])
    }

    func structures(_ names: [String]) async throws -> [TableStructure] {
        var out: [TableStructure] = []
        for n in names { out.append(try await f.inspector.structure(of: f.ref(n))) }
        return out
    }

    func snapshot(_ names: [String]) async throws -> [String: [[DatabaseValue]]] {
        var out: [String: [[DatabaseValue]]] = [:]
        for n in names {
            let r = try await f.session.execute("SELECT * FROM \(f.q).\(d.quoteIdentifier(n))")
            out[n] = r.rows.sorted { String(describing: $0) < String(describing: $1) }
        }
        return out
    }

    func text(_ table: String, _ column: String, where cond: String) async throws -> String {
        let r = try await f.session.execute("SELECT \(d.quoteIdentifier(column)) FROM \(f.q).\(d.quoteIdentifier(table)) WHERE \(cond)")
        guard let v = r.rows.first?.first else { return "" }
        if case .bytes(let data) = v { return String(decoding: data, as: UTF8.self) }
        return v.displayString
    }
}

private let allTables = ["wp_posts", "wp_options", "wp_postmeta", "wp_docs", "no_pk", "comp_key", "legacy_myisam"]

private func config(
    batchSize: Int = 500, guid: Bool = false, hook: (@Sendable (TableRef) async -> Void)? = nil
) -> SearchReplaceConfiguration {
    SearchReplaceConfiguration(search: oldURL, replace: newURL, includeWordPressGUID: guid, batchSize: batchSize,
                               afterBatchScanned: hook)
}

private final class TaskBox: @unchecked Sendable {
    // @unchecked Sendable: all state guarded by `lock`.
    private let lock = NSLock()
    private var _task: Task<SearchReplaceReport, Never>?
    private var _calls = 0
    var task: Task<SearchReplaceReport, Never>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    func bump() -> Int { lock.withLock { _calls += 1; return _calls } }
}

// MARK: - Integration

@Suite("Search & replace integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct SearchReplaceIntegrationTests {
    @Test(arguments: DBTarget.all)
    func planSkipsTablesWithoutPrimaryKeyViewsAndGUID(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config())
            let plan = sr.plan(tables: try await fx.structures(allTables))

            let noPK = try #require(plan.tables.first { $0.table.name == "no_pk" })
            #expect(noPK.skipReason?.contains("primary key") == true)
            let posts = try #require(plan.tables.first { $0.table.name == "wp_posts" })
            #expect(posts.isRunnable)
            #expect(posts.columns.map(\.name).contains("post_content"))
            #expect(!posts.columns.map(\.name).contains("guid"))
            #expect(posts.skippedColumns.contains { $0.name == "guid" })
            #expect(!posts.columns.map(\.name).contains("ID"))
            let docs = try #require(plan.tables.first { $0.table.name == "wp_docs" })
            #expect(docs.columns.first?.isJSON == (target.engine != .mariadb))  // MariaDB's JSON is LONGTEXT
            if !target.isPostgres {
                let myisam = try #require(plan.tables.first { $0.table.name == "legacy_myisam" })
                #expect(!myisam.isTransactional)
                #expect(!myisam.warnings.isEmpty)
            }
            // GUID opt-in
            let sr2 = try DatabaseSearchReplace(session: f.session, configuration: config(guid: true))
            let posts2 = try #require(sr2.plan(tables: try await fx.structures(["wp_posts"])).tables.first)
            #expect(posts2.columns.map(\.name).contains("guid"))
        }
    }

    @Test(arguments: DBTarget.all)
    func dryRunCountsAndWritesNothing(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let before = try await fx.snapshot(allTables)
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config())
            let plan = sr.plan(tables: try await fx.structures(allTables))
            let report = await sr.run(plan: plan, mode: .dryRun)
            let after = try await fx.snapshot(allTables)
            #expect(before == after)

            let posts = try #require(report.tables.first { $0.table.name == "wp_posts" })
            #expect(posts.status == .completed)
            #expect(posts.rowsChanged == 3)  // ids 1, 2, 4 (guid not searched)
            #expect(posts.replacements >= 4)
            #expect(!posts.committed)
            #expect(posts.samples.count == 4)  // post 4 changes in title and content
            let sample = try #require(posts.samples.first { $0.primaryKey.first?.value == "1" })
            #expect(sample.column == "post_content")
            #expect(sample.after.contains(newURL))
            #expect(sample.before.contains(oldURL))
            #expect(report.tables.first { $0.table.name == "no_pk" }?.status == .skipped("No primary key: rows can't be addressed safely"))

            let options = try #require(report.tables.first { $0.table.name == "wp_options" })
            #expect(options.rowsChanged == 3)  // siteurl, widget_text, double_encoded; the broken value is NOT changed
            #expect(options.invalidSerialized.count == 1)
            #expect(options.invalidSerialized.first?.primaryKey.first?.value == "5")
            let docs = try #require(report.tables.first { $0.table.name == "wp_docs" })
            #expect(docs.rowsChanged == 1)
            let comp = try #require(report.tables.first { $0.table.name == "comp_key" })
            #expect(comp.rowsScanned == 3)
            #expect(comp.rowsChanged == 3)
        }
    }

    @Test(arguments: DBTarget.all)
    func applyRewritesSerializedJSONAndEscapedValues(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config())
            let plan = sr.plan(tables: try await fx.structures(allTables))
            let report = await sr.run(plan: plan, mode: .apply)

            for t in report.tables { if case .failed(let m) = t.status { Issue.record("\(t.table): \(m)") } }
            #expect(report.conflicts.isEmpty)

            // plain
            let p1 = try await fx.text("wp_posts", "post_content", where: "ID = 1")
            #expect(p1 == "Visit \(newURL)/page now")
            // multibyte
            let p4 = try await fx.text("wp_posts", "post_content", where: "ID = 4")
            #expect(p4 == "Zażółć gęślą jaźń \(newURL)/ü 🙂")
            #expect(try await fx.text("wp_posts", "post_title", where: "ID = 4") == "Ünï \(newURL)")
            // Gutenberg: both the JSON-escaped and the plain spelling
            let p2 = try await fx.text("wp_posts", "post_content", where: "ID = 2")
            #expect(p2.contains(##"https:\/\/new.example.org\/blog\/wp-content\/a.png"##))
            #expect(p2.contains("src=\"\(newURL)/wp-content/a.png\""))
            #expect(!p2.contains("old.example.com"))
            // guid untouched by default
            #expect(try await fx.text("wp_posts", "guid", where: "ID = 1") == "\(oldURL)/?p=1")

            // serialized options re-parse and carry the new value with corrected lengths
            let widget = try await fx.text("wp_options", "option_value", where: "option_id = 2")
            _ = try PHPSerializedParser.parse(widget)
            #expect(widget.contains(phpString("\(newURL)/")))
            #expect(widget.contains(phpString("Héllo wörld \(newURL)/ ünï")))
            #expect(!widget.contains("old.example.com"))
            let double = try await fx.text("wp_options", "option_value", where: "option_id = 3")
            _ = try PHPSerializedParser.parse(double)
            #expect(double.contains("new.example.org/blog/deep"))
            #expect(try await fx.text("wp_options", "option_value", where: "option_id = 1") == newURL)
            // every serialized value in the options table still parses (except the deliberately broken one)
            let allOptions = try await f.session.execute("SELECT option_id, option_value FROM \(f.q).wp_options ORDER BY 1")
            for row in allOptions.rows {
                guard case .text(let v) = row[1], v.hasPrefix("a:"), row[0].displayString != "5" else { continue }
                _ = try PHPSerializedParser.parse(v)
            }
            // the broken value is untouched
            #expect(try await fx.text("wp_options", "option_value", where: "option_id = 5").contains(oldURL))

            // JSON column
            let doc = try await fx.text("wp_docs", "doc", where: "id = 1")
            _ = try JSONDocument.parse(doc)
            #expect(doc.contains("new.example.org"))
            #expect(!doc.contains("http://old") && !doc.contains(#"http:\/\/old"#))
            #expect(doc.contains("Ünï old.example.com"))  // not a URL: left alone

            // composite PK scanned across keyset pages
            #expect(try await fx.text("comp_key", "txt", where: "a = 2 AND b = 'x'") == "\(newURL)/2x")
            #expect(try await fx.text("comp_key", "txt", where: "a = 2 AND b = 'y'") == "untouched")
            // no-PK table never touched
            #expect(try await fx.text("no_pk", "note", where: "1 = 1") == "\(oldURL)/nopk")

            let posts = try #require(report.tables.first { $0.table.name == "wp_posts" })
            #expect(posts.committed)
            #expect(posts.rowsChanged == 3)

            // second run finds nothing left to change
            let again = await sr.run(plan: plan, mode: .dryRun)
            #expect(again.rowsChanged == 0)
        }
    }

    @Test(arguments: DBTarget.all)
    func guidOptInRewritesGUID(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config(guid: true))
            let plan = sr.plan(tables: try await fx.structures(["wp_posts"]))
            _ = await sr.run(plan: plan, mode: .apply)
            #expect(try await fx.text("wp_posts", "guid", where: "ID = 1") == "\(newURL)/?p=1")
        }
    }

    @Test(arguments: DBTarget.all)
    func keysetPagingProcessesEveryBatch(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create(fillerPosts: 23)
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config(batchSize: 5))
            let plan = sr.plan(tables: try await fx.structures(["wp_posts"]))
            let report = await sr.run(plan: plan, mode: .apply)
            #expect(report.tables.first?.rowsChanged == 26)
            let left = try await f.session.execute("SELECT COUNT(*) FROM \(f.q).wp_posts WHERE post_content LIKE '%old.example.com%'")
            #expect(left.rows.first?.first?.displayString == "0")
        }
    }

    @Test(arguments: DBTarget.all)
    func rowChangedBetweenScanAndWriteIsAConflict(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let other = try await target.connectPrivileged()
            let schemaQ = f.q
            let fired = TaskBox()
            let concurrent = "\(oldURL)/changed-by-someone-else"
            let hook: @Sendable (TableRef) async -> Void = { table in
                guard table.name == "wp_options", fired.bump() == 1 else { return }
                _ = try? await other.execute("UPDATE \(schemaQ).wp_options SET option_value = \(f.dialect.quoteString(concurrent)) WHERE option_id = 1")
            }
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config(hook: hook))
            let plan = sr.plan(tables: try await fx.structures(["wp_options"]))
            let report = await sr.run(plan: plan, mode: .apply)
            await other.close()

            #expect(report.conflicts.count == 1)
            #expect(report.conflicts.first?.primaryKey.first?.value == "1")
            // the concurrent writer's value survives untouched; other rows were rewritten
            #expect(try await fx.text("wp_options", "option_value", where: "option_id = 1") == concurrent)
            #expect(try await fx.text("wp_options", "option_value", where: "option_id = 2").contains("new.example.org"))
        }
    }

    @Test(arguments: DBTarget.all)
    func cancellationRollsBackTheTableInFlight(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create(fillerPosts: 20)
            let before = try await fx.snapshot(["wp_posts"])
            let box = TaskBox()
            let hook: @Sendable (TableRef) async -> Void = { _ in
                if box.bump() == 2 { box.task?.cancel() }
            }
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config(batchSize: 5, hook: hook))
            let plan = sr.plan(tables: try await fx.structures(["wp_posts", "wp_options"]))
            let task = Task { await sr.run(plan: plan, mode: .apply) }
            box.task = task
            let report = await task.value

            #expect(report.wasCancelled)
            let posts = try #require(report.tables.first { $0.table.name == "wp_posts" })
            #expect(posts.status == .cancelled)
            #expect(posts.rolledBack)
            #expect(report.tables.first { $0.table.name == "wp_options" }?.status == .notRun)
            #expect(try await fx.snapshot(["wp_posts"]) == before)
            // the session is usable and not stuck in a transaction
            _ = try await f.session.execute("SELECT 1")
        }
    }

    @Test(arguments: DBTarget.all)
    func failedTableRollsBackAndRunContinues(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            // Make the replacement overflow a narrow column (old values fit in 28 chars, new ones don't).
            try await f.run("ALTER TABLE \(f.q).comp_key " + (target.isPostgres
                ? "ALTER COLUMN txt TYPE varchar(28)" : "MODIFY txt varchar(28)"))
            let sr = try DatabaseSearchReplace(session: f.session, configuration: config())
            let plan = sr.plan(tables: try await fx.structures(["comp_key", "wp_options"]))
            let report = await sr.run(plan: plan, mode: .apply)
            let comp = try #require(report.tables.first { $0.table.name == "comp_key" })
            guard case .failed = comp.status else { Issue.record("expected failure, got \(comp.status)"); return }
            #expect(comp.rolledBack)
            #expect(try await fx.text("comp_key", "txt", where: "a = 1 AND b = 'x'") == "\(oldURL)/1x")
            // run continued with the next table
            #expect(report.tables.first { $0.table.name == "wp_options" }?.status == .completed)
        }
    }

    @Test(arguments: DBTarget.all)
    func regexAndCaseInsensitiveRuns(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let fx = SRFixture(f: f)
            try await fx.create()
            let cfg = SearchReplaceConfiguration(
                search: #"HTTP://OLD\.example\.com/(\w+)"#, replace: "https://cdn.example.net/$1",
                options: SafeReplaceOptions(caseSensitive: false, regex: true))
            let sr = try DatabaseSearchReplace(session: f.session, configuration: cfg)
            let plan = sr.plan(tables: try await fx.structures(["wp_posts"]))
            let report = await sr.run(plan: plan, mode: .apply)
            #expect(report.tables.first?.rowsChanged == 3)  // posts 1, 2 (plain src) and 4
            #expect(try await fx.text("wp_posts", "post_content", where: "ID = 1") == "Visit https://cdn.example.net/page now")
        }
    }
}
