import Foundation

/// What the New Database sheet asks for. Optional fields are left out of the statement so the
/// server's defaults apply.
public struct NewDatabaseSpec: Sendable, Equatable {
    public var name: String
    /// MySQL / MariaDB.
    public var characterSet: String?
    public var collation: String?
    /// PostgreSQL.
    public var owner: String?
    public var encoding: String?
    public var template: String?

    public init(
        name: String, characterSet: String? = nil, collation: String? = nil,
        owner: String? = nil, encoding: String? = nil, template: String? = nil
    ) {
        self.name = name
        self.characterSet = characterSet
        self.collation = collation
        self.owner = owner
        self.encoding = encoding
        self.template = template
    }
}

/// `CREATE DATABASE` / `DROP DATABASE` text. The app runs the result through the write gate.
public enum DatabaseDDL {
    /// Why a spec can't be used; empty when it is fine. `existing` is the server's database list.
    public static func problems(_ spec: NewDatabaseSpec, dialect: SQLDialect, existing: [String]) -> [String] {
        var out: [String] = []
        let name = normalizedName(spec.name)
        if name.isEmpty {
            out.append("Enter a name.")
        } else {
            switch dialect.family {
            case .mysql:
                if name.count > 64 { out.append("Names are at most 64 characters.") }
                if name.contains(where: { "/\\.".contains($0) }) { out.append("A name can't contain / \\ or .") }
                if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    out.append("A database called “\(name)” already exists.")
                }
            case .postgres:
                if name.utf8.count > 63 { out.append("Names are at most 63 bytes.") }
                if existing.contains(name) { out.append("A database called “\(name)” already exists.") }
            }
            if name.unicodeScalars.contains("\0") { out.append("A name can't contain a NUL character.") }
        }
        if dialect.family == .mysql {
            for (label, value) in [("character set", spec.characterSet), ("collation", spec.collation)] {
                if let value = clean(value), !isPlainWord(value) { out.append("The \(label) “\(value)” isn't valid.") }
            }
        }
        return out
    }

    /// The statement, without a trailing semicolon (like the other generated DDL).
    public static func create(_ spec: NewDatabaseSpec, dialect: SQLDialect) -> String {
        var sql = "CREATE DATABASE " + dialect.quoteIdentifier(normalizedName(spec.name))
        switch dialect.family {
        case .mysql:
            if let cs = clean(spec.characterSet) { sql += " CHARACTER SET " + cs }
            if let co = clean(spec.collation) { sql += " COLLATE " + co }
        case .postgres:
            if let owner = clean(spec.owner) { sql += " OWNER " + dialect.quoteIdentifier(owner) }
            if let template = clean(spec.template) { sql += " TEMPLATE " + dialect.quoteIdentifier(template) }
            if let encoding = clean(spec.encoding) { sql += " ENCODING " + dialect.quoteString(encoding) }
        }
        return sql
    }

    public static func drop(_ name: String, dialect: SQLDialect) -> String {
        "DROP DATABASE " + dialect.quoteIdentifier(name)
    }

    /// The name as it will be created (surrounding whitespace removed).
    public static func normalizedName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// Charset and collation names are bare words in MySQL (`utf8mb4_0900_ai_ci`).
    private static func isPlainWord(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }
}
