import AppKit
import QuerywellCore
import SwiftUI

/// Options for exporting one result or table view to CSV / JSON / SQL INSERT.
struct ResultExportSheet: View {
    @Bindable var model: ResultExportModel
    var onClose: () -> Void
    var chooseDestination: @MainActor (ResultExportModel) async -> URL? = ResultExportSheet.runSavePanel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export \(model.name)").font(.system(size: 17, weight: .semibold))
                    if let hint = model.rowCountHint { Text(hint).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
                }
                Picker("Format", selection: $model.kind) {
                    ForEach(ResultExportModel.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.isRunning)
                options.disabled(model.isRunning)
                status
            }
            .padding(24)
            footer
        }
        .frame(width: 480)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export results")
    }

    @ViewBuilder
    private var options: some View {
        switch model.kind {
        case .csv:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Delimiter").foregroundStyle(Theme.textSecondary)
                    Picker("Delimiter", selection: $model.delimiter) {
                        ForEach(ResultExportModel.Delimiter.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 160, alignment: .leading)
                }
                GridRow {
                    Text("NULL as").foregroundStyle(Theme.textSecondary)
                    Picker("NULL as", selection: $model.nullStyle) {
                        ForEach(ResultExportModel.NullStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 160, alignment: .leading)
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Header row with column names", isOn: $model.includeHeader)
                        Toggle("UTF-8 byte-order mark (helps Excel)", isOn: $model.utf8BOM)
                    }.toggleStyle(.checkbox)
                }
            }
            .font(.system(size: 13))
        case .json:
            Picker("Layout", selection: $model.jsonLayout) {
                ForEach(ResultExportModel.JSONLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden().font(.system(size: 13))
        case .sql:
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Table name").foregroundStyle(Theme.textSecondary)
                    TextField("table or schema.table", text: $model.insertTable).textFieldStyle(.roundedBorder).frame(width: 240, alignment: .leading)
                }
                GridRow {
                    Text("Rows per INSERT").foregroundStyle(Theme.textSecondary)
                    Stepper(value: $model.rowsPerStatement, in: 1...5_000, step: 50) { Text("\(model.rowsPerStatement)").monospacedDigit() }
                }
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .idle: EmptyView()
        case .running(let rows):
            VStack(alignment: .leading, spacing: 6) {
                Text("Exporting… \(rows.formatted()) rows written").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                ProgressView().progressViewStyle(.linear)
            }
        case .finished(let url, let rows, let bytes):
            VStack(alignment: .leading, spacing: 6) {
                Label("Exported \(rows.formatted()) row\(rows == 1 ? "" : "s") · \(ExportSheetModel.byteString(bytes))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.connectedText)
                Text(url.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(2).textSelection(.enabled)
            }
        case .failed(let message): ErrorNote(title: "The export failed", detail: message)
        case .cancelled: AmberNote(text: "Export cancelled. The partial file was deleted.", systemImage: "xmark.circle")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch model.state {
            case .running:
                Button("Cancel") { model.cancel() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
            case .finished(let url, _, _):
                Button("Reveal in Finder") { Reveal.inFinder(url) }.buttonStyle(OutlineButtonStyle())
                Button("Done") { onClose() }.buttonStyle(AccentFillButtonStyle()).keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { onClose() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export…") {
                    Task {
                        guard let url = await chooseDestination(model) else { return }
                        await model.run(to: url)
                    }
                }
                .buttonStyle(AccentFillButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    @MainActor
    static func runSavePanel(_ model: ResultExportModel) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.suggestedFileName
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        if let window = NSApp.keyWindow {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
