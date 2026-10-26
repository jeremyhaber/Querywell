import Foundation
import Testing
@testable import Querywell

@Suite("Editor text transforms")
struct EditorTransformsTests {
    private func apply(_ text: String, _ edit: EditorTransforms.Edit) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func toggleCommentAddsAndRemovesMarkers() {
        let text = "SELECT 1\n  FROM t\n\nWHERE x"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let commented = EditorTransforms.toggleComment(in: text, selection: all)
        #expect(apply(text, commented) == "-- SELECT 1\n--   FROM t\n\n-- WHERE x")
        let back = apply(text, commented)
        let uncommented = EditorTransforms.toggleComment(in: back, selection: NSRange(location: 0, length: (back as NSString).length))
        #expect(apply(back, uncommented) == text)
        // One line, caret only.
        let one = EditorTransforms.toggleComment(in: text, selection: NSRange(location: 3, length: 0))
        #expect(apply(text, one).hasPrefix("-- SELECT 1\n  FROM t"))
        // Mixed lines get commented, not uncommented.
        let mixed = "-- a\nb"
        let m = EditorTransforms.toggleComment(in: mixed, selection: NSRange(location: 0, length: 6))
        #expect(apply(mixed, m) == "-- -- a\n-- b")
    }

    @Test func indentAndOutdentCoverTouchedLines() {
        let text = "a\nb\nc"
        let sel = NSRange(location: 0, length: 3)  // "a\nb"
        let indented = EditorTransforms.indent(in: text, selection: sel)
        #expect(apply(text, indented) == "    a\n    b\nc")
        let back = EditorTransforms.outdent(in: apply(text, indented), selection: indented.selection)
        #expect(apply(apply(text, indented), back) == text)
        #expect(EditorTransforms.isMultiline(text, selection: sel))
        #expect(!EditorTransforms.isMultiline(text, selection: NSRange(location: 0, length: 1)))
        #expect(!EditorTransforms.isMultiline(text, selection: NSRange(location: 0, length: 2)), "a trailing newline alone isn't multi-line")
        // Outdent never eats text.
        let o = EditorTransforms.outdent(in: "  x\n\ty", selection: NSRange(location: 0, length: 5))
        #expect(apply("  x\n\ty", o) == "x\ny")
    }

    @Test func newlineKeepsIndentAndOpensAfterParen() {
        #expect(EditorTransforms.newlineIndent(in: "    SELECT 1", caret: 12) == "    ")
        #expect(EditorTransforms.newlineIndent(in: "SELECT (", caret: 8) == "    ")
        #expect(EditorTransforms.newlineIndent(in: "a\n  b", caret: 5) == "  ")
        #expect(EditorTransforms.newlineIndent(in: "  x", caret: 1) == " ", "only the part before the caret")
    }

    @Test func bracketMatchingSkipsStringsAndComments() {
        let text = "SELECT f(a, (b)) -- )\nFROM t WHERE s = ')'"
        let strings = [NSRange(location: 17, length: 4), NSRange(location: 39, length: 3)].map { $0.location..<($0.location + $0.length) }
        let pair = EditorTransforms.matchingBrackets(in: text, caret: 9, skipping: strings)  // after "f("
        #expect(pair?.0 == NSRange(location: 8, length: 1))
        #expect(pair?.1 == NSRange(location: 15, length: 1))
        let inner = EditorTransforms.matchingBrackets(in: text, caret: 13, skipping: strings)
        #expect(inner?.0 == NSRange(location: 12, length: 1) && inner?.1 == NSRange(location: 14, length: 1))
        #expect(EditorTransforms.matchingBrackets(in: "SELECT (1", caret: 8) == nil)
        #expect(EditorTransforms.matchingBrackets(in: "no brackets", caret: 3) == nil)
    }

    @Test func completionTriggers() {
        #expect(EditorTransforms.triggersCompletion(inserted: "a"))
        #expect(EditorTransforms.triggersCompletion(inserted: "."))
        #expect(EditorTransforms.triggersCompletion(inserted: "_"))
        #expect(!EditorTransforms.triggersCompletion(inserted: " "))
        #expect(!EditorTransforms.triggersCompletion(inserted: "("))
        #expect(!EditorTransforms.triggersCompletion(inserted: "ab"), "pastes don't pop the list")
    }
}
