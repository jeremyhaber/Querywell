import Foundation

/// Pure text transforms behind the editor's keyboard commands, so they can be unit-tested without
/// an NSTextView. Ranges are UTF-16 (NSRange), like AppKit's.
enum EditorTransforms {
    /// A replacement of `range` by `replacement`, and where the selection goes afterwards.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    static let indentUnit = "    "

    // MARK: Lines

    /// The range of the whole lines touched by `selection` (a selection ending at a line start doesn't include that line).
    static func lineBlock(in text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        var sel = selection
        if sel.length > 0, sel.upperBound <= ns.length, ns.character(at: sel.upperBound - 1) == 10 {
            sel.length -= 1
        }
        return ns.lineRange(for: sel)
    }

    // MARK: Auto-indent

    /// Whitespace to put after a newline typed at `caret`: the current line's indentation, plus one
    /// unit when the line ends with an opening bracket right before the caret.
    static func newlineIndent(in text: String, caret: Int) -> String {
        let ns = text as NSString
        let caret = max(0, min(caret, ns.length))
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var indent = ""
        var i = line.location
        while i < caret, i < ns.length {
            let c = ns.character(at: i)
            if c == 32 || c == 9 { indent.append(Character(UnicodeScalar(c)!)) } else { break }
            i += 1
        }
        if caret > 0 {
            let before = ns.character(at: caret - 1)
            if before == UInt16(ascii: "(") { indent += indentUnit }
        }
        return indent
    }

    // MARK: Comments

    /// ⌘/: comments the lines touched by `selection` with `-- `, or removes the comment markers when
    /// every non-blank line already has one.
    static func toggleComment(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = lineBlock(in: text, selection: selection)
        let body = ns.substring(with: block)
        var lines = body.components(separatedBy: "\n")
        let trailingNewline = body.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }

        func isBlank(_ l: String) -> Bool { l.allSatisfy { $0 == " " || $0 == "\t" } }
        func indentLength(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        let active = lines.filter { !isBlank($0) }
        let allCommented = !active.isEmpty && active.allSatisfy { $0.dropFirst(indentLength($0)).hasPrefix("--") }

        var out: [String] = []
        if allCommented {
            for l in lines {
                guard !isBlank(l) else { out.append(l); continue }
                let n = indentLength(l)
                var rest = String(l.dropFirst(n))
                rest.removeFirst(2)
                if rest.hasPrefix(" ") { rest.removeFirst() }
                out.append(String(l.prefix(n)) + rest)
            }
        } else {
            let minIndent = active.map(indentLength).min() ?? 0
            for l in lines {
                guard !isBlank(l) else { out.append(l); continue }
                let idx = l.index(l.startIndex, offsetBy: minIndent)
                out.append(String(l[..<idx]) + "-- " + String(l[idx...]))
            }
        }
        let replacement = out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let len = (replacement as NSString).length
        return Edit(range: block, replacement: replacement, selection: NSRange(location: block.location, length: trailingNewline ? len - 1 : len))
    }

    // MARK: Indentation

    /// ⇥ with a multi-line selection: indents every touched line.
    static func indent(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = lineBlock(in: text, selection: selection)
        let body = ns.substring(with: block)
        var lines = body.components(separatedBy: "\n")
        let trailing = body.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let out = lines.map { $0.isEmpty ? $0 : indentUnit + $0 }.joined(separator: "\n") + (trailing ? "\n" : "")
        let len = (out as NSString).length
        return Edit(range: block, replacement: out, selection: NSRange(location: block.location, length: trailing ? len - 1 : len))
    }

    /// ⇧⇥: removes one indent unit (or up to four spaces / one tab) from every touched line.
    static func outdent(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let block = lineBlock(in: text, selection: selection)
        let body = ns.substring(with: block)
        var lines = body.components(separatedBy: "\n")
        let trailing = body.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let out = lines.map { l -> String in
            if l.hasPrefix("\t") { return String(l.dropFirst()) }
            var n = 0
            for ch in l.prefix(indentUnit.count) { if ch == " " { n += 1 } else { break } }
            return String(l.dropFirst(n))
        }.joined(separator: "\n") + (trailing ? "\n" : "")
        let len = (out as NSString).length
        // A caret-only selection stays on its line, shifted left by what was removed.
        if selection.length == 0 {
            let removed = (body as NSString).length - len
            return Edit(range: block, replacement: out, selection: NSRange(location: max(block.location, selection.location - removed), length: 0))
        }
        return Edit(range: block, replacement: out, selection: NSRange(location: block.location, length: trailing ? len - 1 : len))
    }

    /// Whether the selection covers more than one line (⇥ then indents instead of inserting spaces).
    static func isMultiline(_ text: String, selection: NSRange) -> Bool {
        guard selection.length > 0 else { return false }
        let ns = text as NSString
        let sub = ns.substring(with: selection)
        let trimmed = sub.hasSuffix("\n") ? String(sub.dropLast()) : sub
        return trimmed.contains("\n")
    }

    // MARK: Brackets

    private static let pairs: [UInt16: UInt16] = [
        UInt16(ascii: "("): UInt16(ascii: ")"), UInt16(ascii: "["): UInt16(ascii: "]"), UInt16(ascii: "{"): UInt16(ascii: "}"),
    ]

    /// The bracket next to `caret` (before it first, then after it) and its partner, skipping brackets
    /// inside `skipping` ranges (strings and comments). Nil when there is none or it is unbalanced.
    static func matchingBrackets(in text: String, caret: Int, skipping: [Range<Int>] = []) -> (NSRange, NSRange)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        func skipped(_ i: Int) -> Bool { skipping.contains { $0.contains(i) } }
        for position in [caret - 1, caret] where position >= 0 && position < ns.length {
            let c = ns.character(at: position)
            guard !skipped(position) else { continue }
            if let close = pairs[c] {
                var depth = 0
                var i = position
                while i < ns.length {
                    if !skipped(i) {
                        let d = ns.character(at: i)
                        if d == c { depth += 1 } else if d == close {
                            depth -= 1
                            if depth == 0 { return (NSRange(location: position, length: 1), NSRange(location: i, length: 1)) }
                        }
                    }
                    i += 1
                }
            } else if let open = pairs.first(where: { $0.value == c })?.key {
                var depth = 0
                var i = position
                while i >= 0 {
                    if !skipped(i) {
                        let d = ns.character(at: i)
                        if d == c { depth += 1 } else if d == open {
                            depth -= 1
                            if depth == 0 { return (NSRange(location: i, length: 1), NSRange(location: position, length: 1)) }
                        }
                    }
                    i -= 1
                }
            }
        }
        return nil
    }

    // MARK: Completion triggers

    static func isIdentifierUnit(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    /// Whether typing `inserted` should open the completion popup.
    static func triggersCompletion(inserted: String) -> Bool {
        guard inserted.utf16.count == 1, let u = inserted.utf16.first else { return false }
        return isIdentifierUnit(u) || u == UInt16(ascii: ".")
    }
}

extension UInt16 {
    /// A UTF-16 unit for an ASCII scalar (`UInt16(ascii: "(")`).
    init(ascii scalar: Unicode.Scalar) { self.init(scalar.value) }
}
