import QuerywellCore
import SwiftUI

extension AppModel {
    /// A binding to one settings value that persists on every change.
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "shield.lefthalf.filled") }
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
            DataGridSettings()
                .tabItem { Label("Data Grid", systemImage: "tablecells") }
            HistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 470)
        .task { await model.load() }
        .appAlert()
    }

    @Environment(AppModel.self) private var model
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Reopen last session at launch", isOn: model.binding(\.general.reopenLastSession))
                Text("Takes effect once session restore ships in a later phase.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Picker("Opening a connection that is already open", selection: model.binding(\.general.openConnectionBehaviour)) {
                    Text("Focus its window").tag(OpenConnectionBehaviour.focusExisting)
                    Text("Open another window").tag(OpenConnectionBehaviour.newWindow)
                }
                Text("Hold ⌥ while clicking Connect to open a second window either way.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Toggle(
                    "Confirm before closing a connected window",
                    isOn: model.binding(\.general.confirmBeforeClosingConnectionWindow))
            }
        }
        .formStyle(.grouped)
    }
}

private struct SafetySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Confirm writes on Production connections", isOn: .constant(true))
                    .disabled(true)
                Text("Always on. Statements that change data on a connection tagged Production need an explicit confirmation, and this can't be turned off.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Toggle(
                    "Require typing the database name for destructive statements",
                    isOn: model.binding(\.safety.requireTypingDatabaseNameForDestructive))
                Toggle(
                    "Make new Production connections read-only by default",
                    isOn: model.binding(\.safety.defaultReadOnlyForNewProductionConnections))
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: model.binding(\.editor.fontSize),
                    in: AppSettings.Editor.fontSizeRange, step: 1
                ) {
                    LabeledContent("Font size", value: "\(Int(model.settings.editor.fontSize)) pt")
                }
                Toggle("Show line numbers", isOn: model.binding(\.editor.showLineNumbers))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataGridSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: model.binding(\.dataGrid.pageSize),
                    in: AppSettings.DataGrid.pageSizeRange, step: 50
                ) {
                    LabeledContent("Rows per page", value: "\(model.settings.dataGrid.pageSize)")
                }
                Toggle("Show column types in headers", isOn: model.binding(\.dataGrid.showColumnTypes))
                TextField("NULL display", text: model.binding(\.dataGrid.nullDisplay))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    private enum Check: Equatable {
        case idle
        case working
        case ok(String)
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var models: [AIModelInfo] = []
    @State private var modelCheck = Check.idle
    @State private var keyCheck = Check.idle

    private var provider: AIProviderID? { model.settings.ai.provider }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: model.binding(\.ai.provider)) {
                    Text("Not configured").tag(AIProviderID?.none)
                    Text("OpenAI").tag(AIProviderID?.some(.openai))
                    Text("Anthropic").tag(AIProviderID?.some(.anthropic))
                    Text("OpenRouter").tag(AIProviderID?.some(.openrouter))
                }
                LabeledContent("API key") {
                    HStack {
                        RevealableSecureField(title: "API key", text: $apiKey)
                        Button("Save") {
                            if let provider, model.setAIAPIKey(apiKey, provider: provider) { savedKey = apiKey }
                        }
                        .disabled(provider == nil || apiKey == savedKey)
                        Button("Test key") { Task { await testKey() } }
                            .disabled(provider == nil || apiKey.trimmingCharacters(in: .whitespaces).isEmpty || keyCheck == .working)
                    }
                }
                .disabled(provider == nil)
                checkLine(keyCheck)
                Text("Stored in the macOS Keychain, never in settings.json.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section {
                LabeledContent("Model") {
                    HStack {
                        TextField("Model", text: Binding(
                            get: { model.settings.ai.model ?? "" },
                            set: { value in model.updateSettings { $0.ai.model = value.isEmpty ? nil : value } }),
                            prompt: Text(provider?.suggestedModel ?? "Choose a provider first"))
                            .labelsHidden()
                            .disabled(provider == nil)
                        Menu {
                            if models.isEmpty {
                                Text("Press Refresh to load the list")
                            } else {
                                ForEach(models) { m in
                                    Button(m.displayName) { model.updateSettings { $0.ai.model = m.id } }
                                }
                            }
                        } label: {
                            Text("Choose")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(provider == nil)
                        Button { Task { await refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Ask \(provider?.displayName ?? "the provider") which models this key can use")
                            .accessibilityLabel("Refresh models")
                            .disabled(provider == nil || apiKey.trimmingCharacters(in: .whitespaces).isEmpty || modelCheck == .working)
                    }
                }
                checkLine(modelCheck)
                Text("Type any model name if it isn't in the list. Leave empty to use \(provider?.suggestedModel ?? "the provider's default").")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section {
                Toggle("Include sample rows by default", isOn: model.binding(\.ai.includeSampleRowsByDefault))
                Text("Sample rows can contain personal or confidential data. When on, rows from your tables are sent to the provider with your questions; when off, only the schema is. Each connection can override this from the assistant panel.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .task(id: provider) {
            models = []
            modelCheck = .idle
            keyCheck = .idle
            if let provider {
                let key = model.aiAPIKey(provider: provider) ?? ""
                apiKey = key
                savedKey = key
            } else {
                apiKey = ""
                savedKey = ""
            }
        }
    }

    @ViewBuilder
    private func checkLine(_ check: Check) -> some View {
        switch check {
        case .idle: EmptyView()
        case .working: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Contacting \(provider?.displayName ?? "provider")…").font(.caption) }
        case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.connectedText)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.dangerText)
        }
    }

    private func makeProvider() -> (any AIProvider)? {
        guard let provider else { return nil }
        return AIProviderRegistry.provider(for: provider, apiKey: apiKey)
    }

    private func refreshModels() async {
        guard let p = makeProvider() else { return }
        modelCheck = .working
        do {
            let list = try await p.listModels()
            models = list.sorted { $0.id < $1.id }
            modelCheck = .ok("\(list.count) model\(list.count == 1 ? "" : "s") available")
        } catch {
            modelCheck = .failed(AIHTTPDescription.text(error))
        }
    }

    private func testKey() async {
        guard let p = makeProvider() else { return }
        keyCheck = .working
        do {
            let list = try await p.listModels()
            models = list.sorted { $0.id < $1.id }
            keyCheck = .ok("The key works — \(list.count) model\(list.count == 1 ? "" : "s") available.")
        } catch {
            keyCheck = .failed(AIHTTPDescription.text(error))
        }
    }
}

/// User-facing text for an error thrown by a provider call.
enum AIHTTPDescription {
    static func text(_ error: any Error) -> String {
        if let e = error as? AIError { return e.errorDescription ?? "Something went wrong." }
        return error.localizedDescription
    }
}

private struct HistorySettings: View {
    private enum ClearTarget: Identifiable {
        case connection(ConnectionProfile)
        case all
        var id: String {
            switch self {
            case .connection(let p): p.id.uuidString
            case .all: "all"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var usedBytes = 0
    @State private var pendingClear: ClearTarget?

    var body: some View {
        Form {
            Section {
                Stepper(value: model.binding(\.historyRetention.maxEntries), in: 50...50_000, step: 50) {
                    LabeledContent("Keep at most", value: "\(model.settings.historyRetention.maxEntries.formatted()) statements")
                }
                Stepper(value: model.binding(\.historyRetention.maxAgeDays), in: 1...3_650, step: 1) {
                    LabeledContent("Keep for", value: "\(model.settings.historyRetention.maxAgeDays) days")
                }
                Stepper(value: megabytes, in: 1...256, step: 1) {
                    LabeledContent("Size limit per connection", value: "\(megabytes.wrappedValue) MB")
                }
                Text("History is stored per connection on this Mac. Passwords in statements are masked before saving, and statements over 64 KB are kept truncated (open-only).")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section {
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file))
                HStack {
                    Menu("Clear History For…") {
                        ForEach(model.library.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { p in
                            Button(p.name) { pendingClear = .connection(p) }
                        }
                    }
                    .menuStyle(.button).fixedSize()
                    .disabled(model.library.profiles.isEmpty)
                    Button("Clear All History…", role: .destructive) { pendingClear = .all }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { usedBytes = model.queryServices.historyBytes() }
        .alert(alertTitle, isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }), presenting: pendingClear) { target in
            Button("Clear History", role: .destructive) {
                Task {
                    switch target {
                    case .connection(let p): await model.queryServices.clearHistory(connectionID: p.id)
                    case .all: await model.queryServices.clearAllHistory()
                    }
                    usedBytes = model.queryServices.historyBytes()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone. Saved queries and snippets are not affected.")
        }
    }

    private var alertTitle: String {
        switch pendingClear {
        case .connection(let p): "Clear history for “\(p.name)”?"
        case .all: "Clear history for every connection?"
        case nil: ""
        }
    }

    private var megabytes: Binding<Int> {
        Binding(
            get: { max(1, model.settings.historyRetention.maxFileBytes / (1024 * 1024)) },
            set: { mb in model.updateSettings { $0.historyRetention.maxFileBytes = max(1, mb) * 1024 * 1024 } })
    }
}
