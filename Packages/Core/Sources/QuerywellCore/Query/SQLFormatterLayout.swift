import Foundation

/// The layout pass behind ``SQLFormatter``. Walks the token stream once, deciding for each token whether
/// it starts a new line (and at which indent) or follows the previous token on the same line.
struct SQLFormatterLayout {
    enum Clause { case none, select, from, on, where_, groupBy, having, orderBy, set, values, other }

    struct Frame {
        var isSubquery: Bool
        /// Indent (in levels) of this query's clause keywords.
        var base: Int
        /// Indent of the line the opening parenthesis was on (where `)` goes).
        var closeIndent: Int
        var clause: Clause = .none
        var caseDepth = 0
        var betweenPending = 0
        var selectMulti = false
        var firstItemPending = false
    }

    /// A significant token with what separated it from the previous one in the source.
    struct Item {
        var token: SQLToken
        var spaceBefore: Bool
        var newlineBefore: Bool
    }

    let options: SQLFormatOptions
    var items: [Item] = []

    var out = ""
    var atLineStart = true
    var lineIndent = 0
    var frames = [Frame(isSubquery: true, base: 0, closeIndent: 0)]

    var statementStart = true
    var statementVerb: String?
    var inUpdateClause = false
    /// Last non-comment token written / last token of any kind written.
    var prevSig: SQLToken?
    var prevAny: SQLToken?
    var lastCommentOwnLine = false
    /// A list item break (after a comma in a SELECT / SET list) that is emitted before the next token,
    /// so a same-line trailing comment can still attach to the comma.
    var pendingBreakIndent: Int?
    var equalsIsSpaced = false

    init(tokens: [SQLToken], options: SQLFormatOptions) {
        self.options = options
        var space = false, newline = false
        for t in tokens {
            if t.kind == .whitespace {
                space = true
                if t.text.contains("\n") || t.text.contains("\r") { newline = true }
                continue
            }
            items.append(Item(token: t, spaceBefore: space, newlineBefore: newline))
            space = false
            newline = false
        }
    }

