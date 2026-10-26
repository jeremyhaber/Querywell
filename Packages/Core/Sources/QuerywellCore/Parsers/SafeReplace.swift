import Foundation

// MARK: - Options / outcome

public struct SafeReplaceOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    /// Treat `search` as an ICU regular expression and `replace` as a template (`$1`, `\$`).
    public var regex: Bool
    /// Only match where the match is not adjacent to a letter, digit or underscore.
    public var wholeWord: Bool
    /// JSON object keys are also searched (default off: keys are structure, not content).
    public var replaceInJSONKeys: Bool
    /// String keys of PHP arrays are also searched (default on, like `wp search-replace`).
    /// Object property names and class names are never touched.
    public var replaceInPHPArrayKeys: Bool

    public init(caseSensitive: Bool = true, regex: Bool = false, wholeWord: Bool = false,
                replaceInJSONKeys: Bool = false, replaceInPHPArrayKeys: Bool = true) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
        self.replaceInJSONKeys = replaceInJSONKeys
        self.replaceInPHPArrayKeys = replaceInPHPArrayKeys
    }
}

public enum ReplaceKind: Equatable, Sendable {
    case plain
    case phpSerialized
    case json
    /// Looks like PHP serialized data but does not parse: left untouched, reported.
    case phpSerializedInvalid
}

public enum ReplaceWarning: Equatable, Sendable {
    /// Top-level value looked serialized but is malformed (see `PHPSerializedRepair`).
    case invalidSerialized(PHPSerializedError)
    /// A `C:` payload contains a match but is opaque, so it was not changed.
    case customObjectSkipped(className: String, matches: Int)
    /// A string value containing a match is not valid UTF-8 and was not changed.
    case binaryStringSkipped
    /// A string inside the value looked serialized but was malformed; it was treated as plain text.
    case nestedInvalidSerialized
}

public struct ReplaceOutcome: Equatable, Sendable {
    public var newValue: String
    public var replacements: Int
    /// Top-level kind. When nothing matched and a literal search lets the replacer skip parsing,
    /// this is derived from a cheap "looks like" check and an invalid value may be reported as its
    /// nominal kind.
    public var kind: ReplaceKind
    public var warnings: [ReplaceWarning]

    public var changed: Bool { replacements > 0 }
}

public struct ReplaceBytesOutcome: Equatable, Sendable {
    public var newValue: Data
    public var replacements: Int
    public var kind: ReplaceKind
    public var warnings: [ReplaceWarning]

    public var changed: Bool { replacements > 0 }
}

public enum SafeReplacerError: Error, Equatable, Sendable {
    case emptySearch
    case invalidRegex(String)
}

// MARK: - Replacer

/// Serialization-safe search & replace for a single database value (the engine behind a
/// `wp search-replace`-style tool).
///
/// - Plain strings: ordinary replace.
/// - PHP serialized values: parsed, every string value (and string array key) is replaced, then the
///   tree is re-serialized so `s:N:` lengths stay correct. Class names, object property names, numbers
///   and `C:` payloads are never changed. Strings that are themselves serialized or JSON (double-encoded
///   WordPress data) are processed recursively.
/// - JSON values: parsed, string values (optionally keys) replaced on the *decoded* text — so
///   `https://example.com` also matches `https:\/\/example.com` — and re-emitted in the original style.
/// - If nothing matches, `newValue` is the input, byte-identical.
///
/// Literal searches containing only "unescapable" ASCII (no `/`, `\`, `"`) are pre-filtered with a
/// raw substring test, which skips parsing values that cannot match. This assumes JSON does not
/// `\u`-escape plain ASCII letters (true for every mainstream encoder).
public struct SafeReplacer {
    public let search: String
    public let replace: String
    public let options: SafeReplaceOptions

    private let regex: NSRegularExpression?
    private let literalSearch: [UInt8]
    private let literalReplace: [UInt8]
    private let useLiteral: Bool
    private let prefilterSafe: Bool

    static let maxNesting = 16

