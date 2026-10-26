import Foundation

// Runs scripts for the query editor. The sequence is always
//
//     QueryRunner.prepare(...)  →  .ready | .needsConfirmation | .blocked | .empty
//     QueryRunner.run(prepared, on: session)
//
// `prepare` classifies every statement and asks the `WriteGuard`; `run` accepts only a
// `PreparedScript`, which can be obtained solely from a `.ready` outcome or from
// `PendingConfirmation.confirm(typed:)` — so there is no path that executes writes on a guarded
// connection without the guard having approved them. This is also the only way AI-generated SQL
// reaches a server: the assistant inserts text into the editor, the user runs it from here.

/// What the user asked to run.
public enum RunScope: Sendable, Equatable {
    case all
    /// A UTF-16 selection in the editor text. An empty selection runs everything.
    case selection(Range<Int>)
    /// The statement under the caret (UTF-16 offset).
    case currentStatement(cursor: Int)
}

public struct QueryRunOptions: Sendable, Equatable {
    /// Stop at the first failing statement; later ones are reported as skipped.
    public var stopOnError: Bool
    /// Rows kept per result set. Rows beyond are dropped and the result flagged truncated.
    ///
    /// Memory caveat: the drivers materialise a statement's whole result before returning it, so this
    /// bounds what the UI holds, not what the driver buffered. Streaming rows from the driver (and
    /// stopping the server early) is future work; until then prefer `LIMIT` for huge tables.
    public var maxRowsPerResult: Int

    public init(stopOnError: Bool = true, maxRowsPerResult: Int = 50_000) {
        self.stopOnError = stopOnError
        self.maxRowsPerResult = max(1, maxRowsPerResult)
    }
}

/// A script that passed classification and the write guard. Only ``QueryRunner`` can create one.
public struct PreparedScript: Sendable, Equatable {
    public let statements: [ClassifiedStatement]
    /// UTF-16 offset of the prepared text within the editor text (non-zero for selections), so
    /// `statement.source?.utf16Range` can be mapped back for error highlighting.
    public let baseUTF16Offset: Int
    /// True when the guard asked for confirmation and the user gave it.
    public let wasConfirmed: Bool

    init(statements: [ClassifiedStatement], baseUTF16Offset: Int, wasConfirmed: Bool) {
        self.statements = statements
        self.baseUTF16Offset = baseUTF16Offset
        self.wasConfirmed = wasConfirmed
    }
}

/// The guard wants a human decision before this script runs.
public struct PendingConfirmation: Sendable, Equatable {
    public let request: ConfirmationRequest
    let statements: [ClassifiedStatement]
    let baseUTF16Offset: Int

    /// Returns the script as runnable once the user's typed text satisfies the request
    /// (nil otherwise — e.g. the database name was mistyped).
    public func confirm(typed: String = "") -> PreparedScript? {
        guard request.isSatisfied(byTyped: typed) else { return nil }
        return PreparedScript(statements: statements, baseUTF16Offset: baseUTF16Offset, wasConfirmed: true)
    }
}

public enum RunPreparation: Sendable, Equatable {
    case ready(PreparedScript)
    case needsConfirmation(PendingConfirmation)
    /// Read-only connection; the message is user-facing.
    case blocked(String)
    /// Nothing to run (blank or comment-only text).
    case empty
}

public enum StatementOutcome: Sendable, Equatable {
    case resultSet(QueryResult)
    case affected(rowsAffected: UInt64, lastInsertID: UInt64?)
    case error(DatabaseError)
    /// Not run: an earlier statement failed (stop on error) or the run was cancelled.
    case skipped
}

public struct StatementResult: Sendable, Equatable {
    public var statement: ClassifiedStatement
    public var outcome: StatementOutcome
    /// Wall-clock time of the call, including network.
    public var duration: Duration
    /// Log lines for this statement, e.g. "3 rows affected (12 ms)".
    public var messages: [String]
    /// A result set was cut at ``QueryRunOptions/maxRowsPerResult``.
    public var isTruncated: Bool
    /// Rows the server returned before truncation (result sets only).
    public var totalRows: Int?

