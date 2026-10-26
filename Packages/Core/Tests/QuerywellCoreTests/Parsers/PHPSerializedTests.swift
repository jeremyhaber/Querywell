import Foundation
import Testing
@testable import QuerywellCore

private func parse(_ s: String) throws -> PHPDocument { try PHPSerializedParser.parse(s) }
private func parse(_ d: Data) throws -> PHPDocument { try PHPSerializedParser.parse(d) }
private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

private func entry(_ v: PHPValue, _ key: String) -> PHPValue? {
    v.entries.first { $0.key == .key(key) }?.value
}

@Suite("PHP serialized: round trip")
struct PHPRoundTripTests {
    @Test("every PHP-generated fixture round-trips byte for byte", arguments: PHPFixtures.all.map(\.name))
    func fixtureRoundTrip(name: String) throws {
        let fx = PHPFixtures.named(name)
        let doc = try PHPSerializedParser.parse(fx.bytes)
        #expect(!doc.isModified)
        #expect(doc.serialize() == fx.bytes)
        // The serializer alone (no original bytes) must reproduce PHP's output too.
        var canonical = PHPSerializer.serialize(doc.root)
        canonical.append(contentsOf: fx.bytes.suffix(while: { $0 == 0x0A }))
        #expect(canonical == fx.bytes, "re-serialization differs for \(name)")
        // And a reparse of the canonical form is the same tree.
        #expect(try PHPSerializedParser.parse(canonical).root == doc.root)
    }

    @Test func fixtureCorpusSize() {
        #expect(PHPFixtures.all.count >= 40)
        #expect(Set(PHPFixtures.all.map(\.name)).count == PHPFixtures.all.count)
    }

    @Test func looksSerializedAgreesOnAllFixtures() {
        for fx in PHPFixtures.all {
            #expect(PHPSerialized.looksSerialized(fx.bytes), "\(fx.name)")
        }
    }
}

private extension Data {
    func suffix(while predicate: (UInt8) -> Bool) -> Data {
        var n = 0
        for b in reversed() { if predicate(b) { n += 1 } else { break } }
        return Data(suffix(n))
    }
}

