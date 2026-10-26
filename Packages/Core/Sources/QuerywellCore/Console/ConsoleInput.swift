import Foundation

// Pure logic of the SQL console's input line: when is what the user typed a complete statement, which
// words are client commands (the mysql client's `use`, `\c`, `\q`, …), and what the prompts look like.

/// A statement typed at the console, ready to run.
public struct ConsoleStatement: Equatable, Sendable {
    /// The SQL without its terminator, trimmed.
    public var sql: String
    /// Ended with `\G`: print each row as a vertical record (mysql client) instead of a table.
    public var vertical: Bool

    public init(sql: String, vertical: Bool = false) {
        self.sql = sql
        self.vertical = vertical
    }
}

/// Commands the console handles itself instead of sending them to the server.
public enum ConsoleClientCommand: Equatable, Sendable {
    /// `quit`, `exit`, `\q`: closes the console tab.
    case quit
    /// `clear`: wipes the scrollback.
    case clear
    /// `\c` typed in the middle of a statement: throws the pending input away.
    case cancelInput
    /// `help`, `\h`, `?`.
    case help
    /// `use <database>`.
    case use(String)
}

/// What an unfinished statement is waiting for, shown in the continuation prompt (`'>`, `->`, …).
public enum ConsoleContinuation: Equatable, Sendable {
    case statement
    case singleQuote
    case doubleQuote
    case backtick
    case blockComment
    case dollarQuote
}

public enum ConsoleInputResult: Equatable, Sendable {
    /// Blank or comment-only input.
    case empty
    /// Keep reading lines.
    case incomplete(ConsoleContinuation)
    case command(ConsoleClientCommand)
    /// One or more complete statements. `remainder` is unfinished text after the last terminator that
    /// stays in the input buffer (like the mysql client, which keeps reading after a `;`).
    case run([ConsoleStatement], remainder: String)
}

public enum ConsoleInput {
    /// Classifies the whole input buffer (all typed lines joined with `\n`).
    public static func analyze(_ buffer: String, dialect: SQLDialect) -> ConsoleInputResult {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let command = clientCommand(trimmed) { return .command(command) }

        let bytes = Array(buffer.utf8)
        let tokens = SQLLexer(dialect).tokenize(buffer)
        var statements: [ConsoleStatement] = []
        var start: Int?                 // first content byte of the statement being read
        var lastEnd = 0                 // end of the last content token
        var previous: SQLToken?
        var unterminated: SQLToken?

        func emit(vertical: Bool) {
            defer { start = nil }
            guard let s = start, lastEnd > s else { return }
            let sql = String(decoding: bytes[s..<lastEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sql.isEmpty { statements.append(ConsoleStatement(sql: sql, vertical: vertical)) }
        }

        for token in tokens {
            defer { if token.kind != .whitespace { previous = token } }
            if !token.isTerminated { unterminated = token }
            switch token.kind {
            case .whitespace, .lineComment, .blockComment:
                continue
            default:
                break
            }
            if token.isSymbol(";") {
                emit(vertical: false)
                continue
            }
            // `\G` / `\g`: end of statement, G for vertical output.
            if token.kind == .word, let p = previous, p.isSymbol("\\"), p.range.upperBound == token.range.lowerBound,
               token.text == "G" || token.text == "g" {
                // The backslash was recorded as content; cut the statement before it.
                lastEnd = p.range.lowerBound
                emit(vertical: token.text == "G")
                continue
            }
            if start == nil { start = token.range.lowerBound }
            lastEnd = token.range.upperBound
        }

        let remainder = start.map { String(decoding: bytes[$0...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if statements.isEmpty {
            if let open = unterminated { return .incomplete(continuation(for: open)) }
            return start == nil ? .empty : .incomplete(.statement)
        }
        return .run(statements, remainder: remainder)
    }

    private static func continuation(for token: SQLToken) -> ConsoleContinuation {
        switch token.kind {
        case .string: token.text.hasPrefix("\"") ? .doubleQuote : .singleQuote
        case .quotedIdentifier: token.text.hasPrefix("`") ? .backtick : .doubleQuote
        case .blockComment, .versionedComment: .blockComment
        case .dollarString: .dollarQuote
        default: .statement
        }
    }

    // MARK: Client commands

    /// A one-line client command, or nil. Statements keep their `;`; these words don't need one.
    static func clientCommand(_ input: String) -> ConsoleClientCommand? {
        if input.contains("\n") {
            // `\c` after other text cancels the pending input.
            return input.hasSuffix("\\c") ? .cancelInput : nil
        }
        var line = input
        while line.hasSuffix(";") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        switch line.lowercased() {
        case "quit", "exit", "\\q": return .quit
        case "clear", "\\c": return .clear
        case "help", "\\h", "?", "\\?", "\\help": return .help
        default: break
        }
        if line.hasSuffix("\\c"), line.count > 2 { return .cancelInput }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2, parts[0].lowercased() == "use" {
            return .use(unquote(String(parts[1]).trimmingCharacters(in: .whitespaces)))
        }
        if line.lowercased() == "use" { return .use("") }
        return nil
    }

    private static func unquote(_ name: String) -> String {
        guard name.count >= 2, let q = name.first, "`\"'".contains(q), name.last == q else { return name }
        let inner = String(name.dropFirst().dropLast())
        return inner.replacingOccurrences(of: String(q) + String(q), with: String(q))
    }
}

/// Prompt strings. MySQL/MariaDB follow the mysql client (`mysql>`, `    ->`); PostgreSQL follows psql (`db=#`, `db-#`).
public enum ConsolePrompt {
    public static func primary(engine: DatabaseEngine, database: String?) -> String {
        switch engine {
        case .mysql, .mariadb: return "mysql> "
        case .postgresql: return "\(database ?? "postgres")=# "
        }
    }

    public static func continuation(_ kind: ConsoleContinuation, engine: DatabaseEngine, database: String?) -> String {
        switch engine {
        case .mysql, .mariadb:
            let mark: String = switch kind {
            case .statement: "->"
            case .singleQuote: "'>"
            case .doubleQuote: "\">"
            case .backtick: "`>"
            case .blockComment: "/*>"
            case .dollarQuote: "$>"
            }
            // The mysql client right-aligns the mark under `mysql>`.
            return String(repeating: " ", count: max(0, 6 - mark.count)) + mark + " "
        case .postgresql:
            let name = database ?? "postgres"
            let mark: String = switch kind {
            case .statement: "-#"
            case .singleQuote: "'#"
            case .doubleQuote: "\"#"
            case .backtick: "`#"
            case .blockComment: "*#"
            case .dollarQuote: "$#"
            }
            return name + mark + " "
        }
    }

    /// Width of the primary prompt, so continuation prompts line up.
    public static func width(engine: DatabaseEngine, database: String?) -> Int {
        primary(engine: engine, database: database).count
    }
}

/// Text of the `help` command.
public enum ConsoleHelp {
    public static func text(engine: DatabaseEngine) -> [String] {
        var lines = [
            "Querywell SQL console. Type SQL ending with ; (or \\G for vertical output).",
            "",
            "  help, \\h, ?      this text",
            "  clear            clear the screen",
            "  \\c               discard the statement being typed",
            "  quit, exit, \\q   close the console",
        ]
        switch engine {
        case .mysql, .mariadb: lines.insert("  use <database>   switch the default database", at: 3)
        case .postgresql: lines.insert("  use <schema>     SET search_path to a schema", at: 3)
        }
        lines += ["", "Up/Down browse history, Tab completes table and column names."]
        return lines
    }
}
