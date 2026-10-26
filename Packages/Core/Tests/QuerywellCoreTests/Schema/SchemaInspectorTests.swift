import Foundation
import Testing

@testable import QuerywellCore

// MARK: - Unit

@Suite("MySQL schema parsing")
struct MySQLParsingTests {
    @Test func enumValuesParseQuotesAndEscapes() {
        #expect(MySQLSchemaInspector.parseEnumValues("enum('a','b')") == ["a", "b"])
        #expect(MySQLSchemaInspector.parseEnumValues("enum('it''s','x,y','')") == ["it's", "x,y", ""])
        #expect(MySQLSchemaInspector.parseEnumValues("set('c\\\\d','nl\\nx','q\\'r')") == ["c\\d", "nl\nx", "q'r"])
        #expect(MySQLSchemaInspector.parseEnumValues("enum('a (b)','c)')") == ["a (b)", "c)"])
        #expect(MySQLSchemaInspector.parseEnumValues("varchar") == nil)
    }

    @Test func sqlModeStripsOnlyNoBackslashEscapes() {
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES,ANSI_QUOTES")
            == "STRICT_TRANS_TABLES,ANSI_QUOTES")
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "NO_BACKSLASH_ESCAPES") == "")
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "no_backslash_escapes,X") == "X")
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "STRICT_TRANS_TABLES") == nil)
        #expect(MySQLSQLMode.removingNoBackslashEscapes(from: "") == nil)
    }

    @Test func postgresActionCodes() {
        #expect(PostgresSchemaInspector.action("a") == "NO ACTION")
        #expect(PostgresSchemaInspector.action("r") == "RESTRICT")
        #expect(PostgresSchemaInspector.action("c") == "CASCADE")
        #expect(PostgresSchemaInspector.action("n") == "SET NULL")
        #expect(PostgresSchemaInspector.action("d") == "SET DEFAULT")
    }
}

// MARK: - Integration