@Suite("PHP serialized: parsing real-world samples")
struct PHPParsingTests {
    @Test func activePlugins() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("active_plugins").bytes).root
        let e = root.entries
        #expect(e.count == 5)
        #expect(e[0].key == .int(0))
        #expect(e[1].value.stringValue == "woocommerce/woocommerce.php")
    }

    @Test func userRolesNestedCaps() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("wp_user_roles").bytes).root
        let admin = try #require(entry(root, "administrator"))
        #expect(entry(admin, "name")?.stringValue == "Administrator")
        let caps = try #require(entry(admin, "capabilities"))
        #expect(entry(caps, "manage_options") == .bool(true))
        let author = try #require(entry(root, "author"))
        #expect(entry(try #require(entry(author, "capabilities")), "delete_posts") == .bool(false))
        #expect(root.entries.count == 6)
    }

    @Test func multiwidgetAndIntKeys() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("widget_text").bytes).root
        #expect(root.entries.map(\.key) == [.int(2), .int(3), .key("_multiwidget")])
        #expect(entry(root, "_multiwidget") == .int(1))
        let w2 = root.entries[0].value
        #expect(entry(w2, "title")?.stringValue == "Über uns")
        #expect(entry(w2, "text")?.stringValue?.contains("\"world\";") == true)
        #expect(entry(w2, "filter") == .bool(true))
    }

    @Test func cronNumericTimestampKeys() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("cron").bytes).root
        #expect(root.entries[0].key == .int(1735689600))
        #expect(root.entries.last?.key == .key("version"))
        let hooks = root.entries[1].value
        let myHook = try #require(entry(hooks, "my_hook"))
        let abc = try #require(entry(myHook, "abc"))
        #expect(entry(abc, "schedule") == .bool(false))
        #expect(entry(abc, "args")?.entries.count == 3)
    }

    @Test func themeModsHasObjectAndNegativeInt() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("theme_mods_twentytwentyfour").bytes).root
        #expect(entry(root, "custom_css_post_id") == .int(-1))
        guard case .object(let cls, let props) = try #require(entry(root, "header_image_data")) else {
            Issue.record("expected object")
            return
        }
        #expect(cls == "stdClass")
        #expect(props.count == 4)
    }

    @Test func rewriteRulesKeepRegexKeys() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("rewrite_rules").bytes).root
        #expect(root.entries[0].key == .key("^wp-json/?$"))
        #expect(root.entries[0].value.stringValue == "index.php?rest_route=/")
        #expect(root.entries.count == 5)
    }

    @Test func transientStdClass() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("transient_update_core").bytes).root
        guard case .object(let cls, let props) = root else {
            Issue.record("expected object")
            return
        }
        #expect(cls == "stdClass")
        #expect(props.map(\.key.displayName) == ["last_checked", "version_checked", "updates"])
        let updates = props[2].value.entries
        #expect(updates.count == 1)
        if case .object(let c2, _) = updates[0].value { #expect(c2 == "stdClass") } else { Issue.record("nested object") }
    }

    @Test func classWithProtectedAndPrivateProperties() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("woocommerce_product").bytes)
        guard case .object(let cls, let props) = doc.root else {
            Issue.record("expected object")
            return
        }
        #expect(cls == "WC_Product_Data")
        let keys = props.compactMap { $0.key.stringValue }
        #expect(keys == ["id", "\0*\0data", "\0WC_Product_Data\0cache", "dims"])
        // protected key length counts the NUL bytes: s:7:"\0*\0data"
        #expect(str(doc.originalBytes).contains("s:7:\"\0*\0data\""))
        let data = props[1].value
        #expect(entry(data, "name")?.stringValue == "Café Crème ☕")
    }

    @Test func elementorStyleNesting() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("elementor_data_ish").bytes).root
        let section = root.entries[0].value
        #expect(entry(section, "elType")?.stringValue == "section")
        let settings = try #require(entry(section, "settings"))
        #expect(entry(settings, "custom_css")?.stringValue == "selector { color: red; }\n/* \"quoted\"; */")
        let columns = try #require(entry(section, "elements"))
        let column = columns.entries[0].value
        let widgets = try #require(entry(column, "elements"))
        let widget = try #require(entry(widgets.entries[0].value, "settings"))
        #expect(entry(widget, "title")?.stringValue == "日本語の見出し")
    }

    @Test func multibyteLengthsAreBytes() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("multibyte").bytes)
        let cafe = try #require(entry(doc.root, "accents")?.stringValue)
        #expect(cafe == "Café Crème Brûlée Ünïcödé")
        #expect(cafe.count < cafe.utf8.count)
        #expect(str(doc.originalBytes).contains("s:\(cafe.utf8.count):\"\(cafe)\""))
        #expect(entry(doc.root, "emoji")?.stringValue == "😀🎉 family: 👨‍👩‍👧‍👦")
        #expect(entry(doc.root, "mixed")?.stringValue == "a€b𝄞c")
        // multibyte keys
        #expect(doc.root.entries.map(\.key).contains(.key("日本語キー")))
        #expect(doc.root.entries.map(\.key).contains(.key("ключ")))
    }

    @Test func trickyStrings() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("tricky_strings").bytes).root
        #expect(entry(root, "semi")?.stringValue == "a\";b")
        #expect(entry(root, "quoteEnd")?.stringValue == "ends with \"")
        #expect(entry(root, "fake")?.stringValue == "s:3:\"abc\";")
        #expect(entry(root, "fakeArr")?.stringValue == "a:1:{i:0;s:1:\"x\";}")
        #expect(entry(root, "nl")?.stringValue == "line1\nline2\r\nline3")
        #expect(entry(root, "empty")?.stringValue == "")
        #expect(entry(root, "nul")?.stringValue == "a\0b")
        #expect(entry(root, "brace")?.stringValue == "}{")
        #expect(entry(root, "bs")?.stringValue == "back\\slash")
    }

    @Test func nestedTwentyDeep() throws {
        var v = try PHPSerializedParser.parse(PHPFixtures.named("nested_20").bytes).root
        var depth = 0
        while let next = entry(v, "level\(19 - depth)") {
            v = next
            depth += 1
            if depth == 20 { break }
        }
        #expect(depth == 20)
        #expect(v.stringValue == "leaf")
    }

    @Test func emptyContainers() throws {
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("empty_array").bytes).root == .array([]))
        let root = try PHPSerializedParser.parse(PHPFixtures.named("empty_nested").bytes).root
        #expect(entry(root, "a") == .array([]))
        #expect(entry(root, "d") == .object(className: "stdClass", properties: []))
        #expect(entry(try #require(entry(root, "b")), "c") == .array([]))
    }

    @Test func negativeAndBoundaryInts() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("negative_ints").bytes).root
        #expect(root.entries.map(\.value) == [.int(-1), .int(Int64.min), .int(Int64.max), .int(0), .int(0)])
    }

    @Test func intKeysVersusNumericStringKeys() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("int_vs_string_keys").bytes).root
        let keys = root.entries.map(\.key)
        // PHP only normalises canonical decimal strings to ints: "05", "5a", " 5", "-0" stay strings, "-3" becomes int.
        #expect(keys == [.int(5), .key("05"), .key("5a"), .key(" 5"), .int(-3), .key("-0"), .int(Int64.max)])
        #expect(keys[0] != PHPArrayKey.key("5"))
    }

    @Test func scalarRoots() throws {
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_null").bytes).root == .null)
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_true").bytes).root == .bool(true))
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_false").bytes).root == .bool(false))
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_int").bytes).root == .int(12345))
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_string").bytes).root.stringValue == "Just a string é")
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("scalar_double").bytes).root == .double(raw: "3.14159"))
        #expect(try PHPSerializedParser.parse(PHPFixtures.named("site_url_option").bytes).root.stringValue == "http://old.test")
    }

    @Test func doublesKeepRawText() throws {
        let root = try PHPSerializedParser.parse(PHPFixtures.named("doubles").bytes).root
        let raws = root.entries.compactMap { e -> String? in
            if case .double(let r) = e.value { return r }
            return nil
        }
        #expect(raws.count == 20)
        #expect(raws[0] == "0.1")
        #expect(raws[1] == "1")
        #expect(raws[2] == "-0")
        #expect(raws[3] == "1.0E+25")
        #expect(raws[11] == "INF")
        #expect(raws[12] == "-INF")
        #expect(raws[13] == "NAN")
        let values = root.entries.map(\.value)
        #expect(values[0].doubleValue == 0.1)
        #expect(values[2].doubleValue?.sign == .minus)
        #expect(values[11].doubleValue == .infinity)
        #expect(values[12].doubleValue == -.infinity)
        #expect(values[13].doubleValue?.isNaN == true)
        #expect(values[3].doubleValue == 1e25)
    }

    @Test func referencesAreParsedAndPreserved() throws {
        let r = try PHPSerializedParser.parse(PHPFixtures.named("refs_R").bytes)
        #expect(r.root.entries.map(\.value) == [.int(1), .reference(kind: .reference, index: 2), .reference(kind: .reference, index: 2)])
        #expect(r.root.containsReferences)
        let o = try PHPSerializedParser.parse(PHPFixtures.named("refs_r").bytes)
        #expect(o.root.entries[1].value == .reference(kind: .object, index: 2))
        #expect(o.serialize() == PHPFixtures.named("refs_r").bytes)
    }

    @Test func customObjectIsOpaque() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("custom_object").bytes)
        guard case .customObject(let cls, let payload) = try #require(entry(doc.root, "legacy")) else {
            Issue.record("expected C:")
            return
        }
        #expect(cls == "Legacy")
        #expect(str(payload) == "x|payload é")
        #expect(payload.count == 12)  // bytes, not characters
        #expect(entry(doc.root, "after")?.stringValue == "é")
    }

    @Test func enumCase() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("enum_case").bytes)
        #expect(entry(doc.root, "suit") == .enumCase(className: "Suit", caseName: "Hearts"))
    }

    @Test func invalidUTF8StringsKeepBytes() throws {
        let fx = PHPFixtures.named("invalid_utf8")
        let doc = try PHPSerializedParser.parse(fx.bytes)
        let first = doc.root.entries[0].value
        #expect(first.stringValue == nil)
        guard case .string(let d) = first else { return }
        #expect(d == Data([0x62, 0x69, 0x6E, 0xFF, 0xFE, 0x80, 0x20, 0x64, 0x61, 0x74, 0x61]))
        #expect(doc.root.entries[2].value.stringValue == "ok é")
        #expect(doc.serialize() == fx.bytes)
        // keys too
        let k = try PHPSerializedParser.parse(PHPFixtures.named("invalid_utf8_key").bytes)
        #expect(k.root.entries[0].key.stringValue == nil)
        #expect(k.root.entries[0].key == .string(Data([0x6B, 0xFF])))
    }

    @Test func trailingWhitespaceIsToleratedAndPreserved() throws {
        let fx = PHPFixtures.named("whitespace_trailing")
        #expect(fx.bytes.last == 0x0A)
        let doc = try PHPSerializedParser.parse(fx.bytes)
        #expect(doc.serialize() == fx.bytes)
        var edited = doc
        try edited.setValue(.int(2), at: [.key(.key("a"))])
        #expect(str(edited.serialize()) == "a:1:{s:1:\"a\";i:2;}\n")
    }

    @Test func largeArrayParses() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("large_500").bytes)
        #expect(doc.root.entries.count == 500)
        #expect(entry(doc.root.entries[499].value, "title")?.stringValue == "Title 499 é")
    }

    @Test func singleStringRootsAndEscapesInClassNames() throws {
        let doc = try parse("O:11:\"Foo\\Bar\\Baz\":0:{}")
        #expect(doc.root == .object(className: "Foo\\Bar\\Baz", properties: []))
    }

    @Test func plusSignedIntAccepted() throws {
        let doc = try parse("i:+5;")
        #expect(doc.root == .int(5))
        #expect(doc.serialize() == Data("i:+5;".utf8))  // unmodified -> original bytes
    }
}