    public var isError: Bool { if case .error = outcome { true } else { false } }
    public var resultSet: QueryResult? { if case .resultSet(let r) = outcome { r } else { nil } }
}

/// One line of the Messages tab.
public struct QueryMessage: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case info, warning, error }
    /// 0-based statement index, nil for run-level messages.
    public var statementIndex: Int?
    public var level: Level
    public var text: String
}

public struct QueryRunResult: Sendable, Equatable {
    public var results: [StatementResult]
    /// True when the task was cancelled before every statement ran.
    public var wasCancelled: Bool
    public var totalDuration: Duration

    /// Messages tab content, in order.
    public var messages: [QueryMessage] {
        var out: [QueryMessage] = []
        for (i, r) in results.enumerated() {
            let prefix = results.count > 1 ? "[\(i + 1)] " : ""
            for line in r.messages {
                let level: QueryMessage.Level = r.isError ? .error : (r.isTruncated && line.hasPrefix("Showing") ? .warning : .info)
                out.append(QueryMessage(statementIndex: i, level: level, text: prefix + line))
            }
        }
        if wasCancelled { out.append(QueryMessage(statementIndex: nil, level: .warning, text: "Run cancelled.")) }
        if results.count > 1 {
            out.append(QueryMessage(statementIndex: nil, level: .info,
                                    text: "\(results.count) statements, total \(QueryRunner.format(totalDuration))"))
        }
        return out
    }

    public var hasErrors: Bool { results.contains(where: \.isError) }
}

public struct QueryRunner: Sendable {
    public let dialect: SQLDialect
    public let guardContext: GuardContext
    public let safety: AppSettings.Safety
    public var options: QueryRunOptions

    public init(guardContext: GuardContext, safety: AppSettings.Safety = AppSettings.Safety(),
                options: QueryRunOptions = QueryRunOptions()) {
        self.dialect = guardContext.dialect
        self.guardContext = guardContext
        self.safety = safety
        self.options = options
    }

    // MARK: Prepare

    /// Cuts the text to run out of the editor text, splits and classifies it and consults the write guard.
    public func prepare(editorText: String, scope: RunScope = .all) -> RunPreparation {
        let ns = editorText as NSString
        var script = editorText
        var base = 0
        switch scope {
        case .all:
            break
        case .selection(let r):
            let lo = max(0, min(r.lowerBound, ns.length)), hi = max(lo, min(r.upperBound, ns.length))
            if hi > lo {
                script = ns.substring(with: NSRange(location: lo, length: hi - lo))
                base = lo
            }
        case .currentStatement(let cursor):
            let all = StatementSplitter.split(editorText, dialect: dialect)
            guard let s = StatementSplitter.statement(at: cursor, in: all) else { return .empty }
            script = s.text
            base = s.utf16Range.lowerBound
        }
        return prepare(script: script, baseUTF16Offset: base)
    }

    public func prepare(script: String, baseUTF16Offset: Int = 0) -> RunPreparation {
        let statements = StatementClassifier(dialect: dialect).classify(script: script)
        guard !statements.isEmpty else { return .empty }
        switch WriteGuard.evaluate(statements, context: guardContext, settings: safety) {
        case .allow:
            return .ready(PreparedScript(statements: statements, baseUTF16Offset: baseUTF16Offset, wasConfirmed: false))
        case .blockedReadOnly(let message):
            return .blocked(message)
        case .confirm(let request):
            return .needsConfirmation(PendingConfirmation(request: request, statements: statements,
                                                          baseUTF16Offset: baseUTF16Offset))
        }
    }

    // MARK: Run

