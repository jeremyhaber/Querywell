import Foundation

public struct WhereCompletionItem: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable { case column, keyword, op, value }

    /// What the popup shows.
    public var label: String
    /// What replaces ``WhereCompletionResult/range``: quoted if the name needs it, enum values as SQL literals.
    public var insertText: String
    public var kind: Kind
    /// Secondary text: a column's declared type, "enum value", …
    public var detail: String?

    public init(label: String, insertText: String, kind: Kind, detail: String? = nil) {
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.detail = detail
    }
}

public struct WhereCompletionResult: Hashable, Sendable {
    /// The text to replace, as UTF-16 offsets into the input (NSRange-compatible): the identifier under
    /// the cursor, extended to the end of that word; empty at the cursor when there is no prefix.
    public var range: Range<Int>
    public var items: [WhereCompletionItem]

    public init(range: Range<Int>, items: [WhereCompletionItem]) {
        self.range = range
        self.items = items
    }
}

/// Autocomplete for the raw WHERE bar. Pure: text + cursor + columns in, suggestions out.
///
/// Context-aware: after `AND`/`OR`/`(`/start → column names; after a column → operators; after
/// `column =`, `<>`, `!=` or inside `column IN (…)` → the column's enum values as quoted literals;
/// after a value → `AND`/`OR`. Nothing is offered inside string literals, quoted identifiers or comments.
/// Offsets are UTF-16 (what NSTextView / NSString use).
public enum WhereCompletion {
    public static func complete(
        text: String, cursor: Int, columns: [ColumnDefinition], dialect: SQLDialect
    ) -> WhereCompletionResult {
        let units = Array(text.utf16)
        let cursor = max(0, min(cursor, units.count))
        let empty = WhereCompletionResult(range: cursor..<cursor, items: [])

        let scan = Lexer(units: units, upTo: cursor, dialect: dialect).run()
        if scan.insideLiteral { return empty }

        var tokens = scan.tokens
        var prefix = ""
        var start = cursor
        if let last = tokens.last, last.end == cursor, last.kind == .word {
            prefix = last.text
            start = last.start
            tokens.removeLast()
        } else if let last = tokens.last, last.end == cursor, [.number, .string, .quotedIdent].contains(last.kind) {
            return empty  // right after a literal / identifier with no separator
        }
        // Replace the whole word when the cursor sits inside it.
        var end = cursor
        while end < units.count, Lexer.isWordUnit(units[end]) { end += 1 }
        if prefix.isEmpty { end = cursor }
        let range = start..<end

        let context = Context.detect(tokens: tokens, columns: columns)
        var items = suggestions(for: context, prefix: prefix, columns: columns, dialect: dialect)
        if items.isEmpty, !prefix.isEmpty {
            // Unknown context: fall back to anything that matches the prefix.
            items = columnItems(columns, prefix: prefix, dialect: dialect)
                + keywordItems(Self.allKeywords(dialect), prefix: prefix)
        }
        return WhereCompletionResult(range: range, items: items)
    }

    // MARK: Suggestions

    private static func suggestions(
        for context: Context, prefix: String, columns: [ColumnDefinition], dialect: SQLDialect
    ) -> [WhereCompletionItem] {
        switch context {
        case .expectColumn:
            return columnItems(columns, prefix: prefix, dialect: dialect)
                + keywordItems(["NOT"], prefix: prefix)
        case .expectOperator:
            var ops = ["IN", "NOT IN", "LIKE", "NOT LIKE", "IS NULL", "IS NOT NULL", "BETWEEN"]
            ops.append(dialect.family == .postgres ? "ILIKE" : "REGEXP")
            var items = keywordItems(ops, prefix: prefix)
            if prefix.isEmpty {
                let symbols = ["=", "<>", "!=", "<", ">", "<=", ">="] + (dialect.family == .postgres ? ["~"] : [])
                items = symbols.map { WhereCompletionItem(label: $0, insertText: $0, kind: .op) } + items
            }
            return items
        case .expectValue(let column):
            var items: [WhereCompletionItem] = []
            if let column { items += enumItems(column, prefix: prefix, dialect: dialect) }
            if !prefix.isEmpty { items += columnItems(columns, prefix: prefix, dialect: dialect) }
            if prefix.isEmpty || "null".hasPrefix(prefix.lowercased()) { items += keywordItems(["NULL"], prefix: prefix) }
            return items
        case .afterIs:
            return keywordItems(["NULL", "NOT NULL"], prefix: prefix)
        case .afterNotOperator:
            return keywordItems(
                ["IN", "LIKE", "BETWEEN", dialect.family == .postgres ? "ILIKE" : "REGEXP"], prefix: prefix
            )
        case .afterValue:
            return keywordItems(["AND", "OR"], prefix: prefix)
        case .none:
            return []
        }
    }

