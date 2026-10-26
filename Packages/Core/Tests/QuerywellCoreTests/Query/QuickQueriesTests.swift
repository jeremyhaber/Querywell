import Foundation
import Testing

@testable import QuerywellCore

private let mysql = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func col(_ name: String, _ type: String = "varchar", pk: Bool = false, auto: Bool = false, nullable: Bool = true) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: 1, dataType: type, fullType: type, isNullable: nullable, isPrimaryKey: pk, isAutoIncrement: auto)
}

private func posts(schema: String = "wp") -> TableStructure {
    let ref = TableRef(schema: schema, name: "wp_posts")
    return TableStructure(
        info: TableInfo(ref: ref, kind: .table),
        columns: [col("ID", "bigint", pk: true, auto: true, nullable: false), col("post_title"), col("post_author", "bigint"), col("post_date", "datetime")],
        indexes: [
            IndexDefinition(name: "PRIMARY", columns: ["ID"], isUnique: true, isPrimary: true),
            IndexDefinition(name: "author", columns: ["post_author"], isUnique: false, isPrimary: false),
            IndexDefinition(name: "title_u", columns: ["post_title"], isUnique: true, isPrimary: false),
        ],
        foreignKeys: [ForeignKeyDefinition(name: "fk", columns: ["post_author"], referenced: TableRef(schema: schema, name: "wp_users"), referencedColumns: ["ID"])],
        referencedBy: [])
}

private func ctx(_ d: SQLDialect, structure: TableStructure? = posts(), current: String? = "wp", column: String? = nil) -> QuickQueryContext {
    QuickQueryContext(dialect: d, currentSchema: current, table: structure?.info.ref ?? TableRef(schema: "wp", name: "wp_posts"),
                      structure: structure, column: column)
}

private func sql(_ kind: QuickQueryKind, _ c: QuickQueryContext) -> String {
    QuickQueries.plainText(QuickQueries.template(kind, c) ?? "<nil>")
}

@Suite("Quick queries")
struct QuickQueriesTests {
    @Test func selectVariantsMySQL() {
        #expect(sql(.selectAll, ctx(mysql)) == "SELECT * FROM `wp_posts` LIMIT 100;")
        #expect(sql(.selectColumns, ctx(mysql)) == "SELECT `ID`, `post_title`, `post_author`, `post_date`\nFROM `wp_posts`\nLIMIT 100;")
        #expect(sql(.count, ctx(mysql)) == "SELECT COUNT(*) FROM `wp_posts`;")
    }

    @Test func otherDatabaseIsQualifiedOnMySQLAndPostgresAlways() {
        #expect(sql(.count, ctx(mysql, current: "other")) == "SELECT COUNT(*) FROM `wp`.`wp_posts`;")
        let s = posts(schema: "public")
        #expect(sql(.count, ctx(pg, structure: s, current: "public")) == "SELECT COUNT(*) FROM \"public\".\"wp_posts\";")
    }

    @Test func newestUsesPrimaryKeyThenDateThenFirstColumn() {
        #expect(sql(.newest, ctx(mysql)).contains("ORDER BY `ID` DESC\nLIMIT 100;"))
        var noKey = posts()
        noKey.indexes = []
        noKey.columns = noKey.columns.map { var c = $0; c.isPrimaryKey = false; return c }
        #expect(sql(.newest, ctx(mysql, structure: noKey)).contains("ORDER BY `post_date` DESC"))
        noKey.columns = [col("a"), col("b")]
        #expect(sql(.newest, ctx(mysql, structure: noKey)).contains("ORDER BY `a` DESC"))
    }

    @Test func findByValueAndDuplicatesPickFirstNonKeyColumn() {
        #expect(sql(.findByValue, ctx(mysql)) == "SELECT * FROM `wp_posts`\nWHERE `post_title` = ?\nLIMIT 100;")
        let dup = sql(.duplicates, ctx(mysql, column: "post_author"))
        #expect(dup == "SELECT `post_author`, COUNT(*) AS duplicates\nFROM `wp_posts`\nGROUP BY `post_author`\nHAVING COUNT(*) > 1\nORDER BY duplicates DESC;")
    }

    @Test func duplicatesMirrorsTheColumnStop() {
        let t = QuickQueries.template(.duplicates, ctx(mysql))!
        let parsed = SnippetTemplate.parse(t)
        #expect(parsed.stops.first?.index == 1)
        #expect(parsed.stops.first?.ranges.count == 2)
    }

    @Test func insertListsAllColumnsWithDefaultForAutoIncrement() {
        let text = sql(.insert, ctx(mysql))
        #expect(text == "INSERT INTO `wp_posts`\n  (`ID`, `post_title`, `post_author`, `post_date`)\nVALUES\n  (DEFAULT, ?, ?, ?);")
        let stops = SnippetTemplate.parse(QuickQueries.template(.insert, ctx(mysql))!).stops
        #expect(stops.count == 4)  // three ?, plus the final caret stop
    }

    @Test func updateAndDeleteUseThePrimaryKey() {
        #expect(sql(.update, ctx(mysql)) == "UPDATE `wp_posts`\nSET `post_title` = ?,\n    `post_author` = ?,\n    `post_date` = ?\nWHERE `ID` = ?;")
        #expect(sql(.delete, ctx(mysql)) == "DELETE FROM `wp_posts`\nWHERE `ID` = ?;")
    }

    @Test func compositeKeyAndMissingKey() {
        var s = posts()
        s.indexes = [IndexDefinition(name: "PRIMARY", columns: ["a", "b"], isUnique: true, isPrimary: true)]
        s.columns = [col("a", pk: true), col("b", pk: true), col("c")]
        #expect(sql(.delete, ctx(mysql, structure: s)) == "DELETE FROM `wp_posts`\nWHERE `a` = ?\n  AND `b` = ?;")
        s.indexes = []
        s.columns = [col("c")]
        #expect(sql(.delete, ctx(mysql, structure: s)) == "DELETE FROM `wp_posts`\nWHERE condition;")
    }

