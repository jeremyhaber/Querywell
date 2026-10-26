import Foundation
import Testing
import os

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

// MARK: Fixture

private func col(_ name: String, _ type: String, _ ordinal: Int, pk: Bool = false, enumValues: [String]? = nil) -> ColumnDefinition {
    ColumnDefinition(name: name, ordinal: ordinal, dataType: type.split(separator: "(").first.map(String.init) ?? type,
                     fullType: type, isNullable: !pk, isPrimaryKey: pk, isAutoIncrement: pk, enumValues: enumValues)
}

private func table(_ schema: String, _ name: String, kind: TableKind = .table) -> TableInfo {
    TableInfo(ref: TableRef(schema: schema, name: name), kind: kind)
}

/// A WordPress-flavoured catalog: wp_posts, wp_postmeta, wp_users, wp_options in schema `shop`,
/// plus a second schema `analytics` with one table.
private func catalog(dialect: SQLDialect = my, loadColumns: Bool = true) -> SchemaCatalog {
    let idName = dialect.family == .mysql ? "ID" : "id"
    var c = SchemaCatalog(schemas: ["shop", "analytics"])
    c.setTables(["wp_posts", "wp_postmeta", "wp_users", "wp_options", "v_published"].map {
        table("shop", $0, kind: $0.hasPrefix("v_") ? .view : .table)
    }, in: "shop")
    c.setTables([table("analytics", "events")], in: "analytics")
    c.setRoutines([RoutineInfo(schema: "shop", name: "fn_double", kind: .function),
                   RoutineInfo(schema: "shop", name: "sp_noop", kind: .procedure)], in: "shop")
    if loadColumns {
        c.setColumns([
            col(idName, "bigint unsigned", 1, pk: true), col("post_author", "bigint unsigned", 2),
            col("post_title", "varchar(255)", 3), col("post_content", "longtext", 4),
            col("post_status", "enum('publish','draft','it''s')", 5, enumValues: ["publish", "draft", "it's"]),
            col("post_type", "varchar(20)", 6), col("post date", "datetime", 7),
        ], for: TableRef(schema: "shop", name: "wp_posts"))
        c.setColumns([
            col("meta_id", "bigint unsigned", 1, pk: true), col("post_id", "bigint unsigned", 2),
            col("meta_key", "varchar(255)", 3), col("meta_value", "longtext", 4),
        ], for: TableRef(schema: "shop", name: "wp_postmeta"))
        c.setColumns([
            col(idName, "bigint unsigned", 1, pk: true), col("user_login", "varchar(60)", 2),
            col("user_email", "varchar(100)", 3),
        ], for: TableRef(schema: "shop", name: "wp_users"))
        c.setColumns([
            col("option_id", "bigint", 1, pk: true), col("option_name", "varchar(191)", 2),
            col("option_value", "longtext", 3), col("autoload", "varchar(20)", 4),
        ], for: TableRef(schema: "shop", name: "wp_options"))
        c.setColumns([col("event_id", "int", 1, pk: true), col("name", "varchar(50)", 2)],
                     for: TableRef(schema: "analytics", name: "events"))
    }
    return c
}

/// Completes at the `|` marker in `sql`.
private func complete(_ sql: String, _ d: SQLDialect = my, catalog cat: SchemaCatalog? = nil, schema: String? = "shop") -> CompletionResult {
    let cursor = (sql as NSString).range(of: "|").location
    let text = sql.replacingOccurrences(of: "|", with: "")
    return SQLCompletion.complete(text: text, cursor: cursor, dialect: d, catalog: cat ?? catalog(dialect: d),
                                  currentSchema: schema)
}

private func labels(_ r: CompletionResult, _ kind: CompletionItem.Kind? = nil) -> [String] {
    r.items.filter { kind == nil || $0.kind == kind }.map(\.label)
}

private func inserts(_ r: CompletionResult, _ kind: CompletionItem.Kind) -> [String] {
    r.items.filter { $0.kind == kind }.map(\.insertText)
}

@Suite("SQL completion")
struct SQLCompletionTests {
    // MARK: Tables

    @Test func tablesAfterFrom() {
        let r = complete("SELECT * FROM |")
        #expect(r.context == .tableName)
        #expect(labels(r, .table).contains("wp_posts"))
        #expect(labels(r, .view) == ["v_published"])
        #expect(labels(r, .schema).contains("analytics"))
        #expect(!labels(r).contains("events"))  // other schema's tables only after `analytics.`
    }

