import QuerywellCore
import SwiftUI

/// Triggers mode of a table tab: the table's triggers with create, edit, drop and "view definition".
struct TableTriggersView: View {
    @Bindable var model: TableDataModel
    let workspace: ConnectionWorkspace
    @State private var triggers = TableTriggersModel()
    @State private var pendingDrop: TriggerInfo?

    var body: some View {
        @Bindable var triggers = triggers
        return VStack(spacing: 0) {
            if !triggers.isTable {
                ContentMessage(symbol: "tablecells", title: "Triggers apply to tables", detail: "\(model.table.name) is a view.")
            } else if let error = triggers.loadError, !triggers.hasLoaded {
                ContentMessage(symbol: "exclamationmark.triangle", title: "Couldn't read the triggers", detail: error)
            } else if !triggers.hasLoaded {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading triggers…").foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                toolbar
                if triggers.triggers.isEmpty {
                    ContentMessage(
                        symbol: "bolt", title: "No triggers on \(model.table.name)",
                        detail: "A trigger runs a statement automatically before or after rows are inserted, updated or deleted.")
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: model.table) {
            triggers.attach(owner: model, workspace: workspace)
            await triggers.load()
        }
        .sheet(item: $triggers.editor) { _ in
            TriggerEditorSheet(model: triggers) { triggers.editor = nil }
        }
        .sheet(item: $triggers.definition) { sheet in
            TriggerDefinitionSheet(sheet: sheet) { triggers.definition = nil }
        }
        .confirmationDialog(
            "Drop trigger “\(pendingDrop?.name ?? "")”?", isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }),
            titleVisibility: .visible
        ) {
            Button("Drop trigger", role: .destructive) {
                if let trigger = pendingDrop { Task { await triggers.drop(trigger) } }
                pendingDrop = nil
            }
            Button("Cancel", role: .cancel) { pendingDrop = nil }
        } message: {
            if let trigger = pendingDrop { Text(TriggerDDL.drop(trigger, dialect: triggers.dialect) + ";") }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("\(triggers.triggers.count) trigger\(triggers.triggers.count == 1 ? "" : "s")")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if triggers.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Reading triggers") }
            if let status = triggers.status {
                Label(status.message, systemImage: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(status.isError ? Theme.dangerText : Theme.connectedText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("New Trigger…") { triggers.beginCreate() }
                .buttonStyle(AccentFillButtonStyle())
                .font(.system(size: 13, weight: .medium))
                .disabled(triggers.isReadOnly)
                .help(triggers.isReadOnly ? "This connection is read-only." : "Create a trigger on this table")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("NAME").frame(width: 180, alignment: .leading)
                    Text("FIRES").frame(width: 150, alignment: .leading)
                    Text(triggers.isPostgres ? "FUNCTION" : "STATEMENT").frame(maxWidth: .infinity, alignment: .leading)
                    if !triggers.isPostgres { Text("DEFINER").frame(width: 150, alignment: .leading) }
                    Color.clear.frame(width: 190)
                }
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.sidebar)
                Divider()
                ForEach(triggers.triggers) { trigger in
                    row(trigger)
                    Divider().opacity(0.5)
                }
            }
            .background(Theme.background)
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .padding(16)
        }
    }

