import Foundation

// Turns text typed into a grid cell (or inspector field) into a `DatabaseValue` for a column.
// Pure: no server round trip. Validation is deliberately loose where the server is the authority
// (dates), and strict where a wrong guess would silently write the wrong thing (numbers, enums,
// JSON, binary). Anything accepted here is rendered to SQL through `SQLDialect.literal`.

/// Why typed text was rejected, phrased for the user.
public struct CellInputError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct CellValueParser: Sendable {
    public let column: ColumnDefinition
    public let dialect: SQLDialect
    public let kind: ColumnKind

    public init(column: ColumnDefinition, dialect: SQLDialect) {
        self.column = column
        self.dialect = dialect
        self.kind = column.enumValues != nil ? .enumeration : ColumnKind.classify(dataType: column.dataType)
    }

    // MARK: Editor hints

    /// Allowed values of an `enum` column (a single choice); nil for everything else.
    public var allowedValues: [String]? {
        guard let values = column.enumValues, !isSet else { return nil }
        return values
    }

    /// MySQL `SET`: a comma-separated subset of ``column`` enum values.
    public var isSet: Bool { column.dataType.lowercased() == "set" }

    /// Enum and boolean cells are changed through a picker instead of free text.
    public var usesPicker: Bool { allowedValues != nil || kind == .boolean && dialect.family == .postgres }

    /// Values a picker offers (excluding NULL, which the picker adds for nullable columns).
    public var pickerChoices: [String] {
        if let allowedValues { return allowedValues }
        if kind == .boolean { return ["true", "false"] }
        return []
    }

    /// Long text and JSON are edited in the inspector's multi-line field rather than in the cell.
    public var prefersInspector: Bool { kind == .longText || kind == .json }

    /// The "empty" value for "Set to Empty String": text kinds only.
    public var emptyValue: DatabaseValue? {
        switch kind {
        case .text, .longText: .text("")
        case .binary: .bytes(Data())
        default: nil
        }
    }

    // MARK: Parsing

