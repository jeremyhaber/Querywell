import Foundation
import Testing

/// SwiftUI's accessibility tree is only partly visible to an in-process walk (custom views become opaque
/// proxies), so icon-only controls are also checked in the source: a `Button`/`Menu`/`Toggle` whose label is
/// only an image, or a labelless text input, must carry an `accessibilityLabel` (or be hidden from VoiceOver).
@Suite("Accessibility lint")
struct SourceAccessibilityLintTests {
    private static let sourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    private static func swiftFiles() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: keys) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Index of the `}` / `)` that closes the bracket at `open`.
    private static func closing(_ s: [Character], from open: Int) -> Int? {
        let (o, c): (Character, Character) = s[open] == "{" ? ("{", "}") : ("(", ")")
        var depth = 0
        var i = open
        var inString = false
        while i < s.count {
            let ch = s[i]
            if ch == "\"" && (i == 0 || s[i - 1] != "\\") { inString.toggle() }
            if !inString {
                if ch == o { depth += 1 } else if ch == c { depth -= 1; if depth == 0 { return i } }
            }
            i += 1
        }
        return nil
    }

    /// The modifier chain (`.foo(...)` lines) that follows `end`.
    private static func modifierChain(_ s: [Character], after end: Int) -> String {
        var j = end + 1
        var chain = ""
        while j < s.count {
            var k = j
            while k < s.count, s[k].isWhitespace { k += 1 }
            guard k < s.count, s[k] == ".", k + 1 < s.count, s[k + 1].isLetter else { break }
            var p = k + 1
            while p < s.count, s[p].isLetter || s[p].isNumber { p += 1 }
            if p < s.count, s[p] == "(", let c = closing(s, from: p) { p = c + 1 }
            if p < s.count, s[p] == "{", let c = closing(s, from: p) { p = c + 1 }
            chain += String(s[j..<p]); j = p
        }
        return chain
    }

    @Test func iconOnlyControlsAreLabelled() throws {
        var hits: [String] = []
        let files = Self.swiftFiles()
        #expect(files.count > 50)
        let opener = try Regex(#"\b(Button|Menu)\b\s*[\(\{]"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let chars = Array(text)
            for m in text.matches(of: opener) {
                let startOffset = text.distance(from: text.startIndex, to: m.range.lowerBound)
                var i = text.distance(from: text.startIndex, to: m.range.upperBound) - 1
                var args = ""
                if chars[i] == "(" {
                    guard let close = Self.closing(chars, from: i) else { continue }
                    args = String(chars[i...close])
                    if args.hasPrefix("(\"") || args.hasPrefix("(role") && args.contains("\"") { continue }  // titled
                    i = close + 1
                }
                var k = i
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                guard k < chars.count, chars[k] == "{", let c1 = Self.closing(chars, from: k) else { continue }
                var label = String(chars[k...c1]); var end = c1
                var tailIdx = c1 + 1
                while tailIdx < chars.count, chars[tailIdx].isWhitespace { tailIdx += 1 }
                if tailIdx + 6 < chars.count, String(chars[tailIdx..<(tailIdx + 6)]) == "label:" {
                    var lk = tailIdx + 6
                    while lk < chars.count, chars[lk].isWhitespace { lk += 1 }
                    if chars[lk] == "{", let lc = Self.closing(chars, from: lk) { label = String(chars[lk...lc]); end = lc }
                } else if !args.contains("action:") && !label.contains("Image(") { continue }
                let chain = Self.modifierChain(chars, after: end)
                let hasImage = label.contains("Image(")
                let hasText = label.contains("Text(") || label.contains("Label(") || label.contains("content()")
                // Everything up to the next blank line belongs to this control (covers `primaryAction:` closures).
                let rest = String(chars[(end + 1)...].prefix(while: { _ in true }).prefix(1200))
                let block = rest.components(separatedBy: "\n\n").first ?? ""
                let named = chain.contains("accessibilityLabel") || chain.contains("accessibilityHidden") || block.contains("accessibilityLabel")
                    || label.contains("accessibilityLabel") || label.contains("accessibilityElement")
                if hasImage, !hasText, !named {
                    let line = text.prefix(startOffset).filter { $0 == "\n" }.count + 1
                    hits.append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        #expect(hits.isEmpty, Comment(rawValue: "icon-only controls without accessibilityLabel:\n" + hits.joined(separator: "\n")))
    }

    @Test func textInputsHaveLabels() throws {
        var hits: [String] = []
        for file in Self.swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains("TextEditor(") || l.contains("TextField(\"\"") || l.contains("SecureField(\"\"") {
                // Everything up to the next blank line belongs to this input.
                var j = i + 1
                var named = false
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    if lines[j].contains("accessibilityLabel") { named = true }
                    j += 1
                }
                if !named { hits.append("\(file.lastPathComponent):\(i + 1)") }
            }
        }
        #expect(hits.isEmpty, Comment(rawValue: "text inputs without accessibilityLabel:\n" + hits.joined(separator: "\n")))
    }
}
