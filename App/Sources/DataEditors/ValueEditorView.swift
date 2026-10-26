import QuerywellCore
import SwiftUI

/// "Edit Value…": JSON / PHP serialized / plain text editor for one cell. A sheet; nested values open
/// another sheet on top.
struct ValueEditorView: View {
    @Bindable var model: ValueEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isReadOnly {
                EditorBanner(
                    style: .info, title: "View only",
                    detail: model.readOnlyReason ?? "This value can't be edited.")
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(item: $model.nested) { child in
            ValueEditorView(model: child)
        }
        .confirmationDialog("Discard your changes to this value?", isPresented: $model.confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { model.discardAndClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Nothing has been saved to the table yet.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Value editor, \(model.title)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if model.valueWasNull {
                        Text("NULL").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.chipText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                    }
                    if model.isReadOnly {
                        Label("View only", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(model.subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(model.availableModes) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Editor mode")
                Text(model.mode == model.detectedMode ? "Detected automatically" : "Detected: \(model.detectedMode.rawValue)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .json: JSONEditorView(model: model.json)
        case .php: PHPEditorView(model: model.php)
        case .text:
            VStack(spacing: 0) {
                if model.isBinaryData {
                    EditorBanner(
                        style: .info, title: "Binary data (\(model.originalData.count.formatted()) bytes)",
                        detail: "Not valid UTF-8, so it is shown as a hex dump and can't be edited as text.")
                }
                CodeTextView(
                    text: $model.plainText, syntax: .none, isEditable: !model.isReadOnly && !model.isBinaryData, wraps: !model.isBinaryData,
                    accessibilityLabel: model.isBinaryData ? "Hex dump" : "Text value")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(footerSummary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if let error = model.saveError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                } else if let reason = model.saveBlockedReason, !model.isReadOnly, model.hasChanges || !model.isValidForMode {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.isReadOnly {
                Button("Close") { model.onClose() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") { model.requestClose() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .buttonStyle(AccentFillButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                    .help("Record the change as a pending edit (⌘S). Nothing is written until you commit.")
                    .accessibilityHint("Records a pending edit; nothing is written until you commit")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private var footerSummary: String {
        switch model.mode {
        case .php: model.php.footer
        case .json: model.json.isValid ? "JSON · \(model.sizeSummary)" : "Invalid JSON · \(model.originalData.count.formatted()) B stored"
        case .text:
            model.isBinaryData ? "Binary · \(model.originalData.count.formatted()) B" : "Text · \(model.sizeSummary)"
        }
    }
}

extension ValueEditorModel {
    /// False while the active mode's content can't be saved as is (invalid JSON / malformed serialized data).
    var isValidForMode: Bool {
        switch mode {
        case .json: json.isValid
        case .php: php.isValid
        case .text: true
        }
    }
}
