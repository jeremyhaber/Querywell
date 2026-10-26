import Foundation

// MARK: - Editing types

/// One step of a path into a PHP value tree.
public enum PHPPathStep: Hashable, Sendable {
    /// Position among the ordered entries (unambiguous even when crafted data repeats a key).
    case index(Int)
    /// First entry with this key.
    case key(PHPArrayKey)
}

public enum PHPEditError: Error, Equatable, Sendable {
    case invalidPath
    case notContainer
    /// Custom (`C:`) objects, references (`r:`/`R:`) and enum cases cannot be edited or replaced.
    case readOnly
    case duplicateKey
    case indexOutOfRange
    /// Object property names must be strings.
    case invalidKeyForObject
    /// The document contains `r:`/`R:` references whose numbering depends on the position and number
    /// of values, so structural edits (insert / remove / container replacement) are refused.
    case referencesWouldBreak
    case unsupportedConversion
}

// MARK: - Document

/// A parsed PHP serialized value plus the original bytes. Unmodified documents serialize back to the
/// original bytes exactly; modified ones are re-serialized with fresh lengths and counts.
public struct PHPDocument: Sendable {
    public let originalBytes: Data
    public private(set) var root: PHPValue
    private let originalRoot: PHPValue
    private let trailing: Data

    init(original: Data, root: PHPValue, trailing: Data) {
        self.originalBytes = original
        self.root = root
        self.originalRoot = root
        self.trailing = trailing
    }

    /// Creates an unmodified document from a value.
    public init(root: PHPValue) {
        let bytes = PHPSerializer.serialize(root)
        self.init(original: bytes, root: root, trailing: Data())
    }

    /// True when the tree differs from what was parsed (editing and then reverting is "unmodified").
    public var isModified: Bool { root != originalRoot }

    /// Original bytes when unmodified (byte-for-byte), otherwise a fresh canonical serialization.
    public func serialize() -> Data {
        guard isModified else { return originalBytes }
        var d = PHPSerializer.serialize(root)
        d.append(trailing)
        return d
    }

    public var containsReferences: Bool { root.containsReferences }

    // MARK: Reading

    public func value(at path: [PHPPathStep]) throws -> PHPValue {
        var cur = root
        for step in path {
            let entries = cur.entries
            guard cur.isContainer else { throw PHPEditError.notContainer }
            cur = entries[try Self.resolve(step, in: entries)].value
        }
        return cur
    }

    // MARK: Editing

    /// Replaces the value at `path` (an empty path replaces the root). This is also how types change:
    /// pass a value of another type, or use ``changeType(at:to:)`` for a best-effort conversion.
    public mutating func setValue(_ new: PHPValue, at path: [PHPPathStep]) throws {
        if case .reference = new { throw PHPEditError.referencesWouldBreak }
        let hasRefs = root.containsReferences
        try mutate(path) { old in
            guard !old.isReadOnly else { throw PHPEditError.readOnly }
            if hasRefs && (old.isContainer || new.isContainer) { throw PHPEditError.referencesWouldBreak }
            old = new
        }
    }

    public mutating func changeType(at path: [PHPPathStep], to type: PHPValueType) throws {
        let current = try value(at: path)
        try setValue(try current.converted(to: type), at: path)
    }

    /// Inserts a new entry into the array/object at `container`. `index == nil` appends.
    public mutating func insert(_ value: PHPValue, key: PHPArrayKey, into container: [PHPPathStep], at index: Int? = nil) throws {
        if root.containsReferences { throw PHPEditError.referencesWouldBreak }
        if case .reference = value { throw PHPEditError.referencesWouldBreak }
        try mutate(container) { node in
            switch node {
            case .array(var entries):
                if entries.contains(where: { $0.key == key }) { throw PHPEditError.duplicateKey }
                let at = index ?? entries.count
                guard at >= 0, at <= entries.count else { throw PHPEditError.indexOutOfRange }
                entries.insert(PHPEntry(key: key, value: value), at: at)
                node = .array(entries)
            case .object(let cls, var props):
                guard case .string = key else { throw PHPEditError.invalidKeyForObject }
                if props.contains(where: { $0.key == key }) { throw PHPEditError.duplicateKey }
                let at = index ?? props.count
                guard at >= 0, at <= props.count else { throw PHPEditError.indexOutOfRange }
                props.insert(PHPEntry(key: key, value: value), at: at)
                node = .object(className: cls, properties: props)
            default:
                throw PHPEditError.notContainer
            }
        }
    }

    /// Removes the entry at `path` (must be non-empty).
    public mutating func remove(at path: [PHPPathStep]) throws {
        guard let last = path.last else { throw PHPEditError.invalidPath }
        if root.containsReferences { throw PHPEditError.referencesWouldBreak }
        try mutate(Array(path.dropLast())) { node in
            var entries = node.entries
            guard node.isContainer else { throw PHPEditError.notContainer }
            entries.remove(at: try Self.resolve(last, in: entries))
            node = node.replacingEntries(entries)
        }
    }

