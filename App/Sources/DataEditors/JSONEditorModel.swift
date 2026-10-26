import Foundation
import Observation
import QuerywellCore

/// State and edits of the JSON editor (Tree and Raw views over one document).
///
/// The raw text is the saved text in "Keep original formatting" mode: a tree edit re-emits it in the
/// style detected from the original, and untouched documents keep their exact bytes.
@MainActor @Observable
final class JSONEditorModel {
    enum Pane: String, CaseIterable, Identifiable {
        case tree = "Tree", raw = "Raw"
        var id: String { rawValue }
    }

    enum SaveFormat: String, CaseIterable, Identifiable {
        case keep = "Keep original formatting"
        case minified = "Minified"
        case pretty = "Pretty"
        var id: String { rawValue }
    }

    enum Kind: String, CaseIterable {
        case object, array, string, number, bool, null
    }

    typealias Path = [Int]

    let originalText: String
    var pane: Pane = .tree
    var saveFormat: SaveFormat = .keep
    private(set) var rawText: String
    private(set) var root: JSONNode = .null
    private(set) var error: JSONParseError?
    private(set) var detected: JSONFormatting
    var selection: String?
    private(set) var expanded: Set<Path> = []
    private(set) var jump: TextJump?
    let isReadOnly: Bool
    private var history: [(root: JSONNode, raw: String)] = []
    private var originalRoot: JSONNode?
    private var originalIsValid = false
    @ObservationIgnored var openNestedHandler: ((Data, String, @escaping (Data) -> String?) -> Void)?

    static let maxRows = 20_000

    init(text: String, isReadOnly: Bool) {
        originalText = text
        rawText = text
        self.isReadOnly = isReadOnly
        detected = JSONFormatting(layout: .pretty(indent: .spaces(2)))
        if let doc = try? JSONDocument.parse(text) {
            root = doc.root
            originalRoot = doc.root
            originalIsValid = true
            detected = doc.detectedFormatting
            expandInitially()
        } else {
            error = JSONDocument.validate(text)
        }
    }

    // MARK: Output

    var isValid: Bool { error == nil }

    /// The text that would be saved with the chosen format; nil while the JSON is invalid.
    var output: String? {
        guard error == nil else { return nil }
        switch saveFormat {
        case .keep:
            return rawText
        case .minified, .pretty:
            guard let doc = try? JSONDocument.parse(rawText) else { return nil }
            if saveFormat == .minified { return doc.minified }
            if case .pretty(let indent) = detected.layout { return doc.prettyPrinted(indent: indent) }
            return doc.prettyPrinted(indent: 2)
        }
    }

    var outputBytes: Int { (output ?? rawText).utf8.count }
    var originalBytes: Int { originalText.utf8.count }

    var nodeCount: Int { Self.count(root) }

    // MARK: Raw

    func setRaw(_ text: String) {
        guard text != rawText else { return }
        rawText = text
        revalidate()
    }

    private func revalidate() {
        if rawText.utf8.count > 300_000 { debouncedRevalidate(); return }
        applyValidation()
    }

    @ObservationIgnored private var debounce: Task<Void, Never>?

