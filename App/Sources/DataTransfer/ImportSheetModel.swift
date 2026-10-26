import Foundation
import Observation
import QuerywellCore

/// State of the "Import SQL" sheet: the file, what the pre-scan found, the target, the collation fix and the
/// run. Authorization goes through the shared `WriteGate` (PROD: the database name must be typed).
@MainActor @Observable
final class ImportSheetModel {
    enum CollationChoice: Equatable, Hashable {
        case none, suggested, mysql57, legacy, custom
    }

    enum ScanState: Equatable {
        case scanning
        case done(Summary)
        case failed(String)

        /// `ImportScanReport` is not Equatable; the parts the UI shows are.
        struct Summary: Equatable {
            var unsupportedCollations: [String]
            var unsupportedCharsets: [String]
            var suggestedName: String?
            var isComplete: Bool
            var isGzip: Bool
            var bytesScanned: Int64
            var needsRewrite: Bool { !unsupportedCollations.isEmpty || !unsupportedCharsets.isEmpty }
        }
    }

    enum Phase: Equatable {
        case setup
        case running
        case finished
        case failed(String)
    }

    /// A failing statement waiting for the user's Continue / Stop.
    struct PendingError: Equatable {
        var error: ImportStatementError
    }

    // MARK: Fixed context

    let file: URL
    let fileSize: Int64
    let fileDate: Date?
    let profile: ConnectionProfile
    let schemas: [String]
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var inspectorProvider: @MainActor () -> (any SchemaInspector)? = { nil }
    @ObservationIgnored var gate: WriteGate?
    /// Called when the run ended (sidebar refresh).
    @ObservationIgnored var onFinished: @MainActor (_ targetSchema: String?) -> Void = { _ in }
    @ObservationIgnored private var scanReport: ImportScanReport?
    @ObservationIgnored private var runTask: Task<ImportReport, any Error>?
    @ObservationIgnored private var errorContinuation: CheckedContinuation<ImportErrorDecision, Never>?

    // MARK: Options

    /// `nil` = the file chooses its own database (`USE` / `CREATE DATABASE` inside it).
    var targetSchema: String?
    var stopOnError = true
    var collationChoice: CollationChoice = .none
    var customCharset = "utf8mb4"
    var customCollation = "utf8mb4_unicode_ci"
    /// With stop-on-error off: ask at each failing statement (until "Continue, don't ask again").
    var asksAtEachError = true

    // MARK: State

