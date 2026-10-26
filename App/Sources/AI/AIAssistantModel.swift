import Foundation
import Observation
import QuerywellCore

/// What the panel shows about the configured provider.
struct AIConfiguration: Equatable {
    var provider: AIProviderID?
    var model: String?
    var hasKey: Bool

    var isReady: Bool { provider != nil && hasKey }
    var modelName: String? { provider.map { model?.isEmpty == false ? model! : $0.suggestedModel } }
}

/// State of the assistant panel docked beside a query editor.
///
/// SAFETY: the assistant only produces text. `insert` and `replace` put SQL in the editor; nothing
/// here can run it — the user presses Run, and `QueryRunner`/`WriteGate` take it from there.
@MainActor @Observable
final class AIAssistantModel {
    enum Kind: Equatable { case generate, explain, fixError, optimize }

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        /// What the user asked (the prompt, or the action's name).
        var request: String
        var text = ""
        var sql: String?
        var isFinished = false
    }

    enum Status: Equatable {
        case idle
        case loadingContext
        case streaming
        case failed(AIError)
    }

    // MARK: Environment

    @ObservationIgnored var makeProvider: @MainActor () throws -> any AIProvider = { throw AIError.missingAPIKey(.anthropic) }
    /// Builds the schema context. `allowSampleRows` is the per-connection opt-in; implementations must pass it on as is.
    @ObservationIgnored var loadContext: @MainActor (_ prompt: String, _ allowSampleRows: Bool) async throws -> AssistantContext = { _, _ in
        throw AIError.invalidResponse("No database connection.")
    }
    @ObservationIgnored var allowSampleRows: @MainActor () -> Bool = { false }
    @ObservationIgnored var setAllowSampleRows: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored var wordPress: @MainActor () -> WordPressInfo? = { nil }
    /// SQL the explain / optimize actions apply to (selection, else the statement at the caret, else everything).
    @ObservationIgnored var currentSQL: @MainActor () -> String = { "" }
    @ObservationIgnored var lastError: @MainActor () -> (sql: String, message: String)? = { nil }
    @ObservationIgnored var optimizeInput: @MainActor () async -> (sql: String, plan: String?) = { ("", nil) }
    @ObservationIgnored var insertIntoEditor: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var replaceEditor: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var dialect: @MainActor () -> SQLDialect = { SQLDialect(.mysql) }

    // MARK: State

    /// Provider, model and key presence from Settings (the view refreshes them; the Keychain isn't read per redraw).
    var providerID: AIProviderID?
    var modelOverride: String?
    var hasKey = false
    var configuration: AIConfiguration { AIConfiguration(provider: providerID, model: modelOverride, hasKey: hasKey) }

    var prompt = ""
    private(set) var turns: [Turn] = []
    private(set) var status: Status = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: (Kind, String)?

    var isBusy: Bool { status == .loadingContext || status == .streaming }
    var canFixError: Bool { lastError() != nil }
    var latest: Turn? { turns.last }

    /// The SQL of the newest answer and what the review says about it.
    var latestSQL: String? {
        guard let sql = latest?.sql, !sql.isEmpty else { return nil }
        return sql
    }

    var review: AssistantSQLReview? {
        latestSQL.map { AssistantSQLReview.review(sql: $0, dialect: dialect()) }
    }

    /// Warnings shown under "Insert into editor".
    var reviewWarnings: [String] {
        guard let r = review else { return [] }
        var out: [String] = []
        if r.containsDestructive {
            out.append("This statement writes and changes or removes data or structure — it will ask for confirmation before running.")
        } else if r.containsWrites {
            out.append("This statement writes — it will ask for confirmation.")
        }
        if r.hasUnfilteredMutation { out.append("It has no WHERE clause, so it would apply to every row.") }
        return out
    }

    // MARK: Actions

    func generate() { start(.generate) }
    func explain() { start(.explain) }
    func fixError() { start(.fixError) }
    func optimize() { start(.optimize) }

    func stop() {
        task?.cancel()
    }

    func retry() {
        guard let (kind, _) = lastRequest, !isBusy else { return }
        start(kind)
    }

    func clear() {
        task?.cancel()
        turns = []
        status = .idle
    }

    func insert() {
        guard let sql = latestSQL else { return }
        insertIntoEditor(sql)
    }

    func replace() {
        guard let sql = latestSQL else { return }
        replaceEditor(sql)
    }

    private func start(_ kind: Kind) {
        guard !isBusy else { return }
        task = Task { [weak self] in await self?.perform(kind) }
    }

    /// Runs one action to completion (awaited directly in tests).
    func perform(_ kind: Kind) async {
        let config = configuration
        guard config.isReady, let model = config.modelName else {
            status = .failed(.missingAPIKey(config.provider ?? .anthropic))
            return
        }
        // Build the action.
        let action: AssistantAction
        let request: String
        switch kind {
        case .generate:
            let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return }
            action = .generate(p)
            request = p
        case .explain:
            let sql = currentSQL()
            guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            action = .explain(sql: sql)
            request = "Explain query"
        case .fixError:
            guard let e = lastError() else { return }
            action = .fixError(sql: e.sql, error: e.message)
            request = "Fix error"
        case .optimize:
            status = .loadingContext
            let input = await optimizeInput()
            guard !input.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .idle; return }
            action = .optimize(sql: input.sql, explainPlanJSON: input.plan)
            request = "Optimize"
        }
        lastRequest = (kind, request)
        if kind == .generate { prompt = "" }
        turns.append(Turn(kind: kind, request: request))
        let index = turns.count - 1
        status = .loadingContext

        do {
            let provider = try makeProvider()
            let focus: String
            switch action {
            case .generate(let p): focus = p
            case .explain(let sql), .optimize(let sql, _): focus = sql
            case .fixError(let sql, let error): focus = sql + " " + error
            }
            let context = try await loadContext(focus, allowSampleRows())
            try Task.checkCancellation()
            status = .streaming
            let assistant = QueryAssistant(provider: provider, model: model)
            for try await update in assistant.run(action, context: context) {
                turns[index].text = update.text
                turns[index].sql = update.sql
                if update.isFinished { turns[index].isFinished = true }
            }
            turns[index].isFinished = true
            status = .idle
        } catch is CancellationError {
            turns[index].isFinished = true
            status = .idle
        } catch let e as AIError {
            finishFailed(index, e)
        } catch {
            if Task.isCancelled { turns[index].isFinished = true; status = .idle } else {
                finishFailed(index, .network(error.localizedDescription))
            }
        }
    }

    private func finishFailed(_ index: Int, _ error: AIError) {
        if error == .cancelled {
            turns[index].isFinished = true
            status = .idle
            return
        }
        turns[index].isFinished = true
        status = .failed(error)
        // An empty answer that failed adds nothing to the transcript.
        if turns[index].text.isEmpty { turns.remove(at: index) }
    }
}