    /// Renames the key of the entry at `path` (must be non-empty).
    public mutating func renameKey(at path: [PHPPathStep], to newKey: PHPArrayKey) throws {
        guard let last = path.last else { throw PHPEditError.invalidPath }
        try mutate(Array(path.dropLast())) { node in
            var entries = node.entries
            guard node.isContainer else { throw PHPEditError.notContainer }
            if case .object = node, case .int = newKey { throw PHPEditError.invalidKeyForObject }
            let idx = try Self.resolve(last, in: entries)
            if entries.enumerated().contains(where: { $0.offset != idx && $0.element.key == newKey }) {
                throw PHPEditError.duplicateKey
            }
            entries[idx].key = newKey
            node = node.replacingEntries(entries)
        }
    }

    // MARK: Internals

    private static func resolve(_ step: PHPPathStep, in entries: [PHPEntry]) throws -> Int {
        switch step {
        case .index(let i):
            guard i >= 0, i < entries.count else { throw PHPEditError.invalidPath }
            return i
        case .key(let k):
            guard let i = entries.firstIndex(where: { $0.key == k }) else { throw PHPEditError.invalidPath }
            return i
        }
    }

    private mutating func mutate(_ path: [PHPPathStep], _ body: (inout PHPValue) throws -> Void) throws {
        var copy = root
        try Self.descend(&copy, path[...], body)
        root = copy
    }

    private static func descend(_ v: inout PHPValue, _ path: ArraySlice<PHPPathStep>,
                                _ body: (inout PHPValue) throws -> Void) throws {
        guard let step = path.first else {
            try body(&v)
            return
        }
        guard v.isContainer else { throw PHPEditError.notContainer }
        var entries = v.entries
        let idx = try resolve(step, in: entries)
        try descend(&entries[idx].value, path.dropFirst(), body)
        v = v.replacingEntries(entries)
    }
}

extension PHPValue {
    func replacingEntries(_ entries: [PHPEntry]) -> PHPValue {
        switch self {
        case .array: return .array(entries)
        case .object(let cls, _): return .object(className: cls, properties: entries)
        default: return self
        }
    }

    /// Best-effort conversion used by the editor's "change type" action.
    public func converted(to target: PHPValueType) throws -> PHPValue {
        if isReadOnly { throw PHPEditError.readOnly }
        if type == target { return self }
        func text() -> String? {
            switch self {
            case .null: return ""
            case .bool(let b): return b ? "1" : ""
            case .int(let i): return String(i)
            case .double(let raw): return raw
            case .string(let d): return String(decoding: d, as: UTF8.self)
            default: return nil
            }
        }
        func number() -> Double {
            switch self {
            case .bool(let b): return b ? 1 : 0
            case .int(let i): return Double(i)
            case .double: return doubleValue ?? 0
            case .string(let d):
                let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if let v = Double(s) { return v }
                // leading numeric prefix, like PHP's (float)"12abc"
                var prefix = ""
                for ch in s {
                    if ch.isNumber || ((ch == "-" || ch == "+") && prefix.isEmpty) || (ch == "." && !prefix.contains(".")) {
                        prefix.append(ch)
                    } else { break }
                }
                return Double(prefix) ?? 0
            default: return 0
            }
        }
        switch target {
        case .null: return .null
        case .bool:
            switch self {
            case .null: return .bool(false)
            case .int(let i): return .bool(i != 0)
            case .double: return .bool(number() != 0)
            case .string(let d): return .bool(!(d.isEmpty || d == Data("0".utf8)))
            case .array(let e): return .bool(!e.isEmpty)
            default: return .bool(true)
            }
        case .int:
            switch self {
            case .array(let e): return .int(e.isEmpty ? 0 : 1)
            default:
                let n = number()
                guard n.isFinite else { return .int(0) }
                if n >= 9.2233720368547758e18 || n <= -9.2233720368547758e18 { return .int(n < 0 ? Int64.min : Int64.max) }
                return .int(Int64(n))
            }
        case .double:
            if case .array(let e) = self { return .makeDouble(e.isEmpty ? 0 : 1) }
            return .makeDouble(number())
        case .string:
            guard let t = text() else { throw PHPEditError.unsupportedConversion }
            return .makeString(t)
        case .array:
            switch self {
            case .null: return .array([])
            case .object(_, let props): return .array(props)
            default: return .array([PHPEntry(key: .int(0), value: self)])
            }
        case .object:
            switch self {
            case .array(let e):
                let props = e.map { entry -> PHPEntry in
                    if case .int(let i) = entry.key { return PHPEntry(key: .key(String(i)), value: entry.value) }
                    return entry
                }
                return .object(className: "stdClass", properties: props)
            case .null: return .object(className: "stdClass", properties: [])
            default:
                return .object(className: "stdClass", properties: [PHPEntry(key: .key("scalar"), value: self)])
            }
        }
    }
}

// MARK: - Repair

