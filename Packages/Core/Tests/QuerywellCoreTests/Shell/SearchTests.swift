import Foundation
import Testing
@testable import QuerywellCore

private func matched(_ query: String, _ candidate: String) -> String? {
    FuzzyMatcher.score(query: query, candidate: candidate).map { m in
        String(m.matchedIndices.map { candidate[$0] })
    }
}

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func subsequenceAndCase() {
        #expect(FuzzyMatcher.score(query: "usr", candidate: "users") != nil)
        #expect(FuzzyMatcher.score(query: "USR", candidate: "Users") != nil)
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "users") == nil)
        #expect(FuzzyMatcher.score(query: "sru", candidate: "users") == nil)   // order matters
        #expect(FuzzyMatcher.score(query: "userss", candidate: "users") == nil)  // longer than candidate
        #expect(FuzzyMatcher.score(query: "a", candidate: "") == nil)
    }

    @Test func emptyQueryMatchesAll() {
        let m = FuzzyMatcher.score(query: "", candidate: "anything")
        #expect(m?.score == 0 && m?.matchedIndices.isEmpty == true)
        #expect(FuzzyMatcher.score(query: "  ", candidate: "")?.score == 0)
    }

    @Test func matchedIndicesAreAscendingAndCorrect() {
        let c = "order_items"
        let m = FuzzyMatcher.score(query: "oi", candidate: c)!
        #expect(m.matchedIndices.count == 2)
        #expect(m.matchedIndices == m.matchedIndices.sorted())
        #expect(matched("oi", c) == "oi")
        // Chooses the boundary "i" after the underscore, not the one inside "order".
        #expect(c.distance(from: c.startIndex, to: m.matchedIndices[1]) == 6)
    }

    @Test func prefixBeatsInnerMatch() {
        let a = FuzzyMatcher.score(query: "user", candidate: "users")!
        let b = FuzzyMatcher.score(query: "user", candidate: "app_users")!
        let c = FuzzyMatcher.score(query: "user", candidate: "superuser")!
        #expect(a.score > b.score)
        #expect(b.score > c.score)   // word boundary beats mid-word
    }

    @Test func boundaries() {
        let camel = FuzzyMatcher.score(query: "ui", candidate: "userId")!
        let flat = FuzzyMatcher.score(query: "ui", candidate: "quiet")!
        #expect(camel.score > flat.score)
        let dot = FuzzyMatcher.score(query: "ab", candidate: "x.ab")!
        let mid = FuzzyMatcher.score(query: "ab", candidate: "xxab")!
        #expect(dot.score > mid.score)
    }

    @Test func consecutiveBeatsGaps() {
        let tight = FuzzyMatcher.score(query: "abc", candidate: "xabcx")!
        let loose = FuzzyMatcher.score(query: "abc", candidate: "xaxbxcx")!
        #expect(tight.score > loose.score)
        let near = FuzzyMatcher.score(query: "ac", candidate: "xaxcx")!
        let far = FuzzyMatcher.score(query: "ac", candidate: "xaxxxxxcx")!
        #expect(near.score > far.score)
    }

    @Test func unicode() {
        #expect(FuzzyMatcher.score(query: "café", candidate: "Café_Orders") != nil)
        #expect(FuzzyMatcher.score(query: "ÉCOLE", candidate: "école") != nil)
        let emoji = "🙂users"
        let m = FuzzyMatcher.score(query: "us", candidate: emoji)!
        #expect(String(m.matchedIndices.map { emoji[$0] }) == "us")
    }

    @Test func whitespaceInQueryIgnored() {
        #expect(FuzzyMatcher.score(query: "ord it", candidate: "order_items") != nil)
    }

    @Test func rankIsStableAndLimited() {
        let items = ["beta", "alpha", "alphabet", "zeta"]
        let r = FuzzyMatcher.rank(items, query: "", key: { $0 }, limit: 3)
        #expect(r.map(\.0) == ["beta", "alpha", "alphabet"])
        #expect(r.allSatisfy { $0.1.score == 0 })

        let ties = ["a1", "a2", "a3"]
        #expect(FuzzyMatcher.rank(ties, query: "a", key: { $0 }, limit: 10).map(\.0) == ties)

        let ranked = FuzzyMatcher.rank(["xalx", "alpha", "al"], query: "al", key: { $0 }, limit: 10)
        #expect(ranked.first?.0 == "al" || ranked.first?.0 == "alpha")
        #expect(ranked.last?.0 == "xalx")
        #expect(FuzzyMatcher.rank(items, query: "a", key: { $0 }, limit: 0).isEmpty)
        #expect(FuzzyMatcher.rank([String](), query: "a", key: { $0 }, limit: 5).isEmpty)
    }

    @Test func performanceOn10kCandidates() {
        let words = ["user", "order", "item", "product", "invoice", "session", "log", "audit"]
        let candidates = (0..<10_000).map { i in
            "\(words[i % 8])_\(words[(i / 8) % 8])_\(i)_\(i % 2 == 0 ? "Tbl" : "view")"
        }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = FuzzyMatcher.rank(candidates, query: "usort", key: { $0 }, limit: 50).count
        }
        #expect(count == 50)
        #expect(elapsed < .seconds(1))
    }
}

@Suite("QuickSwitcher")
struct QuickSwitcherTests {
    let tabID = UUID(), connID = UUID()
    var items: [QuickSwitcherItem] {
        [
            .action(.newQuery),
            .connection(connID, name: "Users DB", tag: .production),
            .table(database: "app", name: "users"),
            .openTab(tabID, title: "users"),
            .action(.settings),
        ]
    }

    @Test func actionTitles() {
        #expect(QuickAction.newQuery.title == "New Query")
        #expect(QuickAction.newConsole.title == "New Console")
        #expect(QuickAction.openConnections.title == "Open Connections")
        #expect(QuickAction.settings.title == "Settings")
    }

    @Test func emptyQueryGroupsByCategory() {
        let r = QuickSwitcher.results(query: "", items: items, limit: 10)
        #expect(r.map(\.item.category) == [.openTab, .table, .connection, .action, .action])
        #expect(r.last?.item == .action(.settings))   // original order inside a category
    }

    @Test func tiesResolvedByCategory() {
        let r = QuickSwitcher.results(query: "users", items: items, limit: 10)
        #expect(r.count == 3)
        #expect(r[0].item == .openTab(tabID, title: "users"))
        #expect(r[1].item == .table(database: "app", name: "users"))
        #expect(r[2].item.category == .connection)
    }

    @Test func clearlyBetterMatchWinsOverCategory() {
        let list: [QuickSwitcherItem] = [
            .openTab(tabID, title: "Some Long Query Name"),
            .action(.settings),
        ]
        let r = QuickSwitcher.results(query: "set", items: list, limit: 5)
        #expect(r.first?.item == .action(.settings))
    }

    @Test func limitAndNoMatch() {
        #expect(QuickSwitcher.results(query: "zzzz", items: items, limit: 5).isEmpty)
        #expect(QuickSwitcher.results(query: "", items: items, limit: 2).count == 2)
        #expect(QuickSwitcher.results(query: "", items: items, limit: 0).isEmpty)
        #expect(QuickSwitcher.results(query: "u", items: [], limit: 5).isEmpty)
    }

    @Test func subtitleAndTitle() {
        #expect(QuickSwitcherItem.table(database: "app", name: "users").subtitle == "app")
        #expect(QuickSwitcherItem.action(.settings).subtitle == nil)
        #expect(QuickSwitcherItem.connection(connID, name: "X", tag: nil).title == "X")
    }
}
