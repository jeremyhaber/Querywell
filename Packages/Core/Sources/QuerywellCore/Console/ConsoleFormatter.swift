import Foundation

// mysql-client-style rendering of query results: ASCII tables, vertical records, timing footers,
// "Query OK" lines and `ERROR 1054 (42S22): …` messages. Pure, so it is unit-tested; the app only
// decides colours.

public struct ConsoleFormatOptions: Sendable, Equatable {
    /// Cells wider than this many terminal columns are cut with an ellipsis. `nil` shows everything.
    public var maxCellWidth: Int?
    public var nullText: String

    public init(maxCellWidth: Int? = 64, nullText: String = "NULL") {
        self.maxCellWidth = maxCellWidth.map { max(4, $0) }
        self.nullText = nullText
    }
}

/// One line of output with its role, so the view can colour borders and headers differently from data.
public struct ConsoleOutputLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case border, header, row, text
        /// The "N rows in set" line.
        case footer
        case success
        case error
        case warning
    }

    public var text: String
    public var kind: Kind

    public init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

public enum ConsoleFormatter {
    // MARK: Text measurement

    /// Terminal columns a string occupies: East Asian wide characters and emoji take two, combining marks none.
    public static func displayWidth(_ s: String) -> Int {
        var width = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format: continue
            default: break
            }
            if v == 0x200D || (0xFE00...0xFE0F).contains(v) { continue }
            width += isWide(v) ? 2 : 1
        }
        return width
    }

    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
    }

    /// Cuts `s` to `width` terminal columns, ending in `…` when something was dropped.
    public static func truncate(_ s: String, to width: Int) -> String {
        guard displayWidth(s) > width else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let w = displayWidth(String(ch))
            if used + w > width - 1 { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    static func pad(_ s: String, to width: Int, rightAligned: Bool) -> String {
        let fill = String(repeating: " ", count: max(0, width - displayWidth(s)))
        return rightAligned ? fill + s : s + fill
    }

    // MARK: Cells

    /// A cell as one line of text: NULL, control characters escaped, binary as hex.
    public static func cellText(_ value: DatabaseValue, options: ConsoleFormatOptions) -> String {
        let raw: String
        switch value {
        case .null: return options.nullText
        case .text(let s): raw = s
        default: raw = value.displayString
        }
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.unicodeScalars {
            switch ch {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default:
                if ch.value < 0x20 || ch.value == 0x7F { out += String(format: "\\x%02X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        if let max = options.maxCellWidth { return truncate(out, to: max) }
        return out
    }

    private static let numericTypes: Set<String> = [
        "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "newdecimal", "float", "double",
        "real", "int2", "int4", "int8", "float4", "float8", "money", "serial", "bigserial", "smallserial",
    ]

    /// Numbers are right-aligned, like the mysql client does.
    static func isNumeric(column: ColumnInfo, index: Int, rows: [[DatabaseValue]]) -> Bool {
        let base = column.typeName.lowercased().split(separator: "(").first.map(String.init)?
            .replacingOccurrences(of: " unsigned", with: "") ?? ""
        if numericTypes.contains(base) { return true }
        var sawValue = false
        for row in rows {
            guard index < row.count else { continue }
            switch row[index] {
            case .null: continue
            case .integer, .unsignedInteger, .double: sawValue = true
            default: return false
            }
        }
        return sawValue
    }

    // MARK: Tables

    /// The `+----+` table. Empty result sets render nothing (use ``footer(rowCount:duration:)`` → "Empty set").
    public static func table(columns: [ColumnInfo], rows: [[DatabaseValue]], options: ConsoleFormatOptions = ConsoleFormatOptions()) -> [ConsoleOutputLine] {
        guard !columns.isEmpty, !rows.isEmpty else { return [] }
        let headers = columns.map { cellHeader($0.name, options: options) }
        let cells = rows.map { row in columns.indices.map { i in i < row.count ? cellText(row[i], options: options) : "" } }
        let numeric = columns.indices.map { isNumeric(column: columns[$0], index: $0, rows: rows) }
        var widths = headers.map(displayWidth)
        for row in cells { for (i, c) in row.enumerated() { widths[i] = max(widths[i], displayWidth(c)) } }

        let border = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        func line(_ values: [String], alignNumbers: Bool) -> String {
            "| " + values.enumerated().map { i, v in pad(v, to: widths[i], rightAligned: alignNumbers && numeric[i]) }.joined(separator: " | ") + " |"
        }
        var out = [ConsoleOutputLine(border, .border), ConsoleOutputLine(line(headers, alignNumbers: false), .header), ConsoleOutputLine(border, .border)]
        for row in cells { out.append(ConsoleOutputLine(line(row, alignNumbers: true), .row)) }
        out.append(ConsoleOutputLine(border, .border))
        return out
    }

    private static func cellHeader(_ name: String, options: ConsoleFormatOptions) -> String {
        cellText(.text(name), options: ConsoleFormatOptions(maxCellWidth: options.maxCellWidth, nullText: options.nullText))
    }

    /// The `\G` form: one `*** n. row ***` block per row with right-aligned column names.
    public static func vertical(columns: [ColumnInfo], rows: [[DatabaseValue]], options: ConsoleFormatOptions = ConsoleFormatOptions()) -> [ConsoleOutputLine] {
        guard !columns.isEmpty else { return [] }
        let nameWidth = columns.map { displayWidth($0.name) }.max() ?? 0
        var out: [ConsoleOutputLine] = []
        for (n, row) in rows.enumerated() {
            out.append(ConsoleOutputLine("*************************** \(n + 1). row ***************************", .border))
            for (i, column) in columns.enumerated() {
                let value = i < row.count ? row[i] : .null
                // Vertical output keeps line breaks, as the mysql client does.
                let text: String
                switch value {
                case .text(let s): text = s
                case .null: text = options.nullText
                default: text = value.displayString
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let head = pad(column.name, to: nameWidth, rightAligned: true) + ": "
                out.append(ConsoleOutputLine(head + (lines.first ?? ""), .row))
                for extra in lines.dropFirst() { out.append(ConsoleOutputLine(extra, .row)) }
            }
        }
        return out
    }

    // MARK: Footers

    /// "0.02 sec", the mysql client's two-decimal seconds.
    public static func seconds(_ d: Duration) -> String {
        let c = d.components
        let s = Double(c.seconds) + Double(c.attoseconds) / 1e18
        return String(format: "%.2f sec", s)
    }

    /// "2 rows in set (0.02 sec)" / "Empty set (0.00 sec)".
    public static func footer(rowCount: Int, duration: Duration) -> String {
        switch rowCount {
        case 0: "Empty set (\(seconds(duration)))"
        case 1: "1 row in set (\(seconds(duration)))"
        default: "\(rowCount) rows in set (\(seconds(duration)))"
        }
    }

    /// "Query OK, 1 row affected (0.01 sec)" (MySQL) or the psql command tag (`UPDATE 3`) for PostgreSQL.
    public static func affected(sql: String, rows: UInt64, duration: Duration, engine: DatabaseEngine) -> String {
        switch engine {
        case .mysql, .mariadb:
            return "Query OK, \(rows) row\(rows == 1 ? "" : "s") affected (\(seconds(duration)))"
        case .postgresql:
            return postgresCommandTag(sql: sql, rows: rows) + " (\(seconds(duration)))"
        }
    }

    /// `INSERT 0 3`, `UPDATE 2`, `DELETE 1`, `CREATE TABLE`, …
    public static func postgresCommandTag(sql: String, rows: UInt64) -> String {
        let words = SQLLexer(family: .postgres).tokenize(sql).filter { $0.kind == .word }.prefix(3).map { $0.text.uppercased() }
        guard let first = words.first else { return "OK" }
        switch first {
        case "INSERT": return "INSERT 0 \(rows)"
        case "UPDATE", "DELETE", "MERGE", "COPY": return "\(first) \(rows)"
        case "CREATE", "DROP", "ALTER":
            var tag = [first]
            for w in words.dropFirst() {
                if ["OR", "REPLACE", "UNIQUE", "TEMPORARY", "TEMP", "MATERIALIZED", "UNLOGGED", "IF", "EXISTS"].contains(w) { continue }
                tag.append(w)
                break
            }
            return tag.joined(separator: " ")
        default: return first
        }
    }

    // MARK: Errors

    /// `ERROR 1054 (42S22): Unknown column 'x' in 'field list'` / psql's `ERROR:  column "x" does not exist`.
    public static func error(_ error: DatabaseError, engine: DatabaseEngine) -> String {
        switch error {
        case .query(let message, let code):
            switch engine {
            case .mysql, .mariadb:
                if let code, let errno = Int(code) {
                    return "ERROR \(errno) (\(ConsoleSQLState.mysql(errno: errno))): \(message)"
                }
                return "ERROR: \(message)"
            case .postgresql:
                return "ERROR:  \(message)" + (code.map { " (SQLSTATE \($0))" } ?? "")
            }
        case .sessionClosed:
            return engine == .postgresql ? "FATAL:  the connection to the server was lost" : "ERROR 2006 (HY000): MySQL server has gone away"
        case .timeout:
            return engine == .postgresql ? "ERROR:  the server did not respond in time" : "ERROR 2013 (HY000): Lost connection to MySQL server during query"
        case .connectionFailed(let m), .authenticationFailed(let m), .tlsFailed(let m), .unsupported(let m):
            return "ERROR: \(m)"
        }
    }
}

/// SQLSTATE for the MySQL errors users meet most; anything else is the generic `HY000`.
public enum ConsoleSQLState {
    public static func mysql(errno: Int) -> String {
        table[errno] ?? "HY000"
    }

    private static let table: [Int: String] = [
        1007: "HY000", 1008: "HY000", 1022: "23000", 1044: "42000", 1045: "28000", 1046: "3D000", 1048: "23000", 1049: "42000",
        1050: "42S01", 1051: "42S02", 1052: "23000", 1054: "42S22", 1060: "42S21", 1061: "42000", 1062: "23000", 1063: "42000",
        1064: "42000", 1065: "42000", 1066: "42000", 1067: "42000", 1068: "42000", 1071: "42000", 1072: "42000", 1073: "42000",
        1075: "42000", 1091: "42000", 1093: "HY000", 1100: "HY000", 1109: "42S02", 1110: "42000", 1111: "HY000", 1113: "42000",
        1115: "42000", 1116: "HY000", 1118: "42000", 1119: "42000", 1121: "42000", 1136: "21S01", 1138: "22004", 1139: "42000",
        1140: "42000", 1141: "42000", 1142: "42000", 1143: "42000", 1146: "42S02", 1147: "42000", 1149: "42000", 1166: "42000",
        1167: "42000", 1169: "23000", 1170: "42000", 1171: "42000", 1172: "42000", 1176: "42000", 1177: "42000", 1178: "42000",
        1205: "HY000", 1213: "40001", 1215: "HY000", 1216: "23000", 1217: "23000", 1218: "08S01", 1222: "21000", 1225: "HY000",
        1227: "42000", 1230: "42000", 1231: "42000", 1232: "42000", 1241: "21000", 1242: "21000", 1247: "42S22", 1248: "42000",
        1250: "42000", 1263: "22004", 1264: "22003", 1265: "01000", 1267: "HY000", 1270: "HY000", 1271: "HY000", 1280: "42000",
        1292: "22007", 1293: "HY000", 1305: "42000", 1317: "70100", 1318: "42000", 1319: "42000", 1322: "42000", 1325: "24000",
        1327: "42000", 1328: "42000", 1329: "02000", 1330: "42000", 1331: "42000", 1332: "42000", 1333: "42000", 1334: "42000",
        1335: "0A000", 1336: "42000", 1337: "42000", 1338: "42000", 1339: "20000", 1364: "HY000", 1365: "22012", 1366: "HY000",
        1406: "22001", 1407: "22007", 1415: "0A000", 1416: "22003", 1422: "HY000", 1451: "23000", 1452: "23000", 1453: "42000",
        1458: "HY000", 1459: "HY000", 1460: "HY000", 1461: "42000", 1462: "42000", 1463: "42000", 1485: "HY000", 1500: "HY000",
        1690: "22003", 1698: "28000", 1701: "42000", 1702: "42000", 1706: "HY000", 1740: "HY000", 1749: "HY000", 1750: "HY000",
        1792: "25006", 1793: "25006", 1827: "HY000", 1835: "HY000", 1836: "HY000", 1845: "0A000", 1846: "0A000", 1860: "HY000",
        2002: "HY000", 2003: "HY000", 2006: "HY000", 2013: "HY000", 3024: "HY000", 3105: "HY000", 3140: "22032", 3141: "22032",
        3819: "HY000", 4025: "23000",
    ]
}
