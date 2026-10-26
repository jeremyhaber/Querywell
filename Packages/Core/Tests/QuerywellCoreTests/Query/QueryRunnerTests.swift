import Foundation
import Testing
import os

@testable import QuerywellCore

private let my = SQLDialect(.mysql)

/// A scripted session: replies are looked up by substring of the executed SQL.
final class ScriptedSession: DatabaseSession {
    enum Reply: Sendable {
        case result(QueryResult)
        case failure(DatabaseError)
        case delay(Duration, QueryResult)
    }

    let engine: DatabaseEngine
    let serverInfo: ServerInfo
    private let replies: [(String, Reply)]
    private let log = OSAllocatedUnfairLock(initialState: [String]())

    init(engine: DatabaseEngine = .mysql, replies: [(String, Reply)]) {
        self.engine = engine
        self.replies = replies
        serverInfo = ServerInfo(engine: engine, versionString: "8.4.0", major: 8, minor: 4, patch: 0, tlsActive: false)
    }

    var executed: [String] { log.withLock { $0 } }

    func execute(_ sql: String) async throws -> QueryResult {
        log.withLock { $0.append(sql) }
        guard let (_, reply) = replies.first(where: { sql.contains($0.0) }) else {
            return QueryResult(rowsAffected: 0)
        }
        switch reply {
        case .result(let r): return r
        case .failure(let e): throw e
        case .delay(let d, let r):
            try await Task.sleep(for: d)
            return r
        }
    }

    func listDatabases() async throws -> [String] { ["shop"] }
    func currentDatabase() async throws -> String? { "shop" }
    func close() async {}
}

private func rows(_ n: Int) -> QueryResult {
    QueryResult(columns: [ColumnInfo(name: "n", typeName: "int")], rows: (0..<n).map { [.integer(Int64($0))] })
}

private func runner(prod: Bool = false, readOnly: Bool = false, options: QueryRunOptions = .init()) -> QueryRunner {
    QueryRunner(guardContext: GuardContext(isProduction: prod, isReadOnly: readOnly, databaseName: "shop", connectionName: "Shop", dialect: my),
                options: options)
}

private func ready(_ p: RunPreparation) -> PreparedScript? {
    if case .ready(let s) = p { return s }
    return nil
}

@Suite("Query runner")
struct QueryRunnerTests {
    @Test func multipleStatementsProduceOneResultEach() async throws {
        let session = ScriptedSession(replies: [
            ("SELECT 1", .result(rows(1))),
            ("UPDATE", .result(QueryResult(rowsAffected: 3, lastInsertID: nil))),
            ("INSERT", .result(QueryResult(rowsAffected: 1, lastInsertID: 42))),
        ])
        let prep = try #require(ready(runner().prepare(editorText: "SELECT 1; UPDATE t SET a = 1 WHERE id < 4; INSERT INTO t (a) VALUES (1)")))
        let result = await runner().run(prep, on: session)
        #expect(result.results.count == 3)
        #expect(result.results[0].resultSet?.rows.count == 1)
        #expect(result.results[1].outcome == .affected(rowsAffected: 3, lastInsertID: nil))
        #expect(result.results[2].outcome == .affected(rowsAffected: 1, lastInsertID: 42))
        #expect(session.executed == ["SELECT 1", "UPDATE t SET a = 1 WHERE id < 4", "INSERT INTO t (a) VALUES (1)"])
        #expect(!result.hasErrors && !result.wasCancelled)
    }

