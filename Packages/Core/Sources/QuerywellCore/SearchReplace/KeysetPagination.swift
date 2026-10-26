import Foundation

/// Keyset ("seek") pagination helpers shared by search & replace and whole-table export.
enum KeysetPagination {
    /// `WHERE` fragment selecting rows strictly after `after` in primary-key order, written out in
    /// expanded form (`a > x OR (a = x AND b > y)`) so it is valid on every engine and uses the key index.
    static func condition(primaryKey: [String], after: [DatabaseValue], dialect: SQLDialect) -> String? {
        guard !primaryKey.isEmpty, after.count == primaryKey.count else { return nil }
        var terms: [String] = []
        for i in 0..<primaryKey.count {
            var parts: [String] = []
            for j in 0..<i {
                parts.append("\(dialect.quoteIdentifier(primaryKey[j])) = \(dialect.literal(after[j]))")
            }
            parts.append("\(dialect.quoteIdentifier(primaryKey[i])) > \(dialect.literal(after[i]))")
            terms.append("(" + parts.joined(separator: " AND ") + ")")
        }
        return "(" + terms.joined(separator: " OR ") + ")"
    }
}
