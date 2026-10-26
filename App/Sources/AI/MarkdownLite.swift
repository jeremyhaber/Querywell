import AppKit
import Foundation
import QuerywellCore
import SwiftUI

/// The small subset of Markdown the assistant's answers use: paragraphs, headings, bullet lists and fenced code.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    /// `isOpen`: the closing fence hasn't arrived yet (still streaming).
    case code(language: String, text: String, isOpen: Bool)
}

enum MarkdownLite {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushBullets()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { closed = true; break }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n"), isOpen: !closed))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); flushBullets()
            } else if trimmed.hasPrefix("#") {
                flushParagraph(); flushBullets()
                blocks.append(.heading(String(trimmed.drop(while: { $0 == "#" || $0 == " " }))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed.index(after: dot) < trimmed.endIndex, trimmed[trimmed.index(after: dot)] == " " {
                flushParagraph()
                bullets.append(String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
            } else {
                flushBullets()
                paragraph.append(trimmed)
            }
            i += 1
        }
        flushParagraph(); flushBullets()
        return blocks
    }

    /// Inline Markdown (`code`, **bold**, *italic*) as an attributed string; plain text if it doesn't parse.
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

/// SQL as an attributed string coloured like the editor.
enum SQLAttributed {
    @MainActor
    static func make(_ sql: String, dialect: SQLDialect, fontSize: CGFloat = 12) -> AttributedString {
        let base = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let medium = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let out = NSMutableAttributedString(string: sql, attributes: [.font: base, .foregroundColor: ThemeNS.text])
        for span in SQLHighlighter(dialect: dialect).highlight(sql) {
            let color: NSColor
            var font = base
            switch span.style {
            case .keyword: color = ThemeNS.syntaxKeyword; font = medium
            case .function: color = ThemeNS.syntaxFunction
            case .string: color = ThemeNS.syntaxString
            case .number: color = ThemeNS.syntaxNumber
            case .comment: color = ThemeNS.syntaxComment
            case .variable: color = ThemeNS.syntaxVariable
            default: continue
            }
            out.addAttributes([.foregroundColor: color, .font: font], range: span.nsRange)
        }
        return (try? AttributedString(out, including: \.appKit)) ?? AttributedString(sql)
    }
}
