import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private func styled(_ sql: String, _ d: SQLDialect = my) -> [(String, SQLHighlightStyle)] {
    let ns = sql as NSString
    return SQLHighlighter(dialect: d).highlight(sql).map { (ns.substring(with: $0.nsRange), $0.style) }
}

private func style(of word: String, in sql: String, _ d: SQLDialect = my) -> SQLHighlightStyle? {
    styled(sql, d).first { $0.0 == word }?.1
}

@Suite("SQL highlighter")
struct SQLHighlighterTests {
    @Test func basicSelect() {
        let spans = styled("SELECT COUNT(*), `name` FROM wp_posts WHERE ID = 5 AND title = 'a''b' -- done")
        #expect(spans.contains { $0 == ("SELECT", .keyword) })
        #expect(spans.contains { $0 == ("COUNT", .function) })
        #expect(spans.contains { $0 == ("`name`", .quotedIdentifier) })
        #expect(spans.contains { $0 == ("wp_posts", .identifier) })
        #expect(spans.contains { $0 == ("5", .number) })
        #expect(spans.contains { $0 == ("'a''b'", .string) })
        #expect(spans.contains { $0 == ("-- done", .comment) })
        #expect(spans.contains { $0 == ("=", .operator) })
    }

    @Test func functionOnlyBeforeParenthesis() {
        // COUNT as a bare word is an identifier (a column called count), LEFT before JOIN is a keyword.
        #expect(style(of: "count", in: "SELECT count FROM t") == .identifier)
        #expect(style(of: "LEFT", in: "SELECT 1 FROM a LEFT JOIN b ON 1") == .keyword)
        #expect(style(of: "LEFT", in: "SELECT LEFT(name, 2) FROM a") == .function)
        #expect(style(of: "VALUES", in: "INSERT INTO t VALUES (1)") == .keyword)
    }

    @Test func partsOfDottedNamesAreIdentifiers() {
        #expect(style(of: "status", in: "SELECT p.status FROM p") == .identifier)
        #expect(style(of: "select", in: "SELECT t.select FROM t") == .identifier)
    }

    @Test func variablesAndPlaceholders() {
        let spans = styled("SELECT @a, @@global.max_connections, :named, ? FROM t WHERE x = @`odd name`")
        #expect(spans.contains { $0 == ("@a", .variable) })
        #expect(spans.contains { $0 == ("@@global.max_connections", .variable) })
        #expect(spans.contains { $0 == (":named", .variable) })
        #expect(spans.contains { $0 == ("?", .variable) })
        #expect(spans.contains { $0 == ("@`odd name`", .variable) })

        let p = styled("SELECT $1, a::int FROM t WHERE b = $2", pg)
        #expect(p.contains { $0 == ("$1", .variable) })
        #expect(p.contains { $0 == ("$2", .variable) })
        #expect(!p.contains { $0.1 == .variable && $0.0.hasPrefix(":") })
    }

    @Test func dollarQuotedAndVersionedComments() {
        let p = styled("SELECT $tag$ it's ; here $tag$ AS x", pg)
        #expect(p.contains { $0 == ("$tag$ it's ; here $tag$", .string) })
        let m = styled("/*!40101 SET NAMES utf8 */; /* plain */ # hash\nSELECT 1")
        #expect(m.filter { $0.1 == .comment }.count == 3)
    }

    @Test func dialectKeywords() {
        #expect(style(of: "ILIKE", in: "SELECT 1 WHERE a ILIKE 'x'", pg) == .keyword)
        #expect(style(of: "ILIKE", in: "SELECT 1 WHERE a ILIKE 'x'", my) == .identifier)
        #expect(style(of: "GROUP_CONCAT", in: "SELECT GROUP_CONCAT(a) FROM t", my) == .function)
        #expect(style(of: "string_agg", in: "SELECT string_agg(a, ',') FROM t", pg) == .function)
        #expect(style(of: "\"Name\"", in: "SELECT \"Name\" FROM t", pg) == .quotedIdentifier)
        #expect(style(of: "\"text\"", in: "SELECT \"text\" FROM t", my) == .string)
    }

