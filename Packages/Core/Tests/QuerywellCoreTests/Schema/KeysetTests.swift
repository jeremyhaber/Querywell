import Testing

@testable import QuerywellCore

@Suite("Keyset paging SQL")
struct KeysetTests {
    let my = SQLDialect(.mysql)
    let pg = SQLDialect(.postgresql)
    let posts = TableRef(schema: "wp", name: "wp_posts")

    private func structure(
        pk: [String] = ["ID"], extraIndexes: [IndexDefinition] = [], nullable: Set<String> = [], types: [String: String] = [:]
    ) -> TableStructure {
        let names = ["ID", "post_author", "post_date", "post_status", "post_name", "score"]
        let columns = names.enumerated().map { i, n in
            ColumnDefinition(
                name: n, ordinal: i + 1, dataType: types[n] ?? (n == "ID" || n == "post_author" ? "bigint" : n == "post_date" ? "datetime" : "varchar"),
                fullType: "x", isNullable: nullable.contains(n), isPrimaryKey: pk.contains(n))
        }
        let indexes = [IndexDefinition(name: "PRIMARY", columns: pk, isUnique: true, isPrimary: true, method: "BTREE")] + extraIndexes
        let info = TableInfo(ref: posts, kind: .table)
        return TableStructure(info: info, columns: columns, indexes: indexes, foreignKeys: [], referencedBy: [])
    }

    @Test func singleKeyForwardAndBackward() {
        let forward = TableQuery(
            table: posts, limit: 500,
            keyset: KeysetPage(order: [SortKey(column: "ID")], direction: .forward, boundary: [.integer(500)]))
        #expect(forward.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` WHERE ((`ID` > 500)) ORDER BY `ID` ASC LIMIT 500")
        let backward = TableQuery(
            table: posts, limit: 500,
            keyset: KeysetPage(order: [SortKey(column: "ID")], direction: .backward, boundary: [.integer(501)]))
        #expect(backward.sql(dialect: pg) == "SELECT * FROM \"wp\".\"wp_posts\" WHERE ((\"ID\" < 501)) ORDER BY \"ID\" DESC LIMIT 500")
        let last = TableQuery(table: posts, limit: 500, keyset: KeysetPage(order: [SortKey(column: "ID")], direction: .backward))
        #expect(last.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` ORDER BY `ID` DESC LIMIT 500")
        let first = TableQuery(table: posts, limit: 500, keyset: KeysetPage(order: [SortKey(column: "ID")]))
        #expect(first.sql(dialect: my) == "SELECT * FROM `wp`.`wp_posts` ORDER BY `ID` ASC LIMIT 500")
    }

    @Test func descendingOrderFlipsOperators() {
        let order = [SortKey(column: "ID", ascending: false)]
        let next = TableQuery(table: posts, limit: 10, keyset: KeysetPage(order: order, direction: .forward, boundary: [.integer(90)]))
        #expect(next.sql(dialect: my).contains("WHERE ((`ID` < 90)) ORDER BY `ID` DESC"))
        let prev = TableQuery(table: posts, limit: 10, keyset: KeysetPage(order: order, direction: .backward, boundary: [.integer(100)]))
        #expect(prev.sql(dialect: my).contains("WHERE ((`ID` > 100)) ORDER BY `ID` ASC"))
    }

