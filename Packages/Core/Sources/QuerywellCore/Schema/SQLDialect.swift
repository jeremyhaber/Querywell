import Foundation

/// Engine-specific SQL spelling. Every identifier and literal that Querywell generates goes
/// through here — never string-interpolate user data into SQL elsewhere.
public struct SQLDialect: Sendable, Hashable {
    public enum Family: Sendable, Hashable { case mysql, postgres }

    public let family: Family

    public init(_ engine: DatabaseEngine) {
        switch engine {
        case .mysql, .mariadb: family = .mysql
        case .postgresql: family = .postgres
        }
    }

    /// `name` → `` `name` `` (MySQL) or `"name"` (Postgres), doubling embedded quote chars.
    public func quoteIdentifier(_ name: String) -> String {
        switch family {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// `schema`.`table`
    public func qualified(_ table: TableRef) -> String {
        quoteIdentifier(table.schema) + "." + quoteIdentifier(table.name)
    }

    /// A string literal safe regardless of server settings.
    ///
    /// MySQL: `'…'` with `\` and `'` escaped by backslash (valid unless NO_BACKSLASH_ESCAPES, which
    /// sessions opened by Querywell never set — see DECISIONS #29). Postgres: standard-conforming
    /// `'…'` with `'` doubled; strings containing a backslash use `E'…'` with `\` doubled too.
    /// NUL bytes are rejected by both servers in text and are not representable here.
    public func quoteString(_ value: String) -> String {
        switch family {
        case .mysql:
            var out = "'"
            for ch in value.unicodeScalars {
                switch ch {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\u{1A}": out += "\\Z"
                default: out.unicodeScalars.append(ch)
                }
            }
            return out + "'"
        case .postgres:
            if value.contains("\\") {
                return "E'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
            }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// A literal for any cell value: NULL, numbers bare, bool, text quoted, bytes as hex.
    public func literal(_ value: DatabaseValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .unsignedInteger(let v): String(v)
        case .double(let v):
            v.isFinite ? String(v) : quoteString(String(v))  // NaN/Infinity only valid as text (Postgres)
        case .bool(let v):
            family == .postgres ? (v ? "TRUE" : "FALSE") : (v ? "1" : "0")
        case .text(let v): quoteString(v)
        case .bytes(let d):
            switch family {
            case .mysql: d.isEmpty ? "''" : "0x" + d.map { String(format: "%02X", $0) }.joined()
            case .postgres: "'\\x" + d.map { String(format: "%02x", $0) }.joined() + "'::bytea"
            }
        }
    }

    /// ` LIMIT n OFFSET m` (same spelling on both families).
    public func limitClause(limit: Int, offset: Int) -> String {
        offset > 0 ? " LIMIT \(limit) OFFSET \(offset)" : " LIMIT \(limit)"
    }

    /// Escapes `%`, `_` and the escape char itself for use inside a LIKE pattern (escape char `\`).
    public func escapeLikePattern(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
