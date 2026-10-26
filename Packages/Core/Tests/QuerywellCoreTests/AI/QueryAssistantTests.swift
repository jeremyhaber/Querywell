import Foundation
import Testing
import os

@testable import QuerywellCore

private func def(_ name: String, _ type: String = "bigint", pk: Bool = false, ai: Bool = false, enumValues: [String]? = nil) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: 1, dataType: type, fullType: type, isNullable: !pk, isPrimaryKey: pk, isAutoIncrement: ai, enumValues: enumValues)
}

private func structure(_ name: String, _ cols: [ColumnDefinition], fks: [ForeignKeyDefinition] = [], referencedBy: [ForeignKeyDefinition] = [],
                       indexes: [IndexDefinition] = [], schema: String = "shop") -> TableStructure {
    let ref = TableRef(schema: schema, name: name)
    return TableStructure(info: TableInfo(ref: ref, kind: .table), columns: cols,
                          indexes: [IndexDefinition(name: "PRIMARY", columns: cols.filter(\.isPrimaryKey).map(\.name), isUnique: true, isPrimary: true)] + indexes,
                          foreignKeys: fks.map { var f = $0; f.table = ref; return f }, referencedBy: referencedBy)
}

private func wordPress() -> [TableStructure] {
    let posts = TableRef(schema: "shop", name: "wp_posts")
    let fk = ForeignKeyDefinition(name: "fk_meta_post", columns: ["post_id"], referenced: posts, referencedColumns: ["ID"])
    var postsStructure = structure("wp_posts", [def("ID", pk: true, ai: true), def("post_title", "varchar(255)"),
                                                def("post_status", "enum('publish','draft')", enumValues: ["publish", "draft"])],
                                   indexes: [IndexDefinition(name: "post_name", columns: ["post_name"], isUnique: false, isPrimary: false)])
    postsStructure.referencedBy = [{ var f = fk; f.table = TableRef(schema: "shop", name: "wp_postmeta"); return f }()]
    return [
        postsStructure,
        structure("wp_postmeta", [def("meta_id", pk: true), def("post_id"), def("meta_key", "varchar(255)"), def("meta_value", "longtext")], fks: [fk]),
        structure("wp_options", [def("option_id", pk: true), def("option_name", "varchar(191)"), def("option_value", "longtext"), def("autoload", "varchar(20)")]),
        structure("wp_users", [def("ID", pk: true), def("user_login", "varchar(60)")]),
        structure("wp_usermeta", [def("umeta_id", pk: true), def("user_id"), def("meta_key", "varchar(255)")]),
    ]
}

private func context(prompt: String = "", allowSampleRows: Bool = false, samples: [TableRef: SampleRows]? = nil,
                     structures: [TableStructure]? = nil, engine: DatabaseEngine = .mysql) -> AssistantContext {
    AssistantContext.make(engine: engine, serverVersion: "8.4.3", currentSchema: "shop", structures: structures ?? wordPress(),
                          prompt: prompt, allowSampleRows: allowSampleRows, sampleRows: samples)
}

private let secretRow = SampleRows(columns: ["user_login", "user_email"], rows: [[.text("alice"), .text("alice-private@example.com")]])

@Suite("Assistant prompts")
struct AssistantPromptTests {
    @Test func schemaOnlyByDefault() {
        let samples = [TableRef(schema: "shop", name: "wp_users"): secretRow]
        let c = context(prompt: "list users", allowSampleRows: false, samples: samples)
        #expect(c.sampleRows == nil)
        for action in [AssistantAction.generate("list users"), .explain(sql: "SELECT 1"), .fixError(sql: "x", error: "e"), .optimize(sql: "x", explainPlanJSON: nil)] {
            let system = QueryAssistant.systemPrompt(for: action, context: c)
            let user = QueryAssistant.userMessage(for: action, context: c)
            #expect(!system.contains("alice") && !user.contains("alice"))
            #expect(!system.contains("Sample rows"))
        }
        // default init also drops them
        let direct = AssistantContext(engine: .mysql, schemaSummary: "s", sampleRows: samples)
        #expect(direct.sampleRows == nil)
    }

