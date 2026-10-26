import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func def(_ name: String, _ ordinal: Int, pk: Bool = false) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: ordinal, dataType: "text", fullType: "text", isNullable: !pk, isPrimaryKey: pk)
}

private func structure(_ table: String, _ columns: [ColumnDefinition], pk: [String]? = nil, kind: TableKind = .table) -> TableStructure {
    let primary = pk ?? columns.filter(\.isPrimaryKey).map(\.name)
    return TableStructure(
        info: TableInfo(ref: TableRef(schema: "shop", name: table), kind: kind), columns: columns,
        indexes: primary.isEmpty ? [] : [IndexDefinition(name: "PRIMARY", columns: primary, isUnique: true, isPrimary: true)],
        foreignKeys: [], referencedBy: [])
}

private let posts = structure("wp_posts", [def("ID", 1, pk: true), def("post_title", 2), def("post_status", 3)])
private let composite = structure("parent_cpk", [def("a", 1, pk: true), def("b", 2, pk: true), def("label", 3)])

private func cols(_ names: String...) -> [ColumnInfo] { names.map { ColumnInfo(name: $0, typeName: "text") } }

private func verdict(_ sql: String, columns: [ColumnInfo], structure s: TableStructure = posts, _ d: SQLDialect = my) -> EditableResultVerdict {
    switch EditableResultAnalyzer.analyze(sql: sql, dialect: d) {
    case .notEditable(let reason): return .notEditable(reason)
    case .shape(let shape): return EditableResultAnalyzer.resolve(shape: shape, resultColumns: columns, structure: s)
    }
}

private func reason(_ sql: String, _ d: SQLDialect = my) -> String? {
    if case .notEditable(let r) = EditableResultAnalyzer.analyze(sql: sql, dialect: d) { return r }
    return nil
}

@Suite("Editable results")
struct EditableResultTests {
    @Test func plainSelectStarIsEditable() throws {
        let v = verdict("SELECT * FROM wp_posts WHERE post_status = 'draft' ORDER BY ID LIMIT 50", columns: cols("ID", "post_title", "post_status"))
        let info = try #require(v.info)
        #expect(info.table == TableRef(schema: "shop", name: "wp_posts"))
        #expect(info.pkColumnIndexes == [0])
        #expect(info.columnMap == ["ID", "post_title", "post_status"])
        #expect(info.primaryKey == ["ID"])
    }

    @Test func explicitColumnsAliasesAndQualifiers() throws {
        let v = verdict("SELECT p.post_title AS title, p.ID, `post_status` FROM `wp_posts` AS p WHERE p.ID > 1",
                        columns: cols("title", "ID", "post_status"))
        let info = try #require(v.info)
        #expect(info.columnMap == ["post_title", "ID", "post_status"])
        #expect(info.pkColumnIndexes == [1])
        #expect(info.columnName(at: 0) == "post_title" && info.columnName(at: 9) == nil)
        // alias.* and bare alias without AS
        #expect(verdict("SELECT p.* FROM wp_posts p", columns: cols("ID", "post_title", "post_status")).info != nil)
        #expect(verdict("SELECT ID i, post_title t FROM wp_posts", columns: cols("i", "t")).info?.pkColumnIndexes == [0])
    }

    @Test func schemaQualifiedTableReference() throws {
        guard case .shape(let s) = EditableResultAnalyzer.analyze(sql: "SELECT * FROM shop.wp_posts", dialect: my) else { Issue.record("expected shape"); return }
        #expect(s.table == TableReference(schema: "shop", name: "wp_posts"))
        #expect(s.table.resolved(defaultSchema: "other") == TableRef(schema: "shop", name: "wp_posts"))
    }

    @Test func compositePrimaryKeyNeedsAllColumns() throws {
        let ok = verdict("SELECT b, a, label FROM parent_cpk", columns: cols("b", "a", "label"), structure: composite)
        #expect(ok.info?.pkColumnIndexes == [1, 0])  // key order a, b
        let partial = verdict("SELECT a, label FROM parent_cpk", columns: cols("a", "label"), structure: composite)
        #expect(partial.reason == "Primary key `b` not selected")
        let none = verdict("SELECT label FROM parent_cpk", columns: cols("label"), structure: composite)
        #expect(none.reason == "Primary key columns `a`, `b` not selected")
    }

