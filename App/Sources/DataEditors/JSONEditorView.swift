import QuerywellCore
import SwiftUI

/// Banner used by the editors for parse errors (red) and notes.
struct EditorBanner: View {
    enum Style { case error, info }
    var style: Style = .error
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style == .error ? "exclamationmark.octagon.fill" : "info.circle.fill")
                .foregroundStyle(style == .error ? Theme.dangerText : Theme.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(style == .error ? Theme.dangerText : Theme.text)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(style == .error ? Theme.dangerBackground : Theme.accentSubtleBackground)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct JSONEditorView: View {
    @Bindable var model: JSONEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.error {
                EditorBanner(
                    title: "Invalid JSON · line \(error.line), column \(error.column)", detail: error.message,
                    actionTitle: "Jump to error") { model.jumpToError() }
            }
            switch model.pane {
            case .tree: tree
            case .raw: raw
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $model.pane) {
                ForEach(JSONEditorModel.Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("JSON view")

            Button { model.prettyPrint() } label: { Label("Pretty-print", systemImage: "text.alignleft") }
                .disabled(!model.isValid || model.isReadOnly)
                .help("Re-indent the text")
            Button { model.minify() } label: { Label("Minify", systemImage: "arrow.right.and.line.vertical.and.arrow.left") }
                .disabled(!model.isValid || model.isReadOnly)
                .help("Remove all whitespace")
            Spacer()
            HStack(spacing: 6) {
                Text("Save as").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Picker("Save as", selection: $model.saveFormat) {
                    ForEach(JSONEditorModel.SaveFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Save format")
                .help("Keep original formatting writes the document back in the style it was found in")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
    }

    @ViewBuilder
    private var tree: some View {
        if model.isValid {
            EditorTreeView(
                rows: model.rows(), selection: $model.selection, isReadOnly: model.isReadOnly,
                addTypes: JSONEditorModel.Kind.allCases.map(\.rawValue),
                actions: EditorTreeActions(
                    toggle: { model.toggle($0) },
                    commitValue: { model.commitValue(id: $0, text: $1) },
                    commitKey: { model.renameKey(id: $0, to: $1) },
                    setBool: { model.setBool(id: $0, $1) },
                    remove: { model.remove(id: $0) },
                    add: { model.add(to: $0, type: $1) },
                    duplicate: { model.duplicate(id: $0) },
                    move: { model.move(id: $0, by: $1) },
                    changeType: { model.changeType(id: $0, to: $1) },
                    openNested: { model.openNested(id: $0) },
                    expandAll: { model.expandAll() },
                    collapseAll: { model.collapseAll() },
                    undo: model.canUndo ? { model.undo() } : nil),
                summary: "\(model.nodeCount.formatted()) node\(model.nodeCount == 1 ? "" : "s")")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "curlybraces").font(.system(size: 30)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                Text("The tree needs valid JSON").font(.system(size: 14, weight: .semibold))
                Text("Fix the error in the Raw view and the tree comes back.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button("Open Raw View") { model.jumpToError() }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }

    private var raw: some View {
        CodeTextView(
            text: Binding(get: { model.rawText }, set: { model.setRaw($0) }),
            syntax: .json, isEditable: !model.isReadOnly, wraps: false,
            errorOffset: model.error?.offset, jump: model.jump, accessibilityLabel: "Raw JSON")
    }
}
