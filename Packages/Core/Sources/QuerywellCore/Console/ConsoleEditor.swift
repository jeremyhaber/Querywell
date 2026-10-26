import Foundation

/// The editable input line(s) of the console: multi-line text with a caret, readline-style editing keys and
/// ↑/↓ history. Pure value types so the key handling is unit-tested without a view.
public struct ConsoleLineEditor: Hashable, Sendable {
    public private(set) var lines: [String] = [""]
    /// Caret position: line index and column in characters.
    public private(set) var line = 0
    public private(set) var column = 0

    public init() {}

    public init(text: String) {
        set(text: text)
    }

    public var text: String { lines.joined(separator: "\n") }
    public var isEmpty: Bool { lines.count == 1 && lines[0].isEmpty }
    public var isOnFirstLine: Bool { line == 0 }
    public var isOnLastLine: Bool { line == lines.count - 1 }

    public mutating func set(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty { lines = [""] }
        line = lines.count - 1
        column = lines[line].count
    }

    public mutating func clear() { set(text: "") }

    /// Inserts typed or pasted text at the caret; line breaks start new lines.
    public mutating func insert(_ string: String) {
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, part) in parts.enumerated() {
            if i > 0 { newline() }
            guard !part.isEmpty else { continue }
            var chars = Array(lines[line])
            chars.insert(contentsOf: Array(part), at: column)
            lines[line] = String(chars)
            column += part.count
        }
    }

    public mutating func newline() {
        let chars = Array(lines[line])
        lines[line] = String(chars[..<column])
        lines.insert(String(chars[column...]), at: line + 1)
        line += 1
        column = 0
    }

    public mutating func backspace() {
        if column > 0 {
            var chars = Array(lines[line])
            chars.remove(at: column - 1)
            lines[line] = String(chars)
            column -= 1
        } else if line > 0 {
            let joinAt = lines[line - 1].count
            lines[line - 1] += lines[line]
            lines.remove(at: line)
            line -= 1
            column = joinAt
        }
    }

    public mutating func deleteForward() {
        var chars = Array(lines[line])
        if column < chars.count {
            chars.remove(at: column)
            lines[line] = String(chars)
        } else if line < lines.count - 1 {
            lines[line] += lines[line + 1]
            lines.remove(at: line + 1)
        }
    }

    public mutating func moveLeft() {
        if column > 0 { column -= 1 } else if line > 0 { line -= 1; column = lines[line].count }
    }

    public mutating func moveRight() {
        if column < lines[line].count { column += 1 } else if line < lines.count - 1 { line += 1; column = 0 }
    }

    public mutating func moveToLineStart() { column = 0 }
    public mutating func moveToLineEnd() { column = lines[line].count }

    /// Moves up one line; false (and no move) on the first line.
    @discardableResult
    public mutating func moveUp() -> Bool {
        guard line > 0 else { return false }
        line -= 1
        column = min(column, lines[line].count)
        return true
    }

    /// Moves down one line; false (and no move) on the last line.
    @discardableResult
    public mutating func moveDown() -> Bool {
        guard line < lines.count - 1 else { return false }
        line += 1
        column = min(column, lines[line].count)
        return true
    }

    public mutating func moveTo(line newLine: Int, column newColumn: Int) {
        line = max(0, min(newLine, lines.count - 1))
        column = max(0, min(newColumn, lines[line].count))
    }

    /// ⌃K: deletes from the caret to the end of the line.
    public mutating func killToEnd() {
        lines[line] = String(Array(lines[line])[..<column])
    }

    /// ⌃U: deletes from the start of the line to the caret.
    public mutating func killToStart() {
        lines[line] = String(Array(lines[line])[column...])
        column = 0
    }

    /// ⌃W / ⌥⌫: deletes the word before the caret.
    public mutating func deleteWordBackward() {
        var chars = Array(lines[line])
        var i = column
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        chars.removeSubrange(i..<column)
        lines[line] = String(chars)
        column = i
    }

    /// Replaces a UTF-16 range of ``text`` and puts the caret after the replacement (Tab completion).
    public mutating func replace(utf16Range range: Range<Int>, with replacement: String) {
        let ns = text as NSString
        let lower = max(0, min(range.lowerBound, ns.length)), upper = max(lower, min(range.upperBound, ns.length))
        let updated = ns.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: replacement)
        let caret = lower + (replacement as NSString).length
        set(text: updated)
        moveTo(utf16Offset: caret)
    }

    /// Puts the caret at a UTF-16 offset into ``text``.
    public mutating func moveTo(utf16Offset offset: Int) {
        var remaining = offset
        for (i, l) in lines.enumerated() {
            let length = l.utf16.count
            if remaining <= length {
                var col = 0, used = 0
                for ch in l {
                    if used >= remaining { break }
                    used += ch.utf16.count
                    col += 1
                }
                line = i
                column = col
                return
            }
            remaining -= length + 1
        }
        line = lines.count - 1
        column = lines[line].count
    }

    /// The caret as a UTF-16 offset into ``text`` (what the completion engine wants).
    public var caretUTF16Offset: Int {
        var offset = 0
        for l in lines[..<line] { offset += l.utf16.count + 1 }
        return offset + String(Array(lines[line])[..<column]).utf16.count
    }
}

/// ↑/↓ walking through earlier statements, keeping what was being typed.
public struct ConsoleHistoryNavigator: Equatable, Sendable {
    /// Oldest first.
    public private(set) var entries: [String]
    private var position: Int?
    private var draft = ""

    public init(entries: [String] = []) {
        self.entries = entries
    }

    public mutating func replace(with newEntries: [String]) {
        entries = newEntries
        position = nil
    }

    /// Adds a statement that just ran (consecutive duplicates collapse).
    public mutating func record(_ sql: String) {
        let t = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        position = nil
        guard !t.isEmpty, entries.last != t else { return }
        entries.append(t)
    }

    /// The next older statement, given what is currently typed; nil when already at the oldest.
    public mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let p = position {
            guard p > 0 else { return nil }
            position = p - 1
        } else {
            draft = current
            position = entries.count - 1
        }
        return entries[position!]
    }

    /// The next newer statement, or the saved draft after the newest; nil when not browsing.
    public mutating func next() -> String? {
        guard let p = position else { return nil }
        if p + 1 < entries.count {
            position = p + 1
            return entries[p + 1]
        }
        position = nil
        return draft
    }

    public mutating func reset() { position = nil }
    public var isBrowsing: Bool { position != nil }
}