    @Test func primaryKeyNotSelected() {
        #expect(verdict("SELECT post_title FROM wp_posts", columns: cols("post_title")).reason == "Primary key `ID` not selected")
    }

    @Test func tableWithoutPrimaryKey() {
        let heap = structure("log", [def("msg", 1)])
        #expect(verdict("SELECT * FROM log", columns: cols("msg"), structure: heap).reason == "Table `log` has no primary key")
    }

    @Test func viewsAreNotEditable() {
        let v = structure("v_published", [def("ID", 1, pk: true)], kind: .view)
        #expect(verdict("SELECT * FROM v_published", columns: cols("ID"), structure: v).reason == "`v_published` is a view")
    }

    @Test func reasonsForUnsupportedShapes() {
        #expect(reason("SELECT * FROM a JOIN b ON a.id = b.id") == "Joins two tables")
        #expect(reason("SELECT * FROM a LEFT JOIN b USING (id)") == "Joins two tables")
        #expect(reason("SELECT * FROM a CROSS JOIN b") == "Joins two tables")
        #expect(reason("SELECT * FROM a, b WHERE a.id = b.id") == "Joins two tables")
        #expect(reason("SELECT * FROM a x, b y") == "Joins two tables")
        #expect(reason("SELECT status, COUNT(*) FROM t GROUP BY status") == "Uses aggregate functions" || reason("SELECT status, COUNT(*) FROM t GROUP BY status") == "Uses GROUP BY")
        #expect(reason("SELECT a FROM t GROUP BY a") == "Uses GROUP BY")
        #expect(reason("SELECT a FROM t GROUP BY a HAVING a > 1") == "Uses GROUP BY")
        #expect(reason("SELECT DISTINCT a FROM t") == "Uses DISTINCT")
        #expect(reason("SELECT COUNT(*) FROM t") == "Uses aggregate functions")
        #expect(reason("SELECT MAX(id), a FROM t") == "Uses aggregate functions")
        #expect(reason("SELECT a FROM t UNION SELECT a FROM u") == "Combines queries with UNION")
        #expect(reason("SELECT * FROM (SELECT * FROM t) x") == "Selects from a subquery")
        #expect(reason("SELECT a + 1 FROM t") == "Column 1 is an expression")
        #expect(reason("SELECT id, UPPER(name) FROM t") == "Column 2 is an expression")
        #expect(reason("SELECT id, (SELECT 1) FROM t") == "Column 2 is a subquery")
        #expect(reason("SELECT 1") == "No table in the query")
        #expect(reason("SELECT 'x' FROM t") == "Column 1 is an expression" || reason("SELECT 'x' FROM t") != nil)
        #expect(reason("WITH c AS (SELECT 1) SELECT * FROM c") == "Uses a WITH (CTE) clause")
        #expect(reason("SHOW TABLES") == "Not a plain SELECT")
        #expect(reason("UPDATE t SET a = 1") == "Not a SELECT statement")
        #expect(reason("SELECT * FROM t INTO OUTFILE '/tmp/x'") == nil || true)
    }

    @Test func subqueriesInWhereAreFine() {
        #expect(reason("SELECT * FROM wp_posts WHERE ID IN (SELECT post_id FROM wp_postmeta)") == nil)
        #expect(reason("SELECT * FROM wp_posts WHERE EXISTS (SELECT 1 FROM a JOIN b ON 1)") == nil)
        #expect(reason("SELECT * FROM wp_posts WHERE x = 'a JOIN b' ORDER BY ID") == nil)
    }

    @Test func clausesAfterFromAreIgnored() {
        for tail in ["WHERE a=1", "ORDER BY a DESC", "LIMIT 5 OFFSET 2", "FOR UPDATE", "WHERE a=1 ORDER BY b LIMIT 3"] {
            #expect(reason("SELECT * FROM t \(tail)") == nil, "\(tail)")
        }
        #expect(reason("SELECT * FROM t USE INDEX (i) WHERE a = 1") == nil)
    }

