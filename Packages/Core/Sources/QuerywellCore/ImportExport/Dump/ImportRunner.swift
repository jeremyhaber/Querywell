import Foundation

// Streaming import of .sql / .sql.gz dumps into an open session.

// MARK: - Write guard

/// Proof that the user confirmed this import. Imports are writes (and nearly always `DROP TABLE`), so the
/// UI confirms once up front — on Production by typing the database name — and hands the runner this token.
public struct ImportAuthorization: Sendable, Equatable {
    public let databaseName: String?
    public let isProduction: Bool
    public let issuedAt: Date

    fileprivate init(databaseName: String?, isProduction: Bool) {
        self.databaseName = databaseName
        self.isProduction = isProduction
        self.issuedAt = Date()
    }
}

public enum ImportGuard {
    /// What the user has to confirm before an import may run. An import is treated as destructive (it may
    /// replace tables), so on Production the database name must be typed.
    public static func evaluate(context: GuardContext) -> GuardDecision {
        WriteGuard.evaluate(statements: ["DROP TABLE `import`"], context: context, escalateToDestructive: true)
    }

    /// The token for a confirmed import, or `nil` when the connection is read-only or the typed confirmation is wrong.
    public static func authorize(context: GuardContext, typedConfirmation: String? = nil) -> ImportAuthorization? {
        switch evaluate(context: context) {
        case .blockedReadOnly: return nil
        case .allow: return ImportAuthorization(databaseName: context.databaseName, isProduction: context.isProduction)
        case .confirm(let request):
            guard request.isSatisfied(byTyped: typedConfirmation ?? "") else { return nil }
            return ImportAuthorization(databaseName: context.databaseName, isProduction: context.isProduction)
        }
    }
}

// MARK: - Input

/// Reads a (possibly gzip-compressed) file in chunks, reporting position in *file* bytes.
final class DumpFileReader {
    let url: URL
    let totalBytes: Int64
    private let handle: FileHandle
    private let decompressor: GzipDecompressor?
    private(set) var bytesRead: Int64 = 0
    let isGzip: Bool

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        totalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        try handle.seek(toOffset: 0)
        isGzip = magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
        decompressor = isGzip ? try GzipDecompressor() : nil
    }

    deinit { try? handle.close() }

    /// Next chunk of *decompressed* bytes; `nil` at the end of the file.
    func next(maxBytes: Int = 256 * 1024) throws -> Data? {
        while true {
            guard let chunk = try handle.read(upToCount: maxBytes), !chunk.isEmpty else {
                if let decompressor { try decompressor.finish() }
                return nil
            }
            bytesRead += Int64(chunk.count)
            guard let decompressor else { return chunk }
            let out = try decompressor.decompress(chunk)
            if !out.isEmpty { return out }
        }
    }
}

// MARK: - Pre-scan

public struct ImportScanReport: Sendable {
    public var usage: CollationUsage
    /// Collations the file uses that the connected server doesn't list.
    public var unsupportedCollations: [String]
    public var unsupportedCharsets: [String]
    /// A preset that maps every unsupported collation/charset to one the server has, if any.
    public var suggestedMapping: CollationMapping?
    public var suggestedMappingName: String?
    public var bytesScanned: Int64
    public var totalBytes: Int64
    /// `false` when scanning stopped at the limit (names further into the file may be missing).
    public var isComplete: Bool
    public var isGzip: Bool

    public var needsRewrite: Bool { !unsupportedCollations.isEmpty || !unsupportedCharsets.isEmpty }
}

