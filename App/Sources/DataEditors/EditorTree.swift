import SwiftUI

// The tree both structured editors (JSON, PHP serialized) render: one flat list of rows with
// indentation, a key column, a type badge and a value column. The models build `EditorTreeRow`s;
// this view only draws them and forwards intents through `EditorTreeActions`.

enum TreeTone {
    case neutral, string, number, bool, null, container, className, locked
}

/// How the value cell of a row is edited.
enum TreeValueField: Equatable {
    case none, text, number, bool
}

struct EditorTreeRow: Identifiable, Equatable {
    var id: String
    var depth = 0
    var key = ""
    /// Array index (drawn muted, in mono) rather than a name.
    var keyIsIndex = false
    /// Small qualifier after the key ("protected", "private · Foo").
    var keyNote: String?
    var badge = ""
    var tone: TreeTone = .neutral
    var value = ""
    var valueMuted = false
    var field: TreeValueField = .none
    /// What the inline text field starts with.
    var editText = ""
    var boolValue: Bool?
    var isContainer = false
    var isExpanded = false
    var childCount = 0
    /// Set for rows Querywell shows but does not edit (PHP `C:` objects, references, enums).
    var lockNote: String?
    /// "JSON" / "PHP serialized" / "Text": the string value can be opened in a nested editor.
    var nestedLabel: String?
    var canEditKey = false
    var canRemove = false
    var canMoveUp = false
    var canMoveDown = false
    var canAdd = false
    var canDuplicate = false
    var typeChoices: [String] = []
    var currentType = ""
}

struct EditorTreeActions {
    var toggle: (String) -> Void = { _ in }
    /// Both return a message when the text was rejected.
    var commitValue: (String, String) -> String? = { _, _ in nil }
    var commitKey: (String, String) -> String? = { _, _ in nil }
    var setBool: (String, Bool) -> Void = { _, _ in }
    var remove: (String) -> Void = { _ in }
    /// (container row id or nil for the selection / root, type name)
    var add: (String?, String) -> Void = { _, _ in }
    var duplicate: (String) -> Void = { _ in }
    var move: (String, Int) -> Void = { _, _ in }
    var changeType: (String, String) -> Void = { _, _ in }
    var openNested: (String) -> Void = { _ in }
    var expandAll: () -> Void = {}
    var collapseAll: () -> Void = {}
    var undo: (() -> Void)?
}

extension TreeTone {
    var background: Color {
        switch self {
        case .neutral, .null: Theme.chipBackground
        case .string: Theme.pillPositiveBackground
        case .number: Theme.warningBackground
        case .bool: Theme.tabQuery.opacity(0.14)
        case .container: Theme.accentSubtleBackground
        case .className: Theme.tabQuery.opacity(0.14)
        case .locked: Theme.chipBackground
        }
    }

    var foreground: Color {
        switch self {
        case .neutral, .null, .locked: Theme.chipText
        case .string: Theme.pillPositiveText
        case .number: Theme.warningText
        case .bool, .className: Theme.tabQuery
        case .container: Theme.accentSubtleText
        }
    }

    var valueColor: Color {
        switch self {
        case .string: Color(nsColor: EditorSyntaxColors.string)
        case .number: Color(nsColor: EditorSyntaxColors.number)
        case .bool: Color(nsColor: EditorSyntaxColors.literal)
        case .null, .locked: Theme.textTertiary
        default: Theme.text
        }
    }
}

struct TypeBadge: View {
    var text: String
    var tone: TreeTone
    var locked = false

