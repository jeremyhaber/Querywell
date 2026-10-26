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
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 540, height: 380)
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
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var savedKey = ""

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
                TextField("Model", text: Binding(
                    get: { model.settings.ai.model ?? "" },
                    set: { value in model.updateSettings { $0.ai.model = value.isEmpty ? nil : value } }))
                    .disabled(provider == nil)
                LabeledContent("API key") {
                    HStack {
                        RevealableSecureField(title: "API key", text: $apiKey)
                        Button("Save") {
                            if let provider, model.setAIAPIKey(apiKey, provider: provider) { savedKey = apiKey }
                        }
                        .disabled(provider == nil || apiKey == savedKey)
                    }
                }
                .disabled(provider == nil)
                Text("Stored in the macOS Keychain, never in settings.json.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section {
                Toggle("Include sample rows by default", isOn: model.binding(\.ai.includeSampleRowsByDefault))
                Text("Sample rows can contain personal or confidential data. When on, rows from your tables are sent to the provider with your questions; when off, only the schema is.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .task(id: provider) {
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
}
