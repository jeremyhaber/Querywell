import Foundation
import QuerywellCore
import Testing
@testable import Querywell

/// A table with ids 1…25 behind the session contract that understands the keyset predicates the grid sends.
actor KeysetFakeSession: DatabaseSession {
    nonisolated let engine: DatabaseEngine = .mysql
    nonisolated let serverInfo = ServerInfo(engine: .mysql, versionString: "8.4.0", major: 8, minor: 4, patch: 0, tlsActive: false)
    private(set) var executed: [String] = []
    var hangSelects = false
    let total: Int

    init(total: Int = 25) { self.total = total }
    func setHang(_ value: Bool) { hangSelects = value }

    func execute(_ sql: String) async throws -> QueryResult { try await execute(sql, interruptible: false) }

    func execute(_ sql: String, interruptible: Bool) async throws -> QueryResult {
        executed.append(sql)
        if sql.hasPrefix("SELECT COUNT") {
            return QueryResult(columns: [ColumnInfo(name: "c", typeName: "bigint")], rows: [[.integer(Int64(total))]])
        }
        guard sql.hasPrefix("SELECT") else { return QueryResult() }
        if hangSelects {
            for _ in 0..<500 {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        var ids = Array(1...total).map(Int64.init)
        if let r = sql.range(of: "`ID` > ") { let n = Int64(sql[r.upperBound...].prefix { $0.isNumber })!; ids = ids.filter { $0 > n } }
        if let r = sql.range(of: "`ID` < ") { let n = Int64(sql[r.upperBound...].prefix { $0.isNumber })!; ids = ids.filter { $0 < n } }
        if sql.contains("ORDER BY `ID` DESC") { ids.reverse() }
        let limit = Int(sql.components(separatedBy: " LIMIT ").last?.prefix { $0.isNumber } ?? "") ?? 500
        let rows = ids.prefix(limit).map { [DatabaseValue.integer($0), .text("t\($0)"), .text("publish")] }
        return QueryResult(columns: FakeSession.columns, rows: Array(rows), duration: .milliseconds(1))
    }

    func listDatabases() async throws -> [String] { ["app"] }
    func currentDatabase() async throws -> String? { "app" }
    func close() async {}
    func statements() -> [String] { executed }
}

@MainActor
@Suite("Table paging (keyset, count, stop)")
struct PagingTests {
    private func makeModel(_ session: KeysetFakeSession, aux: Bool = false) async throws -> TableDataModel {
        let model = TableDataModel(table: TableRef(schema: "app", name: "posts"))
        model.pageSize = 10
        model.sessionProvider = { session }
        let inspector = FakeInspector()
        model.inspectorProvider = { inspector }
        if aux { model.auxSessionOpener = { KeysetFakeSession() } }
        model.loadIfNeeded(epoch: 1)
        try await waitUntil { model.hasLoaded && !model.isLoading }
        return model
    }

    private func ids(_ model: TableDataModel) -> [Int64] { model.content?.rows.compactMap { TableDataModel.int($0[0]) } ?? [] }

    @Test func nextPreviousFirstAndLastUseKeysetSeeks() async throws {
        let session = KeysetFakeSession()
        let model = try await makeModel(session)
        #expect(ids(model) == Array(1...10))
        try await waitUntil { if case .exact = model.count { true } else { false } }
        model.nextPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 11 }
        #expect(ids(model) == Array(11...20))
        #expect(model.pageInfo.offset == 10)
        model.nextPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 21 }
        #expect(ids(model) == Array(21...25))
        model.previousPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 11 }
        #expect(ids(model) == Array(11...20), "previous page comes back in display order")
        #expect(model.pageInfo.offset == 10)
        model.previousPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 1 }
        #expect(model.pageInfo.offset == 0 && !model.pageInfo.hasPrevious)
        model.lastPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 16 }
        #expect(ids(model) == Array(16...25))
        #expect(model.pageInfo.lastRow == 25 && !model.pageInfo.hasNext)
        model.firstPage()
        try await waitUntil { !model.isLoading && self.ids(model).first == 1 }
        let sql = await session.statements().filter { $0.hasPrefix("SELECT *") }
        #expect(sql.contains { $0.contains("WHERE ((`ID` > 10))") && $0.hasSuffix("LIMIT 10") && !$0.contains("OFFSET") })
        #expect(sql.contains { $0.contains("WHERE ((`ID` < 11))") && $0.contains("ORDER BY `ID` DESC") })
        #expect(sql.allSatisfy { !$0.contains("OFFSET") }, "keyset paging never emits OFFSET")
    }

    @Test func aSortThatIsntIndexedFallsBackToOffsetWithADeepPageNotice() async throws {
        let session = KeysetFakeSession(total: 50)
        let model = try await makeModel(session)
        model.toggleSort(column: "title", additive: false)  // not indexed in FakeInspector
        try await waitUntil { !model.isLoading && model.sort.count == 1 }
        #expect(model.keysetOrder == nil)
        model.nextPage()
        try await waitUntil { !model.isLoading }
        #expect(await session.statements().last { $0.hasPrefix("SELECT *") }?.contains("OFFSET 10") == true)
        #expect(model.deepPagingNotice == nil, "shallow offsets don't warn")
    }

    @Test func stopRestoresTheShownResultAndTheNextLoadIsNotBlocked() async throws {
        let session = KeysetFakeSession()
        let model = try await makeModel(session)
        let before = ids(model)
        await session.setHang(true)
        model.toggleSort(column: "ID", additive: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isLoading)
        model.stopLoading()
        #expect(!model.isLoading && model.sort.isEmpty, "the sort that was being loaded is put back")
        await session.setHang(false)
        model.reload()
        try await waitUntil { !model.isLoading && model.hasLoaded }
        #expect(ids(model) == before)
    }

    @Test func exactCountRunsOnTheAuxiliarySessionWhenAvailable() async throws {
        let session = KeysetFakeSession(total: 25)
        let model = try await makeModel(session, aux: true)
        model.nextPage()
        try await waitUntil { !model.isLoading }
        try await waitUntil { if case .exact(25) = model.count { true } else { false } }
        #expect(await session.statements().allSatisfy { !$0.hasPrefix("SELECT COUNT") }, "COUNT(*) never queued on the main session")
    }
}
