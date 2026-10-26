import Foundation
import Observation
import QuerywellCore

/// One `s:N:"…"` length that repair would correct.
struct PHPLengthFix: Identifiable, Equatable {
    var id: Int { offset }
    /// Byte offset of the `s:` token.
    var offset: Int
    var declared: Int
    var actual: Int
    /// Start of the string as it will read after repair.
    var preview: String
}

/// A proposed repair, shown with a preview before it is applied (never applied silently).
struct PHPRepairProposal: Equatable {
    var repaired: Data
    var fixes: [PHPLengthFix]
}

/// State and edits of the PHP serialized editor. The tree is a `PHPDocument`: unmodified documents save
/// their original bytes, edited ones are re-serialized with every length and count recalculated.
@MainActor @Observable
final class PHPEditorModel {
    enum Pane: String, CaseIterable, Identifiable {
        case tree = "Tree", raw = "Raw"
        var id: String { rawValue }
    }

    typealias Path = [Int]

    let originalData: Data
    let isReadOnly: Bool
    var pane: Pane = .tree
    var selection: String?
    private(set) var document: PHPDocument?
    private(set) var parseError: PHPSerializedError?
    /// The bytes the editor currently holds: the document's serialization, or the unparsed source.
    private(set) var source: Data
    private(set) var expanded: Set<Path> = []
    var repairProposal: PHPRepairProposal?
    private var history: [PHPDocument] = []
    @ObservationIgnored var openNestedHandler: ((Data, String, @escaping (Data) -> String?) -> Void)?

    static let maxRows = 20_000

    init(data: Data, isReadOnly: Bool) {
        originalData = data
        source = data
        self.isReadOnly = isReadOnly
        load(data)
    }

    private func load(_ data: Data) {
        source = data
        do {
            let doc = try PHPSerializedParser.parse(data)
            document = doc
            parseError = nil
            expandInitially()
        } catch let e as PHPSerializedError {
            document = nil
            parseError = e
        } catch {
            document = nil
        }
    }

    // MARK: Output

    /// The bytes that would be saved.
    var currentData: Data { document?.serialize() ?? source }
    var hasChanges: Bool { currentData != originalData }
    var isValid: Bool { document != nil }
    var containsReferences: Bool { document?.containsReferences ?? false }

    var footer: String {
        guard document != nil else { return "Malformed · \(source.count.formatted()) B stored" }
        if !hasChanges { return "No changes (original bytes kept)" }
        let n = currentData.count
        return "Will save \(n.formatted()) byte\(n == 1 ? "" : "s") · lengths recalculated automatically"
    }

    var errorDescription: String? {
        guard let parseError else { return nil }
        return parseError.description
    }

    /// Serialized text for the Raw pane (invalid UTF-8 shows replacement characters).
    var rawText: String { String(decoding: currentData, as: UTF8.self) }

    // MARK: Repair

    func proposeRepair() -> String? {
        guard parseError != nil else { return nil }
        guard let fixed = PHPSerializedRepair.repairLengths(source), fixed != source else {
            return "Querywell couldn't repair this unambiguously. Only wrong string lengths can be repaired; other damage needs a manual fix."
        }
        repairProposal = PHPRepairProposal(repaired: fixed, fixes: Self.fixes(from: source, to: fixed))
        return nil
    }

    func acceptRepair() {
        guard let proposal = repairProposal else { return }
        repairProposal = nil
        history = []
        load(proposal.repaired)
    }

    func cancelRepair() { repairProposal = nil }