    @Test func messagesDescribeEachStatement() async throws {
        let session = ScriptedSession(replies: [
            ("SELECT", .result(rows(5))), ("UPDATE", .result(QueryResult(rowsAffected: 1))),
            ("INSERT", .result(QueryResult(rowsAffected: 3, lastInsertID: 7))),
        ])
        let prep = try #require(ready(runner().prepare(script: "SELECT 1; UPDATE t SET a=1 WHERE b=1; INSERT INTO t VALUES (1),(2),(3)")))
        let result = await runner().run(prep, on: session)
        let texts = result.messages.map(\.text)
        #expect(texts[0].hasPrefix("[1] 5 rows returned ("))
        #expect(texts[1].hasPrefix("[2] 1 row affected ("))
        #expect(texts[2].contains("3 rows affected (") && texts[2].contains("last insert ID 7"))
        #expect(texts.last!.hasPrefix("3 statements, total "))
        // a single statement has no [n] prefix and no summary line
        let one = await runner().run(try #require(ready(runner().prepare(script: "SELECT 1"))), on: session)
        #expect(one.messages.count == 1 && !one.messages[0].text.hasPrefix("["))
    }

    @Test func zeroRowSelectIsAResultSetNotAnAffectedCount() async throws {
        let session = ScriptedSession(replies: [("SELECT", .result(QueryResult(columns: [ColumnInfo(name: "a", typeName: "int")], rows: [])))])
        let r = await runner().run(try #require(ready(runner().prepare(script: "SELECT a FROM t WHERE 0"))), on: session)
        #expect(r.results[0].resultSet?.columns.count == 1)
        #expect(r.results[0].messages == ["0 rows returned (<1 ms)"] || r.results[0].messages[0].hasPrefix("0 rows returned"))
    }

    @Test func stopOnErrorSkipsTheRest() async throws {
        let session = ScriptedSession(replies: [
            ("BOOM", .failure(.query(message: "Unknown column 'x'", code: "1054"))),
        ])
        let prep = try #require(ready(runner().prepare(script: "SELECT 1; SELECT BOOM; SELECT 3")))
        let r = await runner().run(prep, on: session)
        #expect(r.results.map(\.isError) == [false, true, false])
        #expect(r.results[2].outcome == .skipped)
        #expect(session.executed.count == 2)
        #expect(r.hasErrors)
        let err = r.messages.first { $0.level == .error }
        #expect(err?.text.contains("Unknown column 'x' [1054]") == true)
        #expect(err?.statementIndex == 1)
    }

    @Test func continueOnErrorRunsEverything() async throws {
        let session = ScriptedSession(replies: [("BOOM", .failure(.query(message: "nope", code: nil)))])
        let r = QueryRunner(guardContext: runner().guardContext, options: QueryRunOptions(stopOnError: false))
        let prep = try #require(ready(r.prepare(script: "SELECT 1; SELECT BOOM; SELECT 3")))
        let res = await r.run(prep, on: session)
        #expect(session.executed.count == 3)
        #expect(res.results.map(\.isError) == [false, true, false])
    }

    @Test func closedSessionStopsEvenWhenContinuing() async throws {
        let session = ScriptedSession(replies: [("SELECT 2", .failure(.sessionClosed))])
        let r = QueryRunner(guardContext: runner().guardContext, options: QueryRunOptions(stopOnError: false))
        let res = await r.run(try #require(ready(r.prepare(script: "SELECT 1; SELECT 2; SELECT 3"))), on: session)
        #expect(session.executed.count == 2)
        #expect(res.results[2].outcome == .skipped)
    }

    @Test func rowCapTruncatesAndSaysSo() async throws {
        let session = ScriptedSession(replies: [("SELECT", .result(rows(25)))])
        let r = runner(options: QueryRunOptions(maxRowsPerResult: 10))
        let res = await r.run(try #require(ready(r.prepare(script: "SELECT n FROM big"))), on: session)
        let first = res.results[0]
        #expect(first.isTruncated)
        #expect(first.resultSet?.rows.count == 10)
        #expect(first.totalRows == 25)
        #expect(first.messages.contains("Showing the first 10 of 25 rows."))
        #expect(res.messages.contains { $0.level == .warning })
        // exactly at the cap is not truncated
        let exact = await runner(options: QueryRunOptions(maxRowsPerResult: 25)).run(try #require(ready(r.prepare(script: "SELECT n FROM big"))), on: session)
        #expect(!exact.results[0].isTruncated)
    }

    @Test func defaultCapIsFiftyThousand() {
        #expect(QueryRunOptions().maxRowsPerResult == 50_000)
        #expect(QueryRunOptions().stopOnError)
    }

    @Test func cancellationBetweenStatements() async throws {
        let session = ScriptedSession(replies: [("SLOW", .delay(.milliseconds(150), rows(1)))])
        let r = runner()
        let prep = try #require(ready(r.prepare(script: "SELECT SLOW; SELECT 2; SELECT 3")))
        let task = Task { await r.run(prep, on: session) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let res = await task.value
        #expect(res.wasCancelled)
        #expect(res.results.count == 3)
        #expect(res.results[1].outcome == .skipped && res.results[2].outcome == .skipped)
        #expect(res.messages.contains { $0.text == "Run cancelled." })
    }

    @Test func progressCallbackSeesEachResult() async throws {
        let session = ScriptedSession(replies: [])
        let seen = OSAllocatedUnfairLock(initialState: 0)
        let r = runner()
        _ = await r.run(try #require(ready(r.prepare(script: "SELECT 1; SELECT 2"))), on: session, onResult: { _ in seen.withLock { $0 += 1 } })
        #expect(seen.withLock { $0 } == 2)
    }

    // MARK: Scope

    @Test func selectionRunsOnlyTheSelectedText() throws {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let ns = text as NSString
        let sel = ns.range(of: "SELECT 2;")
        let prep = try #require(ready(runner().prepare(editorText: text, scope: .selection(sel.location..<(sel.location + sel.length)))))
        #expect(prep.statements.map(\.text) == ["SELECT 2"])
        #expect(prep.baseUTF16Offset == sel.location)
        // an empty selection runs everything
        let all = try #require(ready(runner().prepare(editorText: text, scope: .selection(5..<5))))
        #expect(all.statements.count == 3 && all.baseUTF16Offset == 0)
    }

    @Test func currentStatementUsesTheCursor() throws {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let cursor = (text as NSString).range(of: "SELECT 2").location + 3
        let prep = try #require(ready(runner().prepare(editorText: text, scope: .currentStatement(cursor: cursor))))
        #expect(prep.statements.map(\.text) == ["SELECT 2"])
        #expect(prep.baseUTF16Offset == (text as NSString).range(of: "SELECT 2").location)
    }

    @Test func blankOrCommentOnlyTextIsEmpty() {
        #expect(runner().prepare(editorText: "  \n -- nothing\n /* really */") == .empty)
        #expect(runner().prepare(editorText: "") == .empty)
    }

    // MARK: Write guard

    @Test func productionWritesNeedConfirmationAndNothingRunsMeanwhile() async throws {
        let session = ScriptedSession(replies: [])
        let r = runner(prod: true)
        let prep = r.prepare(script: "SELECT 1; UPDATE t SET a = 1 WHERE id = 1")
        guard case .needsConfirmation(let pending) = prep else { Issue.record("expected confirmation, got \(prep)"); return }
        #expect(pending.request.reasons.contains(.productionWrite))
        #expect(pending.request.statements.count == 1)  // only the write is listed
        #expect(session.executed.isEmpty)
        let script = try #require(pending.confirm(typed: "shop"))
        #expect(script.wasConfirmed)
        let res = await r.run(script, on: session)
        #expect(res.results.count == 2 && !res.hasErrors)
        #expect(session.executed.count == 2)
    }

    @Test func destructiveOnProductionRequiresTypedName() throws {
        let r = runner(prod: true)
        guard case .needsConfirmation(let pending) = r.prepare(script: "DROP TABLE t") else { Issue.record("expected confirmation"); return }
        #expect(pending.request.requiresTypedName == "shop")
        #expect(pending.confirm(typed: "wrong") == nil)
        #expect(pending.confirm() == nil)
        #expect(pending.confirm(typed: " shop ") != nil)
    }

    @Test func readOnlyBlocksWrites() {
        let r = runner(readOnly: true)
        guard case .blocked(let message) = r.prepare(script: "SELECT 1; DELETE FROM t WHERE id = 1") else { Issue.record("expected blocked"); return }
        #expect(message.contains("read-only"))
        #expect(ready(r.prepare(script: "SELECT 1; SHOW TABLES")) != nil)
    }

    @Test func readOnlyBeatsProduction() {
        guard case .blocked = runner(prod: true, readOnly: true).prepare(script: "UPDATE t SET a=1 WHERE b=1") else {
            Issue.record("expected blocked"); return
        }
    }

    @Test func nonProductionWritesRunWithoutConfirmation() throws {
        #expect(ready(runner().prepare(script: "UPDATE t SET a = 1 WHERE id = 1")) != nil)
        // but an unfiltered mutation always confirms
        guard case .needsConfirmation = runner().prepare(script: "DELETE FROM t") else { Issue.record("expected confirmation"); return }
    }

    @Test func productionReadsRunDirectly() {
        #expect(ready(runner(prod: true).prepare(script: "SELECT * FROM t; SHOW TABLES; EXPLAIN SELECT 1")) != nil)
    }

    @Test func durationFormatting() {
        #expect(QueryRunner.format(.microseconds(300)) == "<1 ms")
        #expect(QueryRunner.format(.milliseconds(12)) == "12 ms")
        #expect(QueryRunner.format(.milliseconds(1234)) == "1.23 s")
    }
}