@Suite("PHP serialized: serializer")
struct PHPSerializerTests {
    @Test func scalars() {
        #expect(str(PHPSerializer.serialize(.null)) == "N;")
        #expect(str(PHPSerializer.serialize(.bool(true))) == "b:1;")
        #expect(str(PHPSerializer.serialize(.bool(false))) == "b:0;")
        #expect(str(PHPSerializer.serialize(.int(-42))) == "i:-42;")
        #expect(str(PHPSerializer.serialize(.makeString("héllo"))) == "s:6:\"héllo\";")
        #expect(str(PHPSerializer.serialize(.makeString(""))) == "s:0:\"\";")
    }

    @Test func utf8ByteLengths() {
        #expect(str(PHPSerializer.serialize(.makeString("日本"))) == "s:6:\"日本\";")
        #expect(str(PHPSerializer.serialize(.makeString("😀"))) == "s:4:\"😀\";")
        #expect(str(PHPSerializer.serialize(.makeString("e\u{301}"))) == "s:3:\"e\u{301}\";")  // combining mark: 1 grapheme, 3 bytes
        let v = PHPValue.makeArray([(.key("κλειδί"), .makeString("значение"))])
        #expect(str(PHPSerializer.serialize(v)) == "a:1:{s:12:\"κλειδί\";s:16:\"значение\";}")
    }