    static func fixes(from old: Data, to new: Data) -> [PHPLengthFix] {
        guard let a = String(data: old, encoding: .isoLatin1), let b = String(data: new, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: #"s:(\d+):""#) else { return [] }
        let ma = regex.matches(in: a, range: NSRange(location: 0, length: (a as NSString).length))
        let mb = regex.matches(in: b, range: NSRange(location: 0, length: (b as NSString).length))
        guard ma.count == mb.count else { return [] }
        var out: [PHPLengthFix] = []
        let bytes = [UInt8](new)
        for (x, y) in zip(ma, mb) {
            let declared = Int((a as NSString).substring(with: x.range(at: 1))) ?? 0
            let actual = Int((b as NSString).substring(with: y.range(at: 1))) ?? 0
            guard declared != actual else { continue }
            let start = y.range.location + y.range.length
            let end = min(bytes.count, start + min(actual, 60))
            let preview = String(decoding: bytes[min(start, bytes.count)..<end], as: UTF8.self)
            out.append(PHPLengthFix(offset: x.range.location, declared: declared, actual: actual, preview: preview))
        }
        return out
    }

    // MARK: Rows

    func rows() -> [EditorTreeRow] {
        guard let document else { return [] }
        var out: [EditorTreeRow] = []
        build(value: document.root, path: [], key: "", keyIsIndex: false, keyNote: nil, parentIsArray: nil, depth: 0, into: &out)
        return out
    }

    private var structuralEditsAllowed: Bool { !isReadOnly && !containsReferences }

    private func build(value: PHPValue, path: Path, key: String, keyIsIndex: Bool, keyNote: String?, parentIsArray: Bool?,
                       depth: Int, into out: inout [EditorTreeRow]) {
        guard out.count < Self.maxRows else { return }
        var row = EditorTreeRow(id: Self.id(path), depth: depth, key: key, keyIsIndex: keyIsIndex)
        row.keyNote = keyNote
        let editable = !isReadOnly && !value.isReadOnly
        row.canEditKey = !isReadOnly && !path.isEmpty
        row.canRemove = structuralEditsAllowed && !path.isEmpty
        row.canDuplicate = structuralEditsAllowed && !path.isEmpty
        row.typeChoices = editable ? PHPValueType.allCases.map(\.rawValue) : []
        row.currentType = value.type?.rawValue ?? ""
        switch value {
        case .null:
            row.badge = "null"; row.tone = .null; row.value = "null"; row.valueMuted = true
        case .bool(let b):
            row.badge = "bool"; row.tone = .bool; row.value = b ? "true" : "false"
            row.field = editable ? .bool : .none; row.boolValue = b
        case .int(let i):
            row.badge = "int"; row.tone = .number; row.value = String(i); row.editText = String(i)
            row.field = editable ? .number : .none
        case .double(let raw):
            row.badge = "double"; row.tone = .number; row.value = raw; row.editText = raw
            row.field = editable ? .number : .none
        case .string(let data):
            if let text = phpText(data) {
                row.badge = "string"; row.tone = .string
                row.value = "\"" + JSONEditorModel.display(text) + "\""
                row.editText = text
                let long = text.contains("\n") || data.count > 400
                let nested = JSONEditorModel.nestedLabel(for: text)
                row.field = editable && !long ? .text : .none
                row.nestedLabel = nested ?? (long ? "Text" : nil)
            } else {
                row.badge = "string · binary"; row.tone = .locked
                row.value = "0x" + data.prefix(24).map { String(format: "%02X", $0) }.joined() + (data.count > 24 ? "… (\(data.count) bytes)" : "")
                row.lockNote = "This string isn't valid UTF-8, so it is shown as hex and kept byte-for-byte. It can't be edited here."
            }
        case .array(let entries):
            row.badge = "array · \(entries.count)"; row.tone = .container
            row.isContainer = true; row.childCount = entries.count; row.isExpanded = expanded.contains(path)
            row.canAdd = structuralEditsAllowed
            row.value = entries.isEmpty ? "[ ]" : "[ \(entries.count) item\(entries.count == 1 ? "" : "s") ]"
            row.valueMuted = true
        case .object(let cls, let props):
            row.badge = cls; row.tone = .className
            row.isContainer = true; row.childCount = props.count; row.isExpanded = expanded.contains(path)
            row.canAdd = structuralEditsAllowed
            row.value = "object · \(props.count) propert\(props.count == 1 ? "y" : "ies")"
            row.valueMuted = true
        case .customObject(let cls, let payload):
            row.badge = "C: \(cls)"; row.tone = .locked
            row.value = "custom-serialized · \(payload.count) bytes"; row.valueMuted = true
            row.lockNote = "“\(cls)” uses PHP's custom serialization (C:). Its payload is opaque to Querywell, so it is shown read-only and kept byte-for-byte."
        case .reference(let kind, let index):
            row.badge = kind == .object ? "object ref" : "reference"; row.tone = .locked
            row.value = "\(kind == .object ? "r" : "R"):\(index)"; row.valueMuted = true
            row.lockNote = "PHP references (r:/R:) point at another value by its position. Querywell shows them read-only, and adding or removing entries anywhere in this value is disabled, because that would shift the numbering."
        case .enumCase(let cls, let name):
            row.badge = "enum"; row.tone = .locked
            row.value = "\(cls)::\(name)"; row.valueMuted = true
            row.lockNote = "PHP 8.1 enum cases (E:) are shown read-only and kept byte-for-byte."
        }
        out.append(row)
        guard row.isExpanded else { return }
        let entries = value.entries
        let isArray: Bool
        if case .array = value { isArray = true } else { isArray = false }
        for (i, entry) in entries.enumerated() {
            let (k, isIdx, note) = Self.keyDisplay(entry.key, inObject: !isArray)
            build(value: entry.value, path: path + [i], key: k, keyIsIndex: isIdx, keyNote: note, parentIsArray: isArray, depth: depth + 1, into: &out)
        }
    }

    private func phpText(_ data: Data) -> String? { phpStringIfUTF8(data) }

    // MARK: Keys

    enum Visibility { case `public`, protected, `private`(String) }

    static func parseKey(_ data: Data) -> (Visibility, String) {
        let bytes = [UInt8](data)
        guard bytes.first == 0, let second = bytes.dropFirst().firstIndex(of: 0) else {
            return (.public, String(decoding: data, as: UTF8.self))
        }
        let cls = String(decoding: bytes[1..<second], as: UTF8.self)
        let name = String(decoding: bytes[(second + 1)...], as: UTF8.self)
        return cls == "*" ? (.protected, name) : (.private(cls), name)
    }

    static func mangle(_ name: String, like original: Visibility) -> Data {
        switch original {
        case .public: return Data(name.utf8)
        case .protected: return Data([0] + Array("*".utf8) + [0] + Array(name.utf8))
        case .private(let cls): return Data([0] + Array(cls.utf8) + [0] + Array(name.utf8))
        }
    }

    static func keyDisplay(_ key: PHPArrayKey, inObject: Bool) -> (String, Bool, String?) {
        switch key {
        case .int(let i): return (String(i), true, nil)
        case .string(let d):
            guard inObject else { return (String(decoding: d, as: UTF8.self), false, nil) }
            let (vis, name) = parseKey(d)
            switch vis {
            case .public: return (name, false, nil)
            case .protected: return (name, false, "protected")
            case .private(let cls): return (name, false, "private · \(cls)")
            }
        }
    }

    // MARK: Ids and lookup

    static func id(_ path: Path) -> String { path.isEmpty ? "root" : path.map(String.init).joined(separator: ".") }

    static func path(from id: String) -> Path? {
        if id == "root" { return [] }
        let parts = id.split(separator: ".").map { Int($0) }
        return parts.contains(where: { $0 == nil }) ? nil : parts.compactMap { $0 }
    }

    private static func steps(_ path: Path) -> [PHPPathStep] { path.map { .index($0) } }

    func value(at path: Path) -> PHPValue? { try? document?.value(at: Self.steps(path)) }

    func lockNote(for id: String) -> String? {
        guard let path = Self.path(from: id), let v = value(at: path) else { return nil }
        switch v {
        case .customObject, .reference, .enumCase:
            return rows().first(where: { $0.id == id })?.lockNote
        case .string(let d) where phpStringIfUTF8(d) == nil:
            return rows().first(where: { $0.id == id })?.lockNote
        default: return nil
        }
    }

    // MARK: Expansion

    func toggle(_ id: String) {
        guard let p = Self.path(from: id) else { return }
        if expanded.contains(p) { expanded.remove(p) } else { expanded.insert(p) }
    }

    func expandAll() {
        var all = Set<Path>()
        func walk(_ v: PHPValue, _ path: Path) {
            guard v.isContainer, all.count < 5_000 else { return }
            all.insert(path)
            for (i, e) in v.entries.enumerated() { walk(e.value, path + [i]) }
        }
        if let root = document?.root { walk(root, []) }
        expanded = all
    }

    func collapseAll() { expanded = [[]] }

    private func expandInitially() {
        var budget = 400
        var set: Set<Path> = [[]]
        func walk(_ v: PHPValue, _ path: Path, depth: Int) {
            guard v.isContainer, depth < 3, budget > 0 else { return }
            set.insert(path)
            budget -= v.entries.count
            for (i, e) in v.entries.enumerated() { walk(e.value, path + [i], depth: depth + 1) }
        }
        if let root = document?.root { walk(root, [], depth: 0) }
        expanded = set
    }

    // MARK: Edits

    static func message(_ error: PHPEditError) -> String {
        switch error {
        case .invalidPath: "That entry no longer exists."
        case .notContainer: "Select an array or object."
        case .readOnly: "This value is read-only."
        case .duplicateKey: "This array or object already has that key."
        case .indexOutOfRange: "That position is out of range."
        case .invalidKeyForObject: "Object property names must be strings."
        case .referencesWouldBreak: "This value contains PHP references (r:/R:), so adding, removing or replacing arrays and objects is disabled: it would break their numbering."
        case .unsupportedConversion: "That value can't be converted to this type."
        }
    }

    private func edit(_ body: (inout PHPDocument) throws -> Void) -> String? {
        guard !isReadOnly, var doc = document else { return nil }
        let before = doc
        do { try body(&doc) } catch let e as PHPEditError { return Self.message(e) } catch { return error.localizedDescription }
        history.append(before)
        if history.count > 100 { history.removeFirst() }
        document = doc
        source = doc.serialize()
        return nil
    }

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        document = last
        source = last.serialize()
        expanded = expanded.filter { value(at: $0) != nil }
    }

