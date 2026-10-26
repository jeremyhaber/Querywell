import Foundation

/// What Tab does with a completion result at the console, like a shell: a single match is inserted, several
/// matches insert their common prefix, and when nothing more can be added the candidates are listed.
public struct ConsoleCompletionPlan: Equatable, Sendable {
    /// UTF-16 range of the input to replace and the text to put there; nil when nothing changes.
    public var replacement: (range: Range<Int>, text: String)?
    /// Candidates to print under the prompt (ambiguous matches that gained no more text).
    public var candidates: [String]

    public static func == (a: Self, b: Self) -> Bool {
        a.candidates == b.candidates && a.replacement?.range == b.replacement?.range && a.replacement?.text == b.replacement?.text
    }

    public static func make(for result: CompletionResult, in text: String) -> ConsoleCompletionPlan {
        let items = result.items
        guard result.context != .suppressed, !items.isEmpty else { return ConsoleCompletionPlan(replacement: nil, candidates: []) }
        let ns = text as NSString
        let current = ns.substring(with: NSRange(location: result.range.lowerBound, length: result.range.count))

        if items.count == 1 {
            let insert = items[0].insertText
            // A lone match is finished with a space unless it is a qualifier (`wp_posts.` keeps typing).
            let tail = insert.hasSuffix(".") ? "" : " "
            return ConsoleCompletionPlan(replacement: (result.range, insert + tail), candidates: [])
        }
        let common = commonPrefix(items.map(\.insertText))
        if common.count > current.count, common.lowercased().hasPrefix(current.lowercased()) {
            return ConsoleCompletionPlan(replacement: (result.range, common), candidates: [])
        }
        var seen = Set<String>()
        let labels = items.map(\.label).filter { seen.insert($0).inserted }
        return ConsoleCompletionPlan(replacement: nil, candidates: labels)
    }

    /// Longest common prefix, compared case-insensitively, taken from the first string's spelling.
    static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first.map(Array.init) else { return "" }
        for s in strings.dropFirst() {
            let other = Array(s)
            var n = 0
            while n < prefix.count, n < other.count, String(prefix[n]).lowercased() == String(other[n]).lowercased() { n += 1 }
            prefix = Array(prefix[..<n])
            if prefix.isEmpty { break }
        }
        return String(prefix)
    }

    /// Lays candidates out in columns that fit `width` terminal columns, like `ls`.
    public static func columns(_ candidates: [String], width: Int) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let cell = (candidates.map(ConsoleFormatter.displayWidth).max() ?? 0) + 2
        let perRow = max(1, width / cell)
        var rows: [String] = []
        var i = 0
        while i < candidates.count {
            let chunk = candidates[i..<min(i + perRow, candidates.count)]
            var line = ""
            for c in chunk { line += ConsoleFormatter.pad(c, to: cell, rightAligned: false) }
            rows.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            i += perRow
        }
        return rows
    }
}
