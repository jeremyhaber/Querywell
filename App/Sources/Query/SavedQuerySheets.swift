import QuerywellCore
import SwiftUI

/// Name / notes / tags / scope form shared by "Save as…" and "Edit details…" of saved queries.
struct SavedQueryForm: View {
    var title: String
    var actionTitle: String
    @State var name: String
    @State var notes: String
    @State var tags: String
    @State var isGlobal: Bool
    var onCancel: () -> Void
    var onSave: (_ name: String, _ notes: String?, _ tags: [String], _ global: Bool) -> Void
    @FocusState private var nameFocused: Bool

    init(title: String, actionTitle: String = "Save", name: String = "", notes: String = "", tags: [String] = [], isGlobal: Bool = false,
         onCancel: @escaping () -> Void, onSave: @escaping (String, String?, [String], Bool) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        _name = State(initialValue: name)
        _notes = State(initialValue: notes)
        _tags = State(initialValue: tags.joined(separator: ", "))
        _isGlobal = State(initialValue: isGlobal)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Name")
                TextField("Pages edited this month", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Notes")
                TextField("Optional", text: $notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Tags")
                TextField("comma, separated", text: $tags).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Available in")
                Picker("Scope", selection: $isGlobal) {
                    Text("This connection").tag(false)
                    Text("All connections").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).buttonStyle(OutlineButtonStyle())
                Button(actionTitle) {
                    let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(name, n.isEmpty ? nil : n, Self.parseTags(tags), isGlobal)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(AccentFillButtonStyle()).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.background)
        .onAppear { nameFocused = true }
    }

    static func parseTags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Create or edit a snippet.
struct SnippetForm: View {
    var existing: Snippet?
    @State var name: String
    @State var sql: String
    @State var tags: String
    @State var isGlobal: Bool
    var onCancel: () -> Void
    var onSave: (_ name: String, _ sql: String, _ tags: [String], _ global: Bool) -> Void

    init(existing: Snippet?, sql: String, onCancel: @escaping () -> Void,
         onSave: @escaping (String, String, [String], Bool) -> Void) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _sql = State(initialValue: existing?.sql ?? sql)
        _tags = State(initialValue: (existing?.tags ?? []).joined(separator: ", "))
        _isGlobal = State(initialValue: existing == nil ? true : existing?.connectionID == nil)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New snippet" : "Edit snippet").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Name")
                TextField("Autoloaded options", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("SQL")
                PlaceholderTextEditor(text: $sql, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                    .frame(height: 120)
                    .accessibilityLabel("SQL")
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
                Text("Use $1, ${2:default} for tab stops and $0 for the final cursor.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Tags")
                TextField("comma, separated", text: $tags).textFieldStyle(.roundedBorder)
            }
            if existing == nil {
                Picker("Available in", selection: $isGlobal) {
                    Text("This connection").tag(false)
                    Text("All connections").tag(true)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).buttonStyle(OutlineButtonStyle())
                Button("Save") { onSave(name, sql, SavedQueryForm.parseTags(tags), isGlobal) }
                    .keyboardShortcut(.defaultAction).buttonStyle(AccentFillButtonStyle()).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.background)
    }
}
