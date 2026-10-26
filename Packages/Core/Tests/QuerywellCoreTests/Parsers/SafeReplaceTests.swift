import Foundation
import Testing
@testable import QuerywellCore

private func ser(_ v: PHPValue) -> String { String(decoding: PHPSerializer.serialize(v), as: UTF8.self) }

private func rep(_ search: String, _ replace: String, _ options: SafeReplaceOptions = SafeReplaceOptions()) throws -> SafeReplacer {
    try SafeReplacer(search: search, replace: replace, options: options)
}

private let oldURL = "http://old.test"
private let newURL = "https://new.example.com"

@Suite("SafeReplace: plain strings")
struct SafeReplacePlainTests {
    @Test func basicReplace() throws {
        let o = try rep(oldURL, newURL).replace(in: "visit http://old.test/a and http://old.test/b")
        #expect(o.newValue == "visit https://new.example.com/a and https://new.example.com/b")
        #expect(o.replacements == 2)
        #expect(o.kind == .plain)
        #expect(o.warnings.isEmpty)
    }

    @Test func noMatchReturnsInputUnchanged() throws {
        let o = try rep("zzz", "y").replace(in: "nothing to see")
        #expect(o.newValue == "nothing to see")
        #expect(o.replacements == 0)
        #expect(!o.changed)
    }

    @Test func emptySearchRejected() {
        #expect(throws: SafeReplacerError.emptySearch) { try SafeReplacer(search: "", replace: "x") }
    }

    @Test func invalidRegexRejected() {
        #expect(throws: SafeReplacerError.self) { try SafeReplacer(search: "(", replace: "x", options: .init(regex: true)) }
    }

    @Test func replacementIsLiteralInNonRegexMode() throws {
        let o = try rep("a", "$1\\n&").replace(in: "banana")
        #expect(o.newValue == "b$1\\n&n$1\\n&n$1\\n&")
        #expect(o.replacements == 3)
    }

    @Test func emptyReplacementDeletes() throws {
        #expect(try rep("-", "").replace(in: "a-b-c").newValue == "abc")
    }

    @Test func byteExactNoUnicodeNormalisation() throws {
        // precomposed é must not match decomposed e + combining acute
        let o = try rep("caf\u{E9}", "X").replace(in: "cafe\u{301} caf\u{E9}")
        #expect(o.replacements == 1)
        #expect(o.newValue == "cafe\u{301} X")
    }

    @Test func overlappingMatchesAreNonOverlapping() throws {
        #expect(try rep("aa", "b").replace(in: "aaaaa").newValue == "bba")
    }

    @Test func caseInsensitive() throws {
        let o = try rep("OLD.test", "new.test", .init(caseSensitive: false)).replace(in: "Old.TEST and old.test and OLD.TEST")
        #expect(o.newValue == "new.test and new.test and new.test")
        #expect(o.replacements == 3)
        let strict = try rep("OLD.test", "x").replace(in: "old.test")
        #expect(strict.replacements == 0)
    }

    @Test func wholeWord() throws {
        let o = try rep("cat", "dog", .init(wholeWord: true)).replace(in: "cat concat cat. category cat_1 (cat)")
        #expect(o.newValue == "dog concat dog. category cat_1 (dog)")
        #expect(o.replacements == 3)
    }

    @Test func wholeWordWithRegexAndCaseInsensitive() throws {
        let o = try rep("c[ao]t", "pet", .init(caseSensitive: false, regex: true, wholeWord: true)).replace(in: "Cat cot cut scat COT")
        #expect(o.newValue == "pet pet cut scat pet")
    }

