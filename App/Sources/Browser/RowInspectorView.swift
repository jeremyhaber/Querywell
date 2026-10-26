import QuerywellCore
import SwiftUI

/// Everything the inspector needs to edit the selected row. `nil` on the view = read-only.
struct InspectorEditing {
    /// Per-column editing facts for the selected row.
    var info: (String) -> CellEditInfo
    /// Returns why the text was rejected, nil when it was recorded.
    var commitText: (String, String) -> CellInputError?
    var setNull: (String) -> Void
    var revertCell: (String) -> Void
    /// The SQL the selected row will run on commit (design: PENDING SQL).
    var pendingSQL: String?
    /// Total unsaved edits in the table ("Commit 2").
    var pendingCount: Int
    var isCommitting: Bool
    var onDiscard: () -> Void
    var onCommit: () -> Void
}

/// Right-hand panel for the selected row (design: Main.dc.html, "Row inspector").
///
/// Read-only unless `editing` is set: then each field edits in place (changes become pending edits,
/// drawn with the amber styling) and the PENDING SQL box with Discard / Commit N appears below.
struct RowInspectorView: View {
    var title: String
    var subtitle: String?
    var columns: [GridColumn]
    var values: [DatabaseValue]?
    var focusColumn: String?
    var nullDisplay: String
    var onClose: () -> Void
    var editing: InspectorEditing?
    /// Opens the value editor for a column of the selected row ("Open in editor").
    var onOpenEditor: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close inspector (⌥⌘I)")
                .accessibilityLabel("Close inspector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let values, values.count == columns.count {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                                InspectorField(
                                    column: column, value: values[index], nullDisplay: nullDisplay,
                                    isFocused: focusColumn?.caseInsensitiveCompare(column.name) == .orderedSame,
                                    editing: editing, onOpenEditor: onOpenEditor)
                                    .id(column.name)
                            }
                            if let editing, editing.pendingCount > 0 { pendingSection(editing) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: focusColumn) { _, _ in scroll(proxy) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.and.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                    Text("Select a row to inspect it").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Row inspector")
    }

    private func pendingSection(_ editing: InspectorEditing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sql = editing.pendingSQL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PENDING SQL")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(sql)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Button(action: editing.onDiscard) {
                    Text("Discard").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(editing.isCommitting)
                .help("Discard this row's pending changes")
                Button(action: editing.onCommit) {
                    Text("Commit \(editing.pendingCount)").frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(AccentFillButtonStyle())
                .disabled(editing.isCommitting)
                .help("Commit all \(editing.pendingCount) unsaved edits")
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.top, 2)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focusColumn else { return }
        Motion.animate { proxy.scrollTo(focusColumn, anchor: .center) }
    }
}

/// One labelled value. Short values are one line; long text and JSON get a multiline monospaced box.
/// With `editing` the box is an editor; an edited value gets the amber pending styling.
struct InspectorField: View {
    var column: GridColumn
    var value: DatabaseValue
    var nullDisplay: String
    var isFocused: Bool
    var editing: InspectorEditing?
    var onOpenEditor: ((String) -> Void)?

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var info: CellEditInfo? { editing?.info(column.name) }
    private var canEdit: Bool { info?.canEdit == true }
    private var isEdited: Bool { info?.isEdited == true }
    private var fullText: String { CellDisplay.full(value, limit: 20_000) }
    private var sourceText: String { CellValueParser.editingText(for: value) }

    private var isMultiline: Bool {
        guard case .text(let s) = value else { return column.presentation.kind == .json || column.presentation.kind == .longText }
        return s.contains("\n") || s.count > 60 || column.presentation.kind == .json || column.presentation.kind == .longText
    }

    /// Text, JSON and binary values open in the value editor (not NULLs).
    private var offersEditor: Bool {
        guard !value.isNull else { return false }
        return isStructured || isMultiline || TableDataModel.supportsValueEditor(column.presentation.kind) && column.presentation.kind != .other
    }