    @Test func sampleRowsOnlyWithExplicitOptIn() {
        let samples = [TableRef(schema: "shop", name: "wp_users"): secretRow]
        let c = context(prompt: "users", allowSampleRows: true, samples: samples)
        #expect(c.sampleRows?.count == 1)
        let system = QueryAssistant.systemPrompt(for: .generate("users"), context: c)
        #expect(system.contains("## Sample rows"))
        #expect(system.contains("alice-private@example.com"))
        #expect(system.contains("wp_users:") && system.contains("user_login | user_email"))
    }

    @Test func sampleRowsAreBoundedAndBytesRedacted() {
        let rows = (0..<10).map { [DatabaseValue.integer(Int64($0)), .text(String(repeating: "x", count: 500)), .bytes(Data(repeating: 1, count: 4096)), .null] }
        let c = context(allowSampleRows: true, samples: [TableRef(schema: "shop", name: "t"): SampleRows(columns: ["a", "b", "c", "d"], rows: rows)])
        let s = QueryAssistant.systemPrompt(for: .generate("x"), context: c)
        #expect(s.components(separatedBy: "\n").filter { $0.contains("xxxx") }.count == 3)
        #expect(s.contains("<4096 bytes>") && s.contains("NULL") && !s.contains(String(repeating: "x", count: 100)))
    }

    @Test func systemPromptCoreRules() {
        let s = QueryAssistant.systemPrompt(for: .generate("x"), context: context())
        #expect(s.contains("MySQL 8.4.3"))
        #expect(s.contains("single ```sql fenced block"))
        #expect(s.contains("Never invent a table or column"))
        #expect(s.contains("precise WHERE"))
        #expect(s.contains("SELECT with the same WHERE"))
        #expect(s.contains("never run automatically"))
        #expect(s.contains("`shop`"))
        #expect(s.contains("## Schema") && s.contains("wp_posts (ID bigint PK AI"))
        let pgPrompt = QueryAssistant.systemPrompt(for: .generate("x"), context: context(engine: .postgresql))
        #expect(pgPrompt.contains("PostgreSQL") && pgPrompt.contains("ILIKE") && !pgPrompt.contains("backticks"))
        let maria = QueryAssistant.systemPrompt(for: .generate("x"), context: context(engine: .mariadb))
        #expect(maria.contains("MariaDB"))
    }

    @Test func explainAsksForProseNotSQL() {
        let s = QueryAssistant.systemPrompt(for: .explain(sql: "SELECT 1"), context: context())
        #expect(s.contains("Explain in plain language"))
        #expect(!s.contains("Reply with SQL only"))
        #expect(QueryAssistant.userMessage(for: .explain(sql: "SELECT 1"), context: context()).contains("```sql\nSELECT 1\n```"))
        #expect(!AssistantAction.explain(sql: "x").producesSQL && AssistantAction.generate("x").producesSQL)
    }

    @Test func fixAndOptimizeMessages() {
        let c = context()
        let fix = QueryAssistant.userMessage(for: .fixError(sql: "SELEC 1", error: "You have an error in your SQL syntax"), context: c)
        #expect(fix.contains("SELEC 1") && fix.contains("You have an error in your SQL syntax"))
        #expect(QueryAssistant.systemPrompt(for: .fixError(sql: "", error: ""), context: c).contains("smallest change"))
        let withPlan = QueryAssistant.userMessage(for: .optimize(sql: "SELECT *", explainPlanJSON: "{\"query_block\":1}"), context: c)
        #expect(withPlan.contains("EXPLAIN output:") && withPlan.contains("query_block"))
        let big = QueryAssistant.userMessage(for: .optimize(sql: "SELECT *", explainPlanJSON: String(repeating: "p", count: 50_000)), context: c)
        #expect(big.count < 9_000)
        #expect(QueryAssistant.userMessage(for: .optimize(sql: "SELECT *", explainPlanJSON: nil), context: c).contains("No EXPLAIN output"))
        #expect(QueryAssistant.systemPrompt(for: .optimize(sql: "", explainPlanJSON: nil), context: c).contains("CREATE INDEX"))
    }

