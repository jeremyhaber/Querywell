import QuerywellCore
import SwiftUI

/// Sheet for creating or editing a connection (edits a `ConnectionDraft`).
struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConnectionEditorModel
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var visited: Set<Field> = []
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case name, host, port, user, sshHost, sshPort, sshUser

        func matches(_ issue: ValidationIssue) -> Bool {
            switch (self, issue) {
            case (.name, .emptyName), (.host, .emptyHost), (.port, .invalidPort), (.user, .emptyUser),
                 (.sshHost, .sshEmptyHost), (.sshPort, .sshInvalidPort), (.sshUser, .sshEmptyUser):
                true
            default:
                false
            }
        }
    }

    init(draft: ConnectionDraft, isNew: Bool) {
        _model = State(initialValue: ConnectionEditorModel(draft: draft, isNew: isNew))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                generalSection(model: $model)
                serverSection(model: $model)
                sshSection(model: $model)
                tlsSection(model: $model)
                safetySection(model: $model)
            }
            .formStyle(.grouped)

            Divider()
            if case .idle = model.test {} else {
                TestResultView(state: model.test)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .frame(maxHeight: 220)
            }
            footer
        }
        .frame(width: 580, height: 700)
        .interactiveDismissDisabled(true)
        .onAppear { model.defaultReadOnlyForProduction = appModel.settings.safety.defaultReadOnlyForNewProductionConnections }
        .onChange(of: model.draft) { _, _ in
            // A result describes the settings it ran with; once they change it is stale.
            if case .finished = model.test { model.cancelTest() }
        }
        .onChange(of: focus) { old, _ in
            if let old { visited.insert(old) }
        }
        .onDisappear { model.cancelTest() }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .appAlert()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.runTest(using: appModel.tester)
            } label: {
                Label("Test Connection", systemImage: "bolt.horizontal")
            }
            .disabled(!model.isValid || model.isTesting)
            .help(model.isValid ? "Try the connection with the settings above" : "Fix the highlighted fields first")
            if model.isTesting {
                Button("Stop") { model.cancelTest() }
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                if model.isDirty { confirmDiscard = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") {
                Task {
                    saving = true
                    if await appModel.save(model.draft) { dismiss() }
                    saving = false
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!model.isValid || saving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Sections

    private func message(for field: Field) -> String? {
        guard visited.contains(field) else { return nil }
        return model.issues.first(where: field.matches)?.message
    }

    @ViewBuilder
    private func fieldMessage(_ field: Field) -> some View {
        if let text = message(for: field) { ValidationMessage(text: text) }
    }

    private func generalSection(model: Bindable<ConnectionEditorModel>) -> some View {
        Section("General") {
            TextField("Name", text: model.draft.name, prompt: Text("sunset-web01"))
                .focused($focus, equals: .name)
            fieldMessage(.name)

            Picker("Tag", selection: Binding(
                get: { model.wrappedValue.tagChoice },
                set: { model.wrappedValue.setTagChoice($0) })
            ) {
                Text("None").tag(ConnectionEditorModel.TagChoice.none)
                ForEach(ColorTag.presets, id: \.self) { tag in
                    Label {
                        Text(tag.displayName)
                    } icon: {
                        ColorTagSwatch(tag: tag)
                    }
                    .tag(choice(for: tag))
                }
                Text("Custom…").tag(ConnectionEditorModel.TagChoice.custom)
            }
            if self.model.tagChoice == .custom {
                TextField("Tag name", text: model.customTagName)
                    .onChange(of: self.model.customTagName) { _, _ in self.model.customTagChanged() }
                ColorPicker("Tag colour", selection: model.customTagColor, supportsOpacity: false)
                    .onChange(of: self.model.customTagColor) { _, _ in self.model.customTagChanged() }
            }

            Picker("Folder", selection: model.draft.folderID) {
                Text("None").tag(UUID?.none)
                ForEach(appModel.sortedFolders) { folder in
                    Text(folder.name).tag(UUID?.some(folder.id))
                }
            }
            Toggle("Favourite", isOn: model.draft.favourite)
        }
    }

    private func choice(for tag: ColorTag) -> ConnectionEditorModel.TagChoice {
        switch tag {
        case .production: .production
        case .staging: .staging
        case .local: .local
        case .custom: .custom
        }
    }

    private func serverSection(model: Bindable<ConnectionEditorModel>) -> some View {
        Section("Server") {
            Picker("Engine", selection: model.draft.engine) {
                ForEach(DatabaseEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Host", text: model.draft.host, prompt: Text("127.0.0.1"))
                .focused($focus, equals: .host)
            fieldMessage(.host)
            TextField("Port", text: model.draft.portText)
                .focused($focus, equals: .port)
            fieldMessage(.port)
            TextField("User", text: model.draft.user)
                .focused($focus, equals: .user)
            fieldMessage(.user)
            LabeledContent("Password") {
                RevealableSecureField(title: "Password", text: model.draft.databasePassword)
            }
            TextField("Default database", text: model.draft.defaultDatabase, prompt: Text("Optional"))
        }
    }

    private func sshSection(model: Bindable<ConnectionEditorModel>) -> some View {
        Section("SSH tunnel") {
            Toggle("Connect through an SSH tunnel", isOn: model.draft.useSSH)
            if self.model.draft.useSSH {
                TextField("SSH host", text: model.draft.sshHost)
                    .focused($focus, equals: .sshHost)
                fieldMessage(.sshHost)
                TextField("SSH port", text: model.draft.sshPortText)
                    .focused($focus, equals: .sshPort)
                fieldMessage(.sshPort)
                TextField("SSH user", text: model.draft.sshUser)
                    .focused($focus, equals: .sshUser)
                fieldMessage(.sshUser)

                Picker("Authentication", selection: model.draft.sshAuth) {
                    Text("Key file").tag(SSHAuthChoice.keyFile)
                    Text("SSH agent").tag(SSHAuthChoice.agent)
                    Text("Password").tag(SSHAuthChoice.password)
                }
                .pickerStyle(.segmented)

                switch self.model.draft.sshAuth {
                case .keyFile:
                    LabeledContent("Key file") {
                        FilePathField(
                            title: "Private key file", path: model.draft.sshKeyPath,
                            startingAt: FilePicker.sshDirectory, showsHiddenFiles: true)
                    }
                    if self.model.issues.contains(.sshKeyFileEmpty) {
                        ValidationMessage(text: ValidationIssue.sshKeyFileEmpty.message)
                    }
                    LabeledContent("Passphrase") {
                        RevealableSecureField(title: "Key passphrase (optional)", text: model.draft.sshSecret)
                    }
                case .agent:
                    TextField("Agent socket", text: model.draft.sshAgentSocketPath, prompt: Text("Uses SSH_AUTH_SOCK"))
                        .font(.system(size: 12, design: .monospaced))
                    HStack {
                        Button("Use 1Password agent") {
                            self.model.draft.sshAgentSocketPath = SSHAuthMethod.onePasswordAgentSocketPath
                        }
                        Button("Use SSH_AUTH_SOCK") {
                            self.model.draft.sshAgentSocketPath = ""
                        }
                    }
                case .password:
                    LabeledContent("Password") {
                        RevealableSecureField(title: "SSH password", text: model.draft.sshSecret)
                    }
                }
            }
        }
    }

    private func tlsSection(model: Bindable<ConnectionEditorModel>) -> some View {
        Section("TLS") {
            Picker("Mode", selection: model.draft.tls.mode) {
                ForEach(TLSMode.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
            }
            Text(Self.explanation(for: self.model.draft.tls.mode))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            let verifies = self.model.draft.tls.mode == .verifyCA || self.model.draft.tls.mode == .verifyIdentity
            if verifies {
                LabeledContent("CA certificate") {
                    FilePathField(title: "CA certificate file", path: optionalPath(model.draft.tls.caCertificatePath))
                }
                if self.model.issues.contains(.tlsMissingCA) {
                    ValidationMessage(text: ValidationIssue.tlsMissingCA.message)
                }
                LabeledContent("Client certificate") {
                    FilePathField(title: "Client certificate file", path: optionalPath(model.draft.tls.clientCertificatePath))
                }
                LabeledContent("Client key") {
                    FilePathField(title: "Client key file", path: optionalPath(model.draft.tls.clientKeyPath))
                }
            }
        }
    }

    private func optionalPath(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    static func title(for mode: TLSMode) -> String {
        switch mode {
        case .disabled: "Off"
        case .preferred: "Preferred"
        case .required: "Required"
        case .verifyCA: "Verify CA"
        case .verifyIdentity: "Verify identity"
        }
    }

    static func explanation(for mode: TLSMode) -> String {
        switch mode {
        case .disabled: "No encryption. Only use this on a trusted network or inside an SSH tunnel."
        case .preferred: "Encrypt when the server supports it, otherwise fall back to plain text."
        case .required: "Always encrypt, but don't check who the server is. Protects against eavesdropping only."
        case .verifyCA: "Encrypt and check the server's certificate was issued by the CA file you provide."
        case .verifyIdentity: "Encrypt, check the CA, and check the certificate matches the host name. The safest option."
        }
    }

    private func safetySection(model: Bindable<ConnectionEditorModel>) -> some View {
        Section("Safety") {
            Toggle("Read-only", isOn: model.draft.readOnly)
            Text("Read-only connections refuse any statement that changes data or structure.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if self.model.isProduction {
                Label {
                    Text("Writes will require confirmation; destructive statements require typing the database name.")
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                }
                .foregroundStyle(Theme.dangerText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