    @Test func containersCountsAndOrder() {
        let v = PHPValue.makeArray([(.int(3), .int(1)), (.key("a"), .null), (.int(0), .array([]))])
        #expect(str(PHPSerializer.serialize(v)) == "a:3:{i:3;i:1;s:1:\"a\";N;i:0;a:0:{}}")
        let o = PHPValue.object(className: "Ünï", properties: [PHPEntry(key: .key("p"), value: .bool(true))])
        #expect(str(PHPSerializer.serialize(o)) == "O:5:\"Ünï\":1:{s:1:\"p\";b:1;}")
    }

    @Test func customObjectAndEnumAndReference() {
        #expect(str(PHPSerializer.serialize(.customObject(className: "C", payload: Data("é".utf8)))) == "C:1:\"C\":2:{é}")
        #expect(str(PHPSerializer.serialize(.enumCase(className: "A\\B", caseName: "X"))) == "E:5:\"A\\B:X\";")
        #expect(str(PHPSerializer.serialize(.reference(kind: .reference, index: 3))) == "R:3;")
        #expect(str(PHPSerializer.serialize(.reference(kind: .object, index: 1))) == "r:1;")
    }

    @Test func binaryStringPreserved() {
        let d = Data([0x00, 0xFF, 0x22, 0x3B])
        let out = PHPSerializer.serialize(.string(d))
        #expect(out == Data("s:4:\"".utf8) + d + Data("\";".utf8))
    }

    @Test func doubleFormatAgainstRealPHP() {
        for (bits, php) in PHPDoubleOracle.table {
            let d = Double(bitPattern: bits)
            #expect(PHPDoubleFormat.format(d) == php, "bits \(String(bits, radix: 16)): expected \(php)")
            // and the PHP text parses back to the exact double
            #expect(PHPDoubleFormat.parse(php)?.bitPattern == bits)
        }
    }

    @Test func doubleSpecials() {
        #expect(PHPValue.makeDouble(.infinity) == .double(raw: "INF"))
        #expect(PHPValue.makeDouble(-.infinity) == .double(raw: "-INF"))
        #expect(PHPValue.makeDouble(.nan) == .double(raw: "NAN"))
        #expect(PHPValue.makeDouble(-0.0) == .double(raw: "-0"))
        #expect(PHPValue.makeDouble(0.0) == .double(raw: "0"))
        #expect(PHPValue.makeDouble(0.1) == .double(raw: "0.1"))
        #expect(PHPValue.makeDouble(1e25) == .double(raw: "1.0E+25"))
        #expect(str(PHPSerializer.serialize(.makeDouble(2.5))) == "d:2.5;")
    }

    @Test func doubleRawValidation() throws {
        #expect(throws: PHPSerializedError.self) { try parse("d:abc;") }
        #expect(throws: PHPSerializedError.self) { try parse("d:0x10;") }
        #expect(throws: PHPSerializedError.self) { try parse("d:;") }
        #expect(throws: PHPSerializedError.self) { try parse("d:1.5") }
        #expect((try parse("d:1.0E+25;")).root == .double(raw: "1.0E+25"))
        #expect((try parse("d:-INF;")).root == .double(raw: "-INF"))
        #expect((try parse("d:NAN;")).root == .double(raw: "NAN"))
    }
}

@Suite("PHP serialized: errors and offsets")
struct PHPErrorTests {
    private func fail(_ s: String, _ kind: PHPSerializedError.Kind, at offset: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try parse(s)
            Issue.record("expected failure for \(s)", sourceLocation: sourceLocation)
        } catch let e as PHPSerializedError {
            #expect(e.kind == kind, sourceLocation: sourceLocation)
            #expect(e.offset == offset, sourceLocation: sourceLocation)
        } catch {
            Issue.record("wrong error type", sourceLocation: sourceLocation)
        }
    }

    @Test func empty() { fail("", .unexpectedEnd, at: 0) }
    @Test func unknownTag() { fail("x:1;", .unsupportedType(0x78), at: 0) }
    @Test func trailingGarbage() { fail("N;junk", .trailingData, at: 2) }
    @Test func badBool() { fail("b:2;", .unexpectedByte(0x32), at: 2) }
    @Test func badInt() { fail("i:abc;", .invalidNumber, at: 2) }
    @Test func intOverflow() { fail("i:9223372036854775808;", .invalidNumber, at: 2) }
    @Test func missingSemicolon() { fail("i:5", .unexpectedEnd, at: 3) }
    @Test func truncatedArray() { fail("a:2:{i:0;i:1;", .unexpectedEnd, at: 13) }
    @Test func arrayCountTooLarge() { fail("a:2:{i:0;i:1;}", .unexpectedByte(0x7D), at: 13) }
    @Test func arrayCountTooSmall() { fail("a:1:{i:0;i:1;i:1;i:2;}", .unexpectedByte(0x69), at: 13) }
    @Test func negativeCount() { fail("a:-1:{}", .invalidLength, at: 2) }
    @Test func valueMissingAfterKey() { fail("a:1:{s:1:\"a\";}", .unsupportedType(0x7D), at: 13) }
    @Test func badKeyType() { fail("a:1:{N;N;}", .unexpectedByte(0x4E), at: 5) }
    @Test func tooDeep() {
        let s = String(repeating: "a:1:{i:0;", count: 300) + "N;" + String(repeating: "}", count: 300)
        fail(s, .tooDeeplyNested, at: 9 * 129)
    }
    @Test func invalidClassName() {
        let bytes = Data("O:2:\"".utf8) + Data([0xFF, 0xFE]) + Data("\":0:{}".utf8)
        do {
            _ = try PHPSerializedParser.parse(bytes)
            Issue.record("expected failure")
        } catch let e as PHPSerializedError {
            #expect(e.kind == .invalidClassName)
        } catch { Issue.record("wrong error") }
    }

    // The classic: a naive search/replace changed the text but not the s:N: length.
    @Test func lengthTooShort() {
        fail("a:1:{s:3:\"key\";s:3:\"hello\";}", .stringLengthMismatch(declared: 3, contentStart: 20), at: 23)
    }
    @Test func lengthTooLong() {
        fail("a:1:{i:0;s:5:\"abc\";}", .stringLengthMismatch(declared: 5, contentStart: 14), at: 19)
    }
    @Test func lengthBeyondInput() {
        fail("s:50:\"abc\";", .stringLengthMismatch(declared: 50, contentStart: 6), at: 11)
    }
    @Test func charCountInsteadOfByteCount() {
        // "é" counted as 1 character instead of 2 bytes
        fail("s:1:\"é\";", .stringLengthMismatch(declared: 1, contentStart: 5), at: 6)
    }
    @Test func errorDescriptionMentionsOffset() {
        do { _ = try parse("s:3:\"ab\";") } catch { #expect("\(error)".contains("byte")) }
    }
    @Test func customPayloadTruncated() { fail("C:1:\"A\":10:{abc}", .unexpectedEnd, at: 16) }
}

