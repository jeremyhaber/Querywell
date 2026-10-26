import Foundation
import QuerywellCore
import Testing
@testable import Querywell

/// An `AIProvider` that streams canned chunks and records the requests it got.
final class MockAIProvider: AIProvider, @unchecked Sendable {  // test double: the lock guards `requests`
    let id: AIProviderID = .anthropic
    var chunks: [String]
    var failure: AIError?
    private let lock = NSLock()
    private var _requests: [AIRequest] = []
    var requests: [AIRequest] { lock.withLock { _requests } }

    init(chunks: [String], failure: AIError? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func listModels() async throws -> [AIModelInfo] { [AIModelInfo(id: "mock-1")] }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lock.withLock { _requests.append(request) }
        let chunks = chunks, failure = failure
        return AsyncThrowingStream { continuation in
            Task {
                for c in chunks {
                    continuation.yield(.textDelta(c))
                    try? await Task.sleep(for: .milliseconds(2))
                }
                if let failure { continuation.finish(throwing: failure) } else {
                    continuation.yield(.done(AIUsage(inputTokens: 10, outputTokens: 5)))
                    continuation.finish()
                }
            }
        }
    }
}

@MainActor
@Suite("AI assistant model")
struct AIAssistantModelTests {
    private let samples: [TableRef: SampleRows] = [
        TableRef(schema: "app", name: "posts"): SampleRows(columns: ["ID", "title"], rows: [[.integer(1), .text("Secret Launch Plan")]])
    ]

    private func make(provider: MockAIProvider, tab: QueryTabModel? = nil) -> (AIAssistantModel, SampleBox) {
        let m = AIAssistantModel()
        m.providerID = .anthropic
        m.hasKey = true
        m.makeProvider = { provider }
        let box = SampleBox()
        let samples = samples
        m.allowSampleRows = { box.allowed }
        m.setAllowSampleRows = { box.allowed = $0 }
        m.loadContext = { prompt, allow in
            box.askedAllow.append(allow)
            return AssistantContext(engine: .mysql, currentSchema: "app", schemaSummary: "posts(ID, title)",
                                    allowSampleRows: allow, sampleRows: samples)
        }
        if let tab {
            m.insertIntoEditor = { tab.insertIntoEditor($0) }
            m.replaceEditor = { tab.setEditorText($0) }
            m.currentSQL = { tab.assistantSQL }
            m.lastError = { tab.lastError.map { ($0.statement.text, $0.message) } }
            m.optimizeInput = { await tab.planForOptimize() }
        }
        return (m, box)
    }

    final class SampleBox { var allowed = false; var askedAllow: [Bool] = [] }

    @Test func streamsAnAnswerAndExtractsTheSQL() async {
        let provider = MockAIProvider(chunks: ["Here you go:\n```sql\nSELECT ID, ", "title FROM posts\n", "WHERE post_status = 'draft';\n```"])
        let (m, _) = make(provider: provider)
        m.prompt = "draft pages"
        await m.perform(.generate)
        #expect(m.status == .idle)
        #expect(m.prompt.isEmpty)
        #expect(m.turns.count == 1 && m.turns[0].isFinished)
        #expect(m.latestSQL == "SELECT ID, title FROM posts\nWHERE post_status = 'draft';")
        #expect(m.turns[0].request == "draft pages")
        #expect(provider.requests.first?.messages.first?.text == "draft pages")
        #expect(provider.requests.first?.model == "claude-sonnet-5-5", "falls back to the provider's suggested model")
    }

    @Test func insertingNeverRunsAnything() async throws {
        let h = TabHarness(production: true, text: "SELECT 1")
        let provider = MockAIProvider(chunks: ["```sql\nDELETE FROM posts WHERE ID = 3;\n```"])
        let (m, _) = make(provider: provider, tab: h.model)
        h.model.selection = NSRange(location: 8, length: 0)
        m.prompt = "remove post 3"
        await m.perform(.generate)
        #expect(m.reviewWarnings.contains { $0.contains("writes") || $0.contains("confirmation") })
        m.insert()
        #expect(h.model.text == "SELECT 1DELETE FROM posts WHERE ID = 3;")
        m.replace()
        #expect(h.model.text == "DELETE FROM posts WHERE ID = 3;")
        #expect(await h.session.executed.isEmpty, "the assistant has no way to execute")
        #expect(h.confirmations.value.isEmpty)
        // Running it afterwards still hits the PROD guard.
        h.answer.value = false
        await h.model.run(.all)
        #expect(h.confirmations.value.count == 1)
        #expect(await h.session.executed.isEmpty)
    }

    @Test func sampleRowsAreSentOnlyWithTheOptIn() async {
        let provider = MockAIProvider(chunks: ["```sql\nSELECT 1\n```"])
        let (m, box) = make(provider: provider)
        m.prompt = "a"
        await m.perform(.generate)
        m.prompt = "b"
        box.allowed = true
        await m.perform(.generate)
        #expect(box.askedAllow == [false, true])
        let systems = provider.requests.map(\.system)
        #expect(!systems[0].contains("Secret Launch Plan") && !systems[0].contains("Sample rows"))
        #expect(systems[1].contains("Secret Launch Plan") && systems[1].contains("Sample rows"))
    }