    @Test func tablePrefixIsFuzzyAndReplacesWholeWord() {
        let r = complete("SELECT * FROM wp_p|ostmeta")
        #expect(r.items.first?.label == "wp_posts" || r.items.first?.label == "wp_postmeta")
        #expect(labels(r, .table).contains("wp_postmeta"))
        let text = "SELECT * FROM wp_postmeta"
        #expect((text as NSString).substring(with: NSRange(location: r.range.lowerBound, length: r.range.count)) == "wp_postmeta")
        let abbreviation = complete("SELECT * FROM wpm|")
        #expect(abbreviation.items.first?.label == "wp_postmeta")
    }

    @Test func tablesAfterJoinIntoUpdateAndTable() {
        for sql in ["SELECT 1 FROM wp_posts p JOIN |", "SELECT 1 FROM wp_posts p LEFT OUTER JOIN |", "INSERT INTO |",
                    "UPDATE |", "DELETE FROM |", "TRUNCATE TABLE |", "ALTER TABLE |", "DESCRIBE |",
                    "SELECT 1 FROM a, |", "DROP TABLE IF EXISTS |"] {
            let r = complete(sql)
            #expect(r.context == .tableName, "\(sql)")
            #expect(labels(r, .table).contains("wp_users"), "\(sql)")
        }
    }

    @Test func schemaQualifiedTables() {
        let r = complete("SELECT * FROM analytics.|")
        #expect(r.context == .qualifiedTables)
        #expect(labels(r) == ["events"])
        let r2 = complete("SELECT * FROM shop.wp_|")
        #expect(labels(r2).allSatisfy { $0.hasPrefix("wp_") })
        #expect(!labels(r2).contains("events"))
    }

    @Test func unloadedSchemaIsReportedForLoading() {
        var c = catalog()
        c.setTables([], in: "analytics")
        var bare = SchemaCatalog(schemas: ["shop", "other"])
        bare.setTables(catalog().tables(in: "shop"), in: "shop")
        let r = complete("SELECT * FROM other.|", catalog: bare)
        #expect(r.missingTableLists == ["other"])
    }

    @Test func noTablesWhereAliasIsExpected() {
        // After a complete table reference the next word is an alias or a clause keyword.
        let r = complete("SELECT * FROM wp_posts |")
        #expect(r.context == .afterTable)
        #expect(!labels(r).contains("wp_users"))
        #expect(labels(r, .keyword).contains("WHERE"))
        #expect(labels(r, .keyword).contains("LEFT JOIN"))
        let j = complete("SELECT * FROM wp_posts p JOIN wp_postmeta pm |")
        #expect(labels(j, .keyword).first == "ON")
    }

    // MARK: Columns and aliases

    @Test func aliasDotGivesThatTablesColumns() {
        let r = complete("SELECT p.| FROM wp_posts p JOIN wp_postmeta pm ON pm.post_id = p.ID")
        #expect(r.context == .qualifiedColumns)
        #expect(labels(r) == ["ID", "post_author", "post_title", "post_content", "post_status", "post_type", "post date"])
        #expect(!labels(r).contains("meta_key"))
    }

    @Test func wordPressJoinOnClause() {
        let sql = "SELECT p.post_title, pm.meta_value FROM wp_posts p JOIN wp_postmeta pm ON pm.post_id = p.|"
        let r = complete(sql)
        #expect(labels(r).first == "ID")
        let meta = complete("SELECT p.post_title FROM wp_posts p JOIN wp_postmeta pm ON pm.|")
        #expect(labels(meta) == ["meta_id", "post_id", "meta_key", "meta_value"])
        let both = complete("SELECT 1 FROM wp_posts p JOIN wp_postmeta pm ON pm.post_id = p.ID WHERE pm.meta_k|")
        #expect(labels(both).first == "meta_key")
    }

    @Test func tableNameWorksAsQualifierWithoutAlias() {
        let r = complete("SELECT wp_postmeta.| FROM wp_postmeta")
        #expect(labels(r).contains("meta_key"))
        let aliased = complete("SELECT wp_posts.| FROM wp_posts AS p")
        #expect(labels(aliased).contains("post_title"))
    }

    @Test func asKeywordAliasAndQuotedAlias() {
        let r = complete("SELECT posts.| FROM wp_posts AS posts")
        #expect(labels(r).contains("post_author"))
        let q = complete("SELECT `p`.| FROM wp_posts `p`")
        #expect(labels(q).contains("post_title"))
    }