    private var isStructured: Bool {
        guard case .text(let s) = value else { return false }
        return ValueSniffer.isJSONLike(s) || ValueSniffer.isPHPSerialized(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.pendingEditBar).accessibilityLabel("Primary key")
                }
                Text(column.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(column.fullType).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                if canEdit {
                    if isEdited {
                        Button("Revert") { editing?.revertCell(column.name) }
                            .controlSize(.mini).help("Undo the edit of \(column.name)")
                    }
                    if info?.isNullable == true, !(info?.currentIsNull ?? false) {
                        Button("NULL") { editing?.setNull(column.name) }
                            .controlSize(.mini).help("Set \(column.name) to NULL")
                    }
                }
                if let onOpenEditor, offersEditor {
                    Button("Open in editor") { onOpenEditor(column.name) }
                        .controlSize(.mini)
                        .help(canEdit ? "Edit this value as JSON, PHP serialized data or text" : "View this value as JSON, PHP serialized data or text")
                        .accessibilityLabel("Open \(column.name) in the value editor")
                }
            }
            if canEdit, let info { editor(info) } else { box }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.dangerText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: canEdit ? .contain : .combine)
        .accessibilityLabel("\(column.name): \(value.isNull ? "null" : CellDisplay.text(value, nullDisplay: nullDisplay))\(isEdited ? ", edited" : "")")
        .onAppear { draft = sourceText }
        .onChange(of: value) { _, _ in
            draft = sourceText
            error = nil
        }
    }

    // MARK: Editing

    @ViewBuilder
    private func editor(_ info: CellEditInfo) -> some View {
        if info.usesPicker {
            picker(info)
        } else if isMultiline || info.prefersInspector {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 130)
                .padding(4)
                .modifier(FieldChrome(isEdited: isEdited, isFocused: isFocused || fieldFocused, hasError: error != nil))
                .focused($fieldFocused)
                .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                .accessibilityLabel(column.name)
        } else {
            TextField(value.isNull ? nullDisplay : "", text: $draft)
                .textFieldStyle(.plain)
                .font(column.presentation.usesMonospace ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .modifier(FieldChrome(isEdited: isEdited, isFocused: isFocused || fieldFocused, hasError: error != nil))
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                .accessibilityLabel(column.name)
        }
    }

    private func picker(_ info: CellEditInfo) -> some View {
        let current = value.isNull ? "\u{0}NULL" : sourceText
        return Picker(column.name, selection: Binding(
            get: { current },
            set: { choice in
                if choice == "\u{0}NULL" { editing?.setNull(column.name) } else { error = editing?.commitText(column.name, choice)?.message }
            })
        ) {
            ForEach(info.choices, id: \.self) { Text($0).tag($0) }
            if info.isNullable { Text("NULL").tag("\u{0}NULL") }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FieldChrome(isEdited: isEdited, isFocused: isFocused, hasError: false))
    }

    private func commit() {
        guard canEdit, draft != sourceText else { return }
        error = editing?.commitText(column.name, draft)?.message
    }

    // MARK: Read-only box

    @ViewBuilder
    private var box: some View {
        let font: Font = column.presentation.usesMonospace || isMultiline || isStructured
            ? .system(size: 12, design: .monospaced) : .system(size: 13)
        Group {
            if value.isNull {
                Text(nullDisplay).font(.system(size: 12, design: .monospaced)).italic().foregroundStyle(Theme.textTertiary)
            } else if isMultiline {
                ScrollView {
                    Text(fullText).font(font).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } else {
                Text(fullText).font(font).textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(isFocused ? Theme.accent : Theme.separator, lineWidth: isFocused ? 1.5 : 1))
    }
}

/// Box styling shared by the inspector's editors: amber when the value has a pending edit.
private struct FieldChrome: ViewModifier {
    var isEdited: Bool
    var isFocused: Bool
    var hasError: Bool

    func body(content: Content) -> some View {
        content
            .background(isEdited ? Theme.pendingFieldBackground : Theme.background, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .strokeBorder(border, lineWidth: isFocused || hasError ? 1.5 : 1))
    }

    private var border: Color {
        if hasError { return Theme.dangerText }
        if isFocused { return Theme.accent }
        return isEdited ? Theme.pendingPillBorder : Theme.separator
    }
}
