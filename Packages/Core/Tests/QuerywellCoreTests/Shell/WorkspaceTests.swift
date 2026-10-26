import Foundation
import Testing
@testable import QuerywellCore

@Suite("WorkspaceTabs")
struct WorkspaceTabsTests {
    @Test func openTableDedupes() {
        var t = WorkspaceTabs()
        let a = t.openTable(database: "app", name: "users")
        let b = t.openTable(database: "app", name: "orders")
        #expect(t.selectedID == b)
        #expect(t.openTable(database: "app", name: "users") == a)
        #expect(t.tabs.count == 2 && t.selectedID == a)
        // Same table name in another database is a different tab.
        let c = t.openTable(database: "other", name: "users")
        #expect(c != a && t.tabs.count == 3)
        #expect(t.titles == ["users", "orders", "users"])
    }

    @Test func queryNumbersNeverReused() {
        var t = WorkspaceTabs()
        let q1 = t.newQuery(), q2 = t.newQuery()
        #expect(t.titles == ["Query 1", "Query 2"])
        t.close(id: q2)
        let q3 = t.newQuery()
        #expect(t.tab(id: q3)?.title == "Query 3")
        t.close(id: q1)
        _ = t.newQuery()
        #expect(t.titles == ["Query 3", "Query 4"])
        #expect(t.tabs[0].kind == .query(number: 3))
    }

    @Test func consoleIsSingleTerminalIsNot() {
        var t = WorkspaceTabs()
        let c = t.openConsole()
        _ = t.newQuery()
        #expect(t.openConsole() == c)
        #expect(t.selectedID == c && t.tabs.count == 2)
        let t1 = t.openTerminal(), t2 = t.openTerminal()
        #expect(t1 != t2 && t.tabs.count == 4)
    }

    @Test func closeSelectionRules() {
        var t = WorkspaceTabs()
        let a = t.newQuery(), b = t.newQuery(), c = t.newQuery()
        t.select(id: b)
        t.close(id: b)                    // right neighbour
        #expect(t.selectedID == c)
        t.close(id: c)                    // no right neighbour -> left
        #expect(t.selectedID == a)
        t.close(id: UUID())               // unknown: no-op
        #expect(t.tabs.count == 1)
        t.close(id: a)                    // last -> nil
        #expect(t.selectedID == nil && t.tabs.isEmpty)
    }

    @Test func closingUnselectedKeepsSelection() {
        var t = WorkspaceTabs()
        let a = t.newQuery(), b = t.newQuery()
        t.select(id: b)
        t.close(id: a)
        #expect(t.selectedID == b)
    }

    @Test func closeOthers() {
        var t = WorkspaceTabs()
        let a = t.newQuery(); _ = t.newQuery(); _ = t.openConsole()
        t.closeOthers(id: a)
        #expect(t.tabs.map(\.id) == [a] && t.selectedID == a)
        t.closeOthers(id: UUID())
        #expect(t.tabs.count == 1)
        // Query numbering survives.
        let next = t.newQuery()
        #expect(t.tab(id: next)?.title == "Query 3")
    }

    @Test func cycling() {
        var t = WorkspaceTabs()
        t.selectNext(); t.selectPrevious()
        #expect(t.selectedID == nil)
        let a = t.newQuery(), b = t.newQuery(), c = t.newQuery()
        #expect(t.selectedID == c)
        t.selectNext();     #expect(t.selectedID == a)
        t.selectPrevious(); #expect(t.selectedID == c)
        t.selectPrevious(); #expect(t.selectedID == b)
        t.select(id: UUID()); #expect(t.selectedID == b)
        var single = WorkspaceTabs()
        let s = single.newQuery()
        single.selectNext(); #expect(single.selectedID == s)
        single.selectPrevious(); #expect(single.selectedID == s)
    }

    @Test func dirty() {
        var t = WorkspaceTabs()
        let a = t.newQuery()
        t.setDirty(id: a, true)
        #expect(t.tab(id: a)?.isDirty == true)
        t.setDirty(id: a, false)
        t.setDirty(id: UUID(), true)
        #expect(t.tabs.allSatisfy { !$0.isDirty })
    }

    @Test func moveMatchesSwiftUISemantics() {
        func order(_ from: [Int], to offset: Int) -> [String] {
            var t = WorkspaceTabs()
            for _ in 0..<4 { t.newQuery() }          // Query 1...4
            let selected = t.tabs[0].id
            t.select(id: selected)
            t.move(fromOffsets: IndexSet(from), toOffset: offset)
            #expect(t.selectedID == selected)
            return t.titles.map { String($0.last!) }
        }
        #expect(order([0], to: 3) == ["2", "3", "1", "4"])
        #expect(order([0], to: 4) == ["2", "3", "4", "1"])
        #expect(order([3], to: 0) == ["4", "1", "2", "3"])
        #expect(order([1], to: 1) == ["1", "2", "3", "4"])
        #expect(order([1], to: 2) == ["1", "2", "3", "4"])
        #expect(order([0, 1], to: 4) == ["3", "4", "1", "2"])
        #expect(order([2, 3], to: 0) == ["3", "4", "1", "2"])
        #expect(order([9], to: 0) == ["1", "2", "3", "4"])
        #expect(order([0], to: 99) == ["2", "3", "4", "1"])
    }

    @Test func accents() {
        var t = WorkspaceTabs()
        let ids = [t.openTable(database: "d", name: "t"), t.newQuery(), t.openConsole(), t.openTerminal()]
        #expect(ids.map { t.tab(id: $0)!.accent } == [.table, .query, .console, .console])
    }

    @Test func codableRoundTripAndTolerance() throws {
        var t = WorkspaceTabs()
        t.openTable(database: "d", name: "t")
        let q = t.newQuery()
        t.openConsole(); t.openTerminal()
        t.setDirty(id: q, true)
        t.close(id: q)
        t.newQuery()
        let data = try JSONFileStore.makeEncoder().encode(t)
        let back = try JSONFileStore.makeDecoder().decode(WorkspaceTabs.self, from: data)
        #expect(back == t)

        let empty = try JSONFileStore.makeDecoder().decode(WorkspaceTabs.self, from: Data("{}".utf8))
        #expect(empty.tabs.isEmpty && empty.selectedID == nil)

        // Stale selection dropped; query counter repaired.
        var stale = back
        stale = try JSONFileStore.makeDecoder().decode(WorkspaceTabs.self, from: Data(
            #"{"selectedID":"\#(UUID().uuidString)","tabs":[{"id":"\#(UUID().uuidString)","kind":{"query":{"number":7}},"title":"Query 7","isDirty":false}]}"#.utf8))
        #expect(stale.selectedID == nil)
        var s2 = stale
        let id8 = s2.newQuery()
        #expect(s2.tab(id: id8)?.title == "Query 8")
    }
}