    @Test func schemaTableDotGivesColumns() {
        let r = complete("SELECT shop.wp_users.| FROM shop.wp_users")
        #expect(r.context == .qualifiedColumns)
        #expect(labels(r).contains("user_login"))
    }

    @Test func unambiguousColumnsAreNotPrefixed() {
        let r = complete("SELECT | FROM wp_posts p JOIN wp_postmeta pm ON pm.post_id = p.ID")
        #expect(r.context == .expression)
        let titles = r.items.filter { $0.label == "post_title" }
        #expect(titles.count == 1)
        #expect(titles[0].insertText == "post_title")
        #expect(titles[0].kind == .column)
        // Columns come before functions and keywords.
        let firstNonColumn = r.items.firstIndex { $0.kind != .column && $0.kind != .alias } ?? r.items.count
        let lastColumn = r.items.lastIndex { $0.kind == .column } ?? -1
        #expect(lastColumn < firstNonColumn)
    }

    @Test func ambiguousColumnsArePrefixedWithAlias() {
        let r = complete("SELECT | FROM wp_posts p JOIN wp_users u ON u.ID = p.post_author")
        let ids = r.items.filter { $0.kind == .column && $0.label.hasSuffix("ID") }
        #expect(Set(ids.map(\.insertText)) == ["p.ID", "u.ID"])
        #expect(Set(ids.map(\.label)) == ["p.ID", "u.ID"])
        #expect(r.items.first { $0.label == "post_title" }?.insertText == "post_title")
    }

    @Test func ambiguousWithoutAliasUsesTableName() {
        let r = complete("SELECT | FROM wp_posts JOIN wp_users ON wp_users.ID = wp_posts.post_author")
        #expect(Set(inserts(r, .column).filter { $0.hasSuffix("ID") }) == ["wp_posts.ID", "wp_users.ID"])
    }

    @Test func columnsFromSingleTableAreUnprefixed() {
        let r = complete("SELECT * FROM wp_options WHERE |")
        #expect(r.context == .expression)
        #expect(inserts(r, .column).contains("option_name"))
        #expect(!inserts(r, .column).contains("post_title"))
    }

    @Test func columnPrefixRanksColumnsFirst() {
        let r = complete("SELECT * FROM wp_posts WHERE post_t|")
        #expect(r.items.first?.label == "post_title" || r.items.first?.label == "post_type")
        #expect(labels(r).prefix(2).allSatisfy { $0.hasPrefix("post_t") })
    }

    @Test func columnNeedingQuotesIsQuoted() {
        let r = complete("SELECT | FROM wp_posts")
        #expect(r.items.first { $0.label == "post date" }?.insertText == "`post date`")
        let p = complete("SELECT | FROM wp_posts", pg)
        #expect(p.items.first { $0.label == "post date" }?.insertText == "\"post date\"")
        // Postgres folds unquoted identifiers: a mixed-case column must be quoted there, not in MySQL.
        var c = catalog(dialect: pg)
        c.setColumns([col("OrderID", "int", 1)], for: TableRef(schema: "shop", name: "wp_options"))
        let p2 = complete("SELECT | FROM wp_options", pg, catalog: c)
        #expect(p2.items.first { $0.label == "OrderID" }?.insertText == "\"OrderID\"")
        var m = catalog()
        m.setColumns([col("OrderID", "int", 1)], for: TableRef(schema: "shop", name: "wp_options"))
        #expect(complete("SELECT | FROM wp_options", catalog: m).items.first { $0.label == "OrderID" }?.insertText == "OrderID")
    }

    @Test func reservedWordTableIsQuoted() {
        var c = catalog()
        c.setTables(c.tables(in: "shop") + [table("shop", "order"), table("shop", "group")], in: "shop")
        let r = complete("SELECT * FROM |", catalog: c)
        #expect(r.items.first { $0.label == "order" }?.insertText == "`order`")
    }

    @Test func aliasesAreOfferedToStartQualifiedReferences() {
        let r = complete("SELECT | FROM wp_posts p JOIN wp_postmeta pm ON 1")
        #expect(inserts(r, .alias).contains("p"))
        #expect(inserts(r, .alias).contains("pm"))
    }

