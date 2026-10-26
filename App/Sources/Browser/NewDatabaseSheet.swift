import Observation
import QuerywellCore
import SwiftUI

/// State of the New Database sheet. The statement comes from Core (`DatabaseDDL`); running it goes
/// through the workspace's write gate.
@MainActor @Observable
final class NewDatabaseModel: Identifiable {
    enum Phase: Equatable {
        case editing
        case running
        case created(String)
    }

    let id = UUID()
    let workspace: ConnectionWorkspace
    var name = ""
    /// `nil` = the server's default.
    var characterSet: String? { didSet { if characterSet != oldValue { collation = nil } } }
    var collation: String?
    var owner: String?
    var encoding: String?
    var template: String?
    private(set) var options: DatabaseCreationOptions?
    private(set) var phase = Phase.editing
    private(set) var errorMessage: String?

    init(workspace: ConnectionWorkspace) {
        self.workspace = workspace
    }

    var isPostgres: Bool { workspace.profile.engine == .postgresql }
    private var dialect: SQLDialect { SQLDialect(workspace.profile.engine) }

    var spec: NewDatabaseSpec {
        NewDatabaseSpec(
            name: name, characterSet: characterSet, collation: collation, owner: owner, encoding: encoding, template: template)
    }

    var sql: String { DatabaseDDL.create(spec, dialect: dialect) }

    /// Reasons the Create button is off. Nothing is reported for an untouched, empty name.
    var problems: [String] {
        let all = DatabaseDDL.problems(spec, dialect: dialect, existing: workspace.databases)
        return name.isEmpty ? [] : all
    }

    var canCreate: Bool {
        phase == .editing && !name.isEmpty && DatabaseDDL.problems(spec, dialect: dialect, existing: workspace.databases).isEmpty
    }

    var collationChoices: [String] { options?.collations(for: characterSet) ?? [] }

    func load() async {
        options = await workspace.loadCreationOptions()
    }

    func create() async {
        guard canCreate else { return }
        phase = .running
        errorMessage = nil
        let created = DatabaseDDL.normalizedName(name)
        switch await workspace.createDatabase(spec) {
        case .done:
            phase = .created(created)
            Announce.post("Created database \(created)")
        case .declined:
            phase = .editing
        case .failed(let message):
            phase = .editing
            errorMessage = message
            Announce.post("Couldn't create database", important: true)
        }
    }
}

struct NewDatabaseSheet: View {
    @Bindable var model: NewDatabaseModel
    /// Called with the new database's name when the user chose to open it, else `nil`.
    var onFinish: (String?) -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Database").font(.title3.weight(.semibold))
            if case .created(let name) = model.phase {
                createdView(name)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await model.load() }
        .onAppear { nameFocused = true }
        .interactiveDismissDisabled(model.phase == .running)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField("Name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { Task { await model.create() } }
                    .accessibilityLabel("Database name")
            }
            if model.isPostgres { postgresFields } else { mysqlFields }
            VStack(alignment: .leading, spacing: 4) {
                Text("SQL").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(model.sql + ";")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    .accessibilityLabel("SQL preview: \(model.sql)")
            }
            ForEach(model.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.warningText)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                    .textSelection(.enabled)
            }
            HStack {
                if model.phase == .running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .running)
                Button("Create") { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreate)
            }
        }
    }

    private var mysqlFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Character set", selection: $model.characterSet) {
                Text(serverDefault(model.options?.defaultCharset)).tag(String?.none)
                ForEach(model.options?.charsets ?? []) { Text($0.name).tag(String?.some($0.name)) }
            }
            Picker("Collation", selection: $model.collation) {
                Text(model.characterSet == nil ? serverDefault(model.options?.defaultCollation) : "Default for character set")
                    .tag(String?.none)
                ForEach(model.collationChoices, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        }
    }

    private var postgresFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Owner", selection: $model.owner) {
                Text("Current user").tag(String?.none)
                ForEach(model.options?.roles ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Encoding", selection: $model.encoding) {
                Text(serverDefault(model.options?.defaultEncoding)).tag(String?.none)
                ForEach(model.options?.encodings ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Template", selection: $model.template) {
                Text(serverDefault(model.options?.defaultTemplate)).tag(String?.none)
                ForEach(model.options?.templates ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
            }
        }
    }

    private func serverDefault(_ value: String?) -> String {
        value.map { "Server default (\($0))" } ?? "Server default"
    }

    // MARK: Done

    private func createdView(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Created “\(name)”.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.connectedText)
            HStack {
                Spacer()
                Button("Done") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Open “\(name)”") { onFinish(name) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