    private(set) var scan: ScanState = .scanning
    private(set) var phase: Phase = .setup
    private(set) var progress: ImportProgress?
    private(set) var errors: [ImportStatementError] = []
    private(set) var errorCount = 0
    private(set) var pendingError: PendingError?
    private(set) var report: ImportReport?
    private(set) var collations: [CollationInfo] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    init(file: URL, profile: ConnectionProfile, schemas: [String], currentSchema: String?) {
        self.file = file
        self.profile = profile
        self.schemas = schemas
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        fileSize = (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
        fileDate = attrs?[.modificationDate] as? Date
        targetSchema = currentSchema ?? schemas.first
    }

    // MARK: Derived

    var engine: DatabaseEngine { profile.engine }
    var isRunning: Bool { phase == .running }
    var dialect: SQLDialect { SQLDialect(engine) }

    var suggestedName: String? {
        if case .done(let s) = scan { return s.suggestedName }
        return nil
    }

    var collationMapping: CollationMapping? {
        switch collationChoice {
        case .none: nil
        case .suggested: scanReport?.suggestedMapping
        case .mysql57: .mysql57MariaDBCompatible
        case .legacy: .legacyUnicodeCI
        case .custom: .custom(charset: customCharset, collation: customCollation)
        }
    }

    var supportsCollationFix: Bool { engine != .postgresql }

    var canStart: Bool {
        if case .scanning = scan { return false }
        return phase == .setup && !profile.effectiveReadOnly
    }

    /// Fraction of the file consumed, 0...1.
    var fraction: Double { phase == .finished ? 1 : (progress?.fraction ?? 0) }

    /// The confirmation the guard asks for, or nil when none is needed.
    func confirmationRequest() -> ConfirmationRequest? {
        guard let gate, let context = gate.contextProvider(targetSchema) else { return nil }
        guard case .confirm(var request) = ImportGuard.evaluate(context: context) else { return nil }
        // The guard's stand-in statement is internal; show what is really about to happen.
        request.statements = StatementClassifier(dialect: dialect).classify(script: "SOURCE \(dialect.quoteString(file.lastPathComponent))")
        return request
    }

    // MARK: Scan

    func loadAndScan() async {
        if let found = try? await inspectorProvider()?.availableCollations(), !found.isEmpty { collations = found }
        scan = .scanning
        let url = file
        let supported = collations
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ImportScanner.scan(file: url, supportedCollations: supported, limitBytes: 512 * 1024 * 1024) }
        }.value
        switch result {
        case .success(let report):
            scanReport = report
            scan = .done(ScanState.Summary(
                unsupportedCollations: report.unsupportedCollations, unsupportedCharsets: report.unsupportedCharsets,
                suggestedName: report.suggestedMappingName, isComplete: report.isComplete, isGzip: report.isGzip,
                bytesScanned: report.bytesScanned))
            collationChoice = report.suggestedMapping != nil ? .suggested : .none
        case .failure(let error):
            scan = .failed(error.localizedDescription)
        }
    }

    // MARK: Authorization

    /// The proof the runner needs, after the guard (and the user) agreed; nil when refused or cancelled.
    func authorize() async -> ImportAuthorization? {
        guard let gate, let context = gate.contextProvider(targetSchema) else { return nil }
        switch ImportGuard.evaluate(context: context) {
        case .blockedReadOnly(let reason):
            await gate.reportBlocked(reason)
            return nil
        case .allow:
            return ImportGuard.authorize(context: context)
        case .confirm:
            guard let request = confirmationRequest(),
                  await gate.confirm(request, actionTitle: profile.isProduction ? "Import on PROD" : "Import") else { return nil }
            return ImportGuard.authorize(context: context, typedConfirmation: request.requiresTypedName)
        }
    }

    // MARK: Run

    func start() async {
        guard canStart, let session = sessionProvider() else { return }
        guard let authorization = await authorize() else { return }
        phase = .running
        errors = []
        errorCount = 0
        report = nil
        progress = nil
        startedAt = Date()
        finishedAt = nil

        if let target = targetSchema, !target.isEmpty {
            do {
                switch engine {
                case .mysql, .mariadb: _ = try await session.execute("USE \(dialect.quoteIdentifier(target))")
                case .postgresql: _ = try await session.execute("SET search_path TO \(dialect.quoteIdentifier(target))")
                }
            } catch {
                phase = .failed("Couldn't switch to “\(target)”: \(error.localizedDescription)")
                finishedAt = Date()
                return
            }
        }

        var options = ImportOptions(stopOnError: stopOnError, collation: supportsCollationFix ? collationMapping : nil)
        if !stopOnError {
            options.onError = { [weak self] error in await self?.ask(about: error) ?? .continue }
        }
        let runner = ImportRunner(session: session)
        let file = file
        let (stream, continuation) = AsyncStream.makeStream(of: ImportEvent.self)
        let task = Task { try await runner.run(file: file, options: options, authorization: authorization) { continuation.yield($0) } }
        runTask = task
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.apply(event) }
        }
        do {
            let result = try await task.value
            continuation.finish()
            await consumer.value
            report = result
            errorCount = result.statementsFailed
            if errors.count < result.errors.count { errors = result.errors }
            phase = .finished
        } catch {
            continuation.finish()
            await consumer.value
            phase = .failed(error.localizedDescription)
        }
        finishedAt = Date()
        runTask = nil
        onFinished(targetSchema)
    }

    func cancel() {
        runTask?.cancel()
        resolveError(.stop)
    }

    private func apply(_ event: ImportEvent) {
        switch event {
        case .started: break
        case .progress(let p): progress = p
        case .statementFailed(let e):
            errorCount += 1
            if errors.count < 500 { errors.append(e) }
        }
    }

    // MARK: Continue / Stop

    private func ask(about error: ImportStatementError) async -> ImportErrorDecision {
        guard asksAtEachError else { return .continue }
        pendingError = PendingError(error: error)
        return await withCheckedContinuation { errorContinuation = $0 }
    }

    /// The user's answer to the banner. `askAgain: false` means "Continue, don't ask again".
    func resolveError(_ decision: ImportErrorDecision, askAgain: Bool = true) {
        if !askAgain { asksAtEachError = false }
        pendingError = nil
        errorContinuation?.resume(returning: decision)
        errorContinuation = nil
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? date).timeIntervalSince(startedAt)
    }
}
