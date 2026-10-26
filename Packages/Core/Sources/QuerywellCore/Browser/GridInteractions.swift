import Foundation

/// Header-click sorting for the grid.
public enum SortCycle {
    /// Plain click: asc → desc → none, replacing any other sort. `additive` (shift-click) edits that
    /// column in place and keeps the other keys, so secondary sorts are possible.
    public static func next(current: [SortKey], column: String, additive: Bool) -> [SortKey] {
        let index = current.firstIndex { $0.column.caseInsensitiveCompare(column) == .orderedSame }
        if additive {
            var keys = current
            guard let index else { return keys + [SortKey(column: column, ascending: true)] }
            if keys[index].ascending {
                keys[index].ascending = false
            } else {
                keys.remove(at: index)
            }
            return keys
        }
        guard let index, current.count == 1 else {
            return [SortKey(column: column, ascending: true)]
        }
        return current[index].ascending ? [SortKey(column: column, ascending: false)] : []
    }

    /// Direction and 1-based priority (nil when only one key) of `column` in `sort`.
    public static func indicator(for column: String, in sort: [SortKey]) -> (ascending: Bool, priority: Int?)? {
        guard let index = sort.firstIndex(where: { $0.column.caseInsensitiveCompare(column) == .orderedSame }) else { return nil }
        return (sort[index].ascending, sort.count > 1 ? index + 1 : nil)
    }
}

/// Conditions offered by the funnel popover, and their mapping to ``FilterOperator``.
public enum FilterCondition: String, CaseIterable, Sendable, Hashable, Identifiable {
    case isAnyOf, isNot, contains, isEmpty, isNotEmpty, dateRange, between, regex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .isAnyOf: "is any of"
        case .isNot: "is not"
        case .contains: "contains"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .dateRange: "date range"
        case .between: "between"
        case .regex: "matches regex"
        }
    }

    /// Value checklist shown (is any of / is not).
    public var usesValueList: Bool { self == .isAnyOf || self == .isNot }
    public var usesText: Bool { self == .contains || self == .regex }
    public var usesRange: Bool { self == .between || self == .dateRange }

    public static func available(for kind: ColumnKind) -> [FilterCondition] {
        var out: [FilterCondition] = [.isAnyOf, .isNot, .contains, .isEmpty, .isNotEmpty]
        if kind.isTemporal { out.append(.dateRange) }
        if kind.isNumeric { out.append(.between) }
        if !kind.isNumeric && !kind.isTemporal && kind != .boolean { out.append(.regex) }
        return out
    }

    /// Builds the operator, or nil while the inputs are incomplete (nothing selected, empty text…).
    public func makeOperator(values: [DatabaseValue], text: String, text2: String, kind: ColumnKind) -> FilterOperator? {
        let a = text.trimmingCharacters(in: .whitespaces)
        let b = text2.trimmingCharacters(in: .whitespaces)
        switch self {
        case .isAnyOf: return values.isEmpty ? nil : .isAnyOf(values)
        case .isNot: return values.isEmpty ? nil : .isNoneOf(values)
        case .contains: return text.isEmpty ? nil : .contains(text)
        case .regex: return text.isEmpty ? nil : .regex(text)
        case .isEmpty: return .isEmpty
        case .isNotEmpty: return .isNotEmpty
        case .dateRange:
            let from = a.isEmpty ? nil : a, to = b.isEmpty ? nil : b
            return from == nil && to == nil ? nil : .dateRange(from: from, to: to)
        case .between:
            guard !a.isEmpty, !b.isEmpty else { return nil }
            func parse(_ s: String) -> DatabaseValue {
                if kind == .integer, let i = Int64(s) { return .integer(i) }
                if let d = Double(s) { return .double(d) }
                return .text(s)
            }
            return .between(parse(a), parse(b))
        }
    }

    /// Reverse mapping, to pre-fill the popover from an existing chip.
    public struct Draft: Sendable, Hashable {
        public var condition: FilterCondition
        public var values: [DatabaseValue]
        public var text: String
        public var text2: String
    }

    public static func draft(from op: FilterOperator) -> Draft? {
        func d(_ c: FilterCondition, values: [DatabaseValue] = [], _ t: String = "", _ t2: String = "") -> Draft {
            Draft(condition: c, values: values, text: t, text2: t2)
        }
        switch op {
        case .isAnyOf(let v): return d(.isAnyOf, values: v)
        case .equals(let v): return d(.isAnyOf, values: [v])
        case .isNoneOf(let v): return d(.isNot, values: v)
        case .notEquals(let v): return d(.isNot, values: [v])
        case .contains(let s): return d(.contains, s)
        case .regex(let s): return d(.regex, s)
        case .isEmpty: return d(.isEmpty)
        case .isNotEmpty: return d(.isNotEmpty)
        case .dateRange(let f, let t): return d(.dateRange, f ?? "", t ?? "")
        case .between(let a, let b): return d(.between, a.displayString, b.displayString)
        case .isNull: return d(.isAnyOf, values: [.null])
        case .isNotNull: return d(.isNot, values: [.null])
        default: return nil
        }
    }
}

