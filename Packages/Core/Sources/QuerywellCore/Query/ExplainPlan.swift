import Foundation

// EXPLAIN support: build the right EXPLAIN statement per engine and turn the server's answer into a tree.
//
//   MySQL 8      EXPLAIN FORMAT=JSON …        (analyze: EXPLAIN ANALYZE …, a text tree)
//   MariaDB      EXPLAIN FORMAT=JSON …        (analyze: ANALYZE FORMAT=JSON …)
//   PostgreSQL   EXPLAIN (FORMAT JSON) …      (analyze: EXPLAIN (ANALYZE, FORMAT JSON) …)
//
// ANALYZE executes the statement, so it is only ever used for reads and only when asked for.

public struct PlanWarning: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable { case info, warning }
    public var severity: Severity
    public var message: String
    /// Title of the node the warning is about.
    public var node: String?
}

public struct PlanNode: Sendable, Hashable, Identifiable {
    /// Position in the tree ("0", "0.1", "0.1.0"), stable for one plan.
    public var id: String
    /// Human title: "Full table scan on wp_posts", "Seq Scan on wp_posts", "Sort".
    public var title: String
    /// Table (relation) this node reads, when it reads one.
    public var table: String?
    /// Engine's node type ("Seq Scan", "Nested Loop", "Table scan", "query_block").
    public var nodeType: String
    /// MySQL/MariaDB access type ("ALL", "ref", "eq_ref", "range", "index", "const"); nil elsewhere.
    public var accessType: String?
    /// Estimated rows.
    public var rows: Double?
    /// Actual rows (ANALYZE only).
    public var actualRows: Double?
    /// Actual time in ms (ANALYZE only).
    public var actualTimeMs: Double?
    public var cost: Double?
    public var keyUsed: String?
    /// Detail lines: conditions, sort keys, "Using index", …
    public var extra: [String]
    public var children: [PlanNode]

    public init(id: String = "0", title: String, table: String? = nil, nodeType: String, accessType: String? = nil,
                rows: Double? = nil, actualRows: Double? = nil, actualTimeMs: Double? = nil, cost: Double? = nil,
                keyUsed: String? = nil, extra: [String] = [], children: [PlanNode] = []) {
        self.id = id
        self.title = title
        self.table = table
        self.nodeType = nodeType
        self.accessType = accessType
        self.rows = rows
        self.actualRows = actualRows
        self.actualTimeMs = actualTimeMs
        self.cost = cost
        self.keyUsed = keyUsed
        self.extra = extra
        self.children = children
    }

    /// Depth-first, parent before children.
    public var flattened: [PlanNode] { [self] + children.flatMap(\.flattened) }
}

public struct ExplainPlan: Sendable, Hashable {
    public var engine: DatabaseEngine
    public var root: PlanNode
    public var warnings: [PlanWarning]
    public var isAnalyze: Bool
    public var planningTimeMs: Double?
    public var executionTimeMs: Double?
    /// The server's answer verbatim (JSON, or the text tree for MySQL ANALYZE) — what Optimize feeds the AI.
    public var raw: String
}

public enum ExplainError: Error, Equatable, Sendable {
    case unsupported(String)
    case unparseable(String)
}

public struct ExplainThresholds: Sendable, Equatable {
    /// A scan reading at least this many (estimated) rows counts as "large".
    public var largeTableRows: Double
    public init(largeTableRows: Double = 10_000) { self.largeTableRows = largeTableRows }
}

/// The EXPLAIN statement to run.
public struct ExplainStatement: Sendable, Equatable {
    public var sql: String
    /// Whether ANALYZE is in effect (it can be refused for non-reads even when requested).
    public var isAnalyze: Bool
    /// Why ANALYZE was dropped, if it was.
    public var note: String?
}

public enum ExplainPlanner {
    // MARK: Building