/// "Fix serialized data" in the style of WordPress plugins: repairs `s:N:"…";` lengths that no longer
/// match the string (typically after a naive text search-and-replace on a database dump).
///
/// **Best effort.** A string's real end is taken to be the first `";` after its start that is followed
/// by something which can legally follow a value (`}`, `i:`, `s:N:"`, `a:N:{` …, or the end of input);
/// strings are repaired left to right and the final result must parse completely, otherwise repair
/// gives up (`nil`). A string whose own text contains `";` directly followed by a serialized-token
/// lookalike (e.g. `";i:0;`) is not recoverable this way and normally fails the final parse rather
/// than being mis-repaired. Only string lengths are fixed — wrong array counts, truncated data and
/// other damage are not repaired.
public enum PHPSerializedRepair {
    /// Returns repaired bytes, the unchanged input if it already parses, or `nil` if it cannot be
    /// repaired unambiguously.
    public static func repairLengths(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        var guardCounter = 0
        while guardCounter < 100_000 {
            guardCounter += 1
            var parser = PHPSerializedParser.Parser(bytes: bytes)
            do {
                _ = try parser.parseValue(depth: 0)
                // trailing data check (whitespace only)
                var i = parser.pos
                while i < bytes.count {
                    let b = bytes[i]
                    guard b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 else { return nil }
                    i += 1
                }
                return Data(bytes)
            } catch let e as PHPSerializedError {
                guard case .stringLengthMismatch(_, let contentStart) = e.kind else { return nil }
                guard let fixed = fixString(bytes, contentStart: contentStart) else { return nil }
                bytes = fixed
            } catch {
                return nil
            }
        }
        return nil
    }

    private static func fixString(_ bytes: [UInt8], contentStart: Int) -> [UInt8]? {
        // Layout: s:<digits>:"<content
        guard contentStart >= 5, bytes[contentStart - 1] == 0x22, bytes[contentStart - 2] == 0x3A else { return nil }
        let digitsEnd = contentStart - 2
        var digitsStart = digitsEnd
        while digitsStart > 0, bytes[digitsStart - 1] >= 0x30, bytes[digitsStart - 1] <= 0x39 { digitsStart -= 1 }
        guard digitsStart < digitsEnd, digitsStart >= 2, bytes[digitsStart - 1] == 0x3A else { return nil }

        var found: Int?
        var p = contentStart
        while p + 1 < bytes.count {
            if bytes[p] == 0x22, bytes[p + 1] == 0x3B, plausibleContinuation(bytes, p + 2) {
                found = p
                break
            }
            p += 1
        }
        guard let end = found else { return nil }
        var out = Array(bytes[..<digitsStart])
        out.append(contentsOf: String(end - contentStart).utf8)
        out.append(contentsOf: bytes[digitsEnd...])
        return out
    }

    /// Whether position `q` can start whatever legally follows a string value or key.
    private static func plausibleContinuation(_ b: [UInt8], _ q: Int) -> Bool {
        if q >= b.count { return true }
        func at(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
        func digitsThen(_ from: Int, _ terminators: [UInt8], signed: Bool = false) -> Bool {
            var i = from
            if signed, at(i) == 0x2D { i += 1 }
            let s = i
            while let c = at(i), c >= 0x30, c <= 0x39 { i += 1 }
            guard i > s, let t = at(i), terminators.contains(t) else { return false }
            return true
        }
        // trailing whitespace only
        if b[q...].allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return true }
        guard let tag = at(q) else { return true }
        switch tag {
        case 0x7D: return true
        case 0x4E: return at(q + 1) == 0x3B
        case 0x62: return at(q + 1) == 0x3A && (at(q + 2) == 0x30 || at(q + 2) == 0x31) && at(q + 3) == 0x3B
        case 0x69: return at(q + 1) == 0x3A && digitsThen(q + 2, [0x3B], signed: true)
        case 0x64: return at(q + 1) == 0x3A
        case 0x72, 0x52: return at(q + 1) == 0x3A && digitsThen(q + 2, [0x3B])
        case 0x73: return at(q + 1) == 0x3A && digitsThen(q + 2, [0x3A]) && quoteFollows(b, q + 2)
        case 0x61: return at(q + 1) == 0x3A && digitsThen(q + 2, [0x3A]) && braceFollows(b, q + 2)
        case 0x4F, 0x43: return at(q + 1) == 0x3A && digitsThen(q + 2, [0x3A]) && quoteFollows(b, q + 2)
        default: return false
        }
    }

    private static func skipDigits(_ b: [UInt8], _ from: Int) -> Int {
        var i = from
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
        return i
    }

    private static func quoteFollows(_ b: [UInt8], _ from: Int) -> Bool {
        let i = skipDigits(b, from)
        return i + 1 < b.count && b[i] == 0x3A && b[i + 1] == 0x22
    }

    private static func braceFollows(_ b: [UInt8], _ from: Int) -> Bool {
        let i = skipDigits(b, from)
        return i + 1 < b.count && b[i] == 0x3A && b[i + 1] == 0x7B
    }
}