    @Test func wordPressDetectionAndPrompt() {
        let c = context()
        #expect(c.wordPress == WordPressInfo(prefix: "wp_", isMultisite: false))
        let s = QueryAssistant.systemPrompt(for: .generate("x"), context: c)
        #expect(s.contains("## WordPress") && s.contains("`wp_`") && s.contains("wp_postmeta"))
        #expect(s.contains("post_status") && s.contains("post_type") && s.contains("meta_key") && s.contains("meta_value"))
        #expect(s.contains("PHP-serialized") && s.contains("NEVER write SQL that string-replaces"))
        #expect(s.contains("Search & Replace"))
        #expect(s.contains("autoload") && s.contains("_transient_%"))
        #expect(!s.contains("multisite"))
        // not WordPress: no section
        let plain = context(structures: [structure("orders", [def("id", pk: true)])])
        #expect(plain.wordPress == nil)
        #expect(!QueryAssistant.systemPrompt(for: .generate("x"), context: plain).contains("WordPress"))
    }

    @Test func wordPressPrefixVariants() {
        func names(_ p: String) -> [String] { ["posts", "options", "postmeta", "users", "usermeta", "comments"].map { p + $0 } }
        #expect(WordPressDetector.detect(tableNames: names("wp7k_"))?.prefix == "wp7k_")
        #expect(WordPressDetector.detect(tableNames: names("WP_"))?.prefix == "WP_")
        #expect(WordPressDetector.detect(tableNames: names(""))?.prefix == "")
        #expect(WordPressDetector.detect(tableNames: ["wp_posts", "wp_options", "wp_postmeta", "wp_users"])?.prefix == "wp_")  // 4 of 5
        #expect(WordPressDetector.detect(tableNames: ["wp_posts", "wp_options", "wp_postmeta"]) == nil)
        #expect(WordPressDetector.detect(tableNames: ["blog_posts", "orders", "wp_options"]) == nil)
        #expect(WordPressDetector.detect(tableNames: []) == nil)
        // case-insensitive (Windows lower_case_table_names)
        #expect(WordPressDetector.detect(tableNames: ["WP_Posts", "wp_OPTIONS", "wp_postmeta", "wp_users", "wp_usermeta"])?.prefix == "WP_")
        // two installs in one schema: the complete one wins
        #expect(WordPressDetector.detect(tableNames: names("a_") + ["b_posts", "b_options"])?.prefix == "a_")
        // Live + staging copy: both are found, the more complete / shorter one is primary.
        let both = names("wpstg0_") + names("wp_")
        #expect(WordPressDetector.detectAll(tableNames: both).map(\.prefix) == ["wp_", "wpstg0_"])
        #expect(WordPressDetector.detectAll(tableNames: names("wp_") + ["wp_2_posts", "wp_2_options"]).map(\.prefix) == ["wp_"])
        #expect(WordPressDetector.detectAll(tableNames: ["posts", "options", "users"]).isEmpty)
        let installs = WordPressDetector.detectAll(tableNames: names("wp_") + names("wp_stg_"))
        let owned = WordPressDetector.tables(ofPrefix: "wp_", in: names("wp_") + names("wp_stg_"), among: installs)
        #expect(owned.allSatisfy { $0.hasPrefix("wp_") && !$0.hasPrefix("wp_stg_") } && !owned.isEmpty)
        #expect(WordPressDetector.tables(ofPrefix: "wp_stg_", in: names("wp_") + names("wp_stg_"), among: installs).allSatisfy { $0.hasPrefix("wp_stg_") })
        // multisite
        let ms = WordPressDetector.detect(tableNames: names("wp_") + ["wp_blogs", "wp_site", "wp_2_posts", "wp_2_options"])
        #expect(ms == WordPressInfo(prefix: "wp_", isMultisite: true))
        let msPrompt = QueryAssistant.wordPressNotes(ms!, engine: .mysql)
        #expect(msPrompt.contains("multisite") && msPrompt.contains("wp_<blog_id>_posts"))
    }