@Suite("PHP serialized: detection")
struct PHPDetectionTests {
    @Test func positives() {
        for s in ["N;", "b:1;", "i:5;", "d:0.5;", "s:3:\"abc\";", "a:0:{}", "O:8:\"stdClass\":0:{}", "i:-5;",
                  "d:INF;", "d:NAN;", "  a:0:{}  \n", "C:1:\"A\":0:{}", "E:3:\"A:B\";", "r:1;", "R:2;"] {
            #expect(PHPSerialized.looksSerialized(s), "\(s)")
        }
    }

    @Test func negatives() {
        for s in ["", "N", "hello", "a", "{\"a\":1}", "[1,2]", "s:abc", "a:1:{", "s:3:\"abc\"", "i:5", "x:1;", "i:;", "123", "true",
                  "https://example.com", "a:b:{}", "O:x"] {
            #expect(!PHPSerialized.looksSerialized(s), "\(s)")
        }
    }

    @Test func dataOverload() {
        #expect(PHPSerialized.looksSerialized(Data("a:0:{}".utf8)))
        #expect(!PHPSerialized.looksSerialized(Data([0xFF, 0xFE])))
    }
}

@Suite("PHP serialized: editing")
struct PHPEditTests {
    private func reparsed(_ d: PHPDocument) throws -> PHPDocument { try PHPSerializedParser.parse(d.serialize()) }

    @Test func unmodifiedKeepsOriginalBytes() throws {
        let doc = try PHPSerializedParser.parse(PHPFixtures.named("wp_user_roles").bytes)
        #expect(doc.serialize() == PHPFixtures.named("wp_user_roles").bytes)
        #expect(!doc.isModified)
    }