    func commitValue(id: String, text: String) -> String? {
        guard let path = Self.path(from: id), let current = value(at: path) else { return nil }
        let new: PHPValue
        switch current {
        case .string: new = .string(Data(text.utf8))
        case .int:
            guard let i = Int64(text.trimmingCharacters(in: .whitespaces)) else { return "“\(text)” is not a whole number that fits in 64 bits." }
            new = .int(i)
        case .double:
            let t = text.trimmingCharacters(in: .whitespaces)
            if ["INF", "-INF", "NAN"].contains(t) {
                new = .double(raw: t)
            } else if let x = Double(t), x.isFinite {
                new = .makeDouble(x)
            } else {
                return "“\(t)” is not a number (use for example 1.5, -2e10, INF or NAN)."
            }
        default: return nil
        }
        return edit { try $0.setValue(new, at: Self.steps(path)) }
    }

    func setBool(id: String, _ value: Bool) {
        guard let path = Self.path(from: id) else { return }
        _ = edit { try $0.setValue(.bool(value), at: Self.steps(path)) }
    }

    func renameKey(id: String, to text: String) -> String? {
        guard let path = Self.path(from: id), let last = path.last else { return nil }
        let parentPath = Array(path.dropLast())
        guard let parent = value(at: parentPath), parent.entries.indices.contains(last) else { return nil }
        let newKey: PHPArrayKey
        switch parent {
        case .object:
            guard case .string(let old) = parent.entries[last].key else { return "Object property names must be strings." }
            newKey = .string(Self.mangle(text, like: Self.parseKey(old).0))
        default:
            if let i = Int64(text), String(i) == text { newKey = .int(i) } else { newKey = .key(text) }
        }
        return edit { try $0.renameKey(at: Self.steps(path), to: newKey) }
    }