public enum ImportScanner {
    /// Scans the DDL of a dump for charsets/collations and compares them with what the server supports.
    ///
    /// - Parameter limitBytes: stop after this many *decompressed* bytes (`nil` = scan the whole file).
    public static func scan(
        file: URL, supportedCollations: [CollationInfo], limitBytes: Int64? = nil
    ) throws -> ImportScanReport {
        let reader = try DumpFileReader(url: file)
        let scanner = CollationScanner()
        var scanned: Int64 = 0
        var complete = true
        while let chunk = try reader.next() {
            scanner.feed(chunk)
            scanned += Int64(chunk.count)
            if let limit = limitBytes, scanned >= limit { complete = false; break }
            try Task.checkCancellation()
        }
        if complete { scanner.finish() }
        let usage = scanner.usage
        let supportedNames = Set(supportedCollations.map { $0.name.lowercased() })
        let supportedCharsets = Set(supportedCollations.map { $0.characterSet.lowercased() })
        let unsupportedCollations = supportedCollations.isEmpty ? [] : usage.unsupportedCollations(supportedBy: supportedNames)
        let unsupportedCharsets = supportedCollations.isEmpty ? [] : usage.unsupportedCharsets(supportedBy: supportedCharsets)

        var suggestion: (CollationMapping, String)?
        if !unsupportedCollations.isEmpty || !unsupportedCharsets.isEmpty {
            let candidates: [(CollationMapping, String)] = [
                (.mysql57MariaDBCompatible, "MySQL 5.7 / MariaDB compatible"), (.legacyUnicodeCI, "Legacy utf8mb4_unicode_ci"),
            ]
            for (mapping, name) in candidates {
                let collationsOK = unsupportedCollations.allSatisfy { c in
                    mapping.mapCollation(c).map { supportedNames.contains($0.lowercased()) } ?? false
                }
                let charsetsOK = unsupportedCharsets.allSatisfy { c in
                    mapping.mapCharset(c).map { supportedCharsets.contains($0.lowercased()) } ?? false
                }
                if collationsOK && charsetsOK { suggestion = (mapping, name); break }
            }
        }
        return ImportScanReport(
            usage: usage, unsupportedCollations: unsupportedCollations, unsupportedCharsets: unsupportedCharsets,
            suggestedMapping: suggestion?.0, suggestedMappingName: suggestion?.1, bytesScanned: scanned,
            totalBytes: reader.totalBytes, isComplete: complete, isGzip: reader.isGzip)
    }
}

// MARK: - Run

/// What to do after a failing statement when ``ImportOptions/stopOnError`` is off and an ``ImportOptions/onError`` hook asks.
public enum ImportErrorDecision: Sendable, Equatable {
    case `continue`
    case stop
}

public struct ImportOptions: Sendable {
    /// Stop at the first failing statement (default). Otherwise keep going and collect the errors.
    public var stopOnError: Bool
    /// Asked after each failing statement when `stopOnError` is off, so a UI can offer Continue / Stop.
    /// The import waits for the answer. `nil` keeps going silently.
    public var onError: (@Sendable (ImportStatementError) async -> ImportErrorDecision)?
    /// Rewrite charsets/collations in the DDL on the fly (`nil` keeps the file as it is).
    public var collation: CollationMapping?
    /// Errors kept in the report when `stopOnError` is off (the count keeps growing).
    public var maxRecordedErrors: Int
    public var maxStatementBytes: Int

    public init(stopOnError: Bool = true, collation: CollationMapping? = nil, maxRecordedErrors: Int = 1000,
                maxStatementBytes: Int = 512 * 1024 * 1024) {
        self.stopOnError = stopOnError
        self.collation = collation
        self.maxRecordedErrors = maxRecordedErrors
        self.maxStatementBytes = maxStatementBytes
    }
}

public struct ImportStatementError: Sendable, Equatable {
    /// 0-based index among the executed statements.
    public var statementIndex: Int
    public var line: Int
    /// First 200 characters of the statement.
    public var snippet: String
    public var message: String
    public var code: String?
}

public struct ImportProgress: Sendable, Equatable {
    /// Bytes of the *file* consumed (compressed size for .gz) and its total size.
    public var bytesRead: Int64
    public var totalBytes: Int64
    public var statementsExecuted: Int
    public var errorCount: Int
    /// The first 120 characters of the statement being (or last) executed, for progress displays.
    public var currentStatement: String?
    public var fraction: Double { totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : 0 }
}

public enum ImportEvent: Sendable, Equatable {
    case started(totalBytes: Int64, isGzip: Bool)
    case progress(ImportProgress)
    case statementFailed(ImportStatementError)
}

public struct ImportReport: Sendable {
    public var statementsExecuted: Int
    public var statementsFailed: Int
    public var errors: [ImportStatementError]
    public var bytesRead: Int64
    public var totalBytes: Int64
    /// The whole file was processed.
    public var completed: Bool
    public var wasCancelled: Bool
    public var stoppedOnError: Bool
    public var duration: Duration
    /// Rewrites applied by the collation stage, if any.
    public var collationRewrites: Int
    /// `SET` statements the server doesn't know (a dump from a newer pg_dump, e.g. `SET transaction_timeout`):
    /// skipped instead of failing the import.
    public var ignoredSettings: [String] = []

    public var succeeded: Bool { completed && statementsFailed == 0 }
}

public struct ImportRunner: Sendable {
    public let session: any DatabaseSession

    public init(session: any DatabaseSession) {
        self.session = session
    }