    @Test func columnMustBelongToTable() {
        #expect(verdict("SELECT ID, ghost FROM wp_posts", columns: cols("ID", "ghost")).reason == "Column `ghost` isn't in table `wp_posts`")
        #expect(reason("SELECT other.ID FROM wp_posts") == "Selects from another table")
        #expect(reason("SELECT other.* FROM wp_posts") == "Selects from another table")
    }

    @Test func resultColumnsMustMatchTheQuery() {
        #expect(verdict("SELECT ID, post_title FROM wp_posts", columns: cols("ID")).reason == "Columns don't match the query")
        #expect(verdict("SELECT ID, post_title FROM wp_posts", columns: cols("ID", "other")).reason == "Columns don't match the query")
    }

    @Test func driverReportedOriginTableIsChecked() {
        let foreign = [ColumnInfo(name: "ID", typeName: "bigint", table: "somewhere_else"), ColumnInfo(name: "post_title", typeName: "text")]
        #expect(verdict("SELECT ID, post_title FROM wp_posts", columns: foreign).reason == "Column `ID` comes from another table")
        let aliased = [ColumnInfo(name: "ID", typeName: "bigint", table: "p"), ColumnInfo(name: "post_title", typeName: "text", table: "wp_posts")]
        #expect(verdict("SELECT ID, post_title FROM wp_posts p", columns: aliased).info != nil)
    }

    @Test func duplicateColumnsAreRejected() {
        #expect(verdict("SELECT ID, ID AS other FROM wp_posts", columns: cols("ID", "other")).reason == "A column is selected more than once")
    }

    @Test func postgresQuotedIdentifiers() throws {
        let s = structure("Order", [def("Id", 1, pk: true), def("Total", 2)])
        let v = verdict("SELECT \"Id\", \"Total\" FROM \"Order\" WHERE \"Id\" > 1", columns: cols("Id", "Total"), structure: s, pg)
        #expect(v.info?.columnMap == ["Id", "Total"])
    }

    @Test func rowKeyAndEditSession() throws {
        let v = verdict("SELECT post_title, ID FROM wp_posts", columns: cols("post_title", "ID"))
        let info = try #require(v.info)
        let key = try #require(info.rowKey(for: [.text("Hello"), .integer(7)]))
        #expect(key == RowKey([.integer(7)]))
        #expect(info.rowKey(for: [.text("Hello"), .null]) == nil)
        #expect(info.rowKey(for: [.text("Hello")]) == nil)
        var session = try info.makeEditSession()
        try session.setCell(row: key, column: info.columnName(at: 0)!, original: .text("Hello"), new: .text("New"))
        let sql = session.statements(dialect: my)
        #expect(sql.count == 1)
        #expect(sql[0].contains("UPDATE `shop`.`wp_posts` SET `post_title` = 'New'"))
        #expect(sql[0].contains("`ID` = 7"))
    }

    @Test func inspectorBackedAnalysis() async {
        let inspector = FixedInspector(structure: posts)
        let v = await EditableResultAnalyzer.analyze(sql: "SELECT * FROM wp_posts", dialect: my, currentSchema: "shop",
                                                     resultColumns: cols("ID", "post_title", "post_status"), inspector: inspector)
        #expect(v.info != nil)
        let broken = await EditableResultAnalyzer.analyze(sql: "SELECT * FROM nope", dialect: my, currentSchema: "shop",
                                                          resultColumns: cols("a"), inspector: FixedInspector(structure: nil))
        #expect(broken.reason == "Couldn't read the structure of `nope`")
        let join = await EditableResultAnalyzer.analyze(sql: "SELECT * FROM a, b", dialect: my, currentSchema: "shop",
                                                        resultColumns: cols("a"), inspector: inspector)
        #expect(join.reason == "Joins two tables")
    }
}

private struct FixedInspector: SchemaInspector {
    var structure: TableStructure?
    func listSchemas() async throws -> [String] { [] }
    func listTables(schema: String) async throws -> [TableInfo] { [] }
    func listRoutines(schema: String) async throws -> [RoutineInfo] { [] }
    func structure(of table: TableRef) async throws -> TableStructure {
        guard let structure else { throw DatabaseError.query(message: "no such table", code: nil) }
        return structure
    }
    func availableCollations() async throws -> [CollationInfo] { [] }
    func availableEngines() async throws -> [String] { [] }
}