    private static func allKeywords(_ dialect: SQLDialect) -> [String] {
        ["AND", "OR", "IN", "LIKE", "IS NULL", "IS NOT NULL", "BETWEEN", "NOT"]
            + (dialect.family == .postgres ? ["ILIKE"] : ["REGEXP"])
    }

    private static func keywordItems(_ words: [String], prefix: String) -> [WhereCompletionItem] {
        words.filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased()) }
            .map { WhereCompletionItem(label: $0, insertText: $0, kind: $0.first?.isLetter == true ? .keyword : .op) }
    }

    private static func columnItems(
        _ columns: [ColumnDefinition], prefix: String, dialect: SQLDialect
    ) -> [WhereCompletionItem] {
        columns.filter { prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix.lowercased()) }
            .map {
                WhereCompletionItem(
                    label: $0.name, insertText: insertableIdentifier($0.name, dialect: dialect),
                    kind: .column, detail: $0.fullType
                )
            }
    }

    private static func enumItems(
        _ column: ColumnDefinition, prefix: String, dialect: SQLDialect
    ) -> [WhereCompletionItem] {
        (column.enumValues ?? []).filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix.lowercased()) }
            .map { WhereCompletionItem(label: $0, insertText: dialect.quoteString($0), kind: .value, detail: "enum value") }
    }

    /// The name itself when it parses as a plain identifier, otherwise quoted.
    static func insertableIdentifier(_ name: String, dialect: SQLDialect) -> String {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else { return dialect.quoteIdentifier(name) }
        func isLower(_ s: Unicode.Scalar) -> Bool { s.value >= 97 && s.value <= 122 }
        func isUpper(_ s: Unicode.Scalar) -> Bool { s.value >= 65 && s.value <= 90 }
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        let startsOK = isLower(first) || first == "_" || (dialect.family == .mysql && isUpper(first))
        let restOK = scalars.dropFirst().allSatisfy {
            isLower($0) || isDigit($0) || $0 == "_" || $0 == "$" || (dialect.family == .mysql && isUpper($0))
        }
        if startsOK && restOK && !reserved.contains(name.lowercased()) { return name }
        return dialect.quoteIdentifier(name)
    }

    private static let reserved: Set<String> = [
        "all", "and", "as", "asc", "between", "by", "case", "check", "column", "constraint", "create", "default",
        "delete", "desc", "distinct", "else", "end", "exists", "false", "for", "foreign", "from", "group",
        "having", "in", "index", "insert", "into", "is", "join", "key", "like", "limit", "not", "null", "on",
        "or", "order", "primary", "references", "select", "set", "table", "then", "to", "true", "union",
        "unique", "update", "user", "using", "values", "when", "where", "rank", "groups", "function",
    ]

    // MARK: Context

    enum Context: Equatable {
        case expectColumn
        case expectOperator
        case expectValue(ColumnDefinition?)
        case afterIs
        case afterNotOperator
        case afterValue
        case none

        static func detect(tokens: [Token], columns: [ColumnDefinition]) -> Context {
            func column(_ token: Token) -> ColumnDefinition? {
                switch token.kind {
                case .word, .quotedIdent:
                    return columns.first { $0.name.caseInsensitiveCompare(token.text) == .orderedSame }
                default: return nil
                }
            }
            func keyword(_ token: Token?) -> String? {
                guard let token, token.kind == .word else { return nil }
                return token.text.uppercased()
            }
            guard let last = tokens.last else { return .expectColumn }
            let prev = tokens.dropLast().last
            let comparison: Set<String> = ["=", "<>", "!=", "<", ">", "<=", ">=", "<=>"]

            switch last.kind {
            case .op:
                if comparison.contains(last.text) { return .expectValue(prev.flatMap(column)) }
                return .expectValue(nil)  // ~ and friends
            case .punct:
                if last.text == "(" || last.text == "," {
                    if let col = inListColumn(tokens: tokens, column: column, keyword: keyword) {
                        return .expectValue(col)
                    }
                    return last.text == "(" ? .expectColumn : .none
                }
                return .afterValue  // ")"
            case .string, .number:
                return .afterValue
            case .word, .quotedIdent:
                if last.kind == .word, let kw = keyword(last) {
                    switch kw {
                    case "AND", "OR": return .expectColumn
                    case "NOT":
                        if let prev, column(prev) != nil { return .afterNotOperator }
                        return .expectColumn
                    case "IS": return .afterIs
                    case "IN", "LIKE", "ILIKE", "BETWEEN", "REGEXP", "RLIKE": return .expectValue(nil)
                    case "NULL", "TRUE", "FALSE": return .afterValue
                    default: break
                    }
                }
                if let col = column(last) {
                    // `x = status` compares two columns: a value, not an operator slot.
                    if let prev, prev.kind == .op { _ = col; return .afterValue }
                    return .expectOperator
                }
                return .afterValue
            }
        }

        /// For `col IN ('a', |` / `col NOT IN (|`: the column being matched.
        private static func inListColumn(
            tokens: [Token], column: (Token) -> ColumnDefinition?, keyword: (Token?) -> String?
        ) -> ColumnDefinition?? {
            var i = tokens.count - 1
            // Walk back over `value ,` pairs to the opening parenthesis.
            while i >= 0 {
                let t = tokens[i]
                if t.kind == .punct, t.text == "(" { break }
                if t.kind == .punct, t.text == ")" { return nil }
                i -= 1
            }
            guard i >= 1, keyword(tokens[i - 1]) == "IN" else { return nil }
            var colIndex = i - 2
            if colIndex >= 0, keyword(tokens[colIndex]) == "NOT" { colIndex -= 1 }
            guard colIndex >= 0 else { return .some(nil) }
            return .some(column(tokens[colIndex]))
        }
    }

    // MARK: Lexer

    struct Token: Equatable {
        enum Kind { case word, quotedIdent, string, number, op, punct }
        var kind: Kind
        var text: String
        var start: Int
        var end: Int
    }

    struct Scan {
        var tokens: [Token]
        var insideLiteral: Bool
    }

    struct Lexer {
        let units: [UInt16]
        let limit: Int
        let dialect: SQLDialect

        init(units: [UInt16], upTo limit: Int, dialect: SQLDialect) {
            self.units = units
            self.limit = limit
            self.dialect = dialect
        }

        static func isWordUnit(_ u: UInt16) -> Bool {
            (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u > 127
        }

        private func string(_ from: Int, _ to: Int) -> String {
            String(decoding: units[from..<to], as: UTF16.self)
        }

        func run() -> Scan {
            var tokens: [Token] = []
            var i = 0
            let isMySQL = dialect.family == .mysql
            func at(_ index: Int) -> UInt16? { index < limit ? units[index] : nil }

            while i < limit {
                let c = units[i]
                // whitespace
                if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }

                // comments
                if c == 45, at(i + 1) == 45 {  // --
                    var j = i + 2
                    while j < limit, units[j] != 10 { j += 1 }
                    if j >= limit { return Scan(tokens: tokens, insideLiteral: true) }
                    i = j + 1
                    continue
                }
                if c == 35, isMySQL {  // #
                    var j = i + 1
                    while j < limit, units[j] != 10 { j += 1 }
                    if j >= limit { return Scan(tokens: tokens, insideLiteral: true) }
                    i = j + 1
                    continue
                }
                if c == 47, at(i + 1) == 42 {  // /*
                    var j = i + 2
                    var closed = false
                    while j + 1 < limit {
                        if units[j] == 42, units[j + 1] == 47 { closed = true; break }
                        j += 1
                    }
                    if !closed { return Scan(tokens: tokens, insideLiteral: true) }
                    i = j + 2
                    continue
                }

                // quoted things: ' always a string; " string (MySQL) or identifier (Postgres); ` identifier (MySQL)
                if c == 39 || c == 34 || (c == 96 && isMySQL) {
                    let quote = c
                    var j = i + 1
                    var closed = false
                    var content: [UInt16] = []
                    while j < limit {
                        let d = units[j]
                        if d == quote {
                            if at(j + 1) == quote { content.append(quote); j += 2; continue }
                            closed = true
                            break
                        }
                        if d == 92, isMySQL, quote != 96, j + 1 < limit {  // backslash escape
                            content.append(units[j + 1]); j += 2; continue
                        }
                        content.append(d)
                        j += 1
                    }
                    if !closed { return Scan(tokens: tokens, insideLiteral: true) }
                    let isIdent = c == 96 || (c == 34 && !isMySQL)
                    tokens.append(Token(
                        kind: isIdent ? .quotedIdent : .string,
                        text: String(decoding: content, as: UTF16.self), start: i, end: j + 1
                    ))
                    i = j + 1
                    continue
                }

                if Self.isWordUnit(c) {
                    var j = i
                    while j < limit, Self.isWordUnit(units[j]) { j += 1 }
                    let isNumber = (units[i] >= 48 && units[i] <= 57)
                    tokens.append(Token(kind: isNumber ? .number : .word, text: string(i, j), start: i, end: j))
                    i = j
                    continue
                }

                if c == 40 || c == 41 || c == 44 || c == 59 || c == 46 {  // ( ) , ; .
                    tokens.append(Token(kind: .punct, text: string(i, i + 1), start: i, end: i + 1))
                    i += 1
                    continue
                }

                // operator run
                var j = i
                while j < limit, "=<>!~+-*/%&|^".utf16.contains(units[j]) { j += 1 }
                if j == i { j = i + 1 }
                tokens.append(Token(kind: .op, text: string(i, j), start: i, end: j))
                i = j
            }
            return Scan(tokens: tokens, insideLiteral: false)
        }
    }
}
