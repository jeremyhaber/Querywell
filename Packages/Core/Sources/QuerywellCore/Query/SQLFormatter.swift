import Foundation

public struct SQLFormatOptions: Sendable, Equatable {
    /// Uppercase reserved words (`select` → `SELECT`). Identifiers, functions and anything
    /// ambiguous are left alone; see ``SQLFormatter`` for the exact word list.
    public var uppercaseKeywords: Bool
    public var indentWidth: Int

    public init(uppercaseKeywords: Bool = true, indentWidth: Int = 4) {
        self.uppercaseKeywords = uppercaseKeywords
        self.indentWidth = max(1, indentWidth)
    }
}

public struct SQLFormatResult: Sendable, Equatable {
    public var text: String
    /// False when the formatter backed out and returned the input unchanged: the script uses a
    /// construct it won't touch (`DELIMITER`, psql `\` commands) or the verification below failed.
    public var didFormat: Bool
}

/// A conservative pretty-printer that never changes what a script means.
///
/// It only changes whitespace between tokens (and, optionally, the case of a short list of reserved
/// words). Strings, quoted identifiers, comments (including `/*! … */` executable comments and
/// optimizer hints) and dollar-quoted bodies are emitted verbatim.
///
/// Layout: a newline before SELECT / FROM / WHERE / GROUP BY / HAVING / ORDER BY / LIMIT / JOIN
/// variants / UNION / SET / VALUES / RETURNING, select-list and SET items one per line, AND/OR in
/// WHERE / HAVING / ON on their own indented lines, subqueries indented one level. Statements
/// are separated by a blank line.
///
/// **Safety net:** after formatting, the output is tokenised again and its non-whitespace token stream
/// must equal the input's (words compared case-insensitively only when keyword upper-casing is on).
/// If it isn't, the original text is returned and ``SQLFormatResult/didFormat`` is false.
public enum SQLFormatter {
    public static func format(_ script: String, dialect: SQLDialect, options: SQLFormatOptions = SQLFormatOptions()) -> String {
        formatDetailed(script, dialect: dialect, options: options).text
    }

    public static func formatDetailed(
        _ script: String, dialect: SQLDialect, options: SQLFormatOptions = SQLFormatOptions()
    ) -> SQLFormatResult {
        let unchanged = SQLFormatResult(text: script, didFormat: false)
        if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return unchanged }
        // Client-side commands that aren't SQL: leave the script alone.
        for line in script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            if t.hasPrefix("\\") { return unchanged }
            if dialect.family == .mysql, t.lowercased().hasPrefix("delimiter ") { return unchanged }
        }
        let lexer = SQLLexer(dialect)
        let tokens = lexer.tokenize(script)
        var layout = SQLFormatterLayout(tokens: tokens, options: options)
        var out = layout.run()
        if script.hasSuffix("\n") { out += "\n" }

        // Verify: identical token stream.
        let before = significant(tokens)
        let after = significant(lexer.tokenize(out))
        guard before.count == after.count else { return unchanged }
        for (a, b) in zip(before, after) {
            guard a.kind == b.kind, a.isTerminated == b.isTerminated else { return unchanged }
            if a.text == b.text { continue }
            if options.uppercaseKeywords, a.kind == .word, a.text.caseInsensitiveCompare(b.text) == .orderedSame { continue }
            return unchanged
        }
        return SQLFormatResult(text: out, didFormat: true)
    }

    /// Token stream without whitespace — the thing that must survive formatting.
    static func significant(_ tokens: [SQLToken]) -> [SQLToken] {
        tokens.filter { $0.kind != .whitespace }
    }
}

