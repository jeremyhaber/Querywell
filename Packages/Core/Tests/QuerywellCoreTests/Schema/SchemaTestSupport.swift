import Foundation
import Testing

@testable import QuerywellCore

let schemaIntegrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

extension DBTarget {
    /// A session with privileges to create databases (MySQL/MariaDB: root; Postgres: the test role is a superuser).
    func connectPrivileged() async throws -> any DatabaseSession {
        var cfg = config()
        if !isPostgres {
            cfg.user = "root"
            cfg.password = "root_pw"
            cfg.database = nil
        }
        return try await DriverRegistry.driver(for: cfg.engine).connect(cfg)
    }
}

/// A uniquely named schema (MySQL: database) created for one test and dropped afterwards.
struct SchemaFixture {
    let target: DBTarget
    let schema: String
    let session: any DatabaseSession
    let dialect: SQLDialect
    var inspector: any SchemaInspector { SchemaInspectorFactory.inspector(for: session) }

    var q: String { dialect.quoteIdentifier(schema) }
    func ref(_ name: String) -> TableRef { TableRef(schema: schema, name: name) }

    func run(_ sql: String) async throws {
        _ = try await session.execute(sql)
    }

    static func with(
        _ target: DBTarget, _ body: (SchemaFixture) async throws -> Void
    ) async throws {
        let session = try await target.connectPrivileged()
        let schema = "qw_insp_" + UUID().uuidString.prefix(8).lowercased()
        let fixture = SchemaFixture(target: target, schema: schema, session: session, dialect: SQLDialect(session.engine))
        do {
            try await fixture.run(target.isPostgres ? "CREATE SCHEMA \(fixture.q)" : "CREATE DATABASE \(fixture.q)")
            try await body(fixture)
        } catch {
            await fixture.drop()
            await session.close()
            throw error
        }
        await fixture.drop()
        await session.close()
    }

    func drop() async {
        _ = try? await session.execute(
            target.isPostgres ? "DROP SCHEMA IF EXISTS \(q) CASCADE" : "DROP DATABASE IF EXISTS \(q)"
        )
    }
}

extension SchemaFixture {
    /// WordPress-flavoured tables, a composite-key parent with a multi-column FK child, a view,
    /// routines and engine-specific extras.
    func createWordPressFixture() async throws {
        if target.isPostgres { try await createPostgresFixture() } else { try await createMySQLFixture() }
    }

    private func createMySQLFixture() async throws {
        let tail = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
        try await run(
            """
            CREATE TABLE \(q).wp_users (
              ID bigint unsigned NOT NULL AUTO_INCREMENT,
              user_login varchar(60) NOT NULL DEFAULT '',
              user_email varchar(100) NOT NULL DEFAULT '',
              user_registered datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
              PRIMARY KEY (ID),
              UNIQUE KEY user_login_key (user_login)
            ) \(tail) COMMENT='Users table'
            """)
        try await run(
            """
            CREATE TABLE \(q).wp_posts (
              ID bigint unsigned NOT NULL AUTO_INCREMENT,
              post_author bigint unsigned NOT NULL DEFAULT 0,
              post_title varchar(255) NOT NULL DEFAULT '' COMMENT 'The title',
              post_content longtext NOT NULL,
              post_status enum('publish','draft','pending','private','it''s') NOT NULL DEFAULT 'draft',
              post_name varchar(200) DEFAULT NULL,
              post_modified datetime DEFAULT NULL,
              PRIMARY KEY (ID),
              KEY post_name (post_name(191)),
              KEY type_status_date (post_status, post_modified, ID),
              FULLTEXT KEY ft_title_content (post_title, post_content)
            ) \(tail)
            """)
        try await run(
            """
            CREATE TABLE \(q).wp_postmeta (
              meta_id bigint unsigned NOT NULL AUTO_INCREMENT,
              post_id bigint unsigned NOT NULL DEFAULT 0,
              meta_key varchar(255) DEFAULT NULL,
              meta_value longtext,
              PRIMARY KEY (meta_id),
              KEY post_id (post_id),
              KEY meta_key (meta_key(191)),
              CONSTRAINT fk_meta_post FOREIGN KEY (post_id) REFERENCES \(q).wp_posts (ID) ON DELETE CASCADE
            ) \(tail)
            """)
        try await run(
            "CREATE TABLE \(q).parent_cpk (a int NOT NULL, b varchar(10) NOT NULL, label varchar(20), PRIMARY KEY (a, b)) \(tail)")
        try await run(
            """
            CREATE TABLE \(q).child_fk (
              id int NOT NULL, pa int NOT NULL, pb varchar(10) NOT NULL, PRIMARY KEY (id),
              KEY pa_pb (pa, pb),
              CONSTRAINT fk_child_parent FOREIGN KEY (pa, pb) REFERENCES \(q).parent_cpk (a, b)
                ON DELETE CASCADE ON UPDATE RESTRICT
            ) \(tail)
            """)
        try await run("CREATE TABLE \(q).legacy_myisam (id int NOT NULL, note varchar(50), PRIMARY KEY (id)) ENGINE=MyISAM")
        try await run("CREATE VIEW \(q).v_published AS SELECT ID, post_title FROM \(q).wp_posts WHERE post_status = 'publish'")
        try await run("CREATE FUNCTION \(q).fn_double(x int) RETURNS int DETERMINISTIC RETURN x * 2")
        try await run("CREATE PROCEDURE \(q).sp_noop() BEGIN SELECT 1; END")
    }