    /// Parses `text`. An empty string is NULL for nullable columns of non-text kinds; for text
    /// columns it is the empty string (use "Set to NULL" for NULL).
    public func parse(_ text: String) -> Result<DatabaseValue, CellInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .text, .longText:
            if let n = declaredLength, text.count > n {
                return .failure(CellInputError("Too long: \(column.name) holds at most \(n) characters (this is \(text.count))."))
            }
            return .success(.text(text))
        case .other where column.enumValues == nil:
            return .success(.text(text))
        default: break
        }

        if trimmed.isEmpty {
            if kind == .binary { return .success(.bytes(Data())) }
            return column.isNullable ? .success(.null) : .failure(CellInputError("\(column.name) can't be empty (it is NOT NULL)."))
        }
        if trimmed == "NULL" {
            return column.isNullable ? .success(.null) : .failure(CellInputError("\(column.name) can't be NULL."))
        }

        switch kind {
        case .integer: return parseInteger(trimmed)
        case .decimal: return parseDecimal(trimmed)
        case .boolean: return parseBoolean(trimmed)
        case .date: return parseDate(trimmed).map { .text($0) }
        case .time: return parseTime(trimmed).map { .text($0) }
        case .dateTime: return parseDateTime(trimmed).map { .text($0) }
        case .json: return parseJSON(text)
        case .uuid: return parseUUID(trimmed)
        case .binary: return parseBinary(trimmed)
        case .enumeration: return parseEnumeration(trimmed)
        case .text, .longText, .other: return .success(.text(text))
        }
    }

    private var declaredLength: Int? {
        let t = column.dataType.lowercased()
        guard t == "varchar" || t == "char" || t == "character varying" || t == "character" || t == "bpchar" else { return nil }
        return Self.parenthesisNumbers(column.fullType).first
    }

    static func parenthesisNumbers(_ fullType: String) -> [Int] {
        guard let open = fullType.firstIndex(of: "("), let close = fullType[open...].firstIndex(of: ")") else { return [] }
        return fullType[fullType.index(after: open)..<close].split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: Integers

    private var isUnsigned: Bool { column.fullType.lowercased().contains("unsigned") }

    private var integerBits: Int {
        switch column.dataType.lowercased() {
        case "tinyint": 8
        case "smallint", "int2", "smallserial": 16
        case "mediumint": 24
        case "int", "integer", "int4", "serial": 32
        case "year": 16
        default: 64
        }
    }

    private func parseInteger(_ s: String) -> Result<DatabaseValue, CellInputError> {
        var body = s
        if body.hasPrefix("+") { body.removeFirst() }
        // Words for tinyint(1) booleans.
        if column.fullType.lowercased().hasPrefix("tinyint(1)"), case .success(let word) = parseBoolean(s), word != .null {
            return .success(word)
        }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }), body.dropFirst().allSatisfy(\.isNumber) else {
            return .failure(CellInputError("“\(s)” isn't a whole number."))
        }
        let bits = integerBits
        if isUnsigned {
            guard !body.hasPrefix("-") else { return .failure(CellInputError("\(column.name) is unsigned; it can't be negative.")) }
            guard let v = UInt64(body) else { return .failure(CellInputError("“\(s)” is too large for \(column.fullType).")) }
            let maximum: UInt64 = bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
            if v > maximum {
                return .failure(CellInputError("“\(s)” is out of range for \(column.fullType) (0 to \(maximum))."))
            }
            return .success(v <= UInt64(Int64.max) ? .integer(Int64(v)) : .unsignedInteger(v))
        }
        guard let v = Int64(body) else { return .failure(CellInputError("“\(s)” is too large for \(column.fullType).")) }
        if bits < 64 {
            let limit: Int64 = Int64(1) << Int64(bits - 1)
            let low: Int64 = -limit
            let high: Int64 = limit - 1
            if v < low || v > high {
                return .failure(CellInputError("“\(s)” is out of range for \(column.fullType) (\(low) to \(high))."))
            }
        }
        return .success(.integer(v))
    }

    // MARK: Decimals and floats

    private var isApproximate: Bool {
        ["float", "double", "real", "float4", "float8", "double precision"].contains(column.dataType.lowercased())
    }

    private func parseDecimal(_ s: String) -> Result<DatabaseValue, CellInputError> {
        if dialect.family == .postgres, ["nan", "infinity", "-infinity"].contains(s.lowercased()) {
            return .success(.text(s))
        }
        guard Self.isNumberLiteral(s) else { return .failure(CellInputError("“\(s)” isn't a number.")) }
        if isApproximate {
            guard let d = Double(s), d.isFinite else { return .failure(CellInputError("“\(s)” isn't a finite number.")) }
            return .success(.double(d))
        }
        // Exact numerics stay text so no digit is lost; check the declared precision loosely.
        var normalized = s.hasPrefix("+") ? String(s.dropFirst()) : s
        if normalized.hasPrefix(".") { normalized = "0" + normalized }
        if normalized.hasPrefix("-.") { normalized = "-0" + normalized.dropFirst() }
        let dims = Self.parenthesisNumbers(column.fullType)
        if dims.count == 2, !normalized.lowercased().contains("e") {
            let unsigned = normalized.hasPrefix("-") ? normalized.dropFirst() : Substring(normalized)
            let integerDigits = unsigned.split(separator: ".", omittingEmptySubsequences: false).first.map {
                $0.drop(while: { $0 == "0" }).count
            } ?? 0
            if integerDigits > dims[0] - dims[1] {
                return .failure(CellInputError("“\(s)” is too large for \(column.fullType)."))
            }
        }
        return .success(.text(normalized))
    }

    static func isNumberLiteral(_ s: String) -> Bool {
        var chars = Substring(s)
        if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
        var digits = 0
        var seenDot = false
        var i = chars.startIndex
        while i < chars.endIndex, chars[i].isASCII, chars[i].isNumber || (chars[i] == "." && !seenDot) {
            if chars[i] == "." { seenDot = true } else { digits += 1 }
            i = chars.index(after: i)
        }
        guard digits > 0 else { return false }
        if i == chars.endIndex { return true }
        guard chars[i] == "e" || chars[i] == "E" else { return false }
        var exp = chars[chars.index(after: i)...]
        if exp.first == "+" || exp.first == "-" { exp = exp.dropFirst() }
        return !exp.isEmpty && exp.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: Booleans

    private func parseBoolean(_ s: String) -> Result<DatabaseValue, CellInputError> {
        let value: Bool
        switch s.lowercased() {
        case "true", "t", "yes", "y", "on", "1": value = true
        case "false", "f", "no", "n", "off", "0": value = false
        default: return .failure(CellInputError("“\(s)” isn't a boolean. Use true or false."))
        }
        return .success(dialect.family == .postgres ? .bool(value) : .integer(value ? 1 : 0))
    }

    // MARK: Dates and times

    private func parseDate(_ s: String) -> Result<String, CellInputError> {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return .failure(CellInputError("“\(s)” isn't a date. Use YYYY-MM-DD."))
        }
        let zeroOK = dialect.family == .mysql
        guard (1...12).contains(m) || (zeroOK && m == 0), (1...31).contains(d) || (zeroOK && d == 0), y >= 0 else {
            return .failure(CellInputError("“\(s)” isn't a valid date."))
        }
        return .success(s)
    }

    private func parseTime(_ s: String) -> Result<String, CellInputError> {
        var body = Substring(s)
        var zone = ""
        if dialect.family == .postgres, let split = Self.zoneSplit(body) {
            zone = String(body[split...])
            body = body[..<split]
        }
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }), let h = Int(parts[0]), let m = Int(parts[1]), m < 60 else {
            return .failure(CellInputError("“\(s)” isn't a time. Use HH:MM:SS."))
        }
        if parts.count == 3 {
            let secParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard secParts.count <= 2, let sec = Int(secParts[0]), sec < 60,
                  secParts.count == 1 || (secParts[1].allSatisfy { $0.isASCII && $0.isNumber } && !secParts[1].isEmpty)
            else { return .failure(CellInputError("“\(s)” isn't a time. Use HH:MM:SS.")) }
        }
        guard h >= 0, h <= (negative || dialect.family == .mysql ? 838 : 24) else {
            return .failure(CellInputError("“\(s)” isn't a valid time."))
        }
        return .success((negative ? "-" : "") + String(body) + zone)
    }

    private func parseDateTime(_ s: String) -> Result<String, CellInputError> {
        if dialect.family == .postgres, ["infinity", "-infinity"].contains(s.lowercased()) { return .success(s) }
        let separator = s.firstIndex(where: { $0 == " " || $0 == "T" })
        let datePart = separator.map { String(s[..<$0]) } ?? s
        let timePart = separator.map { String(s[s.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
        if case .failure(let e) = parseDate(datePart) { return .failure(CellInputError(e.message.replacingOccurrences(of: "a date", with: "a date and time").replacingOccurrences(of: "YYYY-MM-DD", with: "YYYY-MM-DD HH:MM:SS"))) }
        guard let timePart, !timePart.isEmpty else { return .success(datePart + " 00:00:00") }
        var time = timePart
        if time.hasSuffix("Z") || time.hasSuffix("z") { time = String(time.dropLast()) + "+00" }
        switch parseTime(time) {
        case .success(let t): return .success(datePart + " " + t)
        case .failure: return .failure(CellInputError("“\(s)” isn't a date and time. Use YYYY-MM-DD HH:MM:SS."))
        }
    }

    /// Index where a trailing `+HH`, `-HH:MM` or `+HHMM` zone starts in a time string.
    private static func zoneSplit(_ s: Substring) -> Substring.Index? {
        guard let colon = s.firstIndex(of: ":"), let sign = s[colon...].lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        return sign
    }

    // MARK: JSON, UUID, binary, enum

    private func parseJSON(_ text: String) -> Result<DatabaseValue, CellInputError> {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return .failure(CellInputError("That isn't valid JSON."))
        }
        return .success(.text(text))
    }

    private func parseUUID(_ s: String) -> Result<DatabaseValue, CellInputError> {
        guard UUID(uuidString: s) != nil else { return .failure(CellInputError("“\(s)” isn't a UUID (8-4-4-4-12 hex digits).")) }
        return .success(.text(s))
    }

    private func parseBinary(_ s: String) -> Result<DatabaseValue, CellInputError> {
        var hex = Substring(s)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = hex.dropFirst(2) } else if hex.hasPrefix("\\x") { hex = hex.dropFirst(2) } else {
            return .failure(CellInputError("Binary values are typed as hex, for example 0x1F8B."))
        }
        guard hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) else {
            return .failure(CellInputError("Hex needs an even number of digits (0–9, A–F)."))
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return .success(.bytes(data))
    }

    private func parseEnumeration(_ s: String) -> Result<DatabaseValue, CellInputError> {
        let allowed = column.enumValues ?? []
        guard !allowed.isEmpty else { return .success(.text(s)) }
        func canonical(_ v: String) -> String? { allowed.first { $0.caseInsensitiveCompare(v) == .orderedSame } }
        if isSet {
            let picked = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var out: [String] = []
            for p in picked {
                guard let c = canonical(p) else { return .failure(CellInputError("“\(p)” isn't one of: \(allowed.joined(separator: ", ")).")) }
                if !out.contains(c) { out.append(c) }
            }
            // MySQL stores SET members in definition order.
            out.sort { (allowed.firstIndex(of: $0) ?? 0) < (allowed.firstIndex(of: $1) ?? 0) }
            return .success(.text(out.joined(separator: ",")))
        }
        guard let c = canonical(s) else {
            return .failure(CellInputError("“\(s)” isn't one of: \(allowed.joined(separator: ", "))."))
        }
        return .success(.text(c))
    }

    // MARK: Display and comparison

    /// The text an editor starts with for `value` (NULL → empty).
    public static func editingText(for value: DatabaseValue) -> String {
        switch value {
        case .null: ""
        case .bytes(let d): "0x" + d.map { String(format: "%02X", $0) }.joined()
        default: value.displayString
        }
    }

    /// Whether two values denote the same cell content, so re-typing the current value isn't an edit.
    /// Integers compare numerically across signedness; a boolean equals 0/1.
    public static func equivalent(_ a: DatabaseValue, _ b: DatabaseValue) -> Bool {
        if a == b { return true }
        func int(_ v: DatabaseValue) -> Decimal? {
            switch v {
            case .integer(let i): Decimal(i)
            case .unsignedInteger(let u): Decimal(u)
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }
        if let x = int(a), let y = int(b) { return x == y }
        switch (a, b) {
        case (.text(let x), .text(let y)):
            // "1.50" vs "1.5" for decimals is deliberately *not* equivalent: the server would keep scale.
            return x == y
        case (.double(let x), .text(let y)), (.text(let y), .double(let x)): return Double(y) == x
        default: return false
        }
    }

    // MARK: Defaults

    /// The column's default as a value, when it is a plain literal ("0", 'draft', NULL). Expression
    /// defaults (`CURRENT_TIMESTAMP`, `nextval(…)`, `uuid()`) return nil: only the server can evaluate them.
    public func defaultValue() -> DatabaseValue? {
        guard var expr = column.defaultExpression?.trimmingCharacters(in: .whitespacesAndNewlines), !expr.isEmpty else { return nil }
        if expr.uppercased() == "NULL" { return column.isNullable ? DatabaseValue.null : nil }
        if dialect.family == .postgres {
            // 'publish'::character varying, 0, true
            if let cast = expr.range(of: "::", options: .backwards), expr.hasPrefix("'") {
                expr = String(expr[..<cast.lowerBound])
            }
            if expr.hasPrefix("'"), expr.hasSuffix("'"), expr.count >= 2 {
                let inner = String(expr.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                return (try? parse(inner).get())
            }
            if expr.contains("(") || expr.contains("::") { return nil }
            return (try? parse(expr).get())
        }
        // MySQL reports literal defaults unquoted; expressions are parenthesised or are keywords.
        let upper = expr.uppercased()
        if expr.hasPrefix("(") || upper.hasPrefix("CURRENT_") || upper.hasPrefix("NOW(") || upper.hasPrefix("UUID(")
            || upper.hasPrefix("LOCALTIME") || upper.hasPrefix("UTC_") || upper.hasPrefix("GENERATED") { return nil }
        if column.isAutoIncrement { return nil }
        return (try? parse(expr).get())
    }
}