    @Test func updateSetAndWhereUseTargetColumns() {
        let r = complete("UPDATE wp_posts SET |")
        #expect(inserts(r, .column).contains("post_title"))
        let w = complete("UPDATE wp_posts p SET p.post_status = 'draft' WHERE p.|")
        #expect(labels(w).contains("post_author"))
        let ins = complete("INSERT INTO wp_options (|")
        #expect(r.context == .expression && ins.context == .insertColumns)
        #expect(inserts(ins, .column) == ["option_id", "option_name", "option_value", "autoload"])
        let ins2 = complete("INSERT INTO wp_options (option_name, |")
        #expect(inserts(ins2, .column).contains("autoload"))
    }

    @Test func deleteFromAndOrderGroupBy() {
        #expect(inserts(complete("DELETE FROM wp_postmeta WHERE |"), .column).contains("meta_key"))
        #expect(inserts(complete("SELECT post_type, COUNT(*) FROM wp_posts GROUP BY |"), .column).contains("post_type"))
        #expect(inserts(complete("SELECT * FROM wp_posts ORDER BY |"), .column).contains("post_title"))
        #expect(inserts(complete("SELECT * FROM wp_posts ORDER BY post_title DESC, |"), .column).contains("post_author"))
    }

    // MARK: Subqueries, CTEs, scope

    @Test func subqueryScopeSeesItsOwnTableFirst() {
        let r = complete("SELECT * FROM wp_posts p WHERE p.ID IN (SELECT post_id FROM wp_postmeta WHERE |)")
        #expect(labels(r, .column).first == "meta_id")
        // Correlated: the outer alias is visible too.
        #expect(inserts(r, .alias).contains("p"))
        #expect(labels(r, .column).contains("post_title"))
    }

    @Test func outerQueryDoesNotSeeSubqueryTables() {
        let r = complete("SELECT | FROM wp_posts p WHERE EXISTS (SELECT 1 FROM wp_postmeta pm WHERE pm.post_id = p.ID)")
        #expect(inserts(r, .column).contains("post_title"))
        #expect(!inserts(r, .column).contains("meta_key"))
    }

    @Test func derivedTableAliasIsRecognisedButHasNoColumns() {
        let r = complete("SELECT d.| FROM (SELECT ID FROM wp_posts) d")
        #expect(r.items.isEmpty)
    }

    @Test func cteNamesAreOfferedAsTables() {
        let r = complete("WITH recent AS (SELECT * FROM wp_posts) SELECT * FROM |")
        #expect(labels(r, .table).contains("recent"))
    }

    @Test func subqueryFromParenOffersSelect() {
        let r = complete("SELECT * FROM (|")
        #expect(labels(r) == ["SELECT", "WITH", "VALUES"])
    }

    @Test func statementsAreIndependent() {
        let r = complete("SELECT * FROM wp_users; SELECT | FROM wp_options")
        #expect(inserts(r, .column).contains("option_name"))
        #expect(!inserts(r, .column).contains("user_login"))
        let r2 = complete("SELECT | FROM wp_users; SELECT * FROM wp_options")
        #expect(inserts(r2, .column).contains("user_login"))
    }

    @Test func forUpdateAndOnDuplicateKeyUpdateAreNotTables() {
        let r = complete("SELECT | FROM wp_options WHERE option_id = 1 FOR UPDATE")
        #expect(inserts(r, .column).contains("option_name"))
        let d = complete("INSERT INTO wp_options (option_name) VALUES ('a') ON DUPLICATE KEY UPDATE |")
        #expect(inserts(d, .column).contains("option_value"))
    }

    // MARK: Enum values

    @Test func enumValuesAfterEquals() {
        let r = complete("SELECT * FROM wp_posts WHERE post_status = |")
        let values = r.items.filter { $0.kind == .enumValue }
        #expect(values.map(\.insertText) == ["'publish'", "'draft'", "'it''s'"].map { m in m.replacingOccurrences(of: "''s", with: "\\'s") })
        #expect(r.items.first?.kind == .enumValue)
        let qualified = complete("SELECT * FROM wp_posts p WHERE p.post_status <> |")
        #expect(qualified.items.first?.kind == .enumValue)
        let bang = complete("SELECT * FROM wp_posts WHERE post_status != |")
        #expect(bang.items.first?.kind == .enumValue)
    }