    public static func statement(for statement: ClassifiedStatement, engine: DatabaseEngine, analyze: Bool = false) throws -> ExplainStatement {
        let body = stripTrailingSemicolon(statement.text)
        guard !body.isEmpty else { throw ExplainError.unsupported("There is no statement to explain.") }
        switch statement.verb {
        case "SELECT", "WITH", "TABLE", "VALUES", "INSERT", "REPLACE", "UPDATE", "DELETE":
            break
        case "EXPLAIN", "ANALYZE", "DESCRIBE", "DESC":
            throw ExplainError.unsupported("This statement is already an EXPLAIN.")
        default:
            throw ExplainError.unsupported("\(statement.verb.isEmpty ? "This statement" : statement.verb) statements can't be explained.")
        }
        // WITH may wrap a data-modifying statement; the classifier already reports that as a write.
        let isRead = statement.kind == .read
        var note: String?
        var analyzing = analyze
        if analyze, !isRead {
            analyzing = false
            note = "EXPLAIN ANALYZE would execute this statement, so it only runs for read-only queries. Showing the estimated plan instead."
        }
        let sql: String
        switch engine {
        case .mysql:
            sql = analyzing ? "EXPLAIN ANALYZE \(body)" : "EXPLAIN FORMAT=JSON \(body)"
        case .mariadb:
            sql = analyzing ? "ANALYZE FORMAT=JSON \(body)" : "EXPLAIN FORMAT=JSON \(body)"
        case .postgresql:
            sql = analyzing ? "EXPLAIN (ANALYZE, FORMAT JSON) \(body)" : "EXPLAIN (FORMAT JSON) \(body)"
        }
        return ExplainStatement(sql: sql, isAnalyze: analyzing, note: note)
    }

    /// Convenience: classify `sql` and build its EXPLAIN.
    public static func statement(sql: String, dialect: SQLDialect, engine: DatabaseEngine, analyze: Bool = false) throws -> ExplainStatement {
        try statement(for: StatementClassifier(dialect: dialect).classify(text: sql), engine: engine, analyze: analyze)
    }

    private static func stripTrailingSemicolon(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(";") { t.removeLast(); t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return t
    }

    // MARK: Running

    /// Builds and runs the EXPLAIN for one statement and parses the answer.
    public static func explain(
        _ statement: ClassifiedStatement, on session: any DatabaseSession, analyze: Bool = false,
        thresholds: ExplainThresholds = ExplainThresholds()
    ) async throws -> (plan: ExplainPlan, statement: ExplainStatement) {
        let built = try self.statement(for: statement, engine: session.engine, analyze: analyze)
        let result = try await session.execute(built.sql)
        let output = result.rows.compactMap { $0.first.flatMap(text(of:)) }.joined(separator: "\n")
        let plan = try parse(output: output, engine: session.engine, analyze: built.isAnalyze, thresholds: thresholds)
        return (plan, built)
    }

    private static func text(of v: DatabaseValue) -> String? {
        switch v {
        case .text(let s): s
        case .bytes(let d): String(decoding: d, as: UTF8.self)
        case .null: nil
        default: v.displayString
        }
    }

    // MARK: Parsing

    public static func parse(output: String, engine: DatabaseEngine, analyze: Bool = false,
                             thresholds: ExplainThresholds = ExplainThresholds()) throws -> ExplainPlan {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExplainError.unparseable("The server returned an empty plan.") }
        var parser = PlanParser(thresholds: thresholds)
        switch engine {
        case .postgresql:
            return try parser.postgres(trimmed, analyze: analyze)
        case .mysql where analyze:
            return parser.mysqlTree(trimmed)
        case .mysql, .mariadb:
            return try parser.mysqlJSON(trimmed, engine: engine, analyze: analyze)
        }
    }
}

// MARK: - Parser

private struct PlanParser {
    let thresholds: ExplainThresholds
    var warnings: [PlanWarning] = []

    init(thresholds: ExplainThresholds) { self.thresholds = thresholds }

    // MARK: helpers