    /// Runs the statements one after another on `session`.
    ///
    /// - Parameter onResult: called after each statement finishes (for incremental result tabs).
    ///   Cancelling the surrounding task stops between statements; the remainder is reported as skipped.
    public func run(
        _ script: PreparedScript, on session: any DatabaseSession,
        onResult: (@Sendable (StatementResult) -> Void)? = nil
    ) async -> QueryRunResult {
        let clock = ContinuousClock()
        let started = clock.now
        var results: [StatementResult] = []
        var stop = false
        var cancelled = false

        for statement in script.statements {
            if stop || Task.isCancelled {
                if Task.isCancelled { cancelled = true }
                let r = StatementResult(statement: statement, outcome: .skipped, duration: .zero,
                                        messages: ["Skipped."], isTruncated: false, totalRows: nil)
                results.append(r)
                onResult?(r)
                continue
            }
            let r = await runOne(statement, on: session, clock: clock)
            results.append(r)
            onResult?(r)
            if r.isError {
                if case .error(let e) = r.outcome, e == .sessionClosed { stop = true }
                if options.stopOnError { stop = true }
            }
            if Task.isCancelled { cancelled = true }
        }
        let anySkipped = results.contains { $0.outcome == .skipped }
        return QueryRunResult(results: results, wasCancelled: cancelled && anySkipped, totalDuration: clock.now - started)
    }

    private func runOne(_ statement: ClassifiedStatement, on session: any DatabaseSession, clock: ContinuousClock) async -> StatementResult {
        let began = clock.now
        do {
            var result = try await session.execute(statement.text, interruptible: true)
            let elapsed = clock.now - began
            if !result.columns.isEmpty {
                let total = result.rows.count
                var truncated = false
                if total > options.maxRowsPerResult {
                    result.rows = Array(result.rows.prefix(options.maxRowsPerResult))
                    truncated = true
                }
                var lines = ["\(Self.plural(total, "row")) returned (\(Self.format(elapsed)))"]
                if truncated {
                    lines.append("Showing the first \(options.maxRowsPerResult) of \(total) rows.")
                }
                return StatementResult(statement: statement, outcome: .resultSet(result), duration: elapsed,
                                       messages: lines, isTruncated: truncated, totalRows: total)
            }
            let affected = result.rowsAffected ?? 0
            var line = "\(Self.plural(Int(clamping: affected), "row")) affected (\(Self.format(elapsed)))"
            if let id = result.lastInsertID, id > 0 { line += ", last insert ID \(id)" }
            return StatementResult(statement: statement, outcome: .affected(rowsAffected: affected, lastInsertID: result.lastInsertID),
                                   duration: elapsed, messages: [line], isTruncated: false, totalRows: nil)
        } catch is CancellationError {
            // Stop pressed while this statement ran: the server was asked to abort it.
            let elapsed = clock.now - began
            return StatementResult(statement: statement, outcome: .skipped, duration: elapsed,
                                   messages: ["Cancelled after \(Self.format(elapsed))"], isTruncated: false, totalRows: nil)
        } catch {
            let elapsed = clock.now - began
            let dbError = (error as? DatabaseError) ?? .query(message: String(describing: error), code: nil)
            return StatementResult(statement: statement, outcome: .error(dbError), duration: elapsed,
                                   messages: ["Error: \(Self.describe(dbError)) (\(Self.format(elapsed)))"],
                                   isTruncated: false, totalRows: nil)
        }
    }

    // MARK: Formatting helpers

    static func plural(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// "12 ms", "1.23 s", "<1 ms".
    public static func format(_ d: Duration) -> String {
        let c = d.components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        if ms < 1 { return "<1 ms" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        return String(format: "%.2f s", ms / 1000)
    }

    public static func describe(_ e: DatabaseError) -> String {
        switch e {
        case .query(let message, let code): code.map { "\(message) [\($0)]" } ?? message
        case .connectionFailed(let m), .authenticationFailed(let m), .tlsFailed(let m), .unsupported(let m): m
        case .timeout: "The server did not respond in time."
        case .sessionClosed: "The connection is closed."
        }
    }
}