/// Clipboard formats for selected grid rows.
public enum CopyFormat: String, CaseIterable, Sendable, Hashable {
    case tsv, csv, json, sqlInsert

    public var title: String {
        switch self {
        case .tsv: "TSV"
        case .csv: "CSV"
        case .json: "JSON"
        case .sqlInsert: "SQL INSERT"
        }
    }
}

public enum RowCopy {
    /// Serialises rows. TSV/CSV quote only when needed (RFC 4180 style, so spreadsheets paste cleanly) and
    /// write NULL as `nullText`; JSON is an array of objects in column order with real numbers/booleans/null;
    /// SQL INSERT emits one statement per row through `dialect.literal`.
    public static func text(
        format: CopyFormat, columns: [String], rows: [[DatabaseValue]], table: TableRef?,
        dialect: SQLDialect, includeHeader: Bool = true, nullText: String = ""
    ) -> String {
        switch format {
        case .tsv: return delimited("\t", columns, rows, includeHeader, nullText)
        case .csv: return delimited(",", columns, rows, includeHeader, nullText)
        case .json: return json(columns, rows)
        case .sqlInsert:
            let target = table.map(dialect.qualified) ?? dialect.quoteIdentifier("table")
            let names = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
            return rows.map { row in
                "INSERT INTO \(target) (\(names)) VALUES (\(row.map(dialect.literal).joined(separator: ", ")));"
            }.joined(separator: "\n")
        }
    }

    private static func delimited(_ sep: Character, _ columns: [String], _ rows: [[DatabaseValue]], _ header: Bool, _ nullText: String) -> String {
        func field(_ s: String) -> String {
            guard s.contains(where: { $0 == sep || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines: [String] = []
        if header { lines.append(columns.map(field).joined(separator: String(sep))) }
        for row in rows {
            lines.append(row.map { $0.isNull ? nullText : field(CellDisplay.copyText($0)) }.joined(separator: String(sep)))
        }
        return lines.joined(separator: "\n")
    }

    private static func json(_ columns: [String], _ rows: [[DatabaseValue]]) -> String {
        if rows.isEmpty { return "[]" }
        let objects = rows.map { row -> String in
            let pairs = columns.enumerated().map { index, name -> String in
                let value = index < row.count ? row[index] : .null
                return "    \(quote(name)): \(jsonValue(value))"
            }
            return "  {\n" + pairs.joined(separator: ",\n") + "\n  }"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    private static func jsonValue(_ v: DatabaseValue) -> String {
        switch v {
        case .null: "null"
        case .integer(let i): String(i)
        case .unsignedInteger(let u): String(u)
        case .double(let d): d.isFinite ? String(d) : quote(String(d))
        case .bool(let b): b ? "true" : "false"
        case .text(let s): quote(s)
        case .bytes(let d): quote("0x" + d.map { String(format: "%02X", $0) }.joined())
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

extension CellDisplay {
    /// Full, untruncated text of a value for copying (bytes as complete hex).
    public static func copyText(_ value: DatabaseValue) -> String {
        if case .bytes(let d) = value { return "0x" + d.map { String(format: "%02X", $0) }.joined() }
        return value.displayString
    }
}