    public init(search: String, replace: String, options: SafeReplaceOptions = SafeReplaceOptions()) throws {
        guard !search.isEmpty else { throw SafeReplacerError.emptySearch }
        self.search = search
        self.replace = replace
        self.options = options
        self.literalSearch = Array(search.utf8)
        self.literalReplace = Array(replace.utf8)
        self.useLiteral = !options.regex && options.caseSensitive && !options.wholeWord
        self.prefilterSafe = !options.regex && options.caseSensitive
            && literalSearch.allSatisfy { $0 >= 0x20 && $0 < 0x7F && $0 != 0x22 && $0 != 0x5C && $0 != 0x2F }
        if useLiteral {
            regex = nil
        } else {
            var pattern = options.regex ? search : NSRegularExpression.escapedPattern(for: search)
            if options.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
            do {
                regex = try NSRegularExpression(pattern: pattern,
                                                options: options.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                throw SafeReplacerError.invalidRegex(String(describing: error))
            }
        }
    }

    // MARK: Public

    public func replace(in value: String) -> ReplaceOutcome {
        var warnings: [ReplaceWarning] = []
        if prefilterSafe && !Self.contains(Array(value.utf8), literalSearch) {
            let kind: ReplaceKind = PHPSerialized.looksSerialized(value) ? .phpSerialized
                : (JSONDocument.looksLikeJSON(value) ? .json : .plain)
            return ReplaceOutcome(newValue: value, replacements: 0, kind: kind, warnings: [])
        }
        let r = process(value, depth: 0, top: true, warnings: &warnings)
        return ReplaceOutcome(newValue: r.value, replacements: r.count, kind: r.kind, warnings: warnings)
    }

    /// Same as ``replace(in:)`` for raw column bytes (BLOB / binary-collation text). Valid UTF-8 takes
    /// the text path; PHP serialized data that is not valid UTF-8 (strings with arbitrary bytes) is
    /// still processed — only its UTF-8 string values are searched — and anything else is returned
    /// untouched. Output for unchanged input is the input itself.
    public func replace(inBytes data: Data) -> ReplaceBytesOutcome {
        if let text = phpUTF8String(data) {
            let o = replace(in: text)
            return ReplaceBytesOutcome(newValue: o.changed ? Data(o.newValue.utf8) : data, replacements: o.replacements,
                                       kind: o.kind, warnings: o.warnings)
        }
        var warnings: [ReplaceWarning] = []
        guard PHPSerialized.looksSerialized(data) else {
            return ReplaceBytesOutcome(newValue: data, replacements: 0, kind: .plain, warnings: [])
        }
        do {
            let doc = try PHPSerializedParser.parse(data)
            var count = 0
            let newRoot = transform(doc.root, depth: 0, count: &count, warnings: &warnings)
            guard count > 0 else {
                return ReplaceBytesOutcome(newValue: data, replacements: 0, kind: .phpSerialized, warnings: warnings)
            }
            var out = PHPSerializer.serialize(newRoot)
            out.append(contentsOf: Self.trailingWhitespace(ofBytes: data))
            return ReplaceBytesOutcome(newValue: out, replacements: count, kind: .phpSerialized, warnings: warnings)
        } catch {
            if let e = error as? PHPSerializedError { warnings.append(.invalidSerialized(e)) }
            return ReplaceBytesOutcome(newValue: data, replacements: 0, kind: .phpSerializedInvalid, warnings: warnings)
        }
    }

    // MARK: Engine

    private func process(_ value: String, depth: Int, top: Bool,
                         warnings: inout [ReplaceWarning]) -> (value: String, count: Int, kind: ReplaceKind) {
        if depth <= Self.maxNesting {
            if PHPSerialized.looksSerialized(value) {
                do {
                    let doc = try PHPSerializedParser.parse(value)
                    var count = 0
                    let newRoot = transform(doc.root, depth: depth, count: &count, warnings: &warnings)
                    guard count > 0 else { return (value, 0, .phpSerialized) }
                    var out = PHPSerializer.serialize(newRoot)
                    out.append(contentsOf: Self.trailingWhitespace(of: value))
                    return (String(decoding: out, as: UTF8.self), count, .phpSerialized)
                } catch {
                    if top {
                        if let e = error as? PHPSerializedError { warnings.append(.invalidSerialized(e)) }
                        return (value, 0, .phpSerializedInvalid)
                    }
                    warnings.append(.nestedInvalidSerialized)
                }
            } else if JSONDocument.looksLikeJSON(value), let doc = try? JSONDocument.parse(value) {
                var count = 0
                let newRoot = transform(doc.root, depth: depth, count: &count, warnings: &warnings)
                guard count > 0 else { return (value, 0, .json) }
                return (JSONEmitter.emit(newRoot, doc.detectedFormatting), count, .json)
            }
        }
        let (s, n) = replaceText(value)
        return (s, n, .plain)
    }

    private static func trailingWhitespace(of s: String) -> [UInt8] {
        trailingWhitespace(ofBytes: Data(s.utf8))
    }

    private static func trailingWhitespace(ofBytes d: Data) -> [UInt8] {
        var tail: [UInt8] = []
        for b in d.reversed() {
            if b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { tail.append(b) } else { break }
        }
        return tail.reversed()
    }

    private func transform(_ v: PHPValue, depth: Int, count: inout Int, warnings: inout [ReplaceWarning]) -> PHPValue {
        switch v {
        case .string(let d):
            guard let s = phpUTF8String(d) else {
                if replaceText(String(decoding: d, as: UTF8.self)).count > 0 { warnings.append(.binaryStringSkipped) }
                return v
            }
            let r = process(s, depth: depth + 1, top: false, warnings: &warnings)
            guard r.count > 0 else { return v }
            count += r.count
            return .string(Data(r.value.utf8))
        case .array(let entries):
            return .array(entries.map { e in
                var e = e
                if options.replaceInPHPArrayKeys, case .string(let kd) = e.key, let ks = phpUTF8String(kd) {
                    let (nk, n) = replaceText(ks)
                    if n > 0 {
                        e.key = .string(Data(nk.utf8))
                        count += n
                    }
                }
                e.value = transform(e.value, depth: depth, count: &count, warnings: &warnings)
                return e
            })
        case .object(let cls, let props):
            return .object(className: cls, properties: props.map { p in
                var p = p
                p.value = transform(p.value, depth: depth, count: &count, warnings: &warnings)
                return p
            })
        case .customObject(let cls, let payload):
            let n = replaceText(String(decoding: payload, as: UTF8.self)).count
            if n > 0 { warnings.append(.customObjectSkipped(className: cls, matches: n)) }
            return v
        default:
            return v
        }
    }

    private func transform(_ n: JSONNode, depth: Int, count: inout Int, warnings: inout [ReplaceWarning]) -> JSONNode {
        switch n {
        case .string(let s):
            let r = process(s, depth: depth + 1, top: false, warnings: &warnings)
            guard r.count > 0 else { return n }
            count += r.count
            return .string(r.value)
        case .array(let items):
            return .array(items.map { transform($0, depth: depth, count: &count, warnings: &warnings) })
        case .object(let members):
            return .object(members.map { m in
                var m = m
                if options.replaceInJSONKeys {
                    let (nk, c) = replaceText(m.key)
                    if c > 0 {
                        m.key = nk
                        count += c
                    }
                }
                m.value = transform(m.value, depth: depth, count: &count, warnings: &warnings)
                return m
            })
        default:
            return n
        }
    }

    // MARK: Text replacement

    private func replaceText(_ s: String) -> (value: String, count: Int) {
        if useLiteral { return replaceLiteral(s) }
        guard let regex else { return (s, 0) }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        let n = regex.numberOfMatches(in: s, options: [], range: full)
        guard n > 0 else { return (s, 0) }
        let template = options.regex ? replace : NSRegularExpression.escapedTemplate(for: replace)
        return (regex.stringByReplacingMatches(in: s, options: [], range: full, withTemplate: template), n)
    }

    /// Byte-exact (no Unicode normalisation) replace of every non-overlapping occurrence.
    private func replaceLiteral(_ s: String) -> (value: String, count: Int) {
        let hay = Array(s.utf8)
        var out: [UInt8] = []
        var count = 0
        var i = 0
        let m = literalSearch.count
        while i <= hay.count - m, let at = Self.find(hay, literalSearch, from: i) {
            out.append(contentsOf: hay[i..<at])
            out.append(contentsOf: literalReplace)
            i = at + m
            count += 1
        }
        guard count > 0 else { return (s, 0) }
        out.append(contentsOf: hay[i...])
        return (String(decoding: out, as: UTF8.self), count)
    }

    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        find(hay, needle, from: 0) != nil
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard from <= hay.count - needle.count else { return nil }
        return hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                guard let base = h.baseAddress, let nb = n.baseAddress,
                      let p = memmem(base + from, h.count - from, nb, n.count) else { return nil }
                return base.distance(to: p.assumingMemoryBound(to: UInt8.self))
            }
        }
    }
}
