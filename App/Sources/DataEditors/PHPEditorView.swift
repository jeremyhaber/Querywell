import QuerywellCore
import SwiftUI

struct PHPEditorView: View {
    @Bindable var model: PHPEditorModel
    @State private var repairMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let description = model.errorDescription {
                EditorBanner(
                    title: "Malformed serialized data", detail: description + (repairMessage.map { "\n" + $0 } ?? ""),
                    actionTitle: "Try to repair lengths…") { repairMessage = model.proposeRepair() }
            } else if model.containsReferences, !model.isReadOnly {
                EditorBanner(
                    style: .info, title: "This value contains PHP references (r:/R:)",
                    detail: "Scalars can be edited. Adding, removing or replacing arrays and objects is disabled because it would break the reference numbering.")
            }
            if model.isValid {
                switch model.pane {
                case .tree: tree
                case .raw: raw
                }
            } else {
                raw
            }
        }
        .sheet(isPresented: Binding(get: { model.repairProposal != nil }, set: { if !$0 { model.cancelRepair() } })) {
            if let proposal = model.repairProposal {
                PHPRepairPreview(proposal: proposal, accept: { model.acceptRepair() }, cancel: { model.cancelRepair() })
            }
        }
        .alert("Couldn't complete that", isPresented: Binding(get: { model.lastMessage != nil }, set: { if !$0 { model.lastMessage = nil } })) {
            Button("OK") { model.lastMessage = nil }
        } message: {
            Text(model.lastMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $model.pane) {
                ForEach(PHPEditorModel.Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130, alignment: .leading)
            .disabled(!model.isValid)
            .accessibilityLabel("PHP view")
            if model.pane == .raw || !model.isValid {
                Text(model.isValid ? "Read-only: edit in the Tree view" : "Read-only")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.chrome)
    }

    private var tree: some View {
        VStack(spacing: 0) {
            EditorTreeView(
                rows: model.rows(), selection: $model.selection, isReadOnly: model.isReadOnly,
                addTypes: PHPValueType.allCases.map(\.rawValue),
                actions: EditorTreeActions(
                    toggle: { model.toggle($0) },
                    commitValue: { model.commitValue(id: $0, text: $1) },
                    commitKey: { model.renameKey(id: $0, to: $1) },
                    setBool: { model.setBool(id: $0, $1) },
                    remove: { model.remove(id: $0) },
                    add: { model.add(to: $0, type: $1) },
                    duplicate: { model.duplicate(id: $0) },
                    changeType: { model.changeType(id: $0, to: $1) },
                    openNested: { model.openNested(id: $0) },
                    expandAll: { model.expandAll() },
                    collapseAll: { model.collapseAll() },
                    undo: model.canUndo ? { model.undo() } : nil))
            if let id = model.selection, let note = model.lockNote(for: id) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.sidebar)
                .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var raw: some View {
        CodeTextView(
            text: .constant(model.isValid ? model.rawText : String(decoding: model.source, as: UTF8.self)),
            syntax: .none, isEditable: false, wraps: true, errorOffset: model.parseError?.offset,
            accessibilityLabel: "Serialized text")
    }
}

/// Shows exactly what repair would change; nothing is applied until the user accepts.
struct PHPRepairPreview: View {
    var proposal: PHPRepairProposal
    var accept: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Repair string lengths").font(.system(size: 15, weight: .semibold))
                Text("PHP refuses serialized strings whose declared length doesn't match their bytes. \(proposal.fixes.count) string length\(proposal.fixes.count == 1 ? "" : "s") would be corrected; nothing else changes. The repair applies to this editor only, and you still review and save it like any other edit.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(proposal.fixes) { fix in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("byte \(fix.offset.formatted())").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 74, alignment: .leading)
                            HStack(spacing: 4) {
                                Text("s:\(fix.declared)")
                                    .foregroundStyle(Theme.dangerText)
                                    .padding(.horizontal, 4)
                                    .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: 3))
                                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                                Text("s:\(fix.actual)")
                                    .foregroundStyle(Theme.pendingInsertedText)
                                    .padding(.horizontal, 4)
                                    .background(Theme.pendingInsertedRow, in: RoundedRectangle(cornerRadius: 3))
                            }
                            .font(.system(size: 12, design: .monospaced))
                            Text("“\(fix.preview)”").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("At byte \(fix.offset), length \(fix.declared) becomes \(fix.actual), string starts \(fix.preview)")
                        Divider()
                    }
                    if proposal.fixes.isEmpty {
                        Text("The repaired text differs in ways that can't be listed as length fixes.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(16)
                    }
                }
            }
            .frame(height: min(260, CGFloat(max(1, proposal.fixes.count)) * 34 + 8))
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply Repair", action: accept)
                    .buttonStyle(AccentFillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repair preview")
    }
}