    var body: some View {
        HStack(spacing: 3) {
            if locked { Image(systemName: "lock.fill").font(.system(size: 8)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }
}

struct EditorTreeView: View {
    var rows: [EditorTreeRow]
    @Binding var selection: String?
    var isReadOnly: Bool
    var addTypes: [String]
    var actions: EditorTreeActions
    /// Shown above the list (for example "10,482 nodes").
    var summary: String?

    private struct EditTarget: Equatable {
        enum Field { case key, value }
        var id: String
        var field: Field
        var draft: String
    }

    @State private var editing: EditTarget?
    @State private var errorMessage: String?
    @State private var hovered: String?
    @FocusState private var fieldFocused: Bool

    private let keyColumn: CGFloat = 270
    private let typeColumn: CGFloat = 118

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            header
            Divider()
            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(row)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .tag(row.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .environment(\.defaultMinListRowHeight, 26)
            .onKeyPress(.return) {
                guard !isReadOnly, let id = selection, let row = rows.first(where: { $0.id == id }) else { return .ignored }
                if row.field != .none, row.field != .bool { beginEdit(row, .value) } else if row.nestedLabel != nil { actions.openNested(row.id) } else { return .ignored }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard let id = selection, let row = rows.first(where: { $0.id == id }), row.isContainer, !row.isExpanded else { return .ignored }
                actions.toggle(id)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard let id = selection, let row = rows.first(where: { $0.id == id }), row.isContainer, row.isExpanded else { return .ignored }
                actions.toggle(id)
                return .handled
            }
            .onKeyPress(.delete) {
                guard !isReadOnly, editing == nil, let id = selection, let row = rows.first(where: { $0.id == id }), row.canRemove else { return .ignored }
                actions.remove(id)
                return .handled
            }
            .accessibilityLabel("Value tree")
            if let message = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.dangerText).accessibilityHidden(true)
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                    Spacer()
                    Button("Dismiss") { errorMessage = nil }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.dangerBackground)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Toolbar and header

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !isReadOnly {
                Menu {
                    ForEach(addTypes, id: \.self) { type in
                        Button(type.capitalized) { actions.add(nil, type) }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Add an entry to the selected array or object")
                .accessibilityLabel("Add entry")
                if let undo = actions.undo {
                    Button(action: undo) { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .controlSize(.small)
                        .help("Undo the last tree edit")
                }
            }
            Spacer()
            if let summary { Text(summary).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            Button { actions.expandAll() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .controlSize(.small)
                .help("Expand all")
                .accessibilityLabel("Expand all")
            Button { actions.collapseAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .controlSize(.small)
                .help("Collapse all")
                .accessibilityLabel("Collapse all")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("KEY").frame(width: keyColumn, alignment: .leading)
            Text("TYPE").frame(width: typeColumn, alignment: .leading)
            Text("VALUE").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 16)
        .padding(.trailing, 36)
        .padding(.vertical, 5)
        .background(Theme.sidebar)
        .accessibilityHidden(true)
    }

    // MARK: Rows

    private func rowView(_ row: EditorTreeRow) -> some View {
        HStack(spacing: 0) {
            keyCell(row).frame(width: keyColumn, alignment: .leading)
            HStack(spacing: 0) {
                TypeBadge(text: row.badge, tone: row.tone, locked: row.lockNote != nil)
                Spacer(minLength: 0)
            }
            .frame(width: typeColumn, alignment: .leading)
            valueCell(row).frame(maxWidth: .infinity, alignment: .leading)
            rowMenuButton(row)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .contextMenu { rowMenu(row) }
        .help(row.lockNote ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.key.isEmpty ? "root" : row.key), \(row.badge), \(row.value)\(row.lockNote != nil ? ", read only" : "")")
        .accessibilityAddTraits(selection == row.id ? .isSelected : [])
        .accessibilityActions {
            if !isReadOnly, row.field == .text || row.field == .number {
                Button("Edit value") { beginEdit(row, .value) }
            }
            if !isReadOnly, row.canRemove { Button("Remove") { actions.remove(row.id) } }
            if row.isContainer { Button(row.isExpanded ? "Collapse" : "Expand") { actions.toggle(row.id) } }
            if row.nestedLabel != nil { Button("Open nested editor") { actions.openNested(row.id) } }
        }
    }

    private func keyCell(_ row: EditorTreeRow) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            if row.isContainer {
                Button { actions.toggle(row.id) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            if let editing, editing.id == row.id, editing.field == .key {
                TextField("Key", text: Binding(get: { self.editing?.draft ?? "" }, set: { self.editing?.draft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commitEdit() } }
            } else {
                Text(row.key.isEmpty ? "(root)" : row.key)
                    .font(.system(size: 12, weight: row.keyIsIndex ? .regular : .medium, design: row.keyIsIndex ? .monospaced : .default))
                    .foregroundStyle(row.keyIsIndex || row.key.isEmpty ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { if !isReadOnly, row.canEditKey { beginEdit(row, .key) } }
                if let note = row.keyNote {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if row.lockNote != nil {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func valueCell(_ row: EditorTreeRow) -> some View {
        if let editing, editing.id == row.id, editing.field == .value {
            TextField("Value", text: Binding(get: { self.editing?.draft ?? "" }, set: { self.editing?.draft = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { cancelEdit() }
                .onAppear { fieldFocused = true }
                .onChange(of: fieldFocused) { _, focused in if !focused { commitEdit() } }
                .accessibilityLabel("Value of \(row.key)")
        } else if row.field == .bool, !isReadOnly, let current = row.boolValue {
            Picker("Value", selection: Binding(get: { current }, set: { actions.setBool(row.id, $0) })) {
                Text("true").tag(true)
                Text("false").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Value of \(row.key)")
        } else {
            HStack(spacing: 6) {
                Text(row.value)
                    .font(.system(size: 12, design: .monospaced))
                    .italic(row.valueMuted)
                    .foregroundStyle(row.valueMuted ? Theme.textTertiary : row.tone.valueColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) {
                        guard !isReadOnly else { return }
                        if row.field == .text || row.field == .number { beginEdit(row, .value) } else if row.nestedLabel != nil { actions.openNested(row.id) }
                    }
                if let label = row.nestedLabel {
                    Button { actions.openNested(row.id) } label: {
                        HStack(spacing: 3) {
                            Text(label)
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentSubtleBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open this value in a nested \(label) editor")
                    .accessibilityLabel("Open nested \(label) editor")
                }
            }
        }
    }

    private func rowMenuButton(_ row: EditorTreeRow) -> some View {
        Menu { rowMenu(row) } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28)
        .opacity(hovered == row.id || selection == row.id ? 1 : 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rowMenu(_ row: EditorTreeRow) -> some View {
        if !isReadOnly {
            if row.field == .text || row.field == .number {
                Button("Edit Value") { beginEdit(row, .value) }
            }
            if row.canEditKey { Button("Rename Key") { beginEdit(row, .key) } }
            if row.nestedLabel != nil { Button("Open Nested \(row.nestedLabel ?? "") Editor") { actions.openNested(row.id) } }
            if row.canAdd {
                Menu("Add Child") {
                    ForEach(addTypes, id: \.self) { type in Button(type.capitalized) { actions.add(row.id, type) } }
                }
            }
            if !row.typeChoices.isEmpty {
                Menu("Change Type") {
                    ForEach(row.typeChoices, id: \.self) { type in
                        Button { actions.changeType(row.id, type) } label: {
                            if type == row.currentType { Label(type.capitalized, systemImage: "checkmark") } else { Text(type.capitalized) }
                        }
                    }
                }
            }
            if row.canDuplicate { Button("Duplicate") { actions.duplicate(row.id) } }
            if row.canMoveUp { Button("Move Up") { actions.move(row.id, -1) } }
            if row.canMoveDown { Button("Move Down") { actions.move(row.id, 1) } }
            if row.canRemove {
                Divider()
                Button("Remove", role: .destructive) { actions.remove(row.id) }
            }
        } else if row.nestedLabel != nil {
            Button("Open Nested \(row.nestedLabel ?? "") Viewer") { actions.openNested(row.id) }
        }
        if row.isContainer {
            Divider()
            Button(row.isExpanded ? "Collapse" : "Expand") { actions.toggle(row.id) }
        }
    }

    // MARK: Editing

    private func beginEdit(_ row: EditorTreeRow, _ field: EditTarget.Field) {
        guard !isReadOnly else { return }
        errorMessage = nil
        selection = row.id
        editing = EditTarget(id: row.id, field: field, draft: field == .key ? row.key : row.editText)
    }

    private func cancelEdit() {
        editing = nil
        fieldFocused = false
    }

    private func commitEdit() {
        guard let target = editing else { return }
        editing = nil
        guard let row = rows.first(where: { $0.id == target.id }) else { return }
        let original = target.field == .key ? row.key : row.editText
        guard target.draft != original else { return }
        let message = target.field == .key ? actions.commitKey(target.id, target.draft) : actions.commitValue(target.id, target.draft)
        errorMessage = message
    }
}