    /// Runs the file's statements on the session, one by one, streaming (the file is never loaded whole).
    ///
    /// Statement failures don't throw: they are in the report (`errors`, with statement index, line and the
    /// first 200 characters). Unreadable / corrupt input throws. Cancelling the task stops after the
    /// statement in flight and returns a report with `wasCancelled`.
    public func run(
        file: URL, options: ImportOptions = ImportOptions(), authorization: ImportAuthorization,
        onEvent: @escaping @Sendable (ImportEvent) -> Void = { _ in }
    ) async throws -> ImportReport {
        _ = authorization  // presence is the proof; see ImportGuard
        let clock = ContinuousClock()
        let started = clock.now
        let dialect = SQLDialect(session.engine)
        let reader = try DumpFileReader(url: file)
        let splitter = StreamingStatementSplitter(family: dialect.family, maxStatementBytes: options.maxStatementBytes)
        let rewriter = dialect.family == .mysql ? options.collation.map { CollationRewriter(mapping: $0) } : nil

        onEvent(.started(totalBytes: reader.totalBytes, isGzip: reader.isGzip))
        var executed = 0, failed = 0
        var errors: [ImportStatementError] = []
        var ignoredSettings: [String] = []
        var stopped = false, cancelled = false
        var lastReport = clock.now

        var current: String?
        func report() -> ImportProgress {
            ImportProgress(bytesRead: reader.bytesRead, totalBytes: reader.totalBytes, statementsExecuted: executed, errorCount: failed,
                           currentStatement: current)
        }

        func execute(_ statements: [SplitStatement]) async -> Bool {
            for st in statements {
                if Task.isCancelled { cancelled = true; return false }
                current = String(st.text.prefix(120))
                do {
                    _ = try await session.execute(st.text)
                    executed += 1
                } catch {
                    if error is CancellationError { cancelled = true; return false }
                    // pg_dump from a newer client sets parameters an older server lacks (42704 undefined_object).
                    if dialect.family == .postgres, case DatabaseError.query(_, let code) = error, code == "42704",
                       st.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SET ") {
                        ignoredSettings.append(String(st.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
                        continue
                    }
                    failed += 1
                    let e = Self.describe(error)
                    let item = ImportStatementError(
                        statementIndex: st.index, line: st.startLine, snippet: String(st.text.prefix(200)),
                        message: e.message, code: e.code)
                    if errors.count < options.maxRecordedErrors { errors.append(item) }
                    onEvent(.statementFailed(item))
                    if options.stopOnError { stopped = true; return false }
                    if let ask = options.onError, await ask(item) == .stop { stopped = true; return false }
                }
                if clock.now - lastReport > .milliseconds(100) {
                    lastReport = clock.now
                    onEvent(.progress(report()))
                }
            }
            return true
        }

        var finishedFile = false
        loop: while true {
            if Task.isCancelled { cancelled = true; break }
            guard var chunk = try reader.next() else { finishedFile = true; break }
            if let rewriter { chunk = rewriter.feed(chunk) }
            let statements = try splitter.feed(chunk)
            if !(await execute(statements)) { break loop }
        }
        if finishedFile {
            if let rewriter {
                let tail = rewriter.finish()
                if !tail.isEmpty, !(await execute(try splitter.feed(tail))) { finishedFile = false }
            }
            if finishedFile, !(await execute(try splitter.finish())) { finishedFile = false }
        }

        await restoreSessionState()
        onEvent(.progress(report()))
        return ImportReport(
            statementsExecuted: executed, statementsFailed: failed, errors: errors, bytesRead: reader.bytesRead,
            totalBytes: reader.totalBytes, completed: finishedFile && !stopped && !cancelled, wasCancelled: cancelled,
            stoppedOnError: stopped, duration: clock.now - started, collationRewrites: rewriter?.totalRewrites ?? 0,
            ignoredSettings: ignoredSettings)
    }

    /// A dump that stops half-way would leave the session with checks disabled and tables locked.
    private func restoreSessionState() async {
        guard SQLDialect(session.engine).family == .mysql else { return }
        let s = session
        await Task.detached {
            _ = try? await s.execute("UNLOCK TABLES")
            _ = try? await s.execute("SET FOREIGN_KEY_CHECKS = 1, UNIQUE_CHECKS = 1")
        }.value
    }

    static func describe(_ error: any Error) -> (message: String, code: String?) {
        if let e = error as? DatabaseError {
            if case .query(let message, let code) = e { return (message, code) }
            return (DryRunExecutor.describe(e), nil)
        }
        return (error.localizedDescription, nil)
    }
}