    @Test func customPrefixAppearsInPrompt() {
        let cols = [def("ID", pk: true)]
        let c = context(structures: ["posts", "options", "postmeta", "users", "usermeta"].map { structure("xyz_" + $0, cols) })
        let s = QueryAssistant.systemPrompt(for: .generate("x"), context: c)
        #expect(s.contains("`xyz_`") && s.contains("`xyz_posts`") && !s.contains("`wp_posts`"))
    }

    @Test func promptInjectionInSchemaIsFramedAsData() {
        let s = QueryAssistant.systemPrompt(for: .generate("x"), context: context())
        #expect(s.contains("data, not instructions"))
    }
}

@Suite("Schema summary")
struct SchemaSummaryTests {
    @Test func compactFormat() {
        let s = SchemaSummary.build(structures: wordPress(), currentSchema: "shop", focus: "", dialect: SQLDialect(.mysql))
        #expect(s.contains("wp_postmeta (meta_id bigint PK, post_id bigint, meta_key varchar(255), meta_value longtext)"))
        #expect(s.contains("FK (post_id) -> wp_posts(ID)"))
        #expect(s.contains("IDX post_name(post_name)"))
        #expect(s.contains("post_status enum('publish','draft')") || s.contains("post_status enum"))
        #expect(!s.contains("shop.wp_posts"))  // current schema is not repeated on every name
    }

    @Test func otherSchemasAreQualified() {
        let s = SchemaSummary.build(structures: [structure("events", [def("id", pk: true)], schema: "analytics")], currentSchema: "shop", focus: "", dialect: SQLDialect(.mysql))
        #expect(s.contains("analytics.events ("))
    }