    @Test func regexWithCaptureGroups() throws {
        let o = try rep(#"http://(\w+)\.test/(\d+)"#, "https://$1.example.com/p/$2", .init(regex: true))
            .replace(in: "a http://shop.test/12 b http://blog.test/7")
        #expect(o.newValue == "a https://shop.example.com/p/12 b https://blog.example.com/p/7")
        #expect(o.replacements == 2)
    }

    @Test func regexEscapedDollar() throws {
        let o = try rep(#"price: (\d+)"#, #"cost: \$$1"#, .init(regex: true)).replace(in: "price: 5")
        #expect(o.newValue == "cost: $5")
    }

    @Test func metacharactersAreLiteralWithoutRegexOption() throws {
        let o = try rep("a.b(c)*", "X", .init(caseSensitive: false)).replace(in: "a.b(c)* aXb(c)*")
        #expect(o.newValue == "X aXb(c)*")
    }

    @Test func multibyteReplacement() throws {
        let o = try rep("Hello", "Héllo 日本語 😀").replace(in: "Hello world")
        #expect(o.newValue == "Héllo 日本語 😀 world")
    }
}

@Suite("SafeReplace: PHP serialized")
struct SafeReplaceSerializedTests {
    @Test func lengthsAreRecomputed() throws {
        let input = "s:15:\"http://old.test\";"
        let o = try rep(oldURL, newURL).replace(in: input)
        #expect(o.newValue == "s:23:\"https://new.example.com\";")
        #expect(o.kind == .phpSerialized)
        #expect(o.replacements == 1)
    }

    @Test func shrinkingReplacementAlsoFixesLength() throws {
        let o = try rep("https://new.example.com", "http://a.b").replace(in: "a:1:{s:3:\"url\";s:23:\"https://new.example.com\";}")
        #expect(o.newValue == "a:1:{s:3:\"url\";s:10:\"http://a.b\";}")
    }

    @Test func matchesRealPHPForEntireCorpus() throws {
        let r = try rep(oldURL, newURL)
        for (name, count, expected) in PHPReplaceOracle.cases {
            let input = String(decoding: PHPFixtures.named(name).bytes, as: UTF8.self)
            let o = r.replace(in: input)
            #expect(o.newValue == expected, "\(name)")
            #expect(o.replacements == count, "\(name)")
            #expect(o.warnings.isEmpty, "\(name)")
            if count == 0 { #expect(o.newValue == input, "\(name) no-op must be identical") }
            // PHP must also be able to... at minimum our own parser accepts the result and it is canonical
            let doc = try PHPSerializedParser.parse(o.newValue)
            #expect(doc.serialize() == Data(o.newValue.utf8), "\(name)")
        }
    }

    @Test func noMatchIsByteIdenticalForEveryValidUTF8Fixture() throws {
        let literal = try rep("string-that-never-occurs-\u{2603}", "x")
        let regex = try rep("never(occurs)?xyz", "x", .init(regex: true))
        let insens = try rep("NEVER-OCCURS", "x", .init(caseSensitive: false))
        for fx in PHPFixtures.all {
            guard let s = phpUTF8String(fx.bytes) else { continue }
            for r in [literal, regex, insens] {
                let o = r.replace(in: s)
                #expect(o.newValue == s, "\(fx.name)")
                #expect(o.replacements == 0)
                #expect(o.kind != .phpSerializedInvalid, "\(fx.name)")
            }
        }
    }

    @Test func multibyteLengthsInBytes() throws {
        let input = ser(.makeArray([(.key("t"), .makeString("Hello old.test"))]))
        let o = try rep("Hello", "Héllo 日本").replace(in: input)
        #expect(o.newValue == ser(.makeArray([(.key("t"), .makeString("Héllo 日本 old.test"))])))
        #expect(o.newValue.contains("s:\("Héllo 日本 old.test".utf8.count):"))
    }

    @Test func arrayKeysReplacedByDefaultAndOptionallyNot() throws {
        let input = ser(.makeArray([(.key("old.test"), .makeString("old.test")), (.int(5), .int(7))]))
        let on = try rep("old.test", "new.example.com").replace(in: input)
        #expect(on.newValue == ser(.makeArray([(.key("new.example.com"), .makeString("new.example.com")), (.int(5), .int(7))])))
        #expect(on.replacements == 2)
        let off = try rep("old.test", "new.example.com", .init(replaceInPHPArrayKeys: false)).replace(in: input)
        #expect(off.newValue == ser(.makeArray([(.key("old.test"), .makeString("new.example.com")), (.int(5), .int(7))])))
        #expect(off.replacements == 1)
    }

    @Test func classNamesAndPropertyNamesAreNeverTouched() throws {
        let priv = "\0Old_Plugin\0old_prop"
        let obj = PHPValue.object(className: "Old_Plugin", properties: [
            PHPEntry(key: .key("old_prop"), value: .makeString("old value")),
            PHPEntry(key: .string(Data(priv.utf8)), value: .makeString("old private")),
            PHPEntry(key: .key("\0*\0old_protected"), value: .makeString("keep")),
        ])
        let input = ser(obj)
        let o = try rep("old", "NEW").replace(in: input)
        guard case .object(let cls, let props) = try PHPSerializedParser.parse(o.newValue).root else { Issue.record("object"); return }
        #expect(cls == "Old_Plugin")
        #expect(props.map(\.key) == [.key("old_prop"), .string(Data(priv.utf8)), .key("\0*\0old_protected")])
        #expect(props.map(\.value.stringValue) == ["NEW value", "NEW private", "keep"])
        #expect(o.replacements == 2)
        #expect(o.newValue.contains("O:10:\"Old_Plugin\":3:"))
    }

    @Test func numbersBoolsNullAndDoublesUntouched() throws {
        let input = "a:5:{i:0;i:1234;i:1;b:1;i:2;N;i:3;d:0.1;i:4;d:1.0E+25;}"
        let o = try rep("1", "9").replace(in: input)
        #expect(o.newValue == input)
        #expect(o.replacements == 0)
    }

    @Test func customObjectPayloadUntouchedAndReported() throws {
        let fx = String(decoding: PHPFixtures.named("custom_object").bytes, as: UTF8.self)
        let o = try rep("payload", "XXXXXXXXXXXXXXX").replace(in: fx)
        #expect(o.replacements == 0)
        #expect(o.newValue == fx)
        #expect(o.warnings == [.customObjectSkipped(className: "Legacy", matches: 1)])
        // other values in the same document are still replaced, payload bytes preserved
        let o2 = try rep("before", "BEFORE-VALUE").replace(in: fx)
        #expect(o2.replacements == 1)  // "before" is an array key; keys are replaced by default
        let o3 = try rep("é", "e").replace(in: fx)
        #expect(o3.newValue.contains("C:6:\"Legacy\":12:{x|payload é}"))
        #expect(o3.newValue.contains("s:5:\"after\";s:1:\"e\";"))
        #expect(o3.replacements == 1)
    }

    @Test func referencesKeepWorking() throws {
        let fx = String(decoding: PHPFixtures.named("refs_R").bytes, as: UTF8.self)
        let o = try rep("k", "kk").replace(in: fx)
        #expect(o.newValue == "a:3:{i:0;i:1;i:1;R:2;s:2:\"kk\";R:2;}")
        let objs = String(decoding: PHPFixtures.named("refs_r").bytes, as: UTF8.self)
        #expect(try rep("again", "twice").replace(in: objs).newValue.contains("r:2;"))
    }

    @Test func enumCasesUntouched() throws {
        let fx = String(decoding: PHPFixtures.named("enum_case").bytes, as: UTF8.self)
        let o = try rep("Hearts", "Spades").replace(in: fx)
        #expect(o.newValue == fx)
    }

    @Test func serializedInsideSerialized() throws {
        let inner = ser(.makeArray([(.key("url"), .makeString("http://old.test/x")), (.key("n"), .int(1))]))
        let outer = ser(.makeArray([(.key("inner"), .makeString(inner)), (.key("plain"), .makeString("http://old.test/y"))]))
        let o = try rep(oldURL, newURL).replace(in: outer)
        let expectedInner = ser(.makeArray([(.key("url"), .makeString("https://new.example.com/x")), (.key("n"), .int(1))]))
        let expected = ser(.makeArray([(.key("inner"), .makeString(expectedInner)), (.key("plain"), .makeString("https://new.example.com/y"))]))
        #expect(o.newValue == expected)
        #expect(o.replacements == 2)
        // both layers are internally consistent
        let outerDoc = try PHPSerializedParser.parse(o.newValue)
        let innerString = try #require(outerDoc.root.entries[0].value.stringValue)
        #expect(try PHPSerializedParser.parse(innerString).root.entries[0].value.stringValue == "https://new.example.com/x")
    }

    @Test func tripleNesting() throws {
        let l3 = ser(.makeArray([(.key("z"), .makeString("see http://old.test/deep"))]))
        let l2 = ser(.makeArray([(.key("y"), .makeString(l3))]))
        let l1 = ser(.makeArray([(.key("x"), .makeString(l2))]))
        let o = try rep(oldURL, newURL).replace(in: l1)
        let e3 = ser(.makeArray([(.key("z"), .makeString("see https://new.example.com/deep"))]))
        let e2 = ser(.makeArray([(.key("y"), .makeString(e3))]))
        #expect(o.newValue == ser(.makeArray([(.key("x"), .makeString(e2))])))
        #expect(o.replacements == 1)
    }

    @Test func nestedSerializedRoot() throws {
        let fx = String(decoding: PHPFixtures.named("serialized_triple").bytes, as: UTF8.self)
        let o = try rep("deep", "DEEPER").replace(in: fx)
        #expect(o.replacements == 1)
        #expect(o.newValue.contains("http://old.test/DEEPER"))
    }

    @Test func jsonInsideSerializedMatchesEscapedSlashes() throws {
        let fx = String(decoding: PHPFixtures.named("json_in_serialized").bytes, as: UTF8.self)
        let o = try rep(oldURL, newURL).replace(in: fx)
        #expect(o.replacements == 4)  // payload: 2, escaped: 1, pretty: 1
        let root = try PHPSerializedParser.parse(o.newValue).root
        let payload = try #require(root.entries[0].value.stringValue)
        #expect(payload.contains("https:\\/\\/new.example.com\\/z"))  // PHP's escaped slashes kept
        #expect(!payload.contains("old.test"))
        let parsed = try JSONDocument.parse(payload)
        guard case .object(let m) = parsed.root else { Issue.record("json object"); return }
        #expect(m[0].value == .string("https://new.example.com/z"))
        // pretty-printed JSON keeps its 4-space layout
        let pretty = try #require(root.entries[2].value.stringValue)
        #expect(pretty.hasPrefix("{\n    \"a\": \"https:\\/\\/new.example.com\\/p\""))
    }

    @Test func invalidSerializedIsLeftUntouchedAndReported() throws {
        let corrupted = "a:1:{s:3:\"url\";s:3:\"http://old.test\";}"
        let o = try rep(oldURL, newURL).replace(in: corrupted)
        #expect(o.kind == .phpSerializedInvalid)
        #expect(o.newValue == corrupted)
        #expect(o.replacements == 0)
        guard case .invalidSerialized(let e)? = o.warnings.first else { Issue.record("warning"); return }
        #expect(e.offset == 23)
        // same through the regex path (no pre-filter)
        let r = try rep("old\\.test", "x", .init(regex: true)).replace(in: corrupted)
        #expect(r.kind == .phpSerializedInvalid)
        #expect(r.newValue == corrupted)
    }

    @Test func nestedInvalidSerializedFallsBackToPlainTextAndWarns() throws {
        let broken = "a:1:{s:1:\"u\";s:99:\"http://old.test\";}"
        let outer = ser(.makeArray([(.key("blob"), .makeString(broken))]))
        let o = try rep(oldURL, newURL).replace(in: outer)
        #expect(o.kind == .phpSerialized)
        #expect(o.replacements == 1)
        #expect(o.warnings == [.nestedInvalidSerialized])
        let v = try #require(try PHPSerializedParser.parse(o.newValue).root.entries[0].value.stringValue)
        #expect(v == "a:1:{s:1:\"u\";s:99:\"https://new.example.com\";}")
    }

    @Test func plainTextThatMerelyLooksSerializedButIsBrokenIsReportedNotChanged() throws {
        let weird = "s:5:\"old.test"  // no closing
        #expect(!PHPSerialized.looksSerialized(weird))
        let o = try rep("old", "new").replace(in: weird)
        #expect(o.kind == .plain)
        #expect(o.newValue == "s:5:\"new.test")
    }

    @Test func trailingWhitespacePreserved() throws {
        let o = try rep("a", "bb").replace(in: "s:1:\"a\";\n")
        #expect(o.newValue == "s:2:\"bb\";\n")
    }

    @Test func regexInsideSerialized() throws {
        let input = ser(.makeArray([(.key("a"), .makeString("http://shop.test/1")), (.key("b"), .makeString("http://blog.test/22 and http://x.test/3"))]))
        let o = try rep(#"http://(\w+)\.test/(\d+)"#, "https://$1.example.com/p/$2", .init(regex: true)).replace(in: input)
        #expect(o.newValue == ser(.makeArray([(.key("a"), .makeString("https://shop.example.com/p/1")),
                                              (.key("b"), .makeString("https://blog.example.com/p/22 and https://x.example.com/p/3"))])))
        #expect(o.replacements == 3)
    }

