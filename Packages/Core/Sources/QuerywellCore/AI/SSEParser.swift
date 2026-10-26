import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Hashable {
    /// `event:` field; nil when absent (the spec's default type is "message").
    public var event: String?
    /// `data:` lines joined with `\n`.
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser for the `text/event-stream` format.
///
/// Feed it bytes in arbitrary chunks — a line or even a UTF-8 character may be split across chunks.
/// Handles LF, CRLF and bare CR line endings, `:` comment lines (keep-alives), a single optional space after the
/// colon, multi-line `data:`, and ignores a leading BOM. An event is dispatched by a blank line; an event
/// without any `data:` line is dropped (per the spec). ``finish()`` flushes a final event that wasn't
/// terminated by a blank line.
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var event: String?
    private var dataLines: [String] = []
    private var lastID: String?
    private var sawData = false
    private var atStart = true
    /// A CR was the last byte consumed: a following LF belongs to the same line ending.
    private var pendingCR = false

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] { feed(Array(chunk)) }

    public mutating func feed(_ chunk: [UInt8]) -> [SSEEvent] {
        var out: [SSEEvent] = []
        var bytes = chunk[...]
        if atStart {
            // Strip a UTF-8 BOM once, even if it arrives split.
            buffer += bytes
            bytes = []
            if buffer.count >= 3 || !([0xEF, 0xBB, 0xBF].starts(with: buffer)) {
                if buffer.starts(with: [0xEF, 0xBB, 0xBF]) { buffer.removeFirst(3) }
                atStart = false
            } else {
                return out
            }
            return process(into: &out)
        }
        buffer += bytes
        return process(into: &out)
    }

    private mutating func process(into out: inout [SSEEvent]) -> [SSEEvent] {
        var start = 0
        var i = 0
        while i < buffer.count {
            let b = buffer[i]
            if pendingCR {
                pendingCR = false
                if b == 0x0A {  // LF of a CRLF pair
                    i += 1
                    start = i
                    continue
                }
            }
            if b == 0x0A || b == 0x0D {
                let line = Array(buffer[start..<i])
                handle(line: line, into: &out)
                if b == 0x0D { pendingCR = true }
                i += 1
                start = i
            } else {
                i += 1
            }
        }
        buffer.removeFirst(start)
        return out
    }

    /// Flushes a trailing event at end of stream.
    public mutating func finish() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !buffer.isEmpty {
            handle(line: buffer, into: &out)
            buffer = []
        }
        dispatch(into: &out)
        return out
    }

    private mutating func handle(line: [UInt8], into out: inout [SSEEvent]) {
        if line.isEmpty {
            dispatch(into: &out)
            return
        }
        if line[0] == 0x3A { return }  // comment
        var field = line
        var value: [UInt8] = []
        if let colon = line.firstIndex(of: 0x3A) {
            field = Array(line[..<colon])
            value = Array(line[(colon + 1)...])
            if value.first == 0x20 { value.removeFirst() }
        }
        let name = String(decoding: field, as: UTF8.self)
        let text = String(decoding: value, as: UTF8.self)
        switch name {
        case "event": event = text
        case "data": dataLines.append(text); sawData = true
        case "id": if !text.contains("\0") { lastID = text }
        default: break  // retry:, unknown fields
        }
    }

    private mutating func dispatch(into out: inout [SSEEvent]) {
        defer {
            event = nil
            dataLines = []
            sawData = false
        }
        guard sawData else { return }
        out.append(SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: lastID))
    }
}