    @Test func setStringRecomputesLength() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("site_url_option").bytes)
        try doc.setValue(.makeString("https://nouveau.example.com/café"), at: [])
        #expect(doc.isModified)
        let out = str(doc.serialize())
        #expect(out == "s:\("https://nouveau.example.com/café".utf8.count):\"https://nouveau.example.com/café\";")
        #expect(try reparsed(doc).root.stringValue == "https://nouveau.example.com/café")
    }

    @Test func editNestedByKeyPath() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("widget_text").bytes)
        try doc.setValue(.makeString("Ünïcode 日本"), at: [.key(.int(2)), .key(.key("title"))])
        let r = try reparsed(doc)
        #expect(try r.value(at: [.key(.int(2)), .key(.key("title"))]).stringValue == "Ünïcode 日本")
        // rest untouched
        #expect(try r.value(at: [.key(.int(3))]) == (try PHPSerializedParser.parse(PHPFixtures.named("widget_text").bytes)).value(at: [.key(.int(3))]))
    }

    @Test func indexPaths() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("active_plugins").bytes)
        try doc.setValue(.makeString("hello-dolly/hello.php"), at: [.index(0)])
        #expect(try doc.value(at: [.index(0)]).stringValue == "hello-dolly/hello.php")
        #expect(throws: PHPEditError.invalidPath) { try doc.value(at: [.index(99)]) }
        #expect(throws: PHPEditError.invalidPath) { try doc.value(at: [.key(.key("nope"))]) }
        #expect(throws: PHPEditError.notContainer) { try doc.value(at: [.index(0), .index(0)]) }
    }

    @Test func insertAppendAndAt() throws {
        var doc = try PHPSerializedParser.parse("a:2:{i:0;s:1:\"a\";i:1;s:1:\"b\";}")
        try doc.insert(.makeString("c"), key: .int(2), into: [])
        try doc.insert(.makeString("z"), key: .int(9), into: [], at: 0)
        #expect(str(doc.serialize()) == "a:4:{i:9;s:1:\"z\";i:0;s:1:\"a\";i:1;s:1:\"b\";i:2;s:1:\"c\";}")
        #expect(throws: PHPEditError.duplicateKey) { try doc.insert(.null, key: .int(0), into: []) }
        #expect(throws: PHPEditError.indexOutOfRange) { try doc.insert(.null, key: .int(77), into: [], at: 50) }
    }

    @Test func insertIntoObjectRequiresStringKey() throws {
        var doc = try parse("O:8:\"stdClass\":1:{s:1:\"a\";i:1;}")
        try doc.insert(.makeString("é"), key: .key("b"), into: [])
        #expect(str(doc.serialize()) == "O:8:\"stdClass\":2:{s:1:\"a\";i:1;s:1:\"b\";s:2:\"é\";}")
        #expect(throws: PHPEditError.invalidKeyForObject) { try doc.insert(.null, key: .int(1), into: []) }
        #expect(throws: PHPEditError.duplicateKey) { try doc.insert(.null, key: .key("a"), into: []) }
    }

    @Test func insertIntoScalarFails() throws {
        var doc = try parse("i:1;")
        #expect(throws: PHPEditError.notContainer) { try doc.insert(.null, key: .int(0), into: []) }
    }

    @Test func removeUpdatesCount() throws {
        var doc = try PHPSerializedParser.parse("a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}")
        try doc.remove(at: [.index(1)])
        #expect(str(doc.serialize()) == "a:2:{i:0;i:1;i:2;i:3;}")
        try doc.remove(at: [.key(.int(0))])
        try doc.remove(at: [.index(0)])
        #expect(str(doc.serialize()) == "a:0:{}")
        #expect(throws: PHPEditError.invalidPath) { try doc.remove(at: []) }
    }

    @Test func removeNested() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("wp_user_roles").bytes)
        try doc.remove(at: [.key(.key("customer"))])
        try doc.remove(at: [.key(.key("administrator")), .key(.key("capabilities")), .key(.key("import"))])
        let r = try reparsed(doc)
        #expect(r.root.entries.count == 5)
        #expect(try r.value(at: [.key(.key("administrator")), .key(.key("capabilities"))]).entries.contains { $0.key == .key("import") } == false)
    }

    @Test func renameKey() throws {
        var doc = try parse("a:2:{s:3:\"old\";i:1;s:1:\"b\";i:2;}")
        try doc.renameKey(at: [.key(.key("old"))], to: .key("nöw"))
        #expect(str(doc.serialize()) == "a:2:{s:4:\"nöw\";i:1;s:1:\"b\";i:2;}")
        #expect(throws: PHPEditError.duplicateKey) { try doc.renameKey(at: [.index(0)], to: .key("b")) }
        try doc.renameKey(at: [.index(1)], to: .int(7))
        #expect(str(doc.serialize()).hasSuffix("i:7;i:2;}"))
        // renaming to its own name is allowed
        try doc.renameKey(at: [.index(0)], to: .key("nöw"))
    }

    @Test func renameObjectPropertyToIntRejected() throws {
        var doc = try parse("O:8:\"stdClass\":1:{s:1:\"a\";i:1;}")
        #expect(throws: PHPEditError.invalidKeyForObject) { try doc.renameKey(at: [.index(0)], to: .int(1)) }
        try doc.renameKey(at: [.index(0)], to: .key("renamed"))
        #expect(str(doc.serialize()) == "O:8:\"stdClass\":1:{s:7:\"renamed\";i:1;}")
    }

    @Test func classNameLengthStaysCorrectOnObjectEdit() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("woocommerce_product").bytes)
        try doc.setValue(.int(7), at: [.key(.key("id"))])
        let r = try reparsed(doc)
        #expect(try r.value(at: [.key(.key("id"))]) == .int(7))
        // mangled keys with NULs survive
        #expect(r.root.entries[1].key.stringValue == "\0*\0data")
        #expect(str(doc.serialize()).hasPrefix("O:15:\"WC_Product_Data\":4:{s:2:\"id\";i:7;"))
    }

    @Test func customObjectReadOnly() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("custom_object").bytes)
        #expect(throws: PHPEditError.readOnly) { try doc.setValue(.null, at: [.key(.key("legacy"))]) }
        #expect(throws: PHPEditError.readOnly) { try doc.changeType(at: [.key(.key("legacy"))], to: .string) }
        // siblings are still editable and the payload is copied through byte-exactly
        try doc.setValue(.int(2), at: [.key(.key("before"))])
        #expect(str(doc.serialize()).contains("C:6:\"Legacy\":12:{x|payload é}"))
        #expect(try reparsed(doc).root.entries[1].value == (try PHPSerializedParser.parse(PHPFixtures.named("custom_object").bytes)).root.entries[1].value)
        // the custom node can be removed as a whole (no references involved)
        try doc.remove(at: [.key(.key("legacy"))])
        #expect(try reparsed(doc).root.entries.count == 2)
    }

    @Test func enumReadOnly() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("enum_case").bytes)
        #expect(throws: PHPEditError.readOnly) { try doc.setValue(.null, at: [.index(0)]) }
    }

    @Test func referencesReadOnlyAndStructuralEditsRefused() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("refs_R").bytes)
        #expect(throws: PHPEditError.readOnly) { try doc.setValue(.int(5), at: [.index(1)]) }
        #expect(throws: PHPEditError.referencesWouldBreak) { try doc.remove(at: [.index(0)]) }
        #expect(throws: PHPEditError.referencesWouldBreak) { try doc.insert(.null, key: .int(10), into: []) }
        #expect(throws: PHPEditError.referencesWouldBreak) { try doc.setValue(.array([]), at: [.index(0)]) }
        // scalar-for-scalar replacement keeps numbering, so it is allowed
        try doc.setValue(.int(99), at: [.index(0)])
        #expect(str(doc.serialize()) == "a:3:{i:0;i:99;i:1;R:2;s:1:\"k\";R:2;}")
        // inserting a reference is refused too
        var plain = try parse("a:0:{}")
        #expect(throws: PHPEditError.referencesWouldBreak) { try plain.insert(.reference(kind: .reference, index: 1), key: .int(0), into: []) }
    }

    @Test func revertingEditsMeansUnmodified() throws {
        var doc = try parse("a:1:{i:0;s:1:\"a\";}")
        try doc.setValue(.makeString("b"), at: [.index(0)])
        #expect(doc.isModified)
        try doc.setValue(.makeString("a"), at: [.index(0)])
        #expect(!doc.isModified)
        #expect(doc.serialize() == Data("a:1:{i:0;s:1:\"a\";}".utf8))
    }

    @Test func typeChanges() throws {
        var doc = try parse("a:5:{i:0;s:2:\"12\";i:1;i:0;i:2;N;i:3;s:3:\"abc\";i:4;d:2.5;}")
        try doc.changeType(at: [.index(0)], to: .int)
        #expect(try doc.value(at: [.index(0)]) == .int(12))
        try doc.changeType(at: [.index(1)], to: .bool)
        #expect(try doc.value(at: [.index(1)]) == .bool(false))
        try doc.changeType(at: [.index(2)], to: .string)
        #expect(try doc.value(at: [.index(2)]) == .string(Data()))
        try doc.changeType(at: [.index(3)], to: .array)
        #expect(try doc.value(at: [.index(3)]) == .array([PHPEntry(key: .int(0), value: .makeString("abc"))]))
        try doc.changeType(at: [.index(4)], to: .int)
        #expect(try doc.value(at: [.index(4)]) == .int(2))
        try doc.changeType(at: [.index(4)], to: .double)
        #expect(try doc.value(at: [.index(4)]) == .double(raw: "2"))
        try doc.changeType(at: [.index(4)], to: .null)
        #expect(try doc.value(at: [.index(4)]) == .null)
        #expect(try reparsed(doc).root == doc.root)
    }

    @Test func arrayToObjectAndBack() throws {
        var doc = try parse("a:2:{i:0;i:1;s:1:\"k\";i:2;}")
        try doc.changeType(at: [], to: .object)
        #expect(str(doc.serialize()) == "O:8:\"stdClass\":2:{s:1:\"0\";i:1;s:1:\"k\";i:2;}")
        try doc.changeType(at: [], to: .array)
        #expect(try doc.value(at: []).entries.count == 2)
    }

    @Test func stringConversionsFromNumbers() throws {
        #expect(try PHPValue.int(5).converted(to: .string) == .makeString("5"))
        #expect(try PHPValue.bool(true).converted(to: .string) == .makeString("1"))
        #expect(try PHPValue.bool(false).converted(to: .string) == .makeString(""))
        #expect(try PHPValue.double(raw: "1.5").converted(to: .string) == .makeString("1.5"))
        #expect(try PHPValue.makeString("12abc").converted(to: .int) == .int(12))
        #expect(try PHPValue.makeString("  7 ").converted(to: .int) == .int(7))
        #expect(try PHPValue.makeString("0").converted(to: .bool) == .bool(false))
        #expect(try PHPValue.makeString("0.0").converted(to: .bool) == .bool(true))
        #expect(throws: PHPEditError.unsupportedConversion) { try PHPValue.array([]).converted(to: .string) }
    }

    @Test func editThenSerializeMatchesFreshBuildForWholeCorpus() throws {
        // For every fixture without references/custom objects: touch the root via setValue(root) and
        // check canonical output equals the original (proves serialize() path is lossless).
        for fx in PHPFixtures.all {
            var doc = try PHPSerializedParser.parse(fx.bytes)
            if doc.containsReferences { continue }
            try? doc.setValue(doc.root, at: [])  // no-op edit
            #expect(doc.serialize() == fx.bytes, "\(fx.name)")
        }
    }

    @Test func editMultibyteInsideDeepStructureCorpus() throws {
        var doc = try PHPSerializedParser.parse(PHPFixtures.named("elementor_data_ish").bytes)
        let path: [PHPPathStep] = [.index(0), .key(.key("elements")), .index(0), .key(.key("elements")), .index(0), .key(.key("settings")), .key(.key("title"))]
        try doc.setValue(.makeString("Titre accentué 🎉"), at: path)
        let r = try reparsed(doc)
        #expect(try r.value(at: path).stringValue == "Titre accentué 🎉")
        #expect(str(doc.serialize()).contains("s:\("Titre accentué 🎉".utf8.count):\"Titre accentué 🎉\""))
    }

    @Test func newDocumentFromValue() {
        let doc = PHPDocument(root: .makeArray([(.key("a"), .int(1))]))
        #expect(!doc.isModified)
        #expect(str(doc.serialize()) == "a:1:{s:1:\"a\";i:1;}")
    }
}