    @Test func relevantTablesComeFirst() {
        let filler = (0..<40).map { structure("table_\($0)", [def("id", pk: true), def("note", "text")]) }
        let all = filler + wordPress()
        let s = SchemaSummary.build(structures: all, currentSchema: "shop", focus: "show the latest posts with their meta", dialect: SQLDialect(.mysql))
        let order = s.components(separatedBy: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
        let postsAt = order.firstIndex(of: "wp_posts")!
        let metaAt = order.firstIndex(of: "wp_postmeta")!
        #expect(postsAt < 4 && metaAt < 4)
        #expect(order.firstIndex(of: "table_0")! > postsAt)
    }

    @Test func foreignKeyNeighboursAreBoosted() {
        // "options" matches wp_options by name; wp_posts is not mentioned but is the FK neighbour of wp_postmeta ("meta").
        let s = SchemaSummary.build(structures: wordPress() + (0..<30).map { structure("zz_\($0)", [def("id", pk: true)]) },
                                    currentSchema: "shop", focus: "meta keys", dialect: SQLDialect(.mysql), maxChars: 700)
        #expect(s.contains("wp_postmeta (") && s.contains("wp_posts ("))
    }

    @Test func pluralsMatchSingularNames() {
        let s = SchemaSummary.build(structures: [structure("category", [def("id", pk: true)]), structure("aaa", [def("id", pk: true)]),
                                                 structure("user", [def("id", pk: true)])],
                                    currentSchema: "s", focus: "how many categories per user", dialect: SQLDialect(.mysql), maxChars: 500)
        let lines = s.components(separatedBy: "\n")
        #expect(lines[1].contains("category") || lines[1].contains("user"))
        #expect(!lines[1].contains("aaa"))
    }

    @Test func sizeCapIsHard() {
        let big = (0..<400).map { i in structure("table_number_\(i)", (0..<30).map { def("column_number_\($0)", "varchar(255)") } + [def("id", pk: true)]) }
        let zebra = structure("zebra_stripes", [def("id", pk: true)])
        for cap in [12_000, 3_000, 800] {
            let s = SchemaSummary.build(structures: big + [zebra], currentSchema: "shop", focus: "zebra", dialect: SQLDialect(.mysql), maxChars: cap)
            #expect(s.count <= cap, "cap \(cap) got \(s.count)")
            if cap >= 3_000 { #expect(s.contains("zebra_stripes ("), "most relevant table kept at cap \(cap)") }
            #expect(s.contains("more tables not shown") || s.contains("Other tables"))
        }
        #expect(AssistantContext.make(engine: .mysql, serverVersion: nil, currentSchema: "shop", structures: big, prompt: "x").schemaSummary.count <= SchemaSummary.defaultCap)
        #expect(SchemaSummary.defaultCap == 12_000)
    }

    @Test func tablesWithoutStructureAreListedByName() {
        let others = (0..<5).map { TableInfo(ref: TableRef(schema: "shop", name: "extra_\($0)"), kind: $0 == 0 ? .view : .table) }
        let s = SchemaSummary.build(structures: wordPress(), otherTables: others, currentSchema: "shop", focus: "", dialect: SQLDialect(.mysql))
        #expect(s.contains("Other tables (columns omitted):") && s.contains("extra_3"))
    }

    @Test func wideTablesAreTruncated() {
        let wide = structure("wide", (0..<200).map { def("c\($0)") })
        let s = SchemaSummary.build(structures: [wide], currentSchema: "shop", focus: "", dialect: SQLDialect(.mysql))
        #expect(s.contains("… +120 more"))
    }
}

@Suite("SQL extraction")
struct SQLExtractorTests {
    @Test func fencedBlock() {
        #expect(SQLExtractor.extractSQL(from: "Here you go:\n```sql\nSELECT 1;\n```\nHope it helps") == "SELECT 1;")
        #expect(SQLExtractor.extractSQL(from: "```SQL\nSELECT 1\n```") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "```mysql\nSELECT 1\n```") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "```postgresql\nSELECT 1\n```") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "```\nSELECT 1\n```") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "```sql\r\nSELECT 1\r\n```\r\n") == "SELECT 1")
    }

    @Test func noFenceMeansWholeText() {
        #expect(SQLExtractor.extractSQL(from: "  SELECT 1  \n") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "") == "")
    }

    @Test func sqlBlocksBeatOtherBlocksAndJoin() {
        let t = "```json\n{\"a\":1}\n```\n```sql\nSELECT 1;\n```\ntext\n```sql\nUPDATE t SET a=1;\n```"
        #expect(SQLExtractor.extractSQL(from: t) == "SELECT 1;\n\nUPDATE t SET a=1;")
        #expect(SQLExtractor.extractSQL(from: "```\nplain\n```\n```sql\nSELECT 2\n```") == "SELECT 2")
    }

    @Test func fencesInsideSQLStringsDoNotConfuse() {
        let t = "```sql\nSELECT '```' AS x, \"a\nb\" FROM t;\n```"
        // a fence marker inside the SQL only counts at the start of a line
        #expect(SQLExtractor.extractSQL(from: t) == "SELECT '```' AS x, \"a\nb\" FROM t;")
    }

    @Test func streamingPrefixesAreStable() {
        let full = "Sure!\n```sql\nSELECT a,\n       b\nFROM t\nWHERE x = 1;\n```\nDone."
        var previous = ""
        for i in 0...full.count {
            let partial = String(full.prefix(i))
            let sql = SQLExtractor.extractSQL(from: partial)
            if partial.contains("```sql\n") {
                // once the block opened, the SQL only grows (never flickers back or shows fence characters)
                #expect(sql.hasPrefix(previous) || previous.hasPrefix(sql) && sql.count >= previous.count - 1, "\(partial.debugDescription) -> \(sql.debugDescription)")
                #expect(!sql.contains("`"), "\(partial.debugDescription) -> \(sql.debugDescription)")
            }
            previous = sql
        }
        #expect(SQLExtractor.extractSQL(from: full) == "SELECT a,\n       b\nFROM t\nWHERE x = 1;")
        // half-typed opening fence yields nothing; closing fence being typed is dropped
        #expect(SQLExtractor.extractSQL(from: "```sq") == "")
        #expect(SQLExtractor.extractSQL(from: "```sql\nSELECT 1\n``") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "```sql\nSELECT 1") == "SELECT 1")
        #expect(SQLExtractor.extractSQL(from: "SELECT 1``") == "SELECT 1")
    }

    @Test func reviewFlagsWrites() {
        let d = SQLDialect(.mysql)
        let read = AssistantSQLReview.review(sql: "SELECT * FROM t", dialect: d)
        #expect(!read.containsWrites && !read.containsDestructive)
        let w = AssistantSQLReview.review(sql: "SELECT 1; UPDATE t SET a = 1 WHERE id = 2", dialect: d)
        #expect(w.containsWrites && w.statements.count == 2)
        let u = AssistantSQLReview.review(sql: "DELETE FROM t", dialect: d)
        #expect(u.containsDestructive && u.hasUnfilteredMutation)
    }
}

// MARK: - End to end with a mock provider

private final class ScriptedProvider: AIProvider {
    let id = AIProviderID.anthropic
    let deltas: [String]
    let failure: AIError?
    private let captured = OSAllocatedUnfairLock(initialState: [AIRequest]())

    init(_ deltas: [String], failure: AIError? = nil) {
        self.deltas = deltas
        self.failure = failure
    }

    var requests: [AIRequest] { captured.withLock { $0 } }

    func listModels() async throws -> [AIModelInfo] { [] }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        captured.withLock { $0.append(request) }
        let deltas = deltas, failure = failure
        return AsyncThrowingStream { c in
            for d in deltas { c.yield(.textDelta(d)) }
            if let failure { c.finish(throwing: failure) } else {
                c.yield(.done(AIUsage(inputTokens: 5, outputTokens: 6)))
                c.finish()
            }
        }
    }
}

@Suite("Query assistant end to end")
struct QueryAssistantEndToEndTests {
    @Test func generateStreamsAndExtractsSQL() async throws {
        let provider = ScriptedProvider(["Here:\n``", "`sql\nSELECT p.post_title\nFROM wp_", "posts p\nWHERE p.post_status = 'publish'\nLIMIT 10;\n", "```\nEnjoy"])
        let assistant = QueryAssistant(provider: provider, model: "claude-sonnet-5-5", maxTokens: 999)
        var updates: [AssistantUpdate] = []
        for try await u in assistant.run(.generate("latest published posts"), context: context(prompt: "latest published posts")) { updates.append(u) }

        #expect(updates.count == 5)
        #expect(updates.map(\.sql!).dropLast().allSatisfy { !$0.contains("`") })
        #expect(updates[1].sql == "SELECT p.post_title\nFROM wp_")
        let last = try #require(updates.last)
        #expect(last.isFinished && last.usage == AIUsage(inputTokens: 5, outputTokens: 6))
        #expect(last.sql == "SELECT p.post_title\nFROM wp_posts p\nWHERE p.post_status = 'publish'\nLIMIT 10;")
        #expect(last.text.hasSuffix("Enjoy"))
        #expect(updates.dropLast().allSatisfy { !$0.isFinished })

        let req = try #require(provider.requests.first)
        #expect(req.model == "claude-sonnet-5-5" && req.maxTokens == 999)
        #expect(req.messages == [.user("latest published posts")])
        #expect(req.system.contains("wp_posts (") && req.system.contains("## WordPress"))
    }