    @Test func enumValuesInList() {
        let r = complete("SELECT * FROM wp_posts WHERE post_status IN ('draft', |")
        #expect(r.items.first?.kind == .enumValue)
        let first = complete("SELECT * FROM wp_posts WHERE post_status NOT IN (|")
        #expect(first.items.first?.kind == .enumValue)
    }

    @Test func enumLiteralsUsePostgresEscaping() {
        var c = catalog(dialect: pg)
        c.setColumns([col("post_status", "post_status", 1, enumValues: ["publish", "it's"])], for: TableRef(schema: "shop", name: "wp_posts"))
        let r = complete("SELECT * FROM wp_posts WHERE post_status = |", pg, catalog: c)
        #expect(r.items.filter { $0.kind == .enumValue }.map(\.insertText) == ["'publish'", "'it''s'"])
    }

    @Test func noEnumValuesForOtherColumns() {
        let r = complete("SELECT * FROM wp_posts WHERE post_title = |")
        #expect(!r.items.contains { $0.kind == .enumValue })
        #expect(r.items.contains { $0.kind == .column })
    }

    // MARK: Never inside strings and comments

    @Test func nothingInsideStringsOrComments() {
        for sql in ["SELECT * FROM wp_posts WHERE post_title = 'ab|c'", "SELECT * FROM wp_posts WHERE post_title = '|",
                    "SELECT 1 -- note |", "SELECT 1 -- note\n-- |", "SELECT /* ab|c */ 1", "SELECT /* unterminated |",
                    "SELECT * FROM wp_posts WHERE post_title = 'done'|", "SELECT 1 /* x */|",
                    "SELECT 1 # hash |"] {
            let r = complete(sql)
            #expect(r.items.isEmpty, "\(sql)")
            #expect(r.context == .suppressed, "\(sql)")
        }
        let pgDollar = complete("SELECT $$ a|b $$", pg)
        #expect(pgDollar.items.isEmpty)
    }

    @Test func completionResumesAfterString() {
        let r = complete("SELECT * FROM wp_posts WHERE post_title = 'a;b' AND |")
        #expect(inserts(r, .column).contains("post_status"))
        let afterComment = complete("SELECT * FROM wp_posts -- hi\nWHERE |")
        #expect(inserts(afterComment, .column).contains("post_status"))
    }

    @Test func semicolonInsideStringDoesNotSplitStatement() {
        let r = complete("SELECT 'x;y' FROM wp_users WHERE |")
        #expect(inserts(r, .column).contains("user_login"))
    }

    // MARK: Quoted identifiers

    @Test func insideBackticksOnlyIdentifiersAlwaysQuoted() {
        let r = complete("SELECT `post_|` FROM wp_posts")
        #expect(inserts(r, .column).first == "`post_title`" || inserts(r, .column).contains("`post_title`"))
        #expect(r.items.allSatisfy { $0.insertText.hasPrefix("`") })
        let text = "SELECT `post_` FROM wp_posts"
        #expect((text as NSString).substring(with: NSRange(location: r.range.lowerBound, length: r.range.count)) == "`post_`")
        let unterminated = complete("SELECT * FROM `wp_|")
        #expect(unterminated.items.first?.insertText.hasPrefix("`wp_") == true)
    }

    // MARK: Functions, keywords, routines

    @Test func functionsAndKeywordsInExpressions() {
        let r = complete("SELECT COU| FROM wp_posts")
        #expect(r.items.first { $0.kind == .function }?.label == "COUNT")
        #expect(r.items.first { $0.label == "COUNT" }?.insertText == "COUNT(")
        // already followed by a parenthesis: don't add another
        let paren = complete("SELECT COU|(*) FROM wp_posts")
        #expect(paren.items.first { $0.label == "COUNT" }?.insertText == "COUNT")
        let lower = complete("select cou| from wp_posts")
        #expect(lower.items.first { $0.label == "COUNT" }?.insertText == "count(")
        let kw = complete("SELECT * FROM wp_posts WHERE post_status = 'x' AN|")
        #expect(kw.items.first?.label == "AND")
    }

    @Test func routinesAreOfferedAsFunctionsAndAfterCall() {
        let r = complete("SELECT fn_|")
        #expect(r.items.contains { $0.label == "fn_double" && $0.kind == .function })
        let call = complete("CALL |")
        #expect(call.context == .routineName)
        #expect(labels(call) == ["sp_noop"])
    }