    private func createPostgresFixture() async throws {
        try await run("CREATE TYPE \(q).post_status AS ENUM ('publish','draft','pending','private','it''s')")
        try await run(
            """
            CREATE TABLE \(q).wp_users (
              id bigserial PRIMARY KEY,
              user_login varchar(60) NOT NULL DEFAULT '',
              user_email varchar(100) NOT NULL DEFAULT '',
              user_registered timestamp NOT NULL DEFAULT now(),
              CONSTRAINT user_login_key UNIQUE (user_login)
            )
            """)
        try await run("COMMENT ON TABLE \(q).wp_users IS 'Users table'")
        try await run(
            """
            CREATE TABLE \(q).wp_posts (
              id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              post_author bigint NOT NULL DEFAULT 0,
              post_title varchar(255) NOT NULL DEFAULT '',
              post_content text NOT NULL,
              post_status \(q).post_status NOT NULL DEFAULT 'draft',
              post_name varchar(200),
              post_modified timestamp
            )
            """)
        try await run("COMMENT ON COLUMN \(q).wp_posts.post_title IS 'The title'")
        try await run("CREATE INDEX post_name ON \(q).wp_posts (post_name)")
        try await run("CREATE INDEX published_modified ON \(q).wp_posts (post_modified) WHERE post_status = 'publish'")
        try await run("CREATE INDEX title_lower ON \(q).wp_posts (lower(post_title), id)")
        try await run("CREATE INDEX content_fts ON \(q).wp_posts USING gin (to_tsvector('english', post_content))")
        try await run(
            """
            CREATE TABLE \(q).wp_postmeta (
              meta_id bigserial PRIMARY KEY,
              post_id bigint NOT NULL DEFAULT 0,
              meta_key varchar(255),
              meta_value text,
              CONSTRAINT fk_meta_post FOREIGN KEY (post_id) REFERENCES \(q).wp_posts (id) ON DELETE CASCADE
            )
            """)
        try await run("CREATE INDEX post_id ON \(q).wp_postmeta (post_id)")
        try await run("CREATE INDEX meta_key ON \(q).wp_postmeta (meta_key)")
        try await run("CREATE TABLE \(q).parent_cpk (a int NOT NULL, b varchar(10) NOT NULL, label varchar(20), PRIMARY KEY (a, b))")
        try await run(
            """
            CREATE TABLE \(q).child_fk (
              id int PRIMARY KEY, pa int NOT NULL, pb varchar(10) NOT NULL,
              CONSTRAINT fk_child_parent FOREIGN KEY (pa, pb) REFERENCES \(q).parent_cpk (a, b)
                ON DELETE CASCADE ON UPDATE RESTRICT
            )
            """)
        try await run("CREATE VIEW \(q).v_published AS SELECT id, post_title FROM \(q).wp_posts WHERE post_status = 'publish'")
        try await run("CREATE MATERIALIZED VIEW \(q).mv_authors AS SELECT post_author, count(*) AS n FROM \(q).wp_posts GROUP BY post_author")
        try await run("CREATE FUNCTION \(q).fn_double(x int) RETURNS int LANGUAGE sql IMMUTABLE AS 'SELECT x * 2'")
        try await run("CREATE PROCEDURE \(q).sp_noop() LANGUAGE sql AS 'SELECT 1'")
    }
}