    func remove(id: String) {
        guard let path = Self.path(from: id), !path.isEmpty else { return }
        if let message = edit({ try $0.remove(at: Self.steps(path)) }) { lastMessage = message }
        selection = Self.id(Array(path.dropLast()))
    }

    /// Set when an edit that came from a menu (no inline field to show the reason in) was refused.
    var lastMessage: String?

    func duplicate(id: String) {
        guard let path = Self.path(from: id), let last = path.last else { return }
        let parentPath = Array(path.dropLast())
        guard let parent = value(at: parentPath), parent.entries.indices.contains(last) else { return }
        let entry = parent.entries[last]
        let key = Self.freshKey(basedOn: entry.key, in: parent)
        if let message = edit({ try $0.insert(entry.value, key: key, into: Self.steps(parentPath), at: last + 1) }) {
            lastMessage = message
        } else {
            selection = Self.id(parentPath + [last + 1])
        }
    }

    func add(to id: String?, type: String) {
        guard let kind = PHPValueType(rawValue: type) else { return }
        var containerPath: Path = []
        if let id, let p = Self.path(from: id) {
            containerPath = p
        } else if let selection, let p = Self.path(from: selection) {
            if value(at: p)?.isContainer == true { containerPath = p } else { containerPath = Array(p.dropLast()) }
        }
        guard let container = value(at: containerPath), container.isContainer else { lastMessage = "Select an array or object to add to."; return }
        let key = Self.freshKey(basedOn: nil, in: container)
        let new = Self.defaultValue(kind)
        if let message = edit({ try $0.insert(new, key: key, into: Self.steps(containerPath)) }) {
            lastMessage = message
        } else {
            expanded.insert(containerPath)
            selection = Self.id(containerPath + [container.entries.count])
        }
    }

