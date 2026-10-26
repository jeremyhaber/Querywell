import Foundation
import Testing
@testable import QuerywellCore

private func doc(_ s: String) throws -> JSONDocument { try JSONDocument.parse(s) }
/// Writes `@uXXXX` in test sources to mean a JSON backslash-u escape.
private func esc(_ s: String) -> String { s.replacingOccurrences(of: "@u", with: String(UnicodeScalar(92)) + "u") }

@Suite("JSON document: parsing")
struct JSONParsingTests {
    @Test func scalarsAndStructures() throws {
        #expect(try doc("null").root == .null)
        #expect(try doc("true").root == .bool(true))
        #expect(try doc("false").root == .bool(false))
        #expect(try doc("\"x\"").root == .string("x"))
        #expect(try doc("[]").root == .array([]))
        #expect(try doc("{}").root == .object([]))
        #expect(try doc(" \n\t [1, 2 , 3 ] \r\n").root == .array([.number(raw: "1"), .number(raw: "2"), .number(raw: "3")]))
    }

    @Test func objectKeyOrderAndDuplicatesPreserved() throws {
        let d = try doc("{\"b\":1,\"a\":2,\"b\":3}")
        guard case .object(let m) = d.root else { Issue.record("object"); return }
        #expect(m.map(\.key) == ["b", "a", "b"])
        #expect(m.map(\.value) == [.number(raw: "1"), .number(raw: "2"), .number(raw: "3")])
    }

    @Test func numberTextPreserved() throws {
        let raws = ["0", "-0", "1.0", "1.50", "1e5", "1E+5", "-1.5e-10", "12345678901234567890123", "0.00000000000000000001", "100", "3.14159265358979323846264338327950288"]
        for r in raws {
            #expect(try doc("[\(r)]").root == .array([.number(raw: r)]), "\(r)")
        }
        let d = try doc("{\"id\":12345678901234567890}")
        #expect(d.minified == "{\"id\":12345678901234567890}")
    }

    @Test func invalidNumbers() {
        for bad in ["01", "-", "1.", ".5", "1e", "1e+", "+1", "0x10", "--1", "1.2.3", "NaN", "Infinity", "-Infinity"] {
            #expect(JSONDocument.validate("[\(bad)]") != nil, "\(bad)")
        }
    }