    @Test func fixErrorNeedsAFailedRunAndSendsTheStatementAndError() async throws {
        let session = FakeSession()
        await session.setFailWhenContaining("nope")
        let h = TabHarness(text: "SELECT nope FROM posts", session: session)
        let provider = MockAIProvider(chunks: ["```sql\nSELECT title FROM posts\n```"])
        let (m, _) = make(provider: provider, tab: h.model)
        #expect(!m.canFixError)
        await m.perform(.fixError)
        #expect(m.turns.isEmpty && provider.requests.isEmpty)
        await h.model.run(.all)
        #expect(m.canFixError)
        await m.perform(.fixError)
        let user = try #require(provider.requests.first?.messages.first?.text)
        #expect(user.contains("SELECT nope FROM posts") && user.contains("Data too long"))
        #expect(m.latestSQL == "SELECT title FROM posts")
    }

    @Test func optimizeRunsExplainFirstAndSendsThePlan() async throws {
        let session = ScriptedSession()
        let plan = #"{"query_block":{"select_id":1,"table":{"table_name":"posts","access_type":"ALL","rows_examined_per_scan":9}}}"#
        await session.respond(prefix: "EXPLAIN FORMAT=JSON", with: QueryResult(columns: [ColumnInfo(name: "EXPLAIN", typeName: "json")], rows: [[.text(plan)]]))
        let tab = QueryTabModel(profile: ConnectionProfile(name: "t", engine: .mysql, user: "u"), text: "SELECT * FROM posts")
        tab.sessionProvider = { session }
        let provider = MockAIProvider(chunks: ["```sql\nSELECT ID FROM posts\n```"])
        let (m, _) = make(provider: provider, tab: tab)
        await m.perform(.optimize)
        let user = try #require(provider.requests.first?.messages.first?.text)
        #expect(user.contains("EXPLAIN output") && user.contains("rows_examined_per_scan"))
        #expect(await session.executed.contains { $0.hasPrefix("EXPLAIN FORMAT=JSON") })
    }

    @Test func errorsAreInlineAndRetryable() async {
        let provider = MockAIProvider(chunks: [], failure: .rateLimited(retryAfter: 3))
        let (m, _) = make(provider: provider)
        m.prompt = "x"
        await m.perform(.generate)
        guard case .failed(let error) = m.status else { Issue.record("expected failure"); return }
        #expect(AIErrorCopy.message(error).contains("Rate limited"))
        #expect(AIErrorCopy.canRetry(error) && !AIErrorCopy.needsSettings(error))
        #expect(m.turns.isEmpty, "a failed, empty answer leaves no stub in the transcript")

        provider.failure = nil
        provider.chunks = ["```sql\nSELECT 1\n```"]
        m.prompt = "x"
        await m.perform(.generate)
        #expect(m.status == .idle)
        #expect(m.latestSQL == "SELECT 1")
    }

    @Test func missingKeyAndBadKeyPointAtSettings() async {
        let (m, _) = make(provider: MockAIProvider(chunks: []))
        m.hasKey = false
        m.prompt = "x"
        await m.perform(.generate)
        guard case .failed(let e) = m.status else { Issue.record("expected failure"); return }
        #expect(AIErrorCopy.needsSettings(e) && !AIErrorCopy.canRetry(e))
        #expect(AIErrorCopy.message(e).contains("Settings → AI"))
        #expect(AIErrorCopy.needsSettings(.unauthorized(.openai)))
    }

    @Test func stopKeepsThePartialAnswer() async throws {
        let provider = MockAIProvider(chunks: (0..<200).map { _ in "word " })
        let (m, _) = make(provider: provider)
        m.prompt = "long"
        m.generate()
        try await waitUntil { m.status == .streaming && !(m.latest?.text.isEmpty ?? true) }
        m.stop()
        try await waitUntil { !m.isBusy }
        #expect(m.status == .idle)
        #expect(m.turns.count == 1 && m.turns[0].isFinished)
    }
}

@Suite("Markdown-lite")
struct MarkdownLiteTests {
    @Test func parsesParagraphsListsAndCode() {
        let blocks = MarkdownLite.parse("""
        ## Why it is slow

        The query scans `wp_postmeta`.
        It has no index.

        - add an index
        - drop the OR

        ```sql
        SELECT 1;
        ```
        """)
        #expect(blocks == [
            .heading("Why it is slow"),
            .paragraph("The query scans `wp_postmeta`. It has no index."),
            .bullets(["add an index", "drop the OR"]),
            .code(language: "sql", text: "SELECT 1;", isOpen: false),
        ])
    }

    @Test func unfinishedFenceIsOpen() {
        #expect(MarkdownLite.parse("```sql\nSELECT") == [.code(language: "sql", text: "SELECT", isOpen: true)])
        #expect(MarkdownLite.parse("1. one\n2. two") == [.bullets(["one", "two"])])
    }
}