    func changeType(id: String, to type: String) {
        guard let path = Self.path(from: id), let kind = PHPValueType(rawValue: type), value(at: path)?.type != kind else { return }
        if let message = edit({ try $0.changeType(at: Self.steps(path), to: kind) }) { lastMessage = message }
    }

    static func defaultValue(_ type: PHPValueType) -> PHPValue {
        switch type {
        case .null: .null
        case .bool: .bool(false)
        case .int: .int(0)
        case .double: .makeDouble(0)
        case .string: .string(Data())
        case .array: .array([])
        case .object: .object(className: "stdClass", properties: [])
        }
    }

    /// A key that is free in `container`: the next integer for list-like arrays, else `new_key`, `new_key_2`…
    static func freshKey(basedOn original: PHPArrayKey?, in container: PHPValue) -> PHPArrayKey {
        let entries = container.entries
        let isObject: Bool
        if case .object = container { isObject = true } else { isObject = false }
        let taken = Set(entries.map(\.key))
        if !isObject, entries.allSatisfy({ if case .int = $0.key { true } else { false } }) {
            let next = (entries.compactMap { k -> Int64? in if case .int(let i) = k.key { i } else { nil } }.max() ?? -1) + 1
            return .int(next)
        }
        var base = isObject ? "property" : "new_key"
        if let original, case .string(let d) = original {
            let (vis, name) = parseKey(d)
            base = name + "_copy"
            var candidate = mangle(base, like: isObject ? vis : .public)
            var n = 2
            while taken.contains(.string(candidate)) {
                candidate = mangle("\(base)_\(n)", like: isObject ? vis : .public)
                n += 1
            }
            return .string(candidate)
        }
        var candidate = PHPArrayKey.key(base)
        var n = 2
        while taken.contains(candidate) {
            candidate = .key("\(base)_\(n)")
            n += 1
        }
        return candidate
    }

    // MARK: Nested editors

    func replaceString(id: String, with data: Data) -> String? {
        guard let path = Self.path(from: id) else { return nil }
        return edit { try $0.setValue(.string(data), at: Self.steps(path)) }
    }

    func openNested(id: String) {
        guard let path = Self.path(from: id), case .string(let data)? = value(at: path) else { return }
        let text = phpStringIfUTF8(data)
        let label = text.flatMap(JSONEditorModel.nestedLabel(for:)) ?? "Text"
        openNestedHandler?(data, label) { [weak self] new in
            self?.replaceString(id: id, with: new)
        }
    }
}

/// UTF-8 text of `data`, or nil when it isn't valid UTF-8.
func phpStringIfUTF8(_ data: Data) -> String? { String(data: data, encoding: .utf8) }