    @Test func utf16RangesWithEmojiAndAccents() {
        let sql = "SELECT 'héllo 😀', 42 FROM t"
        let ns = sql as NSString
        let spans = SQLHighlighter(dialect: my).highlight(sql)
        for s in spans { #expect(s.range.upperBound <= ns.length) }
        #expect(spans.contains { ns.substring(with: $0.nsRange) == "'héllo 😀'" && $0.style == .string })
        #expect(spans.contains { ns.substring(with: $0.nsRange) == "42" && $0.style == .number })
    }

    @Test func spansAscendAndDoNotOverlap() {
        let sql = "SELECT a.b, @x, :y, $1::int /* c */ FROM `t` -- end"
        for d in [my, pg] {
            let spans = SQLHighlighter(dialect: d).highlight(sql)
            for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
        }
    }

    @Test func unterminatedStringStillStyled() {
        let spans = styled("SELECT 'abc")
        #expect(spans.last! == ("'abc", .string))
    }

    @Test func rangeHighlightMatchesFullHighlight() {
        let sql = "SELECT 1;\nSELECT 'a;b' FROM t;\nSELECT 3"
        let h = SQLHighlighter(dialect: my)
        let full = h.highlight(sql)
        let ns = sql as NSString
        let start = ns.range(of: "SELECT 'a;b'").location
        let end = ns.range(of: "t;").upperBound
        let part = h.highlight(sql, in: start..<end)
        #expect(!part.isEmpty)
        for s in part { #expect(full.contains(s)) }
    }

    // MARK: Incremental

    @Test func editInsideStatementRehighlightsOnlyThatStatement() {
        let sql = "SELECT 1;\nSELECT a FROM t WHERE x = 1;\nSELECT 3;"
        let ns = sql as NSString
        let digit = ns.range(of: "x = 1").location + 4
        let r = SQLHighlighter(dialect: my).rehighlightRange(in: sql, edited: digit..<(digit + 1), removed: "2")
        let expectedStart = ns.range(of: "SELECT 1;").upperBound
        let expectedEnd = ns.range(of: "x = 1;").upperBound
        #expect(r == expectedStart..<expectedEnd)
    }

    @Test func editInFirstAndLastStatement() {
        let sql = "SELECT 1; SELECT 2"
        let h = SQLHighlighter(dialect: my)
        #expect(h.rehighlightRange(in: sql, edited: 7..<8, removed: "0") == 0..<9)
        #expect(h.rehighlightRange(in: sql, edited: 17..<18, removed: "3") == 9..<18)
    }

    @Test func typingAQuoteExtendsToEndOfText() {
        let sql = "SELECT 'a;\nSELECT 2;\nSELECT 3;"
        let h = SQLHighlighter(dialect: my)
        let r = h.rehighlightRange(in: sql, edited: 7..<8, removed: "")
        #expect(r.upperBound == (sql as NSString).length)
    }

    @Test func deletionWithUnknownContentIsConservative() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let h = SQLHighlighter(dialect: my)
        #expect(h.rehighlightRange(in: sql, edited: 3..<3).upperBound == (sql as NSString).length)
        // Known to be a plain letter: stays within the statement.
        #expect(h.rehighlightRange(in: sql, edited: 3..<3, removed: "x").upperBound == 9)
    }

    @Test func rangeIsAlwaysSafeForRandomEdits() {
        // Editing then highlighting just the returned range equals highlighting the whole text there.
        let sql = "SELECT a, 'x;y' FROM t; -- c;\nUPDATE t SET a = `b;c` WHERE id = 1;\nSELECT 2"
        let h = SQLHighlighter(dialect: my)
        let total = (sql as NSString).length
        let full = h.highlight(sql)
        for pos in stride(from: 0, to: total, by: 3) {
            let r = h.rehighlightRange(in: sql, edited: pos..<min(pos + 1, total), removed: "z")
            #expect(r.lowerBound <= pos && r.upperBound >= min(pos + 1, total))
            let part = h.highlight(sql, in: r)
            for s in part { #expect(full.contains(s), "span \(s) at edit \(pos)") }
        }
    }

    // MARK: Performance

    @Test func fiveThousandLineScriptHighlightsQuickly() {
        var lines: [String] = []
        for i in 0..<5_000 {
            lines.append("SELECT p.ID, p.post_title, COUNT(m.meta_id) AS n FROM wp_posts p LEFT JOIN wp_postmeta m ON m.post_id = p.ID WHERE p.ID = \(i) AND p.post_status = 'publish'; -- row \(i)")
        }
        let sql = lines.joined(separator: "\n")
        let h = SQLHighlighter(dialect: my)
        let clock = ContinuousClock()
        let t0 = clock.now
        let spans = h.highlight(sql)
        let elapsed = clock.now - t0
        #expect(spans.count > 100_000)
        #if DEBUG
        // Unoptimised builds run ~0.1 s here but share the CPU with parallel integration suites, so
        // this only catches pathological (quadratic) regressions; the product target is ~50 ms (release).
        #expect(elapsed < .seconds(2), "took \(elapsed)")
        #else
        // Release takes ~10 ms; the bound is loose enough to survive a loaded CI machine yet still fails on
        // anything quadratic (which takes seconds at this size).
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
        #endif
    }
}