    @Test func stringEscapes() throws {
        let d = try doc(esc(#"["a\"b\\c\/d\b\f\n\r\t@u0041@u00e9@u4e2d"]"#))
        #expect(d.root == .array([.string("a\"b\\c/d\u{08}\u{0C}\n\r\tAé中")]))
    }

    @Test func surrogatePairs() throws {
        #expect(try doc(esc(#"["@ud83d@ude00"]"#)).root == .array([.string("😀")]))
        #expect(try doc(esc(#"["@uD834@uDD1E"]"#)).root == .array([.string("𝄞")]))
        #expect(try doc("[\"😀 raw\"]").root == .array([.string("😀 raw")]))
    }

    @Test func loneSurrogatesRejected() {
        #expect(JSONDocument.validate(esc(#"["@ud83d"]"#)) != nil)
        #expect(JSONDocument.validate(esc(#"["@ud83dx"]"#)) != nil)
        #expect(JSONDocument.validate(esc(#"["@ud83d@u0041"]"#)) != nil)
        #expect(JSONDocument.validate(esc(#"["@ude00"]"#)) != nil)
    }

    @Test func invalidEscapes() {
        for bad in [#"["\x"]"#, esc(#"["@u12"]"#), esc(#"["@u12G4"]"#), #"["\"#, "[\"abc"] {
            #expect(JSONDocument.validate(bad) != nil, "\(bad)")
        }
    }

    @Test func controlCharactersInStringsRejected() {
        #expect(JSONDocument.validate("[\"a\nb\"]") != nil)
        #expect(JSONDocument.validate("[\"a\tb\"]") != nil)
    }

    @Test func bomIsAccepted() throws {
        let d = try doc("\u{FEFF}{\"a\":1}")
        #expect(d.root == .object([JSONMember(key: "a", value: .number(raw: "1"))]))
        #expect(d.originalFormatting == "\u{FEFF}{\"a\":1}")
    }

    @Test func deepNestingWithinLimit() throws {
        let n = 100
        let s = String(repeating: "[", count: n) + String(repeating: "]", count: n)
        #expect(try doc(s).minified == s)
        let o = String(repeating: "{\"a\":", count: n) + "1" + String(repeating: "}", count: n)
        #expect(try doc(o).minified == o)
    }

    @Test func nestingBeyondLimitIsAnErrorNotACrash() {
        let n = 5000
        let s = String(repeating: "[", count: n) + String(repeating: "]", count: n)
        let e = JSONDocument.validate(s)
        #expect(e?.message.contains("deep") == true)
    }
}

@Suite("JSON document: errors")
struct JSONErrorTests {
    private func err(_ s: String, sourceLocation: SourceLocation = #_sourceLocation) -> JSONParseError? {
        let e = JSONDocument.validate(s)
        #expect(e != nil, "expected error for \(s)", sourceLocation: sourceLocation)
        return e
    }

    @Test func empty() {
        #expect(err("")?.line == 1)
        #expect(err("   \n ")?.line == 2)
    }

    @Test func lineAndColumn() {
        let e = err("{\n  \"a\": 1,\n  \"b\": ,\n  \"c\": 3\n}")
        #expect(e?.line == 3)
        #expect(e?.column == 8)
        #expect(e?.description.contains("line 3, column 8") == true)
    }

    @Test func columnCountsScalarsNotBytes() {
        let e = err("[\"日本語\", x]")
        #expect(e?.line == 1)
        #expect(e?.column == 9)
        #expect(e?.offset == 14)
    }

    @Test func trailingComma() {
        #expect(err("[1,2,]")?.column == 6)
        #expect(err("{\"a\":1,}")?.column == 8)
    }

    @Test func missingColonOrKey() {
        #expect(err("{\"a\" 1}")?.message.contains(":") == true)
        #expect(err("{a:1}")?.message.contains("string key") == true)
        #expect(err("{1:1}") != nil)
        #expect(err("{\"a\":}") != nil)
    }

    @Test func unterminated() {
        #expect(err("[1,2")?.message.contains("end of input") == true)
        #expect(err("{\"a\":1")?.message.contains("end of input") == true)
        #expect(err("\"abc")?.message.contains("Unterminated") == true)
    }

    @Test func trailingData() {
        let e = err("{} x")
        #expect(e?.column == 4)
        #expect(err("1 2") != nil)
        #expect(err("[1][2]") != nil)
    }

    @Test func badLiterals() {
        for bad in ["tru", "nul", "True", "nulll", "falsey", "undefined", "'single'", "[1 2]", "{\"a\":1 \"b\":2}", "// c\n1", "[/*c*/1]"] {
            #expect(JSONDocument.validate(bad) != nil, "\(bad)")
        }
    }

    @Test func validDocumentsHaveNoError() {
        for ok in ["{}", "[]", "0", "\"\"", "null", "{\"a\":[1,{\"b\":null}]}", "  [ ]  "] {
            #expect(JSONDocument.validate(ok) == nil, "\(ok)")
        }
    }
}

@Suite("JSON document: formatting")
struct JSONFormattingTests {
    private let sample = "{\"name\":\"Café\",\"list\":[1,2,{\"x\":null}],\"empty\":{},\"none\":[],\"ok\":true,\"n\":-1.50}"

    @Test func minifiedAndPretty() throws {
        let d = try doc(sample)
        #expect(d.minified == sample)
        let expected = """
        {
          "name": "Café",
          "list": [
            1,
            2,
            {
              "x": null
            }
          ],
          "empty": {},
          "none": [],
          "ok": true,
          "n": -1.50
        }
        """
        #expect(d.prettyPrinted(indent: 2) == expected)
        #expect(d.prettyPrinted() == expected)
        #expect(d.prettyPrinted(indent: 4).contains("\n    \"name\""))
        #expect(d.prettyPrinted(indent: .tab).contains("\n\t\"name\""))
        // pretty output re-parses to the same tree
        #expect(try doc(d.prettyPrinted()).root == d.root)
    }

    @Test func unmodifiedReturnsOriginalTextExactly() throws {
        let weird = "{ \"a\" :1,\n\n\t\"b\":   [ 1 ,2]  }  \n"
        let d = try doc(weird)
        #expect(!d.isModified)
        #expect(d.originalFormatting == weird)
    }

    @Test func detectsTwoSpaceIndent() throws {
        var d = try doc("{\n  \"a\": 1,\n  \"b\": [\n    1\n  ]\n}")
        #expect(d.detectedFormatting.layout == .pretty(indent: .spaces(2)))
        d.root = .object([JSONMember(key: "a", value: .number(raw: "2")), JSONMember(key: "b", value: .array([.number(raw: "1"), .number(raw: "3")]))])
        #expect(d.isModified)
        #expect(d.originalFormatting == "{\n  \"a\": 2,\n  \"b\": [\n    1,\n    3\n  ]\n}")
    }

    @Test func detectsFourSpaceAndTabIndent() throws {
        let four = try doc("{\n    \"a\": 1\n}")
        #expect(four.detectedFormatting.layout == .pretty(indent: .spaces(4)))
        let tab = try doc("{\n\t\"a\": 1\n}")
        #expect(tab.detectedFormatting.layout == .pretty(indent: .tab))
        var t = tab
        t.root = .object([JSONMember(key: "a", value: .number(raw: "1")), JSONMember(key: "b", value: .bool(true))])
        #expect(t.originalFormatting == "{\n\t\"a\": 1,\n\t\"b\": true\n}")
    }

    @Test func detectsMinifiedAndInline() throws {
        let min = try doc("{\"a\":1,\"b\":[1,2]}")
        #expect(min.detectedFormatting.layout == .minified)
        let inline = try doc("{\"a\": 1, \"b\": [1, 2]}")
        #expect(inline.detectedFormatting.layout == .inline)
        var i = inline
        i.root = .object([JSONMember(key: "z", value: .array([.number(raw: "9"), .string("s")]))])
        #expect(i.originalFormatting == "{\"z\": [9, \"s\"]}")
        #expect(try doc("[1,2,3]").detectedFormatting.layout == .minified)
        #expect(try doc("[]").detectedFormatting.layout == .minified)
        #expect(try doc("{\n}").detectedFormatting.layout == .minified)
    }

    @Test func prettyOfPhpStyleJsonKeepsEscapedSlashes() throws {
        // PHP json_encode(JSON_PRETTY_PRINT): 4 spaces, escaped slashes
        let php = "{\n    \"url\": \"http:\\/\\/old.test\\/a\",\n    \"n\": [\n        1,\n        2\n    ]\n}"
        let d = try doc(php)
        #expect(d.detectedFormatting.escapeSlashes)
        #expect(d.detectedFormatting.layout == .pretty(indent: .spaces(4)))
        #expect(d.minified == "{\"url\":\"http:\\/\\/old.test\\/a\",\"n\":[1,2]}")
        var e = d
        e.root = .object([JSONMember(key: "url", value: .string("https://new.example.com/b"))])
        #expect(e.originalFormatting == "{\n    \"url\": \"https:\\/\\/new.example.com\\/b\"\n}")
    }

    @Test func unescapedSlashesStayUnescaped() throws {
        let d = try doc("{\"u\":\"http://x.test/a\"}")
        #expect(!d.detectedFormatting.escapeSlashes)
        #expect(d.minified == "{\"u\":\"http://x.test/a\"}")
    }

    @Test func unicodeEscapeStyleDetected() throws {
        let escaped = try doc(esc(#"{"t":"caf@u00e9 @u65e5@u672c @ud83d@ude00"}"#))
        #expect(escaped.detectedFormatting.escapeNonASCII)
        #expect(escaped.root == .object([JSONMember(key: "t", value: .string("café 日本 😀"))]))
        #expect(escaped.minified == esc(#"{"t":"caf@u00e9 @u65e5@u672c @ud83d@ude00"}"#))
        var edited = escaped
        edited.root = .object([JSONMember(key: "t", value: .string("ñ😀"))])
        #expect(edited.originalFormatting == esc(#"{"t":"@u00f1@ud83d@ude00"}"#))

        let raw = try doc("{\"t\":\"café 日本 😀\"}")
        #expect(!raw.detectedFormatting.escapeNonASCII)
        #expect(raw.minified == "{\"t\":\"café 日本 😀\"}")
    }

    @Test func asciiUEscapesDoNotCountAsNonASCIIStyle() throws {
        // @u0041 is plain ASCII; it must not switch on non-ASCII escaping
        #expect(!(try doc(esc(#"{"t":"@u0041é"}"#))).detectedFormatting.escapeNonASCII)
    }

    @Test func controlAndQuoteEscapingOnEmit() throws {
        var d = try doc("{}")
        d.root = .array([.string("q\" b\\ nl\n cr\r tab\t bs\u{08} ff\u{0C} ctl\u{01} del\u{7F} ls\u{2028}")])
        #expect(d.minified == "[\"q\\\" b\\\\ nl\\n cr\\r tab\\t bs\\b ff\\f ctl\\u0001 del\u{7F} ls\u{2028}\"]")
        #expect(try doc(d.minified).root == d.root)
    }

    @Test func emptyContainersInPretty() throws {
        let d = try doc("{\"a\":[],\"b\":{}}")
        #expect(d.prettyPrinted(indent: 2) == "{\n  \"a\": [],\n  \"b\": {}\n}")
    }

    @Test func minifiedFromPrettyAndBack() throws {
        let pretty = "{\n  \"a\": [\n    1,\n    2\n  ]\n}"
        let d = try doc(pretty)
        #expect(d.minified == "{\"a\":[1,2]}")
        #expect(try doc(d.minified).prettyPrinted(indent: 2) == pretty)
    }

    @Test func specialKeysAreEscaped() throws {
        var d = try doc("{}")
        d.root = .object([JSONMember(key: "k\"ey/\n", value: .null)])
        #expect(try doc(d.minified).root == d.root)
    }
}

@Suite("JSON document: real-world samples")
struct JSONSampleTests {
    @Test func gutenbergBlockAttributes() throws {
        let attrs = ##"{"align":"wide","className":"is-style-rounded","url":"http:\/\/old.test\/wp-content\/uploads\/2024\/01\/pic.jpg","id":123,"sizeSlug":"large","linkDestination":"none","style":{"spacing":{"padding":{"top":"2rem","bottom":"2rem"}},"color":{"background":"#f0f0f0"}}}"##
        let d = try doc(attrs)
        #expect(d.originalFormatting == attrs)
        #expect(d.minified == attrs)  // \/ preserved
        #expect(d.detectedFormatting.escapeSlashes)
        guard case .object(let m) = d.root else { Issue.record("obj"); return }
        #expect(m[2].value == .string("http://old.test/wp-content/uploads/2024/01/pic.jpg"))
        #expect(m.map(\.key).prefix(3) == ["align", "className", "url"])
    }

    @Test func wooCommerceOrderMeta() throws {
        let s = """
        {
            "id": 727,
            "total": "29.99",
            "currency": "EUR",
            "billing": {"first_name": "José", "last_name": "Müller", "email": "jose@example.com"},
            "line_items": [
                {"id": 315, "name": "Woo Single #1", "price": 29.99, "taxes": [], "meta_data": [{"key": "_x", "value": null}]}
            ],
            "date_created_gmt": "2024-01-31T12:00:00",
            "big": 9007199254740993,
            "ratio": 1.0
        }
        """
        let d = try doc(s)
        #expect(d.originalFormatting == s)
        #expect(d.detectedFormatting.layout == .pretty(indent: .spaces(4)))
        #expect(d.minified.contains("\"big\":9007199254740993"))
        #expect(d.minified.contains("\"ratio\":1.0"))
        #expect(d.minified.contains("\"price\":29.99"))
    }

    @Test func wpOptionStyleJSON() throws {
        let s = ##"{"version":"6.4","isGlobalStylesUserThemeJSON":true,"settings":{"color":{"palette":{"theme":[{"slug":"base","color":"#fff","name":"Base"}]}}}}"##
        #expect(try doc(s).prettyPrinted().components(separatedBy: "\n").count > 10)
        #expect(try doc(try doc(s).prettyPrinted()).minified == s)
    }

    @Test func themeJsonWithUnicodeKeysAndValues() throws {
        let s = "{\"日本語\":{\"ключ\":\"значение\",\"emoji\":\"😀\"}}"
        let d = try doc(s)
        #expect(d.minified == s)
        #expect(try doc(d.prettyPrinted()).root == d.root)
    }

    @Test func lookAlike() {
        #expect(JSONDocument.looksLikeJSON("{\"a\":1}"))
        #expect(JSONDocument.looksLikeJSON("  [1,2]\n"))
        #expect(JSONDocument.looksLikeJSON("{}"))
        #expect(!JSONDocument.looksLikeJSON("123"))
        #expect(!JSONDocument.looksLikeJSON("\"str\""))
        #expect(!JSONDocument.looksLikeJSON("true"))
        #expect(!JSONDocument.looksLikeJSON(""))
        #expect(!JSONDocument.looksLikeJSON("{not json"))
        #expect(!JSONDocument.looksLikeJSON("[1,2"))
        #expect(!JSONDocument.looksLikeJSON("a:0:{}"))
        #expect(!JSONDocument.looksLikeJSON("{]"))
    }

    @Test func editingPreservesBigNumbersAndOrder() throws {
        var d = try doc("{\"z\":1,\"a\":12345678901234567890,\"m\":[1.0,2.50]}")
        guard case .object(var m) = d.root else { Issue.record("obj"); return }
        m[0].value = .number(raw: "2")
        d.root = .object(m)
        #expect(d.originalFormatting == "{\"z\":2,\"a\":12345678901234567890,\"m\":[1.0,2.50]}")
    }
}