@Suite("Schema inspector integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct SchemaInspectorIntegrationTests {
    // MARK: lists

    @Test(arguments: DBTarget.all)
    func listsSchemas(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let schemas = try await f.inspector.listSchemas()
            #expect(schemas.contains(f.schema))
            if target.isPostgres {
                #expect(schemas.contains("public"))
                #expect(!schemas.contains("information_schema"))
                #expect(!schemas.contains(where: { $0.hasPrefix("pg_") }))
                #expect(schemas == schemas.sorted())
            } else {
                #expect(schemas.contains("information_schema"))
                #expect(schemas.contains("querywell_test") || schemas.contains("mysql"))
                // Other suites create/drop temporary `qw_*` / `qw7_*` databases concurrently, so the two
                // lists (read at different moments) are compared without them.
                let stable: (String) -> Bool = { !$0.hasPrefix("qw_") && !$0.hasPrefix("qw7_") }
                #expect(schemas.filter(stable) == (try await f.session.listDatabases()).filter(stable))
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func listsTablesViewsAndRoutines(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            // Some rows so estimates are non-trivial.
            let posts = f.dialect.qualified(f.ref("wp_posts"))
            let cols = target.isPostgres ? "(post_content)" : "(post_content)"
            for i in 0..<3 { try await f.run("INSERT INTO \(posts) \(cols) VALUES ('c\(i)')") }

            let tables = try await f.inspector.listTables(schema: f.schema)
            var expected = ["child_fk", "parent_cpk", "v_published", "wp_postmeta", "wp_posts", "wp_users"]
            expected.append(target.isPostgres ? "mv_authors" : "legacy_myisam")
            #expect(tables.map(\.ref.name) == expected.sorted())
            #expect(tables.allSatisfy { $0.ref.schema == f.schema })

            let users = try #require(tables.first { $0.ref.name == "wp_users" })
            #expect(users.kind == .table)
            #expect(users.comment == "Users table")
            let view = try #require(tables.first { $0.ref.name == "v_published" })
            #expect(view.kind == .view)
            #expect(view.engine == nil && view.estimatedRows == nil && view.dataBytes == nil && view.indexBytes == nil)
            #expect(view.collation == nil)
            #expect(view.comment == nil)

            let postsInfo = try #require(tables.first { $0.ref.name == "wp_posts" })
            #expect(postsInfo.kind == .table)
            #expect((postsInfo.dataBytes ?? -1) >= 0)
            #expect((postsInfo.indexBytes ?? -1) >= 0)

            if target.isPostgres {
                #expect(postsInfo.engine == nil && postsInfo.collation == nil)
                let mv = try #require(tables.first { $0.ref.name == "mv_authors" })
                #expect(mv.kind == .materializedView)
                // Never analysed: reltuples is -1, which must surface as nil, not -1.
                #expect(postsInfo.estimatedRows == nil)
                try await f.run("ANALYZE \(posts)")
                let analysed = try await f.inspector.listTables(schema: f.schema)
                #expect(analysed.first { $0.ref.name == "wp_posts" }?.estimatedRows == 3)
            } else {
                #expect(postsInfo.engine == "InnoDB")
                #expect(postsInfo.collation == "utf8mb4_unicode_ci")
                #expect(postsInfo.estimatedRows != nil)
                #expect(users.engine == "InnoDB")
                let myisam = try #require(tables.first { $0.ref.name == "legacy_myisam" })
                #expect(myisam.engine == "MyISAM")
                #expect(myisam.kind == .table)
                #expect(myisam.collation != nil)
            }

            let routines = try await f.inspector.listRoutines(schema: f.schema)
            #expect(Set(routines.map(\.name)) == ["fn_double", "sp_noop"])
            #expect(routines.first { $0.name == "fn_double" }?.kind == .function)
            #expect(routines.first { $0.name == "sp_noop" }?.kind == .procedure)
            #expect(routines.allSatisfy { $0.schema == f.schema })
            let empty0 = try await f.inspector.listRoutines(schema: "no_such_schema_\(f.schema)")
            #expect(empty0.isEmpty)
            let empty1 = try await f.inspector.listTables(schema: "no_such_schema_\(f.schema)")
            #expect(empty1.isEmpty)
        }
    }

    // MARK: columns

    @Test(arguments: DBTarget.all)
    func postsColumns(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            let s = try await f.inspector.structure(of: f.ref("wp_posts"))
            #expect(s.info.ref == f.ref("wp_posts"))
            #expect(s.info.kind == .table)
            let names = s.columns.map(\.name)
            #expect(names == (target.isPostgres
                ? ["id", "post_author", "post_title", "post_content", "post_status", "post_name", "post_modified"]
                : ["ID", "post_author", "post_title", "post_content", "post_status", "post_name", "post_modified"]))
            #expect(s.columns.map(\.ordinal) == Array(1...7))
            #expect(s.primaryKey == [names[0]])

            let id = s.columns[0]
            #expect(id.isPrimaryKey && id.isAutoIncrement && !id.isNullable)
            #expect(id.defaultExpression == nil)
            #expect(id.collation == nil && id.characterSet == nil)

            let author = s.columns[1]
            #expect(!author.isPrimaryKey && !author.isAutoIncrement && !author.isNullable)
            #expect(author.defaultExpression == "0")

            let title = s.columns[2]
            #expect(title.fullType.hasPrefix(target.isPostgres ? "character varying(255)" : "varchar(255)"))
            #expect(title.dataType == (target.isPostgres ? "varchar" : "varchar"))
            #expect(title.defaultExpression == (target.isPostgres ? "''::character varying" : "''"))
            #expect(title.comment == "The title")
            #expect(!title.isNullable)

            let content = s.columns[3]
            #expect(content.dataType == (target.isPostgres ? "text" : "longtext"))
            #expect(content.fullType == (target.isPostgres ? "text" : "longtext"))
            #expect(content.defaultExpression == nil)
            #expect(content.comment == nil)

            let status = s.columns[4]
            #expect(status.dataType == "enum")
            #expect(status.enumValues == ["publish", "draft", "pending", "private", "it's"])
            #expect(!status.isNullable)
            #expect(status.defaultExpression?.contains("'draft'") == true)

            let name = s.columns[5]
            #expect(name.isNullable)
            #expect(name.defaultExpression == nil)
            #expect(name.enumValues == nil)

            let modified = s.columns[6]
            #expect(modified.isNullable)
            #expect(modified.dataType == (target.isPostgres ? "timestamp" : "datetime"))
            #expect(modified.defaultExpression == nil)

            if target.isPostgres {
                #expect(id.dataType == "int8")
                #expect(id.fullType == "bigint")
                #expect(status.fullType.hasSuffix("post_status"))
                #expect(title.characterSet == nil && title.collation == nil)
            } else {
                #expect(id.dataType == "bigint")
                #expect(id.fullType == (target.engine == .mariadb ? "bigint(20) unsigned" : "bigint unsigned"))
                #expect(author.fullType == (target.engine == .mariadb ? "bigint(20) unsigned" : "bigint unsigned"))
                #expect(status.fullType == "enum('publish','draft','pending','private','it''s')")
                #expect(title.characterSet == "utf8mb4")
                #expect(title.collation == "utf8mb4_unicode_ci")
                #expect(content.characterSet == "utf8mb4")
                #expect(author.characterSet == nil)
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func usersColumnsAndDefaults(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            let s = try await f.inspector.structure(of: f.ref("wp_users"))
            let registered = try #require(s.columns.first { $0.name == "user_registered" })
            #expect(!registered.isNullable)
            #expect(registered.dataType == (target.isPostgres ? "timestamp" : "datetime"))
            let expr = (registered.defaultExpression ?? "").lowercased()
            #expect(expr.contains(target.isPostgres ? "now()" : "current_timestamp"))
            let login = try #require(s.columns.first { $0.name == "user_login" })
            #expect(login.defaultExpression == (target.isPostgres ? "''::character varying" : "''"))
            #expect(s.info.comment == "Users table")
        }
    }

    // MARK: indexes

    @Test(arguments: DBTarget.all)
    func postsIndexes(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            let s = try await f.inspector.structure(of: f.ref("wp_posts"))
            let pk = target.isPostgres ? "id" : "ID"
            let primary = try #require(s.indexes.first)
            #expect(primary.isPrimary && primary.isUnique)
            #expect(primary.columns == [pk])
            #expect(primary.name == (target.isPostgres ? "wp_posts_pkey" : "PRIMARY"))
            #expect(primary.method == (target.isPostgres ? "btree" : "BTREE"))
            #expect(primary.predicate == nil)

            let byName = Dictionary(uniqueKeysWithValues: s.indexes.map { ($0.name, $0) })
            let postName = try #require(byName["post_name"])
            #expect(postName.columns == ["post_name"])
            #expect(!postName.isUnique && !postName.isPrimary)
            #expect(postName.method == (target.isPostgres ? "btree" : "BTREE"))

            if target.isPostgres {
                #expect(Set(s.indexes.map(\.name)) == ["wp_posts_pkey", "post_name", "published_modified", "title_lower", "content_fts"])
                let partial = try #require(byName["published_modified"])
                #expect(partial.columns == ["post_modified"])
                let predicate = try #require(partial.predicate)
                #expect(predicate.contains("post_status") && predicate.contains("'publish'"))
                let expression = try #require(byName["title_lower"])
                #expect(expression.columns.count == 2)
                #expect(expression.columns[0].contains("lower"))
                #expect(expression.columns[1] == "id")
                let gin = try #require(byName["content_fts"])
                #expect(gin.method == "gin")
                #expect(gin.columns.count == 1 && gin.columns[0].contains("to_tsvector"))
                #expect(byName["post_name"]?.predicate == nil)
            } else {
                #expect(Set(s.indexes.map(\.name)) == ["PRIMARY", "post_name", "type_status_date", "ft_title_content"])
                let composite = try #require(byName["type_status_date"])
                #expect(composite.columns == ["post_status", "post_modified", "ID"])
                #expect(composite.predicate == nil)
                let fulltext = try #require(byName["ft_title_content"])
                #expect(fulltext.method == "FULLTEXT")
                #expect(fulltext.columns == ["post_title", "post_content"])
                #expect(!fulltext.isUnique)
            }

            let users = try await f.inspector.structure(of: f.ref("wp_users"))
            let unique = try #require(users.indexes.first { $0.name == "user_login_key" })
            #expect(unique.isUnique && !unique.isPrimary)
            #expect(unique.columns == ["user_login"])
            #expect(users.indexes.first?.isPrimary == true)

            let meta = try await f.inspector.structure(of: f.ref("wp_postmeta"))
            #expect(Set(meta.indexes.map(\.name)).isSuperset(of: ["post_id", "meta_key"]))
            #expect(meta.indexes.first { $0.name == "post_id" }?.columns == ["post_id"])
        }
    }

    @Test(arguments: DBTarget.all)
    func compositeKeysAndForeignKeys(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()

            let parent = try await f.inspector.structure(of: f.ref("parent_cpk"))
            #expect(parent.primaryKey == ["a", "b"])
            #expect(parent.columns.map(\.isPrimaryKey) == [true, true, false])
            #expect(parent.indexes.first?.columns == ["a", "b"])
            #expect(parent.foreignKeys.isEmpty)
            #expect(parent.referencedBy.count == 1)
            let incoming = parent.referencedBy[0]
            #expect(incoming.name == "fk_child_parent")
            #expect(incoming.table == f.ref("child_fk"))
            #expect(incoming.columns == ["pa", "pb"])
            #expect(incoming.referenced == f.ref("parent_cpk"))
            #expect(incoming.referencedColumns == ["a", "b"])

            let child = try await f.inspector.structure(of: f.ref("child_fk"))
            #expect(child.referencedBy.isEmpty)
            let fk = try #require(child.foreignKeys.first)
            #expect(child.foreignKeys.count == 1)
            #expect(fk == incoming)
            #expect(fk.onDelete == "CASCADE")
            #expect(fk.onUpdate == "RESTRICT")
            #expect(fk.table == f.ref("child_fk"))

            let meta = try await f.inspector.structure(of: f.ref("wp_postmeta"))
            let metaFK = try #require(meta.foreignKeys.first)
            #expect(metaFK.name == "fk_meta_post")
            #expect(metaFK.columns == ["post_id"])
            #expect(metaFK.referenced == f.ref("wp_posts"))
            #expect(metaFK.referencedColumns == [target.isPostgres ? "id" : "ID"])
            #expect(metaFK.onDelete == "CASCADE")
            // Unspecified ON UPDATE: MySQL 8.4 reports NO ACTION, MariaDB reports RESTRICT.
            #expect(metaFK.onUpdate == (target.engine == .mariadb ? "RESTRICT" : "NO ACTION"))

            let posts = try await f.inspector.structure(of: f.ref("wp_posts"))
            #expect(posts.referencedBy.map(\.name) == ["fk_meta_post"])
            #expect(posts.referencedBy.first?.table == f.ref("wp_postmeta"))
            #expect(posts.foreignKeys.isEmpty)
        }
    }

    // MARK: views, DDL, engines

    @Test(arguments: DBTarget.all)
    func viewsAndCreateStatements(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            let view = try await f.inspector.structure(of: f.ref("v_published"))
            #expect(view.info.kind == .view)
            #expect(view.columns.map(\.name) == (target.isPostgres ? ["id", "post_title"] : ["ID", "post_title"]))
            #expect(view.indexes.isEmpty && view.foreignKeys.isEmpty && view.referencedBy.isEmpty)
            let viewDDL = try #require(view.createStatement)
            #expect(viewDDL.uppercased().contains("VIEW"))
            #expect(viewDDL.contains("wp_posts"))

            let posts = try await f.inspector.structure(of: f.ref("wp_posts"))
            let ddl = try #require(posts.createStatement)
            #expect(ddl.uppercased().contains("CREATE TABLE"))
            #expect(ddl.contains("post_status"))
            #expect(ddl.uppercased().contains("PRIMARY KEY"))
            if target.isPostgres {
                #expect(ddl.hasPrefix("-- Reconstructed"))
                #expect(ddl.contains("GENERATED ALWAYS AS IDENTITY"))
                #expect(ddl.contains("CREATE INDEX post_name ON"))
                #expect(ddl.contains("WHERE"))  // the partial index
                let metaDDL = try #require(try await f.inspector.structure(of: f.ref("wp_postmeta")).createStatement)
                #expect(metaDDL.contains("FOREIGN KEY (\"post_id\") REFERENCES \(f.q).\"wp_posts\" (\"id\") ON DELETE CASCADE"))
                let mv = try await f.inspector.structure(of: f.ref("mv_authors"))
                #expect(mv.info.kind == .materializedView)
                #expect(mv.createStatement?.contains("CREATE MATERIALIZED VIEW") == true)
                #expect(mv.columns.map(\.name) == ["post_author", "n"])
            } else {
                #expect(ddl.contains("FULLTEXT KEY `ft_title_content`"))
                let childDDL = try #require(try await f.inspector.structure(of: f.ref("child_fk")).createStatement)
                #expect(childDDL.contains("ON DELETE CASCADE"))
            }
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func mysqlEnginesAndCollations(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            try await f.createWordPressFixture()
            let s = try await f.inspector.structure(of: f.ref("legacy_myisam"))
            #expect(s.info.engine == "MyISAM")
            #expect(s.columns.map(\.name) == ["id", "note"])
            #expect(s.createStatement?.contains("ENGINE=MyISAM") == true)
            #expect(s.primaryKey == ["id"])

            let engines = try await f.inspector.availableEngines()
            #expect(engines.contains("InnoDB") && engines.contains("MyISAM"))
            #expect(!engines.contains("FEDERATED"))  // present but not enabled on both images

            let collations = try await f.inspector.availableCollations()
            let unicode = try #require(collations.first { $0.name == "utf8mb4_unicode_ci" })
            #expect(unicode.characterSet == "utf8mb4")
            #expect(!unicode.isDefault)
            #expect(collations.filter(\.isDefault).filter { $0.characterSet == "utf8mb4" }.count == 1)
            #expect(collations.map(\.name) == collations.map(\.name).sorted())
            let defaultName = target.engine == .mysql ? "utf8mb4_0900_ai_ci" : "utf8mb4_uca1400_ai_ci"
            #expect(collations.contains { $0.name == defaultName && $0.isDefault })
            #expect(collations.allSatisfy { !$0.characterSet.isEmpty })
        }
    }

    @Test
    func postgresHasNoCollationsOrEngines() async throws {
        try await SchemaFixture.with(.postgres16) { f in
            let empty2 = try await f.inspector.availableEngines()
            #expect(empty2.isEmpty)
            let empty3 = try await f.inspector.availableCollations()
            #expect(empty3.isEmpty)
        }
    }

    @Test(arguments: DBTarget.all)
    func missingTableThrows(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            await #expect(throws: DatabaseError.self) {
                _ = try await f.inspector.structure(of: f.ref("nope"))
            }
        }
    }

    @Test(arguments: DBTarget.all)
    func hostileNamesAreQuotedNotInterpolated(target: DBTarget) async throws {
        try await SchemaFixture.with(target) { f in
            let tableName = "we'ird `t\"able\\"
            let col = "co'l `\"x\\"
            let qt = f.dialect.quoteIdentifier(tableName)
            try await f.run("CREATE TABLE \(f.q).\(qt) (\(f.dialect.quoteIdentifier(col)) int PRIMARY KEY)")
            let tables = try await f.inspector.listTables(schema: f.schema)
            #expect(tables.map(\.ref.name) == [tableName])
            let s = try await f.inspector.structure(of: f.ref(tableName))
            #expect(s.columns.map(\.name) == [col])
            #expect(s.primaryKey == [col])
            // A malicious schema name finds nothing instead of injecting.
            let hostile = "x' OR '1'='1"
            let empty4 = try await f.inspector.listTables(schema: hostile)
            #expect(empty4.isEmpty)
        }
    }

    @Test
    func factoryPicksInspectorByEngine() async throws {
        for target in DBTarget.all {
            let session = try await target.connect()
            let inspector = SchemaInspectorFactory.inspector(for: session)
            if target.isPostgres {
                #expect(inspector is PostgresSchemaInspector)
            } else {
                #expect(inspector is MySQLSchemaInspector)
            }
            await session.close()
        }
    }
}
