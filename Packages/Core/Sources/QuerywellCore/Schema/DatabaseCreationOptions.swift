import Foundation

/// What the New Database sheet offers, read from the server.
public struct DatabaseCreationOptions: Sendable, Equatable {
    public struct Charset: Sendable, Equatable, Identifiable {
        public var name: String
        public var defaultCollation: String?
        public var collations: [String]
        public var id: String { name }
    }

    /// MySQL / MariaDB, sorted by name.
    public var charsets: [Charset] = []
    public var defaultCharset: String?
    public var defaultCollation: String?
    /// PostgreSQL.
    public var roles: [String] = []
    public var templates: [String] = []
    public var encodings: [String] = []
    public var defaultTemplate: String?
    public var defaultEncoding: String?

    public init() {}

    public func collations(for charset: String?) -> [String] {
        guard let charset else { return [] }
        return charsets.first { $0.name == charset }?.collations ?? []
    }

    /// Groups `SHOW COLLATION` rows by character set; the server's own defaults come from `@@character_set_server`.
    public static func mysql(collations: [CollationInfo], serverCharset: String?, serverCollation: String?) -> Self {
        var options = Self()
        let grouped = Dictionary(grouping: collations, by: \.characterSet)
        options.charsets = grouped.keys.sorted().map { name in
            let rows = grouped[name] ?? []
            return Charset(
                name: name, defaultCollation: rows.first(where: \.isDefault)?.name,
                collations: rows.map(\.name).sorted())
        }
        options.defaultCharset = serverCharset
        options.defaultCollation = serverCollation
        return options
    }

    /// Encodings PostgreSQL accepts for `CREATE DATABASE` that people actually pick.
    public static let postgresEncodings = [
        "UTF8", "LATIN1", "LATIN2", "LATIN9", "WIN1250", "WIN1251", "WIN1252", "KOI8R",
        "EUC_JP", "EUC_KR", "EUC_CN", "SQL_ASCII",
    ]
}

/// Reads ``DatabaseCreationOptions`` over an open session.
public enum DatabaseCreationOptionsLoader {
    public static func load(session: any DatabaseSession, inspector: any SchemaInspector) async throws -> DatabaseCreationOptions {
        switch session.engine {
        case .mysql, .mariadb:
            let collations = try await inspector.availableCollations()
            let server = try? await session.execute("SELECT @@character_set_server AS qw_cs, @@collation_server AS qw_co")
            let row = server?.records.first
            return .mysql(collations: collations, serverCharset: row?.string("qw_cs"), serverCollation: row?.string("qw_co"))
        case .postgresql:
            var options = DatabaseCreationOptions()
            let roles = try await session.execute("SELECT rolname FROM pg_roles ORDER BY rolname")
            options.roles = roles.rows.compactMap { Record.string(from: $0.first ?? .null) }
            let templates = try await session.execute("SELECT datname FROM pg_database WHERE datistemplate ORDER BY datname")
            options.templates = templates.rows.compactMap { Record.string(from: $0.first ?? .null) }
            options.encodings = DatabaseCreationOptions.postgresEncodings
            options.defaultTemplate = options.templates.contains("template1") ? "template1" : options.templates.first
            let encoding = try? await session.execute("SHOW server_encoding")
            options.defaultEncoding = Record.string(from: encoding?.rows.first?.first ?? .null)
            return options
        }
    }
}
