import AppKit
import SwiftUI

// A plain monospaced NSTextView with light JSON colouring, used by the value editor's Raw panes and
// the Text mode. (The Phase 5 SQL editor is a separate, SQL-specific view.)

/// Syntax colours for the editors; same family as the SQL highlighter tokens in design/DESIGN_NOTES.md.
enum EditorSyntaxColors {
    static var key: NSColor { .dynamic(light: 0x0F6E8C, dark: 0x6CC4E0) }
    static var string: NSColor { .dynamic(light: 0x1F7A4D, dark: 0x7DD6A0) }
    static var number: NSColor { .dynamic(light: 0xB05A00, dark: 0xF0B060) }
    static var literal: NSColor { .dynamic(light: 0x6A3FC2, dark: 0xA98BF0) }
    static var punctuation: NSColor { ThemeNS.textSecondary }
}

/// Colours a JSON text. Tolerant: broken input is still coloured token by token.
enum JSONSyntaxHighlighter {
    /// Above this many UTF-16 units colouring is skipped (typing stays instant on huge documents).
    static let limit = 400_000

    enum Role { case key, string, number, literal, punctuation }

    /// (range, role) runs for `text`.
    static func runs(in text: String) -> [(NSRange, Role)] {
        let u = Array(text.utf16)
        guard u.count <= limit else { return [] }
        var out: [(NSRange, Role)] = []
        var i = 0
        let n = u.count
        func isWS(_ c: UInt16) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }
        while i < n {
            let c = u[i]
            switch c {
            case 0x22:  // "
                var j = i + 1
                while j < n, u[j] != 0x22 {
                    if u[j] == 0x5C { j += 1 }
                    j += 1
                }
                let end = min(j + 1, n)
                var k = end
                while k < n, isWS(u[k]) { k += 1 }
                let isKey = k < n && u[k] == 0x3A
                out.append((NSRange(location: i, length: end - i), isKey ? .key : .string))
                i = end
            case 0x2D, 0x30...0x39:
                var j = i + 1
                while j < n, (u[j] >= 0x30 && u[j] <= 0x39) || u[j] == 0x2E || u[j] == 0x65 || u[j] == 0x45 || u[j] == 0x2B || u[j] == 0x2D { j += 1 }
                out.append((NSRange(location: i, length: j - i), .number))
                i = j
            case 0x74, 0x66, 0x6E:  // t f n
                var j = i + 1
                while j < n, u[j] >= 0x61 && u[j] <= 0x7A { j += 1 }
                out.append((NSRange(location: i, length: j - i), .literal))
                i = j
            case 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A:
                out.append((NSRange(location: i, length: 1), .punctuation))
                i += 1
            default:
                i += 1
            }
        }
        return out
    }

    @MainActor
    static func apply(to storage: NSTextStorage, font: NSFont, errorRange: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: ThemeNS.text], range: full)
        for (range, role) in runs(in: storage.string) {
            let color: NSColor
            switch role {
            case .key: color = EditorSyntaxColors.key
            case .string: color = EditorSyntaxColors.string
            case .number: color = EditorSyntaxColors.number
            case .literal: color = EditorSyntaxColors.literal
            case .punctuation: color = EditorSyntaxColors.punctuation
            }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        if let errorRange, NSMaxRange(errorRange) <= storage.length {
            storage.addAttributes([
                .backgroundColor: ThemeNS.dangerBackground,
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: ThemeNS.dangerText,
            ], range: errorRange)
        }
        storage.endEditing()
    }
}

/// Asks the text view to select and reveal a UTF-8 byte offset.
struct TextJump: Equatable {
    var id = UUID()
    var utf8Offset: Int
}

struct CodeTextView: NSViewRepresentable {
    enum Syntax { case none, json }

    @Binding var text: String
    var syntax: Syntax = .none
    var isEditable = true
    var wraps = false
    /// UTF-8 offset of the character to mark as the error position.
    var errorOffset: Int?
    var jump: TextJump?
    var accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wraps
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ThemeNS.background
        scroll.borderType = .noBorder

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = ThemeNS.background
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.font = Coordinator.font
        textView.insertionPointColor = ThemeNS.accent
        textView.setAccessibilityLabel(accessibilityLabel)
        configureWrapping(textView, in: scroll)
        textView.string = text
        context.coordinator.highlight(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.setAccessibilityLabel(accessibilityLabel)
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        context.coordinator.highlight(textView)
        if let jump, jump.id != context.coordinator.handledJump {
            context.coordinator.handledJump = jump.id
            let u16 = Self.utf16Offset(ofUTF8: jump.utf8Offset, in: textView.string)
            let range = NSRange(location: u16, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func configureWrapping(_ textView: NSTextView, in scroll: NSScrollView) {
        if wraps {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isVerticallyResizable = true
        textView.autoresizingMask = wraps ? [.width] : []
    }

    static func utf16Offset(ofUTF8 offset: Int, in string: String) -> Int {
        let utf8 = string.utf8
        guard offset <= utf8.count, let idx = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex) else {
            return string.utf16.count
        }
        return string.utf16.distance(from: string.utf16.startIndex, to: idx)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var parent: CodeTextView
        var isUpdating = false
        var handledJump: UUID?
        private var lastKey = ""

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            var errorRange: NSRange?
            if let offset = parent.errorOffset {
                let start = CodeTextView.utf16Offset(ofUTF8: offset, in: textView.string)
                let length = (textView.string as NSString).length
                if length > 0 { errorRange = NSRange(location: min(start, length - 1), length: 1) }
            }
            // Skip work when neither the text, the syntax nor the error position changed.
            let key = "\(parent.syntax == .json)|\(errorRange.map { "\($0.location)" } ?? "-")|\(storage.length)|\(textView.string.hashValue)"
            guard key != lastKey else { return }
            lastKey = key
            switch parent.syntax {
            case .json:
                JSONSyntaxHighlighter.apply(to: storage, font: Self.font, errorRange: errorRange)
            case .none:
                storage.beginEditing()
                storage.setAttributes([.font: Self.font, .foregroundColor: ThemeNS.text], range: NSRange(location: 0, length: storage.length))
                if let errorRange, NSMaxRange(errorRange) <= storage.length {
                    storage.addAttributes([
                        .backgroundColor: ThemeNS.dangerBackground,
                        .underlineStyle: NSUnderlineStyle.thick.rawValue,
                        .underlineColor: ThemeNS.dangerText,
                    ], range: errorRange)
                }
                storage.endEditing()
            }
        }
    }
}

/// Classic `offset  hex bytes  |ascii|` dump for data that is not valid UTF-8.
enum HexDump {
    static func string(_ data: Data, limit: Int = 64 * 1024) -> String {
        let bytes = Array(data.prefix(limit))
        var lines: [String] = []
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i..<min(i + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", i) + padded + "  |" + ascii + "|")
            i += 16
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }
}