    private func debouncedRevalidate() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.applyValidation()
        }
    }

    private func applyValidation() {
        if let e = JSONDocument.validate(rawText) {
            error = e
        } else if let doc = try? JSONDocument.parse(rawText) {
            error = nil
            if doc.root != root {
                root = doc.root
                prune()
            }
            if originalRoot == nil {
                // First valid parse of a document that was invalid on open: adopt its style.
                originalRoot = doc.root
                detected = doc.detectedFormatting
                expandInitially()
            }
        }
    }

    func jumpToError() {
        guard let error else { return }
        pane = .raw
        jump = TextJump(utf8Offset: error.offset)
    }

    func prettyPrint() {
        guard error == nil, let doc = try? JSONDocument.parse(rawText) else { return }
        if case .pretty(let indent) = detected.layout {
            setRaw(doc.prettyPrinted(indent: indent))
        } else {
            setRaw(doc.prettyPrinted(indent: 2))
        }
    }

    func minify() {
        guard error == nil, let doc = try? JSONDocument.parse(rawText) else { return }
        setRaw(doc.minified)
    }

    // MARK: Tree rows

    func rows() -> [EditorTreeRow] {
        guard error == nil else { return [] }
        var out: [EditorTreeRow] = []
        build(node: root, path: [], key: "", keyIsIndex: false, depth: 0, into: &out)
        return out
    }

    private func build(node: JSONNode, path: Path, key: String, keyIsIndex: Bool, depth: Int, into out: inout [EditorTreeRow]) {
        guard out.count < Self.maxRows else { return }
        let id = Self.id(path)
        var row = EditorTreeRow(id: id, depth: depth, key: key, keyIsIndex: keyIsIndex)
        let kind = Self.kind(of: node)
        row.currentType = kind.rawValue
        let editable = !isReadOnly
        row.typeChoices = editable ? Kind.allCases.map(\.rawValue) : []
        row.canEditKey = editable && !path.isEmpty && !keyIsIndex
        row.canRemove = editable && !path.isEmpty
        row.canDuplicate = editable && !path.isEmpty
        if let parentKind = parentKind(of: path), parentKind == .array, editable {
            let idx = path.last ?? 0
            let count = childCount(at: Array(path.dropLast()))
            row.canMoveUp = idx > 0
            row.canMoveDown = idx < count - 1
        }
        switch node {
        case .object(let members):
            row.badge = "object · \(members.count)"
            row.tone = .container
            row.isContainer = true
            row.childCount = members.count
            row.isExpanded = expanded.contains(path)
            row.canAdd = editable
            row.value = members.isEmpty ? "{ }" : "{ \(members.count) key\(members.count == 1 ? "" : "s") }"
            row.valueMuted = true
        case .array(let items):
            row.badge = "array · \(items.count)"
            row.tone = .container
            row.isContainer = true
            row.childCount = items.count
            row.isExpanded = expanded.contains(path)
            row.canAdd = editable
            row.value = items.isEmpty ? "[ ]" : "[ \(items.count) item\(items.count == 1 ? "" : "s") ]"
            row.valueMuted = true
        case .string(let s):
            row.badge = "string"
            row.tone = .string
            row.value = Self.display(s)
            row.editText = s
            row.field = (s.contains("\n") || s.utf8.count > 400) ? .none : .text
            if s.contains("\n") || s.utf8.count > 400 { row.nestedLabel = Self.nestedLabel(for: s) ?? "Text" } else { row.nestedLabel = Self.nestedLabel(for: s) }
            row.value = "\"" + row.value + "\""
        case .number(let raw):
            row.badge = "number"
            row.tone = .number
            row.value = raw
            row.editText = raw
            row.field = .number
        case .bool(let b):
            row.badge = "boolean"
            row.tone = .bool
            row.value = b ? "true" : "false"
            row.field = .bool
            row.boolValue = b
        case .null:
            row.badge = "null"
            row.tone = .null
            row.value = "null"
            row.valueMuted = true
        }
        if isReadOnly { row.field = row.field == .bool ? .none : row.field }
        out.append(row)
        guard row.isContainer, row.isExpanded else { return }
        switch node {
        case .object(let members):
            for (i, m) in members.enumerated() {
                build(node: m.value, path: path + [i], key: m.key, keyIsIndex: false, depth: depth + 1, into: &out)
            }
        case .array(let items):
            for (i, item) in items.enumerated() {
                build(node: item, path: path + [i], key: "[\(i)]", keyIsIndex: true, depth: depth + 1, into: &out)
            }
        default: break
        }
    }

    static func display(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "⇥")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    static func nestedLabel(for s: String) -> String? {
        if PHPSerialized.looksSerialized(s) { return "PHP serialized" }
        if JSONDocument.looksLikeJSON(s) && JSONDocument.validate(s) == nil { return "JSON" }
        return nil
    }

    static func id(_ path: Path) -> String { path.isEmpty ? "root" : path.map(String.init).joined(separator: ".") }

    static func path(from id: String) -> Path? {
        if id == "root" { return [] }
        let parts = id.split(separator: ".").map { Int($0) }
        return parts.contains(where: { $0 == nil }) ? nil : parts.compactMap { $0 }
    }

    static func kind(of node: JSONNode) -> Kind {
        switch node {
        case .object: .object
        case .array: .array
        case .string: .string
        case .number: .number
        case .bool: .bool
        case .null: .null
        }
    }

    static func count(_ node: JSONNode) -> Int {
        switch node {
        case .object(let m): 1 + m.reduce(0) { $0 + count($1.value) }
        case .array(let a): 1 + a.reduce(0) { $0 + count($1) }
        default: 1
        }
    }

    // MARK: Expansion

    func toggle(_ id: String) {
        guard let p = Self.path(from: id) else { return }
        if expanded.contains(p) { expanded.remove(p) } else { expanded.insert(p) }
    }

    func expandAll() {
        var all = Set<Path>()
        func walk(_ node: JSONNode, _ path: Path) {
            switch node {
            case .object(let m):
                all.insert(path)
                for (i, x) in m.enumerated() { walk(x.value, path + [i]) }
            case .array(let a):
                all.insert(path)
                for (i, x) in a.enumerated() { walk(x, path + [i]) }
            default: break
            }
            if all.count > 5_000 { return }
        }
        walk(root, [])
        expanded = all
    }

    func collapseAll() { expanded = [[]] }

    private func expandInitially() {
        // Root plus the first levels, bounded so a huge document opens quickly.
        var budget = 400
        var set = Set<Path>()
        func walk(_ node: JSONNode, _ path: Path, depth: Int) {
            let children: [JSONNode]
            switch node {
            case .object(let m): children = m.map(\.value)
            case .array(let a): children = a
            default: return
            }
            guard depth < 3, budget > 0 else { return }
            set.insert(path)
            budget -= children.count
            for (i, c) in children.enumerated() { walk(c, path + [i], depth: depth + 1) }
        }
        walk(root, [], depth: 0)
        set.insert([])
        expanded = set
    }

    /// Drops expansion state for paths that no longer exist.
    private func prune() {
        expanded = expanded.filter { node(at: $0) != nil }
        if let selection, let p = Self.path(from: selection), node(at: p) == nil { self.selection = nil }
    }

    // MARK: Lookup

    func node(at path: Path) -> JSONNode? {
        var cur = root
        for i in path {
            switch cur {
            case .object(let m): guard m.indices.contains(i) else { return nil }; cur = m[i].value
            case .array(let a): guard a.indices.contains(i) else { return nil }; cur = a[i]
            default: return nil
            }
        }
        return cur
    }

    private func childCount(at path: Path) -> Int {
        switch node(at: path) {
        case .object(let m): m.count
        case .array(let a): a.count
        default: 0
        }
    }

    private func parentKind(of path: Path) -> Kind? {
        guard !path.isEmpty, let parent = node(at: Array(path.dropLast())) else { return nil }
        return Self.kind(of: parent)
    }

    // MARK: Edits

    /// Applies a tree edit: snapshot for undo, then re-emit the raw text in the original style.
    private func edit(_ body: (inout JSONNode) -> String?) -> String? {
        guard !isReadOnly, error == nil else { return nil }
        var copy = root
        if let problem = body(&copy) { return problem }
        guard copy != root else { return nil }
        history.append((root, rawText))
        if history.count > 100 { history.removeFirst() }
        root = copy
        reemit()
        return nil
    }

    private func reemit() {
        if let originalRoot, originalRoot == root, originalIsValid {
            rawText = originalText
        } else if var doc = try? JSONDocument.parse("null") {
            doc.root = root
            rawText = doc.emit(detected)
        }
        error = nil
    }

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        root = last.root
        rawText = last.raw
        error = nil
        prune()
    }

    private func mutate(_ path: Path, in node: inout JSONNode, _ body: (inout JSONNode) -> String?) -> String? {
        guard let first = path.first else { return body(&node) }
        let rest = Array(path.dropFirst())
        switch node {
        case .object(var members):
            guard members.indices.contains(first) else { return "That entry no longer exists." }
            let r = mutate(rest, in: &members[first].value, body)
            node = .object(members)
            return r
        case .array(var items):
            guard items.indices.contains(first) else { return "That entry no longer exists." }
            let r = mutate(rest, in: &items[first], body)
            node = .array(items)
            return r
        default:
            return "That entry is not a container."
        }
    }

    /// Edits a scalar from typed text. Returns why it was rejected.
    func commitValue(id: String, text: String) -> String? {
        guard let path = Self.path(from: id), let current = node(at: path) else { return nil }
        let new: JSONNode
        switch current {
        case .string: new = .string(text)
        case .number:
            let t = text.trimmingCharacters(in: .whitespaces)
            guard Self.isJSONNumber(t) else { return "“\(t)” is not a valid JSON number (for example 42, -1.5 or 2e10)." }
            new = .number(raw: t)
        default: return nil
        }
        return edit { root in mutate(path, in: &root) { $0 = new; return nil } }
    }

    func setBool(id: String, _ value: Bool) {
        guard let path = Self.path(from: id) else { return }
        _ = edit { root in mutate(path, in: &root) { $0 = .bool(value); return nil } }
    }

    func renameKey(id: String, to name: String) -> String? {
        guard let path = Self.path(from: id), let last = path.last else { return nil }
        let parentPath = Array(path.dropLast())
        guard case .object(let siblings)? = node(at: parentPath) else { return nil }
        if siblings.enumerated().contains(where: { $0.offset != last && $0.element.key == name }) {
            return "This object already has a key “\(name)”."
        }
        return edit { root in
            mutate(parentPath, in: &root) { node in
                guard case .object(var members) = node, members.indices.contains(last) else { return "That entry no longer exists." }
                members[last].key = name
                node = .object(members)
                return nil
            }
        }
    }

    func remove(id: String) {
        guard let path = Self.path(from: id), let last = path.last else { return }
        let parentPath = Array(path.dropLast())
        _ = edit { root in
            mutate(parentPath, in: &root) { node in
                switch node {
                case .object(var m): m.remove(at: last); node = .object(m)
                case .array(var a): a.remove(at: last); node = .array(a)
                default: break
                }
                return nil
            }
        }
        selection = Self.id(parentPath)
    }

    func duplicate(id: String) {
        guard let path = Self.path(from: id), let last = path.last else { return }
        let parentPath = Array(path.dropLast())
        _ = edit { root in
            mutate(parentPath, in: &root) { node in
                switch node {
                case .object(var m):
                    var copy = m[last]
                    copy.key = Self.uniqueKey(copy.key + "_copy", in: m)
                    m.insert(copy, at: last + 1)
                    node = .object(m)
                case .array(var a): a.insert(a[last], at: last + 1); node = .array(a)
                default: break
                }
                return nil
            }
        }
        selection = Self.id(parentPath + [last + 1])
    }

    func move(id: String, by delta: Int) {
        guard let path = Self.path(from: id), let last = path.last else { return }
        let parentPath = Array(path.dropLast())
        let target = last + delta
        _ = edit { root in
            mutate(parentPath, in: &root) { node in
                switch node {
                case .array(var a):
                    guard a.indices.contains(target) else { return nil }
                    a.swapAt(last, target)
                    node = .array(a)
                case .object(var m):
                    guard m.indices.contains(target) else { return nil }
                    m.swapAt(last, target)
                    node = .object(m)
                default: break
                }
                return nil
            }
        }
        selection = Self.id(parentPath + [target])
    }

    /// Adds a new entry of `type` into the container `id`, or the selected container / the selection's
    /// parent / the root when `id` is nil.
    func add(to id: String?, type: String) {
        guard let kind = Kind(rawValue: type) else { return }
        var containerPath: Path = []
        if let id, let p = Self.path(from: id) {
            containerPath = p
        } else if let selection, let p = Self.path(from: selection) {
            if let n = node(at: p), Self.kind(of: n) == .object || Self.kind(of: n) == .array { containerPath = p } else { containerPath = Array(p.dropLast()) }
        }
        let newNode = Self.defaultNode(kind)
        var newIndex = 0
        _ = edit { root in
            mutate(containerPath, in: &root) { node in
                switch node {
                case .object(var m):
                    m.append(JSONMember(key: Self.uniqueKey("new_key", in: m), value: newNode))
                    newIndex = m.count - 1
                    node = .object(m)
                case .array(var a):
                    a.append(newNode)
                    newIndex = a.count - 1
                    node = .array(a)
                default:
                    return "Select an array or object to add to."
                }
                return nil
            }
        }
        expanded.insert(containerPath)
        selection = Self.id(containerPath + [newIndex])
    }

    func changeType(id: String, to type: String) {
        guard let path = Self.path(from: id), let kind = Kind(rawValue: type), let current = node(at: path) else { return }
        guard Self.kind(of: current) != kind else { return }
        _ = edit { root in mutate(path, in: &root) { $0 = Self.convert($0, to: kind); return nil } }
    }

    // MARK: Conversion helpers

    static func defaultNode(_ kind: Kind) -> JSONNode {
        switch kind {
        case .object: .object([])
        case .array: .array([])
        case .string: .string("")
        case .number: .number(raw: "0")
        case .bool: .bool(false)
        case .null: .null
        }
    }

    static func convert(_ node: JSONNode, to kind: Kind) -> JSONNode {
        switch (node, kind) {
        case (.string(let s), .number):
            let t = s.trimmingCharacters(in: .whitespaces)
            return .number(raw: isJSONNumber(t) ? t : "0")
        case (.string(let s), .bool): return .bool(["true", "1", "yes"].contains(s.lowercased()))
        case (.number(let raw), .string): return .string(raw)
        case (.number(let raw), .bool): return .bool(raw != "0" && Double(raw) != 0)
        case (.bool(let b), .string): return .string(b ? "true" : "false")
        case (.bool(let b), .number): return .number(raw: b ? "1" : "0")
        case (.array(let items), .object):
            return .object(items.enumerated().map { JSONMember(key: String($0.offset), value: $0.element) })
        case (.object(let members), .array): return .array(members.map(\.value))
        default: return defaultNode(kind)
        }
    }

    static func isJSONNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func uniqueKey(_ base: String, in members: [JSONMember]) -> String {
        let keys = Set(members.map(\.key))
        if !keys.contains(base) { return base }
        var n = 2
        while keys.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    // MARK: Nested editors

    /// Replaces the string at `id` with `text` (a nested editor's result).
    func replaceString(id: String, with text: String) -> String? {
        guard let path = Self.path(from: id) else { return nil }
        return edit { root in mutate(path, in: &root) { $0 = .string(text); return nil } }
    }

    func openNested(id: String) {
        guard let path = Self.path(from: id), case .string(let s)? = node(at: path) else { return }
        let label = Self.nestedLabel(for: s) ?? "Text"
        openNestedHandler?(Data(s.utf8), label) { [weak self] data in
            self?.replaceString(id: id, with: String(decoding: data, as: UTF8.self))
        }
    }
}
