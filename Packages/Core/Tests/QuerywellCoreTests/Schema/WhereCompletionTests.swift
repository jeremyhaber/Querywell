import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)

private let columns: [ColumnDefinition] = [
    ColumnDefinition(name: "ID", ordinal: 1, dataType: "bigint", fullType: "bigint unsigned", isNullable: false, isPrimaryKey: true),
    ColumnDefinition(name: "post_title", ordinal: 2, dataType: "varchar", fullType: "varchar(255)", isNullable: false),
    ColumnDefinition(name: "post_status", ordinal: 3, dataType: "enum", fullType: "enum('publish','draft','it''s')",
                     isNullable: false, enumValues: ["publish", "draft", "it's"]),
    ColumnDefinition(name: "post_name", ordinal: 4, dataType: "varchar", fullType: "varchar(200)", isNullable: true),
    ColumnDefinition(name: "order", ordinal: 5, dataType: "int", fullType: "int", isNullable: false),
    ColumnDefinition(name: "Mixed Case", ordinal: 6, dataType: "int", fullType: "int", isNullable: true),
]

/// `|` in `marked` is the cursor.
private func complete(_ marked: String, dialect: SQLDialect = my) -> WhereCompletionResult {
    let units = Array(marked.utf16)
    let bar = units.firstIndex(of: Character("|").utf16.first!)!
    let text = String(decoding: units[..<bar] + units[(bar + 1)...], as: UTF16.self)
    return WhereCompletion.complete(text: text, cursor: bar, columns: columns, dialect: dialect)
}

private func labels(_ r: WhereCompletionResult) -> [String] { r.items.map(\.label) }
private func inserts(_ r: WhereCompletionResult) -> [String] { r.items.map(\.insertText) }

@Suite("WHERE completion")
struct WhereCompletionTests {
    @Test func startOfInputOffersAllColumnsThenNot() {
        let r = complete("|")
        #expect(labels(r) == ["ID", "post_title", "post_status", "post_name", "order", "Mixed Case", "NOT"])
        #expect(r.range == 0..<0)
    }

    @Test func prefixMatchesColumnsCaseInsensitively() {
        let r = complete("post_|")
        #expect(labels(r) == ["post_title", "post_status", "post_name"])
        #expect(r.range == 0..<5)
        #expect(labels(complete("POST_S|")) == ["post_status"])
        #expect(labels(complete("id|")) == ["ID"])
        #expect(complete("zzz|").items.isEmpty)
    }

    @Test func insertTextQuotesNamesThatNeedIt() {
        let r = complete("|")
        let byLabel = Dictionary(uniqueKeysWithValues: r.items.map { ($0.label, $0.insertText) })
        #expect(byLabel["ID"] == "ID")  // MySQL keeps case
        #expect(byLabel["order"] == "`order`")  // reserved word
        #expect(byLabel["Mixed Case"] == "`Mixed Case`")
        let p = complete("|", dialect: pg)
        let pgMap = Dictionary(uniqueKeysWithValues: p.items.map { ($0.label, $0.insertText) })
        #expect(pgMap["ID"] == "\"ID\"")  // upper case must be quoted on Postgres
        #expect(pgMap["post_title"] == "post_title")
        #expect(pgMap["order"] == "\"order\"")
        #expect(pgMap["Mixed Case"] == "\"Mixed Case\"")
    }

    @Test func columnItemsCarryTheirType() {
        let r = complete("post_t|")
        #expect(r.items.first?.detail == "varchar(255)")
        #expect(r.items.first?.kind == .column)
    }

    @Test func afterColumnOffersOperators() {
        let r = complete("post_title |")
        #expect(labels(r) == ["=", "<>", "!=", "<", ">", "<=", ">=", "IN", "NOT IN", "LIKE", "NOT LIKE", "IS NULL", "IS NOT NULL", "BETWEEN", "REGEXP"])
        #expect(labels(complete("post_title |", dialect: pg)).suffix(2) == ["BETWEEN", "ILIKE"])
        #expect(labels(complete("post_title |", dialect: pg)).contains("~"))
    }

    @Test func keywordPrefixesAfterColumn() {
        #expect(labels(complete("post_title l|")) == ["LIKE"])
        #expect(labels(complete("post_title i|")) == ["IN", "IS NULL", "IS NOT NULL"])
        #expect(labels(complete("post_title b|")) == ["BETWEEN"])
        #expect(labels(complete("post_title n|")) == ["NOT IN", "NOT LIKE"])
        let r = complete("post_title is n|")
        #expect(labels(r) == ["NULL", "NOT NULL"])
        #expect(r.range == 14..<15)
    }

    @Test func afterNotAfterColumn() {
        #expect(labels(complete("post_title NOT |")) == ["IN", "LIKE", "BETWEEN", "REGEXP"])
        #expect(labels(complete("post_title NOT l|")) == ["LIKE"])
        // NOT at the start of an expression expects a column.
        #expect(labels(complete("NOT |")).first == "ID")
    }

    @Test func afterValueOffersAndOr() {
        #expect(labels(complete("post_title = 'x' |")) == ["AND", "OR"])
        #expect(labels(complete("ID = 5 a|")) == ["AND"])
        #expect(labels(complete("ID IN (1, 2) |")) == ["AND", "OR"])
        #expect(labels(complete("ID IS NULL |")) == ["AND", "OR"])
    }

    @Test func afterAndOrOffersColumns() {
        #expect(labels(complete("ID = 1 AND |")).prefix(2) == ["ID", "post_title"])
        #expect(labels(complete("ID = 1 or post_n|")) == ["post_name"])
        #expect(labels(complete("(|")).first == "ID")
        #expect(labels(complete("ID = 1 AND (post_s|")) == ["post_status"])
    }