    @Test func explainYieldsProseWithoutSQL() async throws {
        let provider = ScriptedProvider(["It selects ", "all posts."])
        var last: AssistantUpdate?
        for try await u in QueryAssistant(provider: provider, model: "m").run(.explain(sql: "SELECT * FROM wp_posts"), context: context()) { last = u }
        #expect(last?.sql == nil && last?.text == "It selects all posts." && last?.isFinished == true)
        #expect(provider.requests[0].messages[0].text.contains("SELECT * FROM wp_posts"))
    }

    @Test func providerErrorsSurfaceAsAIError() async {
        let provider = ScriptedProvider(["SEL"], failure: .rateLimited(retryAfter: 4))
        var seen = ""
        do {
            for try await u in QueryAssistant(provider: provider, model: "m").run(.generate("x"), context: context()) { seen = u.text }
            Issue.record("expected error")
        } catch let e as AIError {
            #expect(e == .rateLimited(retryAfter: 4) && seen == "SEL")
        } catch { Issue.record("\(error)") }
    }

    @Test func assistantOutputNeverExecutesAnything() async throws {
        // The assistant has no session: what it returns is text. Running it requires QueryRunner, which
        // applies the write guard (here: production -> confirmation, nothing executed).
        let provider = ScriptedProvider(["```sql\nDELETE FROM wp_posts WHERE post_status = 'trash';\n```"])
        var sql = ""
        for try await u in QueryAssistant(provider: provider, model: "m").run(.generate("clean trash"), context: context()) { sql = u.sql ?? "" }
        let runner = QueryRunner(guardContext: GuardContext(isProduction: true, isReadOnly: false, databaseName: "shop", connectionName: "Prod", dialect: SQLDialect(.mysql)))
        let session = ScriptedSession(replies: [])
        guard case .needsConfirmation(let pending) = runner.prepare(script: sql) else { Issue.record("PROD write must need confirmation"); return }
        #expect(session.executed.isEmpty)
        #expect(pending.request.requiresTypedName == "shop")
        #expect(AssistantSQLReview.review(sql: sql, dialect: SQLDialect(.mysql)).containsWrites)
    }