    @Test func withoutStructureTemplatesStillWork() {
        let c = ctx(mysql, structure: nil)
        #expect(sql(.selectColumns, c) == "SELECT * FROM `wp_posts` LIMIT 100;")
        #expect(sql(.insert, c) == "INSERT INTO `wp_posts` (columns)\nVALUES (values);")
    }

    @Test func structureQueryPerDialect() {
        #expect(sql(.structure, ctx(mysql)) == "SHOW CREATE TABLE `wp_posts`;\nDESCRIBE `wp_posts`;")
        let text = sql(.structure, ctx(pg, structure: posts(schema: "public"), current: "public"))
        #expect(text.contains("FROM information_schema.columns"))
        #expect(text.contains("table_schema = 'public' AND table_name = 'wp_posts'"))
    }

    @Test func databaseLevelQueries() {
        let m = ctx(mysql, structure: nil)
        #expect(sql(.processes, m) == "SHOW FULL PROCESSLIST;")
        #expect(sql(.tableSizes, m).contains("table_schema = 'wp'"))
        #expect(sql(.processes, ctx(pg, structure: nil)).contains("pg_stat_activity"))
        #expect(sql(.tableSizes, ctx(pg, structure: nil)).contains("nspname = 'wp'"))
        var noSchema = ctx(mysql, structure: nil, current: nil)
        noSchema.table = nil
        #expect(QuickQueries.template(.tableSizes, noSchema) == nil)
        #expect(QuickQueries.template(.processes, noSchema) != nil)
    }

    @Test func tableKindsNeedATable() {
        var c = ctx(mysql)
        c.table = nil
        for kind in QuickQueryKind.tableLevel { #expect(QuickQueries.template(kind, c) == nil) }
    }

    @Test func awkwardNamesAreQuotedAndEscaped() {
        let ref = TableRef(schema: "my`db", name: "we$ird}t`able")
        let c = QuickQueryContext(dialect: mysql, currentSchema: "x", table: ref)
        let template = QuickQueries.template(.selectAll, c)!
        #expect(QuickQueries.plainText(template) == "SELECT * FROM `my``db`.`we$ird}t``able` LIMIT 100;")
        let quote = TableRef(schema: "public", name: "o'brien")
        let text = sql(.structure, QuickQueryContext(dialect: pg, currentSchema: "public", table: quote))
        #expect(text.contains("table_name = 'o''brien'"))
    }

    @Test func insertionIsSeparatedFromNeighbouringSQL() {
        #expect(QuickQueries.separated("X;", editorText: "", caret: 0) == "X;")
        #expect(QuickQueries.separated("X;", editorText: "SELECT 1;", caret: 9) == "\n\nX;")
        #expect(QuickQueries.separated("X;", editorText: "SELECT 1;\n", caret: 10) == "\nX;")
        #expect(QuickQueries.separated("X;", editorText: "SELECT 1;\n\n", caret: 11) == "X;")
        #expect(QuickQueries.separated("X;", editorText: "A;\nB;", caret: 3) == "\nX;\n\n")
        #expect(QuickQueries.separated("X;", editorText: "   \n", caret: 0) == "X;")
    }

    @Test func tableFinderPrefersCaretThenPreviousThenNext() {
        let tables = [TableInfo(ref: TableRef(schema: "wp", name: "wp_posts"), kind: .table),
                      TableInfo(ref: TableRef(schema: "wp", name: "wp_users"), kind: .table)]
        let text = "SELECT * FROM wp_posts p JOIN `WP_USERS` u ON 1;"
        func find(_ caret: Int) -> String? { QuickQueryTableFinder.table(in: text, caret: caret, tables: tables, dialect: mysql)?.name }
        #expect(find(16) == "wp_posts")  // inside wp_posts
        #expect(find(38) == "wp_users")  // inside the quoted, differently cased name
        #expect(find(text.utf16.count) == "wp_users")  // after both: the last before the caret
        #expect(find(0) == "wp_posts")  // before both: the next one
        #expect(QuickQueryTableFinder.table(in: "SELECT 1", caret: 3, tables: tables, dialect: mysql) == nil)
        #expect(QuickQueryTableFinder.table(in: "SELECT 'wp_posts'", caret: 3, tables: tables, dialect: mysql) == nil)
    }

    @Test func outlineMarkersAndSummary() {
        let cols = SchemaOutline.columns(of: posts())
        #expect(cols[0].isPrimaryKey && !cols[0].isNullable)
        #expect(cols[1].isUnique && cols[1].isIndexed)
        #expect(cols[2].isIndexed && !cols[2].isUnique && cols[2].foreignKey == "wp_users.ID")
        #expect(!cols[3].isIndexed && cols[3].foreignKey == nil)
        #expect(cols[0].summary == "ID, bigint, primary key, not null")
        #expect(cols[2].summary == "post_author, bigint, indexed, references wp_users.ID, nullable")
    }

    @Test func outlineFilter() {
        let tables = ["wp_posts", "wp_postmeta", "wp_users"].map { TableInfo(ref: TableRef(schema: "wp", name: $0), kind: .table) }
        #expect(SchemaOutline.filter(tables, query: "").map(\.ref.name) == ["wp_posts", "wp_postmeta", "wp_users"])
        #expect(SchemaOutline.filter(tables, query: "usr").map(\.ref.name) == ["wp_users"])
        #expect(SchemaOutline.filter(tables, query: "zzz").isEmpty)
    }
}