    @Test func compositeKeyExpandsAndQuotes() {
        let order = [SortKey(column: "post_name"), SortKey(column: "ID")]
        let q = TableQuery(
            table: posts, limit: 5,
            keyset: KeysetPage(order: order, direction: .forward, boundary: [.text("it's\\x"), .integer(7)]))
        #expect(q.sql(dialect: my)
            == "SELECT * FROM `wp`.`wp_posts` WHERE ((`post_name` > 'it\\'s\\\\x') OR (`post_name` = 'it\\'s\\\\x' AND `ID` > 7)) ORDER BY `post_name` ASC, `ID` ASC LIMIT 5")
        #expect(q.sql(dialect: pg).contains("\"post_name\" > E'it''s\\\\x'"))
    }

    @Test func filtersAndRawWhereStayAndedWithTheSeek() {
        var group = FilterGroup()
        group.filters = [ColumnFilter(column: "post_status", op: .equals(.text("publish")))]
        let q = TableQuery(
            table: posts, filter: group, rawWhere: "post_author = 3", limit: 5,
            keyset: KeysetPage(order: [SortKey(column: "ID")], boundary: [.integer(9)]))
        let sql = q.sql(dialect: my)
        #expect(sql.contains("`post_status` = 'publish' AND (post_author = 3\n) AND ((`ID` > 9))"))
        // Counts never include the seek.
        #expect(!q.countSQL(dialect: my).contains("`ID` > 9"))
        #expect(q.whereSQL(dialect: my)?.contains("`ID` > 9") == false)
    }

    @Test func mismatchedBoundaryIsIgnored() {
        let q = TableQuery(table: posts, limit: 5, keyset: KeysetPage(order: [SortKey(column: "ID")], boundary: [.integer(1), .integer(2)]))
        #expect(!q.sql(dialect: my).contains("WHERE"))
    }

    // MARK: eligibility

    @Test func primaryKeyOnlyIsEligibleInBothDirections() {
        let s = structure()
        #expect(s.keysetOrder(for: []) == [SortKey(column: "ID")])
        #expect(s.keysetOrder(for: [SortKey(column: "id", ascending: false)]) == [SortKey(column: "ID", ascending: false)])
    }

    @Test func indexedNotNullSortGetsPrimaryKeyTiebreak() {
        let s = structure(extraIndexes: [IndexDefinition(name: "a", columns: ["post_author", "post_date"], isUnique: false, isPrimary: false)])
        #expect(s.keysetOrder(for: [SortKey(column: "post_author", ascending: false)])
            == [SortKey(column: "post_author", ascending: false), SortKey(column: "ID", ascending: false)])
        #expect(s.keysetOrder(for: [SortKey(column: "post_author"), SortKey(column: "post_date")])?.map(\.column) == ["post_author", "post_date", "ID"])
    }

    @Test func notEligible() {
        let idx = IndexDefinition(name: "a", columns: ["post_author", "post_date"], isUnique: false, isPrimary: false)
        // not leading an index
        #expect(structure(extraIndexes: [idx]).keysetOrder(for: [SortKey(column: "post_date")]) == nil)
        // unindexed column
        #expect(structure().keysetOrder(for: [SortKey(column: "post_name")]) == nil)
        // mixed directions
        #expect(structure(extraIndexes: [idx]).keysetOrder(for: [SortKey(column: "post_author"), SortKey(column: "post_date", ascending: false)]) == nil)
        // nullable sort column
        #expect(structure(extraIndexes: [idx], nullable: ["post_author"]).keysetOrder(for: [SortKey(column: "post_author")]) == nil)
        // no primary key
        #expect(structure(pk: []).keysetOrder(for: []) == nil)
        // enum / float / json / blob
        for type in ["enum", "double", "json", "blob", "float"] {
            let e = structure(extraIndexes: [idx], types: ["post_author": type])
            #expect(e.keysetOrder(for: [SortKey(column: "post_author")]) == nil, "type \(type)")
        }
        // partial and fulltext indexes don't serve the order
        let partial = IndexDefinition(name: "p", columns: ["post_name"], isUnique: false, isPrimary: false, predicate: "x > 1")
        #expect(structure(extraIndexes: [partial]).keysetOrder(for: [SortKey(column: "post_name")]) == nil)
        let ft = IndexDefinition(name: "f", columns: ["post_name"], isUnique: false, isPrimary: false, method: "FULLTEXT")
        #expect(structure(extraIndexes: [ft]).keysetOrder(for: [SortKey(column: "post_name")]) == nil)
    }

    @Test func compositePrimaryKey() {
        let s = structure(pk: ["post_author", "ID"])
        #expect(s.keysetOrder(for: [])?.map(\.column) == ["post_author", "ID"])
        #expect(s.keysetOrder(for: [SortKey(column: "post_author")])?.map(\.column) == ["post_author", "ID"])
    }
}