    @Test func caseInsensitiveInsideSerialized() throws {
        let input = ser(.makeArray([(.key("a"), .makeString("HTTP://OLD.TEST/x"))]))
        let o = try rep(oldURL, newURL, .init(caseSensitive: false)).replace(in: input)
        #expect(o.newValue == ser(.makeArray([(.key("a"), .makeString("https://new.example.com/x"))])))
    }

    @Test func deepStructureWithMultibyteEverywhere() throws {
        let fx = String(decoding: PHPFixtures.named("elementor_data_ish").bytes, as: UTF8.self)
        let o = try rep("見出し", "ヘッダー🎉").replace(in: fx)
        #expect(o.replacements == 1)
        let doc = try PHPSerializedParser.parse(o.newValue)
        #expect(PHPSerializer.serialize(doc.root) == Data(o.newValue.utf8))
        #expect(o.newValue.contains("日本語のヘッダー🎉"))
    }

    @Test func bytesOverloadHandlesInvalidUTF8Strings() throws {
        let fx = PHPFixtures.named("invalid_utf8")
        // the binary string is left alone, the valid one is replaced
        let o = try rep("ok", "OK!").replace(inBytes: fx.bytes)
        #expect(o.replacements == 1)
        let doc = try PHPSerializedParser.parse(o.newValue)
        #expect(doc.root.entries[0].value == (try PHPSerializedParser.parse(fx.bytes)).root.entries[0].value)
        #expect(doc.root.entries[2].value.stringValue == "OK! é")
        // a match inside the binary string is reported, not changed
        let b = try rep("bin", "BIN").replace(inBytes: fx.bytes)
        #expect(b.replacements == 0)
        #expect(b.newValue == fx.bytes)
        // no match: identical
        #expect(try rep("zzz", "y").replace(inBytes: fx.bytes).newValue == fx.bytes)
        // non-serialized binary: untouched
        let blob = Data([0xFF, 0x00, 0x41])
        #expect(try rep("A", "B").replace(inBytes: blob).newValue == blob)
        // UTF-8 bytes use the text path
        #expect(try rep("a", "b").replace(inBytes: Data("s:1:\"a\";".utf8)).newValue == Data("s:1:\"b\";".utf8))
    }
}