    private func num(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    private func str(_ any: Any?) -> String? { any as? String }
    private func bool(_ any: Any?) -> Bool { (any as? Bool) ?? ((any as? NSNumber)?.boolValue ?? false) }
    private func dict(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
    private func array(_ any: Any?) -> [[String: Any]] { (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }

    private mutating func warn(_ message: String, node: String?, _ severity: PlanWarning.Severity = .warning) {
        warnings.append(PlanWarning(severity: severity, message: message, node: node))
    }

    private func count(_ rows: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: rows.rounded())) ?? String(Int(rows))
    }

    private func assignIDs(_ node: PlanNode, path: String) -> PlanNode {
        var n = node
        n.id = path
        n.children = node.children.enumerated().map { assignIDs($0.element, path: "\(path).\($0.offset)") }
        return n
    }

    // MARK: PostgreSQL

    mutating func postgres(_ text: String, analyze: Bool) throws -> ExplainPlan {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let top = (json as? [Any])?.first as? [String: Any] ?? json as? [String: Any],
              let plan = dict(top["Plan"]) else {
            throw ExplainError.unparseable("Couldn't read the PostgreSQL plan.")
        }
        let root = assignIDs(pgNode(plan), path: "0")
        return ExplainPlan(engine: .postgresql, root: root, warnings: warnings, isAnalyze: analyze,
                           planningTimeMs: num(top["Planning Time"]), executionTimeMs: num(top["Execution Time"]), raw: text)
    }

    private mutating func pgNode(_ d: [String: Any]) -> PlanNode {
        let type = str(d["Node Type"]) ?? "Node"
        let relation = str(d["Relation Name"])
        let alias = str(d["Alias"])
        let index = str(d["Index Name"])
        var title = type
        if let relation {
            if let index, type.contains("Index") { title += " using \(index)" }
            title += " on \(relation)"
            if let alias, alias != relation { title += " \(alias)" }
        } else if let index {
            title += " using \(index)"
        }
        var extra: [String] = []
        for (key, label) in [("Join Type", "Join type"), ("Strategy", "Strategy"), ("Index Cond", "Index cond"),
                             ("Recheck Cond", "Recheck cond"), ("Hash Cond", "Hash cond"), ("Merge Cond", "Merge cond"),
                             ("Filter", "Filter"), ("Join Filter", "Join filter"), ("Sort Method", "Sort method")] {
            if let v = str(d[key]) { extra.append("\(label): \(v)") }
        }
        for (key, label) in [("Sort Key", "Sort key"), ("Group Key", "Group key")] {
            if let v = d[key] as? [String], !v.isEmpty { extra.append("\(label): \(v.joined(separator: ", "))") }
        }
        if let removed = num(d["Rows Removed by Filter"]) { extra.append("Rows removed by filter: \(count(removed))") }
        if let heap = num(d["Heap Fetches"]) { extra.append("Heap fetches: \(count(heap))") }
        if let sortSpace = str(d["Sort Space Type"]), let used = num(d["Sort Space Used"]) {
            extra.append("Sort space: \(count(used)) kB (\(sortSpace))")
        }

        let rows = num(d["Plan Rows"])
        let actual = num(d["Actual Rows"])
        let loops = num(d["Actual Loops"]) ?? 1
        if type == "Seq Scan", let relation, let rows, rows >= thresholds.largeTableRows {
            warn("Sequential scan on \(relation) reads about \(count(rows)) rows. An index on the filtered columns could avoid it.",
                 node: title)
        }
        if type == "Sort", let method = str(d["Sort Method"]), method.lowercased().contains("external") {
            warn("The sort spilled to disk (\(method)); work_mem may be too low.", node: title)
        }
        if let rows, let actual, rows > 0 || actual > 0 {
            let ratio = max(rows, 1) / max(actual, 1)
            if actual * loops >= 1_000, ratio >= 10 || ratio <= 0.1 {
                warn("The planner estimated \(count(rows)) rows but \(count(actual)) came back; statistics may be stale (try ANALYZE).",
                     node: title, .info)
            }
        }

        let children = array(d["Plans"]).map { pgNode($0) }
        return PlanNode(title: title, table: relation, nodeType: type, rows: rows, actualRows: actual,
                        actualTimeMs: num(d["Actual Total Time"]), cost: num(d["Total Cost"]), keyUsed: index,
                        extra: extra, children: children)
    }

    // MARK: MySQL / MariaDB JSON

    mutating func mysqlJSON(_ text: String, engine: DatabaseEngine, analyze: Bool) throws -> ExplainPlan {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
              let top = json as? [String: Any], let block = dict(top["query_block"]) else {
            throw ExplainError.unparseable("Couldn't read the \(engine.displayName) plan.")
        }
        let root = assignIDs(queryBlock(block), path: "0")
        return ExplainPlan(engine: engine, root: root, warnings: warnings, isAnalyze: analyze,
                           planningTimeMs: nil, executionTimeMs: num(block["r_total_time_ms"]), raw: text)
    }

    private mutating func queryBlock(_ b: [String: Any]) -> PlanNode {
        let id = Int(num(b["select_id"]) ?? 1)
        var extra: [String] = []
        if let msg = str(b["message"]) { extra.append(msg) }
        return PlanNode(title: "Query block #\(id)", nodeType: "query_block", rows: nil,
                        actualTimeMs: num(b["r_total_time_ms"]),
                        cost: num(dict(b["cost_info"])?["query_cost"]), extra: extra, children: children(of: b))
    }

    private static let ignoredKeys: Set<String> = [
        "cost_info", "used_columns", "select_id", "message", "possible_keys", "used_key_parts", "ref", "key_length",
        "r_total_time_ms", "table_name", "access_type", "key", "attached_condition", "index_condition",
        "using_filesort", "using_temporary_table", "using_index", "filtered", "rows", "partitions",
        "r_rows", "r_filtered", "r_loops", "loops", "r_total_filesort_time_ms", "r_buffer_size",
    ]

    /// Plan nodes found directly inside `d` (operations, joins, tables, subqueries).
    private mutating func children(of d: [String: Any]) -> [PlanNode] {
        var out: [PlanNode] = []
        for key in d.keys.sorted(by: { order($0) < order($1) }) {
            guard !Self.ignoredKeys.contains(key) else { continue }
            let value = d[key]
            switch key {
            case "table":
                if let t = dict(value) { out.append(tableNode(t)) }
            case "nested_loop":
                let kids = array(value).flatMap { children(of: $0) }
                if kids.count > 1 { out.append(PlanNode(title: "Nested loop join", nodeType: "nested_loop", children: kids)) }
                else { out += kids }
            case "ordering_operation", "grouping_operation", "duplicates_removal", "buffer_result", "windowing",
                 "read_sorted_file", "filesort", "temporary_table", "duplicate_removal", "materialization",
                 "block-nl-join", "union_result":
                guard let inner = dict(value) else { continue }
                out.append(operation(key, inner))
            case "query_specifications", "attached_subqueries", "optimized_away_subqueries", "subqueries":
                for spec in array(value) {
                    if let qb = dict(spec["query_block"]) {
                        var n = queryBlock(qb)
                        n.title = key == "query_specifications" ? "Query #\(Int(num(qb["select_id"]) ?? 1))"
                            : "Subquery #\(Int(num(qb["select_id"]) ?? 1))\(bool(spec["dependent"]) ? " (dependent)" : "")"
                        out.append(n)
                    } else {
                        out += children(of: spec)
                    }
                }
            case "materialized_from_subquery":
                if let m = dict(value) {
                    let kids = dict(m["query_block"]).map { [queryBlock($0)] } ?? []
                    out.append(PlanNode(title: "Materialized subquery", nodeType: key, children: kids))
                }
            case "query_block":
                if let qb = dict(value) { out.append(queryBlock(qb)) }
            default:
                // Unknown container (MariaDB has several): descend and keep what it contains.
                if let inner = dict(value) {
                    let kids = children(of: inner)
                    if !kids.isEmpty { out.append(PlanNode(title: Self.pretty(key), nodeType: key, children: kids)) }
                } else {
                    let kids = array(value).flatMap { children(of: $0) }
                    if !kids.isEmpty { out.append(PlanNode(title: Self.pretty(key), nodeType: key, children: kids)) }
                }
            }
        }
        return out
    }

    /// Keeps operations before tables so "sort over scan" reads top-down.
    private func order(_ key: String) -> Int {
        switch key {
        case "ordering_operation", "grouping_operation", "duplicates_removal", "buffer_result", "windowing",
             "read_sorted_file", "filesort", "temporary_table", "duplicate_removal": 0
        case "nested_loop", "block-nl-join", "union_result": 1
        case "table": 2
        default: 3
        }
    }

    private static func pretty(_ key: String) -> String {
        let s = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private mutating func operation(_ key: String, _ d: [String: Any]) -> PlanNode {
        var title: String
        var extra: [String] = []
        switch key {
        case "ordering_operation", "read_sorted_file", "filesort": title = "Sort"
        case "grouping_operation": title = "Group"
        case "duplicates_removal", "duplicate_removal": title = "Remove duplicates"
        case "buffer_result": title = "Buffer result"
        case "windowing": title = "Window functions"
        case "temporary_table": title = "Temporary table"
        case "materialization": title = "Materialization"
        case "block-nl-join": title = "Block nested loop join"
        case "union_result": title = "UNION"
        default: title = Self.pretty(key)
        }
        if bool(d["using_filesort"]) || key == "filesort" {
            warn("Sorts with filesort (no usable index for the ORDER BY / GROUP BY).", node: title)
            if key != "filesort" { extra.append("Using filesort") }
        }
        if bool(d["using_temporary_table"]) || key == "temporary_table" {
            warn("Builds a temporary table.", node: title)
            if key != "temporary_table" { extra.append("Using temporary table") }
        }
        if let sortKey = d["sort_key"] as? String { extra.append("Sort key: \(sortKey)") }
        if let cond = str(d["attached_condition"]) { extra.append("Filter: \(cond)") }
        if let buffer = str(d["buffer_type"]) { extra.append("Join buffer: \(buffer)") }
        return PlanNode(title: title, nodeType: key, extra: extra, children: children(of: d))
    }

    private mutating func tableNode(_ t: [String: Any]) -> PlanNode {
        let name = str(t["table_name"]) ?? "?"
        let access = str(t["access_type"])
        let key = str(t["key"])
        let rows = num(t["rows_examined_per_scan"]) ?? num(t["rows"])
        let produced = num(t["rows_produced_per_join"])
        let actual = num(t["r_rows"])
        let cost = num(dict(t["cost_info"])?["prefix_cost"]) ?? num(dict(t["cost_info"])?["read_cost"])

        let verb: String
        switch access?.lowercased() {
        case "all": verb = "Full table scan on"
        case "index": verb = "Full index scan on"
        case "range": verb = "Index range scan on"
        case "ref", "ref_or_null": verb = "Index lookup on"
        case "eq_ref": verb = "Unique index lookup on"
        case "const", "system": verb = "Single row from"
        case "fulltext": verb = "Full-text search on"
        case "index_merge": verb = "Index merge on"
        case "unique_subquery", "index_subquery": verb = "Subquery index lookup on"
        case .some(let other): verb = "\(other) on"
        case nil: verb = "Read"
        }
        var title = "\(verb) \(name)"
        if let key, access?.lowercased() != "all" { title += " using \(key)" }

        var extra: [String] = []
        if let possible = t["possible_keys"] as? [String], !possible.isEmpty, key == nil {
            extra.append("Possible keys (none used): \(possible.joined(separator: ", "))")
        }
        if let parts = t["used_key_parts"] as? [String], !parts.isEmpty { extra.append("Key parts: \(parts.joined(separator: ", "))") }
        if bool(t["using_index"]) { extra.append("Using index (covering)") }
        if let cond = str(t["index_condition"]) { extra.append("Index condition: \(cond)") }
        if let cond = str(t["attached_condition"]) { extra.append("Filter: \(cond)") }
        if let f = num(t["filtered"]) { extra.append("Filtered: \(String(format: "%g", f))%") }
        if let buf = str(t["using_join_buffer"]) { extra.append("Join buffer: \(buf)") }
        if let p = produced { extra.append("Rows produced per join: \(count(p))") }
        if bool(t["using_filesort"]) { extra.append("Using filesort") }
        if let loops = num(t["r_loops"]) { extra.append("Loops: \(count(loops))") }

        if access?.uppercased() == "ALL", let rows {
            if rows >= thresholds.largeTableRows {
                warn("Full table scan on \(name) reads about \(count(rows)) rows. An index on the filtered or joined columns could avoid it.",
                     node: title)
            }
        } else if access?.lowercased() == "index", let rows, rows >= thresholds.largeTableRows {
            warn("Full index scan on \(name) reads about \(count(rows)) index entries.", node: title, .info)
        }
        if bool(t["using_filesort"]) { warn("Sorts \(name) with filesort.", node: title) }
        if bool(t["using_temporary_table"]) { warn("Builds a temporary table for \(name).", node: title) }

        // Children inside a table entry (e.g. materialized subqueries).
        var kids: [PlanNode] = []
        if let m = dict(t["materialized_from_subquery"]), let qb = dict(m["query_block"]) {
            kids.append(PlanNode(title: "Materialized subquery", nodeType: "materialized_from_subquery", children: [queryBlock(qb)]))
        }
        kids += array(t["attached_subqueries"]).compactMap { spec in
            dict(spec["query_block"]).map { var n = queryBlock($0); n.title = "Subquery"; return n }
        }
        return PlanNode(title: title, table: name, nodeType: "table", accessType: access, rows: rows, actualRows: actual,
                        actualTimeMs: num(t["r_total_time_ms"]), cost: cost, keyUsed: key, extra: extra, children: kids)
    }

    // MARK: MySQL EXPLAIN ANALYZE (text tree)

    mutating func mysqlTree(_ text: String) -> ExplainPlan {
        struct Line { var depth: Int; var text: String }
        var lines: [Line] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let arrow = raw.range(of: "-> ") else { continue }
            let indent = raw.distance(from: raw.startIndex, to: arrow.lowerBound)
            lines.append(Line(depth: indent / 4, text: String(raw[arrow.upperBound...])))
        }
        guard !lines.isEmpty else {
            return ExplainPlan(engine: .mysql, root: PlanNode(title: "Plan", nodeType: "plan", extra: [text]), warnings: [],
                               isAnalyze: true, planningTimeMs: nil, executionTimeMs: nil, raw: text)
        }

        func node(_ line: String) -> PlanNode {
            var head = line
            var estimate: String?
            var actualBlock: String?
            if let r = line.range(of: "  (cost=") {
                head = String(line[..<r.lowerBound])
                let tail = String(line[r.lowerBound...])
                if let a = tail.range(of: "(actual time=") {
                    estimate = String(tail[..<a.lowerBound])
                    actualBlock = String(tail[a.lowerBound...])
                } else { estimate = tail }
            } else if let a = line.range(of: "  (actual time=") {
                head = String(line[..<a.lowerBound])
                actualBlock = String(line[a.lowerBound...])
            }
            func grab(_ source: String?, _ key: String) -> Double? {
                guard let source, let r = source.range(of: key) else { return nil }
                let rest = source[r.upperBound...]
                let numeric = rest.prefix { $0.isNumber || $0 == "." || $0 == "e" || $0 == "-" || $0 == "+" }
                return Double(numeric)
            }
            let type = head.split(separator: ":", maxSplits: 1).first.map(String.init) ?? head
            var table: String?
            if let r = head.range(of: " on ") {
                table = String(head[r.upperBound...].prefix { !$0.isWhitespace && $0 != "(" })
            }
            var key: String?
            if let r = head.range(of: " using ") { key = String(head[r.upperBound...].prefix { !$0.isWhitespace }) }
            var actualTime: Double?
            if let block = actualBlock, let r = block.range(of: "..") {
                let rest = block[r.upperBound...]
                actualTime = Double(rest.prefix { $0.isNumber || $0 == "." })
            }
            let extra = head.contains(":") ? [String(head.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)] : []
            return PlanNode(title: head, table: table, nodeType: type, rows: grab(estimate, "rows="),
                            actualRows: grab(actualBlock, "rows="), actualTimeMs: actualTime,
                            cost: grab(estimate, "cost="), keyUsed: key, extra: extra)
        }

        // Build the tree from indentation.
        var stack: [(depth: Int, path: [Int])] = []
        var rootNode = node(lines[0].text)
        func insert(_ n: PlanNode, at path: [Int], into root: inout PlanNode) {
            if path.isEmpty { root.children.append(n); return }
            insert(n, at: Array(path.dropFirst()), into: &root.children[path[0]])
        }
        stack.append((lines[0].depth, []))
        for l in lines.dropFirst() {
            let n = node(l.text)
            while let last = stack.last, last.depth >= l.depth, stack.count > 1 { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            insert(n, at: parentPath, into: &rootNode)
            // path of the new node: parent's path + index of the appended child
            var parent = rootNode
            for i in parentPath { parent = parent.children[i] }
            stack.append((l.depth, parentPath + [parent.children.count - 1]))
        }
        let root = assignIDs(rootNode, path: "0")
        for n in root.flattened {
            if n.nodeType.hasPrefix("Table scan"), let rows = n.rows, rows >= thresholds.largeTableRows {
                warn("Table scan on \(n.table ?? "table") reads about \(count(rows)) rows. An index could avoid it.", node: n.title)
            }
            if n.nodeType.hasPrefix("Sort") { warn("Sorts rows without an index (filesort).", node: n.title, .info) }
            if n.nodeType.contains("temporary") || n.nodeType.hasPrefix("Materialize") {
                warn("Uses a temporary table.", node: n.title)
            }
        }
        return ExplainPlan(engine: .mysql, root: root, warnings: warnings, isAnalyze: true, planningTimeMs: nil,
                           executionTimeMs: root.actualTimeMs, raw: text)
    }
}
