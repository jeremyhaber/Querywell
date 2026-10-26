import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func stmt(_ sql: String, engine: DatabaseEngine, analyze: Bool = false) throws -> ExplainStatement {
    try ExplainPlanner.statement(sql: sql, dialect: SQLDialect(engine), engine: engine, analyze: analyze)
}

@Suite("EXPLAIN planning")
struct ExplainStatementTests {
    @Test func perEngineSyntax() throws {
        #expect(try stmt("SELECT 1;", engine: .mysql).sql == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(try stmt("SELECT 1", engine: .mariadb).sql == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(try stmt("SELECT 1", engine: .postgresql).sql == "EXPLAIN (FORMAT JSON) SELECT 1")
    }

    @Test func analyzeVariantsForReads() throws {
        let m = try stmt("SELECT * FROM t", engine: .mysql, analyze: true)
        #expect(m.sql == "EXPLAIN ANALYZE SELECT * FROM t" && m.isAnalyze && m.note == nil)
        #expect(try stmt("SELECT * FROM t", engine: .mariadb, analyze: true).sql == "ANALYZE FORMAT=JSON SELECT * FROM t")
        #expect(try stmt("WITH c AS (SELECT 1) SELECT * FROM c", engine: .postgresql, analyze: true).sql
                == "EXPLAIN (ANALYZE, FORMAT JSON) WITH c AS (SELECT 1) SELECT * FROM c")
    }

    @Test func analyzeIsNeverUsedForWrites() throws {
        for engine in DatabaseEngine.allCases {
            for sql in ["UPDATE t SET a = 1 WHERE b = 2", "DELETE FROM t WHERE a = 1", "INSERT INTO t VALUES (1)",
                        "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", "SELECT * FROM t FOR UPDATE",
                        "SELECT a INTO OUTFILE '/tmp/x' FROM t"] {
                let e = try stmt(sql, engine: engine, analyze: true)
                #expect(!e.isAnalyze, "\(engine) \(sql)")
                #expect(!e.sql.uppercased().contains("ANALYZE"), "\(engine) \(sql): \(e.sql)")
                #expect(e.note?.contains("only runs for read-only") == true)
            }
        }
    }

    @Test func analyzeNotMentionedWhenNotAsked() throws {
        let e = try stmt("UPDATE t SET a = 1 WHERE b = 2", engine: .postgresql)
        #expect(e.sql == "EXPLAIN (FORMAT JSON) UPDATE t SET a = 1 WHERE b = 2" && e.note == nil)
    }

    @Test func unsupportedStatements() {
        for sql in ["EXPLAIN SELECT 1", "CREATE TABLE t (a int)", "DROP TABLE t", "SHOW TABLES", "SET a = 1", ""] {
            #expect(throws: ExplainError.self) { try stmt(sql, engine: .mysql) }
        }
    }
}