@Suite("PHP serialized: repair")
struct PHPRepairTests {
    private func serialized(_ v: PHPValue) -> String { str(PHPSerializer.serialize(v)) }

    @Test func alreadyValidIsReturnedUnchanged() throws {
        let d = Data("a:1:{s:1:\"a\";s:1:\"b\";}".utf8)
        #expect(PHPSerializedRepair.repairLengths(d) == d)
    }

    @Test func domainMigrationWithNaiveReplace() throws {
        let good = serialized(.makeArray([(.key("siteurl"), .makeString("http://old.test")), (.key("home"), .makeString("http://old.test/blog"))]))
        let naive = good.replacingOccurrences(of: "http://old.test", with: "https://new.example.com")
        #expect(throws: PHPSerializedError.self) { try parse(naive) }
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        let expected = serialized(.makeArray([(.key("siteurl"), .makeString("https://new.example.com")), (.key("home"), .makeString("https://new.example.com/blog"))]))
        #expect(str(fixed) == expected)
        #expect(throws: Never.self) { try PHPSerializedParser.parse(fixed) }
    }

    @Test func replacementShorterThanOriginal() throws {
        let naive = "a:1:{s:1:\"u\";s:23:\"https://new.example.com\";}".replacingOccurrences(of: "https://new.example.com", with: "http://a.b")
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        #expect(str(fixed) == "a:1:{s:1:\"u\";s:10:\"http://a.b\";}")
    }

