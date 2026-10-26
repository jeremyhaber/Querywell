import QuerywellCore
import SwiftUI

/// The collapsible assistant docked at the right of a query tab (⌘⇧A).
struct AIAssistantPanel: View {
    @Bindable var model: AIAssistantModel
    var onClose: () -> Void
    @Environment(\.openSettings) private var openSettings
    @FocusState.Binding var promptFocused: Bool
    @State private var showPrivacy = false

    private var config: AIConfiguration { model.configuration }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !config.isReady { setupNotice } else { transcript }
            Divider()
            composer
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI assistant")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.tabQuery).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.system(size: 13, weight: .semibold))
                Text(providerLine).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let wp = model.wordPress() {
                Text("WordPress · \(wp.prefix)\(wp.isMultisite ? " · multisite" : "")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.pillPositiveText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.pillPositiveBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                    .help("WordPress tables detected — the assistant is told the table prefix and how WordPress stores data.")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide assistant (⌘⇧A)")
            .accessibilityLabel("Hide assistant")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var providerLine: String {
        guard let provider = config.provider, let name = config.modelName else { return "Not configured" }
        return "\(provider.displayName) · \(name)"
    }

    private var setupNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "key").font(.system(size: 26)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text("Add an API key in Settings → AI")
                .font(.system(size: 13, weight: .medium))
            Text("The assistant sends your question and the schema to the provider you choose. Nothing runs automatically.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Open Settings…") { openSettings() }
                .buttonStyle(AccentFillButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.turns.isEmpty { emptyHint }
                    ForEach(model.turns) { turn in turnView(turn).id(turn.id) }
                    if case .failed(let error) = model.status { errorView(error) }
                    if model.status == .loadingContext {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the schema…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(model.turns.isEmpty ? .top : .bottom)
            .onChange(of: model.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.status) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask for a query in plain words.").font(.system(size: 12, weight: .medium))
            Text("“Pages edited this month with the author’s name”\n“Autoloaded options bigger than 100 KB”")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text("Answers are inserted into the editor for you to review. They never run on their own.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func turnView(_ turn: AIAssistantModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.request)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.accentSubtleBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .foregroundStyle(Theme.accentSubtleText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ForEach(Array(MarkdownLite.parse(turn.text).enumerated()), id: \.offset) { _, block in blockView(block) }
            if turn.id == model.latest?.id, turn.sql != nil, turn.isFinished || model.status == .streaming { sqlActions(turn) }
            if !turn.isFinished, turn.text.isEmpty == false { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(MarkdownLite.inline(s)).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(s).font(.system(size: 12, weight: .semibold))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.textTertiary)
                        Text(MarkdownLite.inline(item)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
        case .code(let language, let text, _):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(Theme.textTertiary).padding(.horizontal, 10).padding(.top, 6)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(language.isEmpty || ["sql", "mysql", "mariadb", "postgresql", "pgsql", "postgres"].contains(language.lowercased())
                         ? SQLAttributed.make(text, dialect: model.dialect(), fontSize: 11.5)
                         : AttributedString(text))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        }
    }

    private func sqlActions(_ turn: AIAssistantModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.insert() } label: { Text("Insert into editor") }
                    .buttonStyle(AccentFillButtonStyle())
                    .help("Replaces the selection or inserts at the cursor. Nothing runs.")
                Button { model.replace() } label: { Text("Replace editor") }
                    .buttonStyle(OutlineButtonStyle())
                    .help("Replaces the editor text. Undo with ⌘Z.")
            }
            .font(.system(size: 12, weight: .medium))
            .disabled(!turn.isFinished && model.status == .streaming)
            if !model.reviewWarnings.isEmpty {
                WarningCallout(title: nil, lines: model.reviewWarnings)
            }
        }
    }

    private func errorView(_ error: AIError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.dangerText).accessibilityHidden(true)
                Text(AIErrorCopy.message(error)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if AIErrorCopy.canRetry(error) { Button("Retry") { model.retry() }.buttonStyle(OutlineButtonStyle()) }
                if AIErrorCopy.needsSettings(error) { Button("Open Settings…") { openSettings() }.buttonStyle(OutlineButtonStyle()) }
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaceholderTextEditor(
                text: $model.prompt,
                placeholder: "Describe the query you need…",
                isFocused: Binding(get: { promptFocused }, set: { promptFocused = $0 }),
                onCommandReturn: { model.generate() }
            )
            .frame(height: 44)
            .accessibilityLabel("Ask the assistant")
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(promptFocused ? Theme.accent : Theme.separator))

            HStack(spacing: 6) {
                if model.isBusy {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(AccentFillButtonStyle(tint: Theme.dangerFill))
                } else {
                    Button { model.generate() } label: {
                        HStack(spacing: 4) { Text("Generate"); Text("⌘↵").font(.system(size: 10)).opacity(0.85) }
                    }
                    .buttonStyle(AccentFillButtonStyle())
                    .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !config.isReady)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))

            HStack(spacing: 6) {
                Button("Explain query") { model.explain() }
                    .disabled(model.isBusy || !config.isReady)
                Button("Fix error") { model.fixError() }
                    .disabled(model.isBusy || !config.isReady || !model.canFixError)
                    .help(model.canFixError ? "Sends the failing statement and the server's error" : "Available after a run fails")
                Button("Optimize") { model.optimize() }
                    .disabled(model.isBusy || !config.isReady)
                    .help("Runs EXPLAIN first and sends the plan")
            }
            .buttonStyle(OutlineButtonStyle())
            .font(.system(size: 12))

            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { model.allowSampleRows() }, set: { model.setAllowSampleRows($0) })) {
                    Text("Include sample rows").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Button { showPrivacy.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About sample rows")
                .popover(isPresented: $showPrivacy, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sample rows").font(.system(size: 13, weight: .semibold))
                        Text("By default only the schema — table, column, key and index definitions — is sent to your AI provider. With this on, up to 3 rows from the tables most related to your question are sent too, so the model can see value formats. Rows can contain personal or confidential data. The choice is remembered for this connection only.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14).frame(width: 300)
                }
            }
        }
        .padding(12)
    }
}