    private func row(_ trigger: TriggerInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 6) {
                Text(trigger.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if !trigger.isEnabled {
                    Text("disabled").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                }
            }
            .frame(width: 180, alignment: .leading)
            Text("\(trigger.timing.rawValue) \(trigger.eventText)" + (trigger.forEachRow ? "" : " (statement)"))
                .font(.system(size: 12)).frame(width: 150, alignment: .leading)
            Text(Self.oneLine(trigger.function.map { "\($0.schema).\($0.name)()" } ?? trigger.statement))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            if !triggers.isPostgres {
                Text(trigger.definer ?? "—").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)
            }
            HStack(spacing: 6) {
                Button("Definition") { Task { await triggers.showDefinition(trigger) } }
                    .accessibilityLabel("View definition of \(trigger.name)")
                Button("Edit") { triggers.beginEdit(trigger) }
                    .disabled(triggers.isReadOnly)
                    .accessibilityLabel("Edit \(trigger.name)")
                Button("Drop") { pendingDrop = trigger }
                    .disabled(triggers.isReadOnly)
                    .foregroundStyle(Theme.dangerText)
                    .accessibilityLabel("Drop \(trigger.name)")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

// MARK: - Editor sheet

private struct TriggerEditorSheet: View {
    @Bindable var model: TableTriggersModel
    var onClose: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.isEditing ? "Edit trigger" : "New trigger")
                .font(.system(size: 15, weight: .semibold))
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    form
                    bodySection
                    preview
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 640)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.isEditing ? "Edit trigger" : "New trigger")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Name") {
                TextField("Trigger name", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 280)
                    .accessibilityLabel("Trigger name")
            }
            labeled("Fires") {
                HStack(spacing: 10) {
                    Picker("Timing", selection: $model.timing) {
                        ForEach(timings) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130, alignment: .leading)
                    if model.isPostgres {
                        HStack(spacing: 10) {
                            ForEach(TriggerEvent.allCases) { event in
                                Toggle(event.rawValue, isOn: Binding(
                                    get: { model.events.contains(event) },
                                    set: { on in if on { model.events.insert(event) } else { model.events.remove(event) } }))
                            }
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                    } else {
                        Picker("Event", selection: Binding(get: { model.mysqlEvent }, set: { model.mysqlEvent = $0 })) {
                            ForEach([TriggerEvent.insert, .update, .delete]) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130, alignment: .leading)
                    }
                }
            }
            if model.isPostgres {
                labeled("For each") {
                    Picker("Granularity", selection: $model.forEachRow) {
                        Text("Row").tag(true)
                        Text("Statement").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200, alignment: .leading)
                }
                labeled("WHEN") {
                    TextField("Optional condition, e.g. OLD.* IS DISTINCT FROM NEW.*", text: $model.whenCondition)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("WHEN condition")
                }
            } else {
                Text("MySQL triggers run for each row and fire on exactly one event.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var timings: [TriggerTiming] { model.isPostgres ? TriggerTiming.allCases : [.before, .after] }

    @ViewBuilder
    private var bodySection: some View {
        if model.isPostgres {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Function", selection: $model.functionSource) {
                    ForEach(TableTriggersModel.FunctionSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320, alignment: .leading)
                .accessibilityLabel("Trigger function source")
                if model.functionSource == .existing {
                    if model.functions.isEmpty {
                        Text("No trigger functions in this schema yet. Choose “New function” to write one.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Trigger function", selection: $model.functionChoice) {
                            ForEach(model.functions, id: \.self) { Text($0.schema + "." + $0.name).tag(TableTriggersModel.key($0)) }
                        }
                        .labelsHidden()
                        .frame(width: 320, alignment: .leading)
                    }
                } else {
                    labeled("Function name") {
                        TextField("Function name", text: $model.newFunctionName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 280)
                            .accessibilityLabel("New function name")
                    }
                    CaptionLabel("Function body (plpgsql)")
                    editor
                    Text("Created with CREATE OR REPLACE FUNCTION … RETURNS trigger. Return NEW (or OLD for deletes) from BEFORE row triggers.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                CaptionLabel("Body")
                editor
                Text("One statement, or a BEGIN … END block. Refer to the row as NEW and OLD.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var editor: some View {
        SQLTextView(
            controller: model.bodyEditor, initialText: model.initialBody,
            settings: SQLEditorSettings(
                fontSize: app.settings.editor.fontSize, showsLineNumbers: false, dialect: model.dialect))
            .frame(height: 190)
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .accessibilityLabel(model.isPostgres ? "Function body" : "Trigger body")
            .onAppear { model.bodyEditor.onTextChange = { model.bodyText = $0 } }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptionLabel("SQL that will run")
            switch model.plan {
            case .ready(let statements):
                if let note = model.editExplanation {
                    WarningCallout(title: nil, lines: [note], symbol: "info.circle.fill")
                }
                SQLBox(sql: statements.map { $0 + ";" }.joined(separator: "\n"), maxHeight: 150, fontSize: 11)
            case .invalid(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.editorError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                    .lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            if model.isRunning { ProgressView().controlSize(.small).accessibilityLabel("Saving") }
            Button("Cancel", action: onClose)
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(model.isEditing ? "Save" : "Create") {
                Task { if await model.save() { onClose() } }
            }
            .buttonStyle(AccentFillButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRunning || { if case .invalid = model.plan { true } else { false } }())
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(width: 100, alignment: .trailing)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Definition sheet

private struct TriggerDefinitionSheet: View {
    var sheet: TableTriggersModel.DefinitionSheet
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.title).font(.system(size: 15, weight: .semibold))
            SQLBox(sql: sheet.text, maxHeight: 360, fontSize: 12)
            HStack {
                Button("Copy") { copyToPasteboard(sheet.text) }
                    .buttonStyle(OutlineButtonStyle())
                    .accessibilityLabel("Copy definition")
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(AccentFillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(16)
        .frame(width: 620)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Definition of \(sheet.title)")
    }
}