/// Wording for AI failures: the error text, plus where to fix it.
enum AIErrorCopy {
    static func message(_ error: AIError) -> String {
        error.errorDescription ?? "Something went wrong."
    }

    /// Whether Settings → AI is the place to fix it.
    static func needsSettings(_ error: AIError) -> Bool {
        switch error {
        case .missingAPIKey, .unauthorized, .modelNotFound: true
        default: false
        }
    }

    static func canRetry(_ error: AIError) -> Bool {
        switch error {
        case .missingAPIKey, .unauthorized, .modelNotFound, .quotaExceeded: false
        default: true
        }
    }
}

/// Sample rows for the assistant — only ever loaded when the user opted in for the connection.
enum AISampleRows {
    /// Up to `tableLimit` tables ranked by relevance to `focus`, three rows each. Failures skip the table.
    static func load(
        session: any DatabaseSession, tables: [TableInfo], focus: String, dialect: SQLDialect,
        tableLimit: Int = 4, rowsPerTable: Int = 3
    ) async -> [TableRef: SampleRows] {
        let ranked = SchemaSummary.rankNames(tables.filter { $0.kind == .table }.map(\.ref.name), focus: focus)
        var out: [TableRef: SampleRows] = [:]
        for name in ranked.prefix(tableLimit) {
            guard let info = tables.first(where: { $0.ref.name == name }) else { continue }
            let sql = "SELECT * FROM \(dialect.qualified(info.ref)) LIMIT \(rowsPerTable)"
            if let r = try? await session.execute(sql), !r.columns.isEmpty, !r.rows.isEmpty {
                out[info.ref] = SampleRows(columns: r.columns.map(\.name), rows: Array(r.rows.prefix(rowsPerTable)))
            }
        }
        return out
    }
}