@Suite("EXPLAIN parsing")
struct ExplainParseTests {
    @Test func postgresTree() throws {
        let json = """
        [{"Plan":{"Node Type":"Sort","Total Cost":1500.5,"Plan Rows":50000,"Sort Key":["o.created"],"Sort Method":"external merge",
          "Plans":[{"Node Type":"Hash Join","Join Type":"Inner","Hash Cond":"(o.user_id = u.id)","Total Cost":1200.0,"Plan Rows":50000,
            "Plans":[{"Node Type":"Seq Scan","Relation Name":"orders","Alias":"o","Total Cost":900.0,"Plan Rows":50000,"Filter":"(x > 1)","Rows Removed by Filter":10},
                     {"Node Type":"Index Scan","Relation Name":"users","Alias":"u","Index Name":"users_pkey","Total Cost":8.3,"Plan Rows":1,"Index Cond":"(id = 5)"}]}]},
          "Planning Time":0.25,"Execution Time":12.5}]
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .postgresql)
        #expect(plan.engine == .postgresql && !plan.isAnalyze)
        #expect(plan.root.title == "Sort" && plan.root.nodeType == "Sort")
        #expect(plan.root.cost == 1500.5 && plan.root.rows == 50000)
        #expect(plan.root.extra.contains("Sort key: o.created"))
        #expect(plan.planningTimeMs == 0.25 && plan.executionTimeMs == 12.5)
        let nodes = plan.root.flattened
        #expect(nodes.map(\.id) == ["0", "0.0", "0.0.0", "0.0.1"])
        let seq = nodes[2]
        #expect(seq.title == "Seq Scan on orders o" && seq.table == "orders" && seq.extra.contains("Filter: (x > 1)"))
        #expect(seq.extra.contains("Rows removed by filter: 10"))
        let idx = nodes[3]
        #expect(idx.title == "Index Scan using users_pkey on users u" && idx.keyUsed == "users_pkey")
        #expect(plan.warnings.contains { $0.message.contains("Sequential scan on orders") && $0.severity == .warning })
        #expect(plan.warnings.contains { $0.message.contains("spilled to disk") })
        #expect(!plan.warnings.contains { $0.message.contains("users") })
    }

    @Test func postgresSmallSeqScanIsFineAndAnalyzeAddsActuals() throws {
        let json = """
        [{"Plan":{"Node Type":"Seq Scan","Relation Name":"tiny","Alias":"tiny","Total Cost":1.1,"Plan Rows":10,"Actual Rows":4000,"Actual Loops":1,"Actual Total Time":3.5},
          "Planning Time":0.1,"Execution Time":3.9}]
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .postgresql, analyze: true)
        #expect(plan.isAnalyze && plan.root.actualRows == 4000 && plan.root.actualTimeMs == 3.5)
        #expect(!plan.warnings.contains { $0.severity == .warning })
        #expect(plan.warnings.contains { $0.severity == .info && $0.message.contains("estimated 10 rows") })
    }

    @Test func thresholdIsConfigurable() throws {
        let json = #"[{"Plan":{"Node Type":"Seq Scan","Relation Name":"t","Alias":"t","Total Cost":1,"Plan Rows":500}}]"#
        #expect(try ExplainPlanner.parse(output: json, engine: .postgresql).warnings.isEmpty)
        #expect(try ExplainPlanner.parse(output: json, engine: .postgresql, thresholds: ExplainThresholds(largeTableRows: 100)).warnings.count == 1)
    }

    @Test func mysqlJSON() throws {
        let json = """
        {"query_block":{"select_id":1,"cost_info":{"query_cost":"25012.40"},
          "ordering_operation":{"using_filesort":true,
            "nested_loop":[
              {"table":{"table_name":"p","access_type":"ALL","possible_keys":["PRIMARY"],"rows_examined_per_scan":120000,"rows_produced_per_join":120000,"filtered":"100.00",
                        "cost_info":{"read_cost":"12000.00","eval_cost":"12000.00","prefix_cost":"24000.00"},"attached_condition":"(p.post_status = 'publish')"}},
              {"table":{"table_name":"pm","access_type":"ref","key":"post_id","used_key_parts":["post_id"],"rows_examined_per_scan":3,"rows_produced_per_join":360000,
                        "cost_info":{"prefix_cost":"25012.40"},"using_index":true}}]}}}
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .mysql)
        #expect(plan.root.title == "Query block #1" && plan.root.cost == 25012.40)
        let sort = try #require(plan.root.children.first)
        #expect(sort.title == "Sort")
        let join = try #require(sort.children.first)
        #expect(join.title == "Nested loop join" && join.children.count == 2)
        let scan = join.children[0], lookup = join.children[1]
        #expect(scan.title == "Full table scan on p" && scan.accessType == "ALL" && scan.rows == 120000 && scan.cost == 24000)
        #expect(scan.extra.contains("Filter: (p.post_status = 'publish')"))
        #expect(lookup.title == "Index lookup on pm using post_id" && lookup.keyUsed == "post_id" && lookup.extra.contains("Using index (covering)"))
        let messages = plan.warnings.map(\.message)
        #expect(messages.contains { $0.contains("Full table scan on p") && $0.contains("120,000") })
        #expect(messages.contains { $0.contains("filesort") })
        #expect(!messages.contains { $0.contains("temporary") })
    }

    @Test func mysqlTemporaryTableAndGrouping() throws {
        let json = """
        {"query_block":{"select_id":1,"grouping_operation":{"using_temporary_table":true,"using_filesort":false,
          "table":{"table_name":"t","access_type":"index","key":"k","rows_examined_per_scan":50,"cost_info":{"prefix_cost":"6.0"}}}}}
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .mysql)
        #expect(plan.root.children[0].title == "Group")
        #expect(plan.warnings.contains { $0.message == "Builds a temporary table." })
        #expect(!plan.warnings.contains { $0.message.contains("filesort") })
        #expect(plan.root.flattened.contains { $0.table == "t" })
    }

    @Test func mysqlUnionAndSubqueries() throws {
        let json = """
        {"query_block":{"union_result":{"using_temporary_table":true,"query_specifications":[
          {"dependent":false,"cacheable":true,"query_block":{"select_id":1,"table":{"table_name":"a","access_type":"ALL","rows_examined_per_scan":5}}},
          {"dependent":false,"cacheable":true,"query_block":{"select_id":2,"table":{"table_name":"b","access_type":"const","key":"PRIMARY","rows_examined_per_scan":1}}}]}}}
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .mysql)
        let tables = plan.root.flattened.compactMap(\.table)
        #expect(tables == ["a", "b"])
        #expect(plan.root.flattened.contains { $0.title == "UNION" })
        let sub = """
        {"query_block":{"select_id":1,"table":{"table_name":"t","access_type":"ALL","rows_examined_per_scan":3,
          "attached_subqueries":[{"dependent":true,"cacheable":false,"query_block":{"select_id":2,"table":{"table_name":"u","access_type":"ref","key":"i"}}}]}}}
        """
        let p2 = try ExplainPlanner.parse(output: sub, engine: .mysql)
        #expect(p2.root.flattened.compactMap(\.table).sorted() == ["t", "u"])
    }

    @Test func mariaDBJSONAndAnalyze() throws {
        let json = """
        {"query_block":{"select_id":1,"r_loops":1,"r_total_time_ms":5.5,
          "read_sorted_file":{"r_rows":900,"filesort":{"sort_key":"t.created","r_loops":1,
            "table":{"table_name":"t","access_type":"ALL","rows":90000,"r_rows":90000,"r_total_time_ms":4.2,"filtered":100,"r_filtered":10,"attached_condition":"t.a > 3"}}}}}
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .mariadb, analyze: true)
        #expect(plan.isAnalyze && plan.executionTimeMs == 5.5)
        let scan = try #require(plan.root.flattened.first { $0.table == "t" })
        #expect(scan.rows == 90000 && scan.actualRows == 90000 && scan.actualTimeMs == 4.2)
        #expect(plan.root.flattened.contains { $0.title == "Sort" })
        #expect(plan.warnings.contains { $0.message.contains("Full table scan on t") })
        #expect(plan.warnings.contains { $0.message.contains("filesort") })
    }

    @Test func mariaDBTemporaryTable() throws {
        let json = """
        {"query_block":{"select_id":1,"temporary_table":{"table":{"table_name":"x","access_type":"ALL","rows":2}}}}
        """
        let plan = try ExplainPlanner.parse(output: json, engine: .mariadb)
        #expect(plan.warnings.contains { $0.message == "Builds a temporary table." })
        #expect(plan.root.flattened.contains { $0.table == "x" })
    }

    @Test func mysqlExplainAnalyzeTextTree() throws {
        let text = """
        -> Sort: p.post_date DESC  (cost=3.1 rows=30) (actual time=0.2..0.2 rows=30 loops=1)
            -> Filter: (p.post_status = 'publish')  (cost=3.1 rows=30) (actual time=0.03..0.09 rows=30 loops=1)
                -> Table scan on p  (cost=3.1 rows=20000) (actual time=0.02..0.07 rows=40 loops=1)
            -> Single-row index lookup on u using PRIMARY (ID=p.post_author)  (cost=0.25 rows=1) (actual time=0.001..0.001 rows=1 loops=40)
        """
        let plan = try ExplainPlanner.parse(output: text, engine: .mysql, analyze: true)
        #expect(plan.isAnalyze && plan.root.nodeType == "Sort")
        #expect(plan.root.children.count == 2)
        #expect(plan.root.children[0].children.count == 1)
        let scan = plan.root.children[0].children[0]
        #expect(scan.table == "p" && scan.rows == 20000 && scan.actualRows == 40 && scan.cost == 3.1)
        let lookup = plan.root.children[1]
        #expect(lookup.keyUsed == "PRIMARY" && lookup.actualRows == 1)
        #expect(plan.warnings.contains { $0.message.contains("Table scan on p") })
        #expect(plan.root.id == "0" && plan.root.children[1].id == "0.1")
    }

    @Test func garbageIsAnErrorNotACrash() {
        #expect(throws: ExplainError.self) { try ExplainPlanner.parse(output: "", engine: .postgresql) }
        #expect(throws: ExplainError.self) { try ExplainPlanner.parse(output: "not json", engine: .postgresql) }
        #expect(throws: ExplainError.self) { try ExplainPlanner.parse(output: "[]", engine: .postgresql) }
        #expect(throws: ExplainError.self) { try ExplainPlanner.parse(output: "{}", engine: .mysql) }
        #expect(throws: ExplainError.self) { try ExplainPlanner.parse(output: "<xml/>", engine: .mariadb) }
    }

    @Test func runsThroughASession() async throws {
        let json = #"[{"Plan":{"Node Type":"Result","Total Cost":0.01,"Plan Rows":1}}]"#
        let session = ScriptedSession(engine: .postgresql, replies: [("EXPLAIN (FORMAT JSON)", .result(
            QueryResult(columns: [ColumnInfo(name: "QUERY PLAN", typeName: "json")], rows: [[.text(json)]])))])
        let c = StatementClassifier(dialect: pg).classify(text: "SELECT 1")
        let (plan, built) = try await ExplainPlanner.explain(c, on: session)
        #expect(plan.root.title == "Result" && plan.raw == json && !built.isAnalyze)
        #expect(session.executed == ["EXPLAIN (FORMAT JSON) SELECT 1"])
    }
}