    /// Reserved words that are safe to upper-case wherever they appear as bare words: none of them can be an
    /// unquoted table or column name on either engine (`END` is handled separately).
    static let reserved: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "BETWEEN", "JOIN", "INNER",
        "LEFT", "RIGHT", "OUTER", "CROSS", "NATURAL", "ON", "USING", "GROUP", "BY", "ORDER", "HAVING",
        "LIMIT", "UNION", "ALL", "DISTINCT", "AS", "CASE", "WHEN", "THEN", "ELSE", "INSERT",
        "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "EXISTS", "ASC",
        "DESC", "WITH", "TRUE", "FALSE", "INTERSECT", "EXCEPT", "FOR", "DEFAULT", "PRIMARY",
        "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "CONSTRAINT",
    ]

    static let joinModifiers: Set<String> = ["NATURAL", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER"]
    static let selectModifiers: Set<String> = [
        "DISTINCT", "ALL", "DISTINCTROW", "HIGH_PRIORITY", "SQL_SMALL_RESULT", "SQL_BIG_RESULT", "SQL_BUFFER_RESULT",
        "SQL_CACHE", "SQL_NO_CACHE", "SQL_CALC_FOUND_ROWS", "STRAIGHT_JOIN",
    ]
    static let spaceBeforeParen: Set<String> = [
        "IN", "AND", "OR", "NOT", "ON", "AS", "EXISTS", "WHERE", "FROM", "JOIN", "USING", "SELECT", "WHEN", "THEN",
        "ELSE", "UNION", "ALL", "ANY", "SOME", "BY", "HAVING", "INTO", "SET", "BETWEEN", "LIKE", "IS", "CASE",
    ]

    // MARK: Driver

    mutating func run() -> String {
        for i in 0..<items.count {
            let item = items[i]
            switch item.token.kind {
            case .lineComment, .blockComment, .versionedComment: comment(item)
            default: token(item, index: i)
            }
        }
        while out.last == " " || out.last == "\n" { out.removeLast() }
        return out
    }

    // MARK: Writers

    private mutating func newline(indent: Int, blank: Bool = false) {
        while out.last == " " { out.removeLast() }
        if !out.isEmpty {
            if !out.hasSuffix("\n") { out += "\n" }
            if blank, !out.hasSuffix("\n\n") { out += "\n" }
        }
        out += String(repeating: " ", count: max(0, indent) * options.indentWidth)
        lineIndent = indent
        atLineStart = true
    }

    private mutating func write(_ s: String) {
        out += s
        atLineStart = false
    }

    private mutating func space() {
        if !atLineStart, !out.isEmpty, out.last != " ", out.last != "\n" { out += " " }
    }

    private var top: Frame {
        get { frames[frames.count - 1] }
        set { frames[frames.count - 1] = newValue }
    }

    /// Indent for a line that continues the current clause (or starts a new thing at the frame base).
    private var continuationIndent: Int {
        if statementStart { return 0 }
        return top.clause == .none ? top.base : top.base + 1
    }

    // MARK: Comments

    private var lastWasLineComment: Bool { prevAny?.kind == .lineComment }
    private var lastWasComment: Bool {
        guard let k = prevAny?.kind else { return false }
        return k == .lineComment || k == .blockComment || k == .versionedComment
    }

    private mutating func comment(_ item: Item) {
        let t = item.token
        if let indent = pendingBreakIndent, item.newlineBefore {
            pendingBreakIndent = nil
            newline(indent: indent)
        } else if pendingBreakIndent != nil {
            space()  // trailing comment on the line of the comma
        } else if out.isEmpty {
            // first thing in the script
        } else if lastWasLineComment {
            newline(indent: continuationIndent)
        } else if prevSig?.isSymbol(";") == true && statementStart && !lastWasComment {
            if item.newlineBefore { newline(indent: 0, blank: true) } else { space() }
        } else if item.newlineBefore {
            newline(indent: continuationIndent)
        } else if item.spaceBefore || t.kind == .lineComment {
            space()
        }
        lastCommentOwnLine = atLineStart
        write(t.text)
        prevAny = t
    }

    // MARK: Tokens

    private func nextSig(_ i: Int) -> SQLToken? {
        var j = i + 1
        while j < items.count {
            let k = items[j].token.kind
            if k != .lineComment, k != .blockComment, k != .versionedComment { return items[j].token }
            j += 1
        }
        return nil
    }

    private func startsJoin(_ i: Int) -> Bool {
        var j = i
        while j < items.count {
            let t = items[j].token
            if t.kind == .lineComment || t.kind == .blockComment { j += 1; continue }
            guard let kw = t.keyword else { return false }
            if kw == "JOIN" || kw == "STRAIGHT_JOIN" { return true }
            if !Self.joinModifiers.contains(kw) { return false }
            j += 1
        }
        return false
    }

    private func selectHasMultipleItems(from i: Int) -> Bool {
        var depth = 0
        var j = i + 1
        while j < items.count {
            let t = items[j].token
            if t.isSymbol("(") { depth += 1 }
            else if t.isSymbol(")") { if depth == 0 { return false }; depth -= 1 }
            else if depth == 0 {
                if t.isSymbol(",") { return true }
                if t.isSymbol(";") { return false }
                if let kw = t.keyword, ["FROM", "WHERE", "UNION", "INTERSECT", "EXCEPT", "LIMIT", "ORDER", "GROUP", "HAVING",
                                        "RETURNING", "ON", "VALUES"].contains(kw) { return false }
            }
            j += 1
        }
        return false
    }

    private mutating func token(_ item: Item, index i: Int) {
        let t = item.token
        // A word next to a dot (`t.select`, `from.x`) is part of a qualified name, never a keyword.
        let isQualifiedName = prevSig?.isSymbol(".") == true || nextSig(i)?.isSymbol(".") == true
        let kw = isQualifiedName ? nil : t.keyword
        let wasStatementStart = statementStart
        var brokeLine = false

        if let indent = pendingBreakIndent {
            pendingBreakIndent = nil
            newline(indent: indent)
            brokeLine = true
        }

        if brokeLine {
            // the pending list-item break above already placed this token
        } else if statementStart, prevSig != nil {
            // A blank line between statements, unless a comment sits directly above this one.
            newline(indent: 0, blank: !(lastWasComment && lastCommentOwnLine))
            brokeLine = true
        } else if lastWasComment, lastWasLineComment || item.newlineBefore {
            newline(indent: continuationIndent)
            brokeLine = true
        }

        if statementStart {
            statementVerb = kw
            inUpdateClause = kw == "UPDATE"
            statementStart = false
        }

        var f = top

        // First item of a multi-item SELECT list / SET clause goes on its own line.
        if f.firstItemPending {
            if let kw, t.kind == .word, Self.selectModifiers.contains(kw) {
                // modifiers stay on the SELECT line
            } else {
                f.firstItemPending = false
                top = f
                if f.selectMulti {
                    newline(indent: f.base + 1)
                    brokeLine = true
                }
            }
        }
        top = f

        if t.kind == .symbol {
            symbol(item, index: i, brokeLine: brokeLine)
            prevSig = t
            prevAny = t
            return
        }

        var text = t.text
        f = top
        if let kw, f.isSubquery {
            switch kw {
            case "SELECT":
                if !wasStatementStart { newline(indent: f.base); brokeLine = true }
                f.clause = .select
                f.selectMulti = selectHasMultipleItems(from: i)
                f.firstItemPending = true
            case "FROM":
                if prevSig?.keyword != "DELETE", prevSig?.keyword != "DISTINCT" { newline(indent: f.base); brokeLine = true }
                f.clause = .from
            case "WHERE":
                newline(indent: f.base); brokeLine = true
                f.clause = .where_
            case "HAVING":
                newline(indent: f.base); brokeLine = true
                f.clause = .having
            case "GROUP" where nextSig(i)?.keyword == "BY":
                newline(indent: f.base); brokeLine = true
                f.clause = .groupBy
            case "ORDER" where nextSig(i)?.keyword == "BY":
                newline(indent: f.base); brokeLine = true
                f.clause = .orderBy
            case "LIMIT", "OFFSET", "RETURNING":
                newline(indent: f.base); brokeLine = true
                f.clause = .other
            case "UNION", "INTERSECT", "EXCEPT", "MINUS":
                newline(indent: f.base); brokeLine = true
                f.clause = .none
            case "JOIN":
                if !(prevSig?.keyword.map { Self.joinModifiers.contains($0) } ?? false) {
                    newline(indent: f.base); brokeLine = true
                }
                f.clause = .from
            case "STRAIGHT_JOIN" where f.clause != .select && f.clause != .none:
                newline(indent: f.base); brokeLine = true
                f.clause = .from
            case "NATURAL", "INNER", "LEFT", "RIGHT", "FULL", "CROSS":
                if startsJoin(i), !(prevSig?.keyword.map { Self.joinModifiers.contains($0) } ?? false) {
                    newline(indent: f.base); brokeLine = true
                    f.clause = .from
                }
            case "ON":
                if let n = nextSig(i)?.keyword, n == "DUPLICATE" || n == "CONFLICT" {
                    newline(indent: f.base); brokeLine = true
                    f.clause = .other
                    inUpdateClause = true
                } else if prevSig?.keyword != "DISTINCT" {
                    f.clause = .on
                }
            case "SET":
                if statementVerb == "UPDATE" || inUpdateClause {
                    newline(indent: f.base); brokeLine = true
                    f.clause = .set
                    f.firstItemPending = true
                    f.selectMulti = selectHasMultipleItems(from: i)
                }
            case "UPDATE":
                if prevSig?.keyword == "KEY" || prevSig?.keyword == "DO" { inUpdateClause = true }
            case "VALUES":
                if statementVerb == "INSERT" || statementVerb == "REPLACE", f.clause != .set {
                    newline(indent: f.base); brokeLine = true
                    f.clause = .values
                }
            case "AND", "OR":
                if kw == "AND", f.betweenPending > 0 {
                    f.betweenPending -= 1
                } else if f.caseDepth == 0, [.where_, .having, .on].contains(f.clause) {
                    newline(indent: f.base + 1); brokeLine = true
                }
            case "BETWEEN": f.betweenPending += 1
            case "CASE": f.caseDepth += 1
            case "END":
                if f.caseDepth > 0 {
                    f.caseDepth -= 1
                    if options.uppercaseKeywords { text = "END" }
                }
            default: break
            }
        } else if let kw {
            if kw == "BETWEEN" { f.betweenPending += 1 }
            else if kw == "AND", f.betweenPending > 0 { f.betweenPending -= 1 }
            else if kw == "CASE" { f.caseDepth += 1 }
            else if kw == "END", f.caseDepth > 0 {
                f.caseDepth -= 1
                if options.uppercaseKeywords { text = "END" }
            }
        }
        top = f

        if options.uppercaseKeywords, let kw, Self.reserved.contains(kw),
           prevSig?.isSymbol(".") != true, nextSig(i)?.isSymbol(".") != true {
            text = kw
        }

        if !brokeLine { spacing(before: item) }
        write(text)
        prevSig = t
        prevAny = t
    }

    private mutating func symbol(_ item: Item, index i: Int, brokeLine: Bool) {
        let t = item.token
        switch t.text {
        case ";":
            while out.last == " " { out.removeLast() }
            write(";")
            frames = [Frame(isSubquery: true, base: 0, closeIndent: 0)]
            statementStart = true
            statementVerb = nil
            inUpdateClause = false
        case "(":
            let isSub = ["SELECT", "WITH"].contains(nextSig(i)?.keyword ?? "")
            if !brokeLine { spacing(before: item) }
            write("(")
            let parent = top
            frames.append(Frame(isSubquery: isSub, base: isSub ? lineIndent + 1 : parent.base, closeIndent: lineIndent))
        case ")":
            if frames.count > 1 {
                let popped = frames.removeLast()
                if popped.isSubquery {
                    newline(indent: popped.closeIndent)
                } else {
                    while out.last == " " { out.removeLast() }
                }
            } else {
                while out.last == " " { out.removeLast() }
            }
            write(")")
        case ",":
            while out.last == " " { out.removeLast() }
            write(",")
            let f = top
            if f.isSubquery, f.clause == .select || f.clause == .set, f.selectMulti, f.caseDepth == 0 {
                pendingBreakIndent = f.base + 1
            }
        case "=":
            let lone = isLoneEquals(item, index: i)
            if !brokeLine { spacing(before: item) }
            if lone { space() }
            write("=")
            equalsIsSpaced = lone
        default:
            if !brokeLine { spacing(before: item) }
            write(t.text)
        }
    }

    /// `a=1` → `a = 1`, but never the middle of `<=`, `>=`, `!=`, `:=`, `<=>`, `==`.
    private func isLoneEquals(_ item: Item, index i: Int) -> Bool {
        guard let p = prevAny else { return false }
        let prevOK = [.word, .number, .string, .quotedIdentifier, .dollarString].contains(p.kind) || p.isSymbol(")")
        guard prevOK, let n = nextSig(i) else { return false }
        return !(n.kind == .symbol && ["=", ">", "<"].contains(n.text))
    }

    /// Whitespace between the previous token and `item` on the same line: the source's choice (space or
    /// none, runs collapsed), except a space after every comma and none at the inside edges of `( )`.
    private mutating func spacing(before item: Item) {
        guard let p = prevAny, !out.isEmpty, !atLineStart else { return }
        let t = item.token
        if p.isSymbol(",") { space(); return }
        if p.isSymbol("="), equalsIsSpaced { space(); return }
        if p.isSymbol("(") { return }
        if t.isSymbol(")") || t.isSymbol(",") || t.isSymbol(";") { return }
        if t.isSymbol(".") {
            if p.kind == .number, item.spaceBefore { space() }
            return
        }
        if p.isSymbol(".") { return }
        if t.isSymbol("(") {
            if let k = p.keyword, Self.spaceBeforeParen.contains(k) { space(); return }
            if item.spaceBefore { space() }
            return
        }
        if item.spaceBefore { space() }
    }
}