    @Test func enumValuesAfterEquals() {
        let r = complete("post_status = |")
        #expect(inserts(r).prefix(3) == ["'publish'", "'draft'", "'it\\'s'"])
        #expect(r.items.prefix(3).allSatisfy { $0.kind == .value })
        #expect(labels(r).prefix(3) == ["publish", "draft", "it's"])
        #expect(inserts(complete("post_status <> |")).first == "'publish'")
        #expect(inserts(complete("post_status != |")).first == "'publish'")
        // Prefix filter on the raw value, quoted insert.
        let d = complete("post_status = d|")
        #expect(inserts(d) == ["'draft'"])
        #expect(d.range == 14..<15)
        // Postgres doubles the quote instead of backslash escaping.
        #expect(inserts(complete("post_status = |", dialect: pg)).prefix(3) == ["'publish'", "'draft'", "'it''s'"])
    }

    @Test func enumValuesInsideInList() {
        #expect(inserts(complete("post_status IN (|")).prefix(2) == ["'publish'", "'draft'"])
        #expect(inserts(complete("post_status IN ('publish', |")).prefix(2) == ["'publish'", "'draft'"])
        #expect(inserts(complete("post_status NOT IN ('publish', 'draft', d|")) == ["'draft'"])
        // A non-enum column's list offers no values.
        #expect(!inserts(complete("post_title IN (|")).contains("'publish'"))
        // After the list closes we're back to AND/OR.
        #expect(labels(complete("post_status IN ('a') |")) == ["AND", "OR"])
    }

    @Test func nonEnumValueSlotOffersNullAndColumnsOnPrefix() {
        #expect(labels(complete("post_title = |")) == ["NULL"])
        #expect(labels(complete("post_title = po|")) == ["post_title", "post_status", "post_name"])
    }

    @Test func neverCompletesInsideStringLiterals() {
        #expect(complete("post_title = 'pu|").items.isEmpty)
        #expect(complete("post_title = 'pu|blish'").items.isEmpty)
        #expect(complete("post_title = 'it''s po|").items.isEmpty)  // doubled quote stays inside the string
        #expect(complete("post_title = 'a\\'po|").items.isEmpty)  // backslash-escaped quote (MySQL)
        #expect(complete("post_title = \"po|").items.isEmpty)  // double quotes are strings in MySQL
        #expect(complete("post_status = 'draft' AND post_t|").items.count == 1)  // string closed → fine again
    }

    @Test func backslashIsOnlyAnEscapeOnMySQL() {
        // On Postgres a backslash does not escape the quote, so the string ends there.
        #expect(!complete("post_title = 'a\\' AND post_t|", dialect: pg).items.isEmpty)
        #expect(complete("post_title = 'a\\' AND post_t|", dialect: my).items.isEmpty)
    }

    @Test func neverCompletesInsideQuotedIdentifiers() {
        #expect(complete("`post_|").items.isEmpty)
        #expect(complete("`post_|` = 1").items.isEmpty)
        #expect(complete("\"post_|", dialect: pg).items.isEmpty)
        #expect(complete("\"post_|\" = 1", dialect: pg).items.isEmpty)
        // A closed quoted identifier is a column: operators follow.
        #expect(labels(complete("`post_title` l|")) == ["LIKE"])
        #expect(labels(complete("\"post_title\" l|", dialect: pg)) == ["LIKE"])
        #expect(inserts(complete("`post_status` = |")).first == "'publish'")
    }

    @Test func neverCompletesInsideComments() {
        #expect(complete("ID = 1 -- post_|").items.isEmpty)
        #expect(complete("ID = 1 /* post_|").items.isEmpty)
        #expect(complete("# post_|").items.isEmpty)
        #expect(!complete("ID = 1 /* c */ AND post_|").items.isEmpty)
        // `#` starts a comment only on MySQL.
        #expect(complete("# post_|", dialect: pg).items.isEmpty == false)
    }

    @Test func cursorMidWordReplacesTheWholeWord() {
        let r = complete("post_t|itle = 1")
        #expect(labels(r) == ["post_title"])
        #expect(r.range == 0..<10)
    }

    @Test func rangesUseUTF16Offsets() {
        // The emoji is two UTF-16 units; the prefix "po" starts after it.
        let r = complete("title = '😀' AND po|")
        #expect(r.range == 17..<19)
        #expect(labels(r) == ["post_title", "post_status", "post_name"])
    }

    @Test func cursorBeyondOrBeforeBoundsIsClamped() {
        let text = "post_t"
        #expect(labels(WhereCompletion.complete(text: text, cursor: 999, columns: columns, dialect: my)) == ["post_title"])
        #expect(WhereCompletion.complete(text: text, cursor: -5, columns: columns, dialect: my).range == 0..<0)
    }

    @Test func numbersAndGluedLiteralsGetNothing() {
        #expect(complete("ID = 12|").items.isEmpty)
        #expect(complete("ID = 'a'|").items.isEmpty)
        #expect(complete("ID = 1 AND 5|").items.isEmpty)
    }

    @Test func unknownContextFallsBackToPrefixMatches() {
        // A function call result isn't a value slot we model; a typed prefix still finds columns/keywords.
        #expect(labels(complete("LOWER(|")).first == "ID")
        #expect(labels(complete("ID = 1 AND (|)")).first == "ID")
    }

    @Test func noColumnsStillOffersKeywords() {
        let r = WhereCompletion.complete(text: "a ", cursor: 2, columns: [], dialect: my)
        #expect(labels(r) == ["AND", "OR"])  // unknown identifier is treated as a value
        let empty = WhereCompletion.complete(text: "", cursor: 0, columns: [], dialect: my)
        #expect(labels(empty) == ["NOT"])
    }
}