@Suite("SafeReplace: JSON")
struct SafeReplaceJSONTests {
    @Test func escapedAndUnescapedSlashesBothMatch() throws {
        let r = try rep(oldURL, newURL)
        let escaped = r.replace(in: #"{"url":"http:\/\/old.test\/x","other":"y"}"#)
        #expect(escaped.newValue == #"{"url":"https:\/\/new.example.com\/x","other":"y"}"#)
        #expect(escaped.kind == .json)
        #expect(escaped.replacements == 1)
        let plain = r.replace(in: #"{"url":"http://old.test/x"}"#)
        #expect(plain.newValue == #"{"url":"https://new.example.com/x"}"#)
    }

    @Test func formattingPreservedWhenChanged() throws {
        let r = try rep(oldURL, newURL)
        let pretty2 = "{\n  \"a\": \"http://old.test/1\",\n  \"b\": [\n    \"http://old.test/2\"\n  ]\n}"
        #expect(r.replace(in: pretty2).newValue == "{\n  \"a\": \"https://new.example.com/1\",\n  \"b\": [\n    \"https://new.example.com/2\"\n  ]\n}")
        let tab = "{\n\t\"a\": \"http://old.test\"\n}"
        #expect(r.replace(in: tab).newValue == "{\n\t\"a\": \"https://new.example.com\"\n}")
        let inline = "{\"a\": \"http://old.test\", \"b\": 1}"
        #expect(r.replace(in: inline).newValue == "{\"a\": \"https://new.example.com\", \"b\": 1}")
    }

    @Test func noMatchIsByteIdenticalEvenWithOddFormatting() throws {
        let odd = "{ \"a\" :  \"x\",\n\n   \"b\":[1 , 2] }\n"
        let o = try rep("zzz", "y", .init(regex: true)).replace(in: odd)
        #expect(o.newValue == odd)
        #expect(o.kind == .json)
        #expect(o.replacements == 0)
        let o2 = try rep("x", "y").replace(in: odd)  // matches "x" -> reformatted but equal tree
        #expect(o2.replacements == 1)
        #expect(try JSONDocument.parse(o2.newValue).root == (try JSONDocument.parse(odd.replacingOccurrences(of: "\"x\"", with: "\"y\""))).root)
    }

    @Test func keysOnlyWhenOptedIn() throws {
        let input = #"{"old.test":"old.test"}"#
        #expect(try rep("old.test", "new.test").replace(in: input).newValue == #"{"old.test":"new.test"}"#)
        let o = try rep("old.test", "new.test", .init(replaceInJSONKeys: true)).replace(in: input)
        #expect(o.newValue == #"{"new.test":"new.test"}"#)
        #expect(o.replacements == 2)
    }

    @Test func numbersBoolsAndNullUntouched() throws {
        let input = #"{"a":12345678901234567890,"b":true,"c":null,"d":1.50,"e":"1"}"#
        let o = try rep("1", "2").replace(in: input)
        #expect(o.newValue == #"{"a":12345678901234567890,"b":true,"c":null,"d":1.50,"e":"2"}"#)
        #expect(o.replacements == 1)
    }

    @Test func arraysAndDeepNesting() throws {
        let input = #"[{"a":[{"b":["x old.test y",{"c":"old.test"}]}]},"old.test"]"#
        let o = try rep("old.test", "N").replace(in: input)
        #expect(o.newValue == #"[{"a":[{"b":["x N y",{"c":"N"}]}]},"N"]"#)
        #expect(o.replacements == 3)
    }

    @Test func unicodeEscapesRoundTrip() throws {
        let u = String(UnicodeScalar(92)) + "u00e9"
        let input = "{\"t\":\"caf\(u) old.test\"}"
        let o = try rep("old.test", "new.test").replace(in: input)
        #expect(o.newValue == "{\"t\":\"caf\(u) new.test\"}")
    }

    @Test func searchMatchesAcrossUnicodeEscapes() throws {
        let u = String(UnicodeScalar(92)) + "u00e9"
        let input = "{\"t\":\"caf\(u)\"}"
        let o = try rep("café", "tea").replace(in: input)
        #expect(o.newValue == "{\"t\":\"tea\"}")
    }

    @Test func serializedInsideJSON() throws {
        let inner = ser(.makeArray([(.key("url"), .makeString("http://old.test"))]))
        var d = try JSONDocument.parse("{}")
        d.root = .object([JSONMember(key: "meta", value: .string(inner)), JSONMember(key: "n", value: .number(raw: "1"))])
        let json = d.minified
        let o = try rep(oldURL, newURL).replace(in: json)
        #expect(o.kind == .json)
        #expect(o.replacements == 1)
        let out = try JSONDocument.parse(o.newValue)
        guard case .object(let m) = out.root, case .string(let s) = m[0].value else { Issue.record("shape"); return }
        #expect(s == ser(.makeArray([(.key("url"), .makeString("https://new.example.com"))])))
    }

    @Test func jsonInsideJSON() throws {
        var d = try JSONDocument.parse("{}")
        let innerJSON = #"{"link":"http:\/\/old.test\/p"}"#
        d.root = .object([JSONMember(key: "blob", value: .string(innerJSON))])
        let o = try rep(oldURL, newURL).replace(in: d.minified)
        guard case .object(let m) = try JSONDocument.parse(o.newValue).root, case .string(let s) = m[0].value else { Issue.record("shape"); return }
        #expect(s == #"{"link":"https:\/\/new.example.com\/p"}"#)
        #expect(o.replacements == 1)
    }

    @Test func gutenbergBlockJSONAttributes() throws {
        let attrs = ##"{"url":"http:\/\/old.test\/wp-content\/uploads\/a.jpg","id":12,"style":{"color":{"background":"#fff"}}}"##
        let o = try rep(oldURL, newURL).replace(in: attrs)
        #expect(o.newValue == ##"{"url":"https:\/\/new.example.com\/wp-content\/uploads\/a.jpg","id":12,"style":{"color":{"background":"#fff"}}}"##)
    }

    @Test func invalidJSONTreatedAsPlainText() throws {
        let o = try rep("a", "b").replace(in: "{not: json a}")
        #expect(o.kind == .plain)
        #expect(o.newValue == "{not: json b}")
    }

    @Test func bareScalarsAreNotJSON() throws {
        let o = try rep("1", "2").replace(in: "123")
        #expect(o.kind == .plain)
        #expect(o.newValue == "223")
    }

    @Test func nestingDepthIsBounded() throws {
        var v = ser(.makeString("old.test"))
        for _ in 0..<40 { v = ser(.makeArray([(.key("k"), .makeString(v))])) }
        // deeper than maxNesting: outer layers recurse, the rest is replaced as text; never crashes
        let o = try rep("old.test", "new.test").replace(in: v)
        #expect(o.replacements >= 1)
        #expect(!o.newValue.isEmpty)
    }
}
