import Foundation
import Observation
import QuerywellCore

/// The value editor: one cell's value as JSON, PHP serialized data or plain text.
///
/// Saving never writes to the database. It hands the new bytes to `onSave`, which records a pending
/// edit in the table tab's `EditSession`; the normal Review / Commit flow takes over from there.
@MainActor @Observable
final class ValueEditorModel: Identifiable {
    enum Mode: String, CaseIterable, Identifiable {
        case json = "JSON", php = "PHP serialized", text = "Text"
        var id: String { rawValue }
    }

    let id = UUID()
    /// "wp_options · option_value"
    let title: String
    /// "option_id 12 · longtext"
    let subtitle: String
    let originalData: Data
    let isReadOnly: Bool
    let readOnlyReason: String?
    let valueWasNull: Bool
    /// The stored bytes aren't valid UTF-8, so only a hex view is possible (plus PHP, which is byte-safe).
    let isBinaryData: Bool
    let detectedMode: Mode

    private(set) var mode: Mode
    private(set) var json: JSONEditorModel
    private(set) var php: PHPEditorModel
    var plainText: String
    var nested: ValueEditorModel?
    var saveError: String?
    var confirmingDiscard = false

    @ObservationIgnored var onSave: (Data) -> CellInputError?
    @ObservationIgnored var onClose: () -> Void = {}

    init(title: String, subtitle: String, data: Data, isReadOnly: Bool, readOnlyReason: String? = nil, valueWasNull: Bool = false,
         forcedMode: Mode? = nil, onSave: @escaping (Data) -> CellInputError?) {
        self.title = title
        self.subtitle = subtitle
        originalData = data
        self.isReadOnly = isReadOnly
        self.readOnlyReason = readOnlyReason
        self.valueWasNull = valueWasNull
        self.onSave = onSave
        let text = String(data: data, encoding: .utf8)
        isBinaryData = text == nil
        let detected = Self.detect(data)
        detectedMode = detected
        let start = forcedMode ?? detected
        mode = start
        json = JSONEditorModel(text: text ?? "", isReadOnly: isReadOnly || text == nil)
        php = PHPEditorModel(data: data, isReadOnly: isReadOnly)
        plainText = text ?? HexDump.string(data)
        if start == .json, text == nil { mode = .text }
        wire()
    }

    static func detect(_ data: Data) -> Mode {
        if PHPSerialized.looksSerialized(data) { return .php }
        if let s = String(data: data, encoding: .utf8), JSONDocument.looksLikeJSON(s) { return .json }
        return .text
    }

    private func wire() {
        let handler: (Data, String, @escaping (Data) -> String?) -> Void = { [weak self] data, label, apply in
            self?.presentNested(data: data, label: label, apply: apply)
        }
        json.openNestedHandler = handler
        php.openNestedHandler = handler
    }

    private func presentNested(data: Data, label: String, apply: @escaping (Data) -> String?) {
        let forced: Mode = label == "JSON" ? .json : label == "PHP serialized" ? .php : .text
        let child = ValueEditorModel(
            title: "Nested \(label) value", subtitle: title, data: data, isReadOnly: isReadOnly, readOnlyReason: readOnlyReason,
            forcedMode: forced,
            onSave: { new in
                if let message = apply(new) { return CellInputError(message) }
                return nil
            })
        child.onClose = { [weak self] in self?.nested = nil }
        nested = child
    }

    // MARK: Modes

    /// Modes the picker offers. JSON needs text; invalid-UTF-8 data only shows as hex or PHP.
    var availableModes: [Mode] { isBinaryData ? [.php, .text] : Mode.allCases }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        let carry = currentData
        mode = new
        switch new {
        case .json:
            json = JSONEditorModel(text: String(decoding: carry, as: UTF8.self), isReadOnly: isReadOnly || isBinaryData)
            wire()
        case .php:
            php = PHPEditorModel(data: carry, isReadOnly: isReadOnly)
            wire()
        case .text:
            plainText = isBinaryData ? HexDump.string(carry) : String(decoding: carry, as: UTF8.self)
        }
        saveError = nil
    }

    // MARK: Output

    var currentData: Data {
        switch mode {
        case .json: Data((json.output ?? json.rawText).utf8)
        case .php: php.currentData
        case .text: isBinaryData ? originalData : Data(plainText.utf8)
        }
    }

    var hasChanges: Bool { currentData != originalData }

    /// Why Save is unavailable, nil when it can run.
    var saveBlockedReason: String? {
        if isReadOnly { return readOnlyReason ?? "This value is view-only." }
        switch mode {
        case .json: if !json.isValid { return "Fix the JSON error before saving." }
        case .php: if !php.isValid { return "The serialized data is malformed. Fix it or repair the lengths before saving." }
        case .text: if isBinaryData { return "Binary data can't be edited as text." }
        }
        if !hasChanges { return "No changes to save." }
        return nil
    }

    var canSave: Bool { saveBlockedReason == nil }

    /// Records the edit through `onSave`; closes on success.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        if let error = onSave(currentData) {
            saveError = error.message
            return false
        }
        saveError = nil
        onClose()
        return true
    }

    /// Cancel / Esc: asks first when there are unsaved changes.
    func requestClose() {
        if hasChanges, !isReadOnly { confirmingDiscard = true } else { onClose() }
    }

    func discardAndClose() {
        confirmingDiscard = false
        onClose()
    }

    /// "Size 1,204 B → 1,190 B" for the footer.
    var sizeSummary: String {
        let before = originalData.count, after = currentData.count
        let f = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        let exact = { (n: Int) in n.formatted() + " B" }
        if before == after { return "\(exact(before))" + (hasChanges ? " (same size)" : "") }
        return "\(exact(before)) → \(exact(after))" + (abs(after - before) > 1023 ? " (\(f(after)))" : "")
    }
}
