import Foundation

/// Coarse type families used to pick fonts, filter conditions and hex/JSON handling.
public enum ColumnKind: Sendable, Hashable {
    case integer, decimal, boolean, date, time, dateTime, text, longText, json, uuid, binary, enumeration, other

    public var isNumeric: Bool { self == .integer || self == .decimal }
    public var isTemporal: Bool { self == .date || self == .time || self == .dateTime }

    /// Classifies an engine type name ("varchar", "bigint", "timestamptz", "int4", "longtext"…).
    /// Accepts a full type too ("varchar(255)", "bigint unsigned"); only the base word matters.
    public static func classify(dataType: String) -> ColumnKind {
        var t = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        if let paren = t.firstIndex(of: "(") { t = String(t[..<paren]).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("double precision") {
            t = "double precision"
        } else if t.hasPrefix("character varying") {
            t = "character varying"
        } else if t.hasPrefix("timestamp") {
            t = "timestamp"
        } else if let space = t.firstIndex(of: " ") {
            t = String(t[..<space])  // "bigint unsigned"
        }
        switch t {
        case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "int2", "int4", "int8", "serial", "bigserial",
            "smallserial", "year":
            return .integer
        case "decimal", "numeric", "float", "double", "real", "float4", "float8", "money", "double precision", "dec", "fixed":
            return .decimal
        case "bool", "boolean", "bit": return .boolean
        case "date": return .date
        case "time", "timetz": return .time
        case "datetime", "timestamp", "timestamptz", "datetime2": return .dateTime
        case "char", "varchar", "character varying", "character", "bpchar", "name", "citext", "tinytext": return .text
        case "text", "mediumtext", "longtext": return .longText
        case "json", "jsonb": return .json
        case "uuid": return .uuid
        case "blob", "tinyblob", "mediumblob", "longblob", "binary", "varbinary", "bytea": return .binary
        case "enum", "set": return .enumeration
        default: return .other
        }
    }
}

/// How one column is drawn in the grid. Rule (matches the mockup): numeric, date/time, uuid and short
/// identifier-like columns use the monospaced face; prose (`text`, long `varchar`) is proportional.
public struct ColumnPresentation: Sendable, Hashable {
    public var kind: ColumnKind
    public var usesMonospace: Bool
    /// Status-like values drawn as a rounded pill ("publish").
    public var usesPill: Bool

    public init(name: String, dataType: String, fullType: String? = nil) {
        kind = ColumnKind.classify(dataType: dataType)
        let lowered = name.lowercased()
        usesPill = kind == .enumeration || lowered == "status" || lowered.hasSuffix("_status")
        switch kind {
        case .integer, .decimal, .boolean, .date, .time, .dateTime, .uuid, .binary, .json:
            usesMonospace = true
        case .text:
            let shortColumn = Self.declaredLength(fullType ?? dataType).map { $0 <= 64 } ?? false
            usesMonospace = shortColumn || Self.looksLikeIdentifier(lowered)
        case .longText:
            usesMonospace = false
        case .enumeration:
            usesMonospace = true
        case .other:
            usesMonospace = Self.looksLikeIdentifier(lowered)
        }
    }

    /// `varchar(255)` → 255.
    static func declaredLength(_ fullType: String) -> Int? {
        guard let open = fullType.firstIndex(of: "("), let close = fullType.firstIndex(of: ")"), open < close else { return nil }
        let inner = fullType[fullType.index(after: open)..<close]
        return Int(inner.split(separator: ",").first.map(String.init) ?? "")
    }

    /// Slugs, keys, codes and other machine-ish strings read better in mono even when declared long.
    static func looksLikeIdentifier(_ lowered: String) -> Bool {
        let exact: Set<String> = ["slug", "post_name", "guid", "uuid", "email", "url", "ip", "token", "hash", "sku", "code", "key"]
        if exact.contains(lowered) { return true }
        return ["_slug", "_key", "_code", "_uuid", "_guid", "_hash", "_token", "_type", "_name_id", "_id", "_ip", "_mime_type"]
            .contains { lowered.hasSuffix($0) }
    }

    public enum PillTone: Sendable { case positive, neutral }

    /// Green for "good" status words, grey otherwise.
    public static func pillTone(for text: String) -> PillTone {
        let positive: Set<String> = [
            "publish", "published", "active", "enabled", "approved", "paid", "complete", "completed", "success", "succeeded",
            "ok", "open", "yes", "true", "live", "ready", "confirmed", "1",
        ]
        return positive.contains(text.lowercased()) ? .positive : .neutral
    }
}

/// Display strings for cells. Lazy and allocation-light: the grid asks only for visible cells.
public enum CellDisplay {
    /// Longest text that is laid out in a cell; the full value is available via ``full(_:)``.
    public static let cellLimit = 300

    /// Single-line display text (newlines shown as `↵`), truncated for layout. NULL → `nullDisplay`.
    public static func text(_ value: DatabaseValue, nullDisplay: String) -> String {
        switch value {
        case .null: return nullDisplay
        case .text(let s):
            let head = s.utf16.count > cellLimit ? String(s.prefix(cellLimit)) + "…" : s
            guard head.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return head }
            var out = ""
            var previousWasCR = false
            for ch in head {
                switch ch {
                case "\r\n": out.append("↵")
                case "\r": out.append("↵"); previousWasCR = true
                case "\n": if !previousWasCR { out.append("↵") }
                case "\t": out.append(" ")
                default: out.append(ch)
                }
                if ch != "\r" { previousWasCR = false }
            }
            return out
        case .bytes: return value.displayString
        default: return value.displayString
        }
    }

    /// Full text for tooltips/inspector/copy (capped to keep tooltips sane).
    public static func full(_ value: DatabaseValue, limit: Int = 4_000) -> String {
        let s: String
        switch value {
        case .bytes(let d):
            s = "0x" + d.prefix(limit / 2).map { String(format: "%02X", $0) }.joined() + (d.count > limit / 2 ? "… (\(d.count) bytes)" : "")
        default: s = value.displayString
        }
        return s.utf16.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}

/// Cheap shape checks for the inspector's "Open in editor" affordance (Phase 6).
public enum ValueSniffer {
    public static func isJSONLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let last = t.last, t.utf8.count <= 2_000_000 else { return false }
        guard (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }

    /// PHP `serialize()` output: `a:2:{…}`, `s:5:"hello";`, `i:3;`, `b:1;`, `d:0.5;`, `N;`, `O:8:"stdClass":…`.
    public static func isPHPSerialized(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "N;" { return true }
        return t.range(of: #"^(a:\d+:\{|O:\d+:"[^"]+":\d+:\{|s:\d+:"|i:-?\d+;|b:[01];|d:-?[\d.eE+-]+;)"#, options: .regularExpression) != nil
            && (t.hasSuffix("}") || t.hasSuffix(";"))
    }
}