    @Test func dialectFunctionLists() {
        #expect(complete("SELECT GROUP_CON|", my).items.contains { $0.label == "GROUP_CONCAT" })
        #expect(!complete("SELECT GROUP_CON|", pg).items.contains { $0.label == "GROUP_CONCAT" })
        #expect(complete("SELECT string_a|", pg).items.contains { $0.label == "STRING_AGG" })
    }

    @Test func statementStartOffersVerbs() {
        let r = complete("|")
        #expect(r.context == .statementStart)
        #expect(labels(r).contains("SELECT"))
        let after = complete("SELECT 1; |")
        #expect(after.context == .statementStart)
        let partial = complete("sel|")
        #expect(partial.items.first?.insertText == "select")
    }

    @Test func useOffersSchemas() {
        let r = complete("USE |")
        #expect(r.context == .schemaName)
        #expect(Set(labels(r)) == ["shop", "analytics"])
    }

    // MARK: Lazy loading

    @Test func missingColumnsAreReportedForTablesInScope() {
        let r = complete("SELECT p.| FROM wp_posts p JOIN wp_users u ON 1", catalog: catalog(loadColumns: false))
        #expect(r.items.isEmpty)
        #expect(r.missingColumns == [TableRef(schema: "shop", name: "wp_posts")])
        let all = complete("SELECT | FROM wp_posts p JOIN wp_users u ON 1", catalog: catalog(loadColumns: false))
        #expect(Set(all.missingColumns) == [TableRef(schema: "shop", name: "wp_posts"), TableRef(schema: "shop", name: "wp_users")])
    }

    @Test func caseInsensitiveTableLookup() {
        let r = complete("SELECT WP_POSTS.| FROM WP_POSTS")
        #expect(labels(r).contains("post_title"))
    }

    // MARK: Robustness

    @Test func cursorOutOfRangeAndEmptyInputsDoNotCrash() {
        let c = catalog()
        for cursor in [-5, 0, 3, 999] {
            _ = SQLCompletion.complete(text: "SELECT", cursor: cursor, dialect: my, catalog: c, currentSchema: "shop")
            _ = SQLCompletion.complete(text: "", cursor: cursor, dialect: my, catalog: c, currentSchema: nil)
        }
    }

    @Test func everyCursorPositionOfARealisticScriptIsSafe() {
        let sql = "SELECT p.ID, 'a;b' AS s, `x` FROM wp_posts p -- c\nJOIN wp_postmeta pm ON pm.post_id = p.ID WHERE (p.post_status IN ('a','b')) /* z */; UPDATE wp_options SET autoload = 'no' 😀 WHERE option_id = 1"
        let c = catalog()
        let n = (sql as NSString).length
        for cursor in 0...n {
            let r = SQLCompletion.complete(text: sql, cursor: cursor, dialect: my, catalog: c, currentSchema: "shop")
            #expect(r.range.lowerBound >= 0 && r.range.upperBound <= n)
            #expect(r.range.lowerBound <= r.range.upperBound)
        }
    }

    @Test func limitCapsResults() {
        let r = SQLCompletion.complete(text: "SELECT ", cursor: 7, dialect: my, catalog: catalog(), currentSchema: "shop", limit: 5)
        #expect(r.items.count == 5)
    }

    @Test func catalogLoaderFillsFromInspector() async throws {
        let inspector = StubInspector()
        let loader = SchemaCatalogLoader(inspector: inspector)
        try await loader.loadOverview(schemas: ["shop"])
        let text = "SELECT p. FROM wp_posts p"
        let r = await loader.complete(text: text, cursor: 9, dialect: my, currentSchema: "shop")
        #expect(labels(r) == ["ID", "post_title"])
        #expect(inspector.structureCalls == 1)
    }
}

private final class StubInspector: SchemaInspector {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var structureCalls: Int { calls.withLock { $0 } }

    func listSchemas() async throws -> [String] { ["shop"] }
    func listTables(schema: String) async throws -> [TableInfo] { [table("shop", "wp_posts")] }
    func listRoutines(schema: String) async throws -> [RoutineInfo] { [] }
    func structure(of ref: TableRef) async throws -> TableStructure {
        calls.withLock { $0 += 1 }
        return TableStructure(info: table("shop", ref.name), columns: [col("ID", "bigint", 1, pk: true), col("post_title", "text", 2)],
                              indexes: [], foreignKeys: [], referencedBy: [])
    }
    func availableCollations() async throws -> [CollationInfo] { [] }
    func availableEngines() async throws -> [String] { [] }
}