    @Test func contextLoaderUsesInspectorAndKeepsSamplesOptIn() async throws {
        struct Inspector: SchemaInspector {
            func listSchemas() async throws -> [String] { ["shop"] }
            func listTables(schema: String) async throws -> [TableInfo] { wordPress().map(\.info) }
            func listRoutines(schema: String) async throws -> [RoutineInfo] { [] }
            func structure(of table: TableRef) async throws -> TableStructure { wordPress().first { $0.info.ref == table }! }
            func availableCollations() async throws -> [CollationInfo] { [] }
            func availableEngines() async throws -> [String] { [] }
        }
        let samples = [TableRef(schema: "shop", name: "wp_users"): secretRow]
        let off = try await AssistantContext.load(from: Inspector(), engine: .mysql, serverVersion: "8", schema: "shop", prompt: "posts", sampleRows: samples)
        #expect(off.sampleRows == nil && off.wordPress?.prefix == "wp_" && off.schemaSummary.contains("wp_posts ("))
        let on = try await AssistantContext.load(from: Inspector(), engine: .mysql, serverVersion: "8", schema: "shop", prompt: "posts", allowSampleRows: true, sampleRows: samples)
        #expect(on.sampleRows != nil)
        // beyond maxTables, the rest are names only
        let few = try await AssistantContext.load(from: Inspector(), engine: .mysql, serverVersion: "8", schema: "shop", prompt: "posts", maxTables: 2)
        #expect(few.schemaSummary.contains("wp_posts (") && few.schemaSummary.contains("Other tables (columns omitted):"))
    }
}