// MARK: - Live servers

@Suite("EXPLAIN integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct ExplainIntegrationTests {
    private func seed(_ f: SchemaFixture) async throws {
        try await f.createWordPressFixture()
        for i in 0..<20 {
            try await f.run("INSERT INTO \(f.q).wp_posts (post_title, post_content, post_status) VALUES ('t\(i)', 'c', 'publish')")
        }
    }

    private func explain(_ f: SchemaFixture, _ sql: String, analyze: Bool = false, threshold: Double = 1) async throws -> ExplainPlan {
        let c = StatementClassifier(dialect: f.dialect).classify(text: sql)
        return try await ExplainPlanner.explain(c, on: f.session, analyze: analyze,
                                                thresholds: ExplainThresholds(largeTableRows: threshold)).plan
    }

    @Test(arguments: DBTarget.all)
    func scanOnUnindexedColumnWarns(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await seed(f)
            let plan = try await explain(f, "SELECT * FROM \(f.q).wp_posts WHERE post_content = 'zzz'")
            #expect(plan.engine == target.detectedEngine)
            #expect(plan.root.flattened.contains { $0.table == "wp_posts" })
            #expect(plan.warnings.contains { $0.message.contains("scan on") || $0.message.contains("Sequential scan") }, "\(plan.warnings)")
            #expect(!plan.raw.isEmpty)
        }
    }

    @Test(arguments: DBTarget.all)
    func primaryKeyLookupIsNotAScanWarning(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await seed(f)
            let id = target.isPostgres ? "id" : "ID"
            let plan = try await explain(f, "SELECT * FROM \(f.q).wp_posts WHERE \(id) = 1", threshold: 1_000)
            #expect(plan.root.flattened.contains { $0.table == "wp_posts" })
            #expect(plan.warnings.filter { $0.severity == .warning }.isEmpty, "\(plan.warnings)")
        }
    }

    @Test(arguments: DBTarget.all)
    func joinAndOrderByProduceATree(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await seed(f)
            let id = target.isPostgres ? "id" : "ID"
            let plan = try await explain(f, "SELECT p.post_title, m.meta_value FROM \(f.q).wp_posts p JOIN \(f.q).wp_postmeta m ON m.post_id = p.\(id) ORDER BY p.post_title")
            let tables = Set(plan.root.flattened.compactMap(\.table))
            // MySQL/MariaDB report the alias as table_name, Postgres the relation.
            #expect(tables.count == 2 && (tables.isSuperset(of: ["wp_posts", "wp_postmeta"]) || tables == ["p", "m"]), "\(tables)")
            #expect(plan.root.flattened.count >= 3)
        }
    }

    @Test(arguments: DBTarget.all)
    func analyzeRunsReadsAndReportsActuals(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await seed(f)
            let plan = try await explain(f, "SELECT * FROM \(f.q).wp_posts WHERE post_content = 'c'", analyze: true)
            #expect(plan.isAnalyze)
            #expect(plan.root.flattened.contains { $0.actualRows != nil || $0.actualTimeMs != nil } || plan.executionTimeMs != nil, "\(plan.raw)")
        }
    }

    @Test(arguments: DBTarget.all)
    func writesAreExplainedButNeverExecuted(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await seed(f)
            let c = StatementClassifier(dialect: f.dialect).classify(text: "UPDATE \(f.q).wp_posts SET post_status = 'private' WHERE post_content = 'c'")
            let (plan, built) = try await ExplainPlanner.explain(c, on: f.session, analyze: true)
            #expect(!built.isAnalyze && built.note != nil && !plan.isAnalyze)
            let r = try await f.session.execute("SELECT COUNT(*) FROM \(f.q).wp_posts WHERE post_status = 'private'")
            #expect(r.rows.first?.first.map { $0.displayString } == "0")
        }
    }
}