    @Test func multibyteReplacementCountsBytes() throws {
        let naive = "a:1:{s:1:\"t\";s:3:\"abc\";}".replacingOccurrences(of: "abc", with: "日本語 café")
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        #expect(str(fixed) == "a:1:{s:1:\"t\";s:\("日本語 café".utf8.count):\"日本語 café\";}")
    }

    @Test func characterCountedLengthsAreFixed() throws {
        // WordPress export tools that counted characters instead of bytes
        let naive = "a:1:{s:4:\"café\";s:5:\"日本語\";}"
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        #expect(str(fixed) == "a:1:{s:5:\"café\";s:9:\"日本語\";}")
    }

    @Test func fixesKeysAndNestedValues() throws {
        let naive = "a:2:{s:3:\"old.test\";a:1:{i:0;s:2:\"http://old.test/x\";}s:1:\"z\";s:1:\"é\";}"
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        #expect(str(fixed) == "a:2:{s:8:\"old.test\";a:1:{i:0;s:17:\"http://old.test/x\";}s:1:\"z\";s:2:\"é\";}")
    }

    @Test func stringContainingTokenLookalikeIsNotMisrepaired() {
        // the content itself contains `";i:0;` -> the first plausible end is wrong, the final parse fails, no guess is returned
        let naive = "a:1:{s:1:\"k\";s:2:\"x\";i:0;y\";}"
        #expect(PHPSerializedRepair.repairLengths(Data(naive.utf8)) == nil)
    }

    @Test func stringContainingQuoteSemicolonNotFollowedByTokenIsFine() throws {
        // `";b` is not a plausible continuation, so the only real terminator is found
        let naive = "a:1:{s:1:\"k\";s:2:\"a\";b and more\";}"
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)))
        #expect(str(fixed) == "a:1:{s:1:\"k\";s:15:\"a\";b and more\";}".replacingOccurrences(of: "s:15", with: "s:\("a\";b and more".utf8.count)"))
        #expect(try parse(fixed).root.entries[0].value.stringValue == "a\";b and more")
    }

    @Test func notRepairableCases() {
        for s in ["", "garbage", "a:2:{i:0;i:1;}", "a:1:{s:1:\"a\";", "s:3:\"abc", "i:abc;", "N;x"] {
            #expect(PHPSerializedRepair.repairLengths(Data(s.utf8)) == nil, "\(s)")
        }
    }

    @Test func wrongArrayCountIsNotFixed() {
        // only string lengths are repaired
        #expect(PHPSerializedRepair.repairLengths(Data("a:5:{i:0;s:3:\"abcd\";}".utf8)) == nil)
    }

    @Test func repairsLargeCorpusSamples() throws {
        for name in ["widget_text", "multibyte", "elementor_data_ish", "theme_mods_twentytwentyfour", "large_500"] {
            let good = str(PHPFixtures.named(name).bytes)
            let naive = good.replacingOccurrences(of: "http://old.test", with: "https://production.example.org")
                .replacingOccurrences(of: "é", with: "ee")
                .replacingOccurrences(of: "Ü", with: "Ue")
            guard naive != good else { continue }
            let fixed = try #require(PHPSerializedRepair.repairLengths(Data(naive.utf8)), "\(name)")
            let doc = try PHPSerializedParser.parse(fixed)
            // The repaired data must equal canonical serialization of its own tree
            #expect(PHPSerializer.serialize(doc.root) == fixed, "\(name)")
        }
    }

    @Test func trailingWhitespaceSurvivesRepair() throws {
        let fixed = try #require(PHPSerializedRepair.repairLengths(Data("s:1:\"abc\";\n".utf8)))
        #expect(str(fixed) == "s:3:\"abc\";\n")
    }
}
