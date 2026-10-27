import AppKit
import QuerywellCore
import SwiftUI

/// "Import SQL…": file facts, the compatibility scan, target and options, then progress with the error list.
struct ImportSheetView: View {
    @Bindable var model: ImportSheetModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fileSection
                    compatibilitySection
                    if model.phase == .setup { optionsSection }
                    if model.pendingError != nil { pendingBanner }
                    runStatus
                    if !model.errors.isEmpty { errorList }
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
            }
            footer
        }
        .frame(width: 680)
        .frame(minHeight: 480, idealHeight: 600, maxHeight: 760)
        .background(Theme.background)
        .task { await model.loadAndScan() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import SQL")
    }

    // MARK: Header and file

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import SQL").font(.system(size: 17, weight: .semibold))
            Text("\(model.profile.name) · \(model.targetSchema ?? "database from the file")")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("File")
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 24)).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.file.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(fileFacts).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        }
    }

    private var fileFacts: String {
        var parts = [ExportSheetModel.byteString(model.fileSize)]
        if case .done(let s) = model.scan { parts.append(s.isGzip ? "gzip-compressed" : "plain SQL") }
        if let date = model.fileDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Scan

    @ViewBuilder
    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Compatibility")
            switch model.scan {
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning the file for character sets and collations…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            case .failed(let message):
                ErrorNote(title: "Couldn't read the file", detail: message)
            case .done(let s):
                if s.needsRewrite {
                    VStack(alignment: .leading, spacing: 8) {
                        AmberNote(text: "This server doesn't support \(unsupportedText(s)). Importing as-is would fail with “Unknown collation”.")
                        if let name = s.suggestedName {
                            Label("Suggested fix: \(name). It is preselected below.", systemImage: "wand.and.stars")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                } else {
                    Label(model.supportsCollationFix ? "Looks compatible with this server." : "No character set or collation check for PostgreSQL files.",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(Theme.connectedText)
                        .labelStyle(.titleAndIcon)
                }
                if !s.isComplete {
                    Text("Only the first \(ExportSheetModel.byteString(s.bytesScanned)) were scanned.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func unsupportedText(_ s: ImportSheetModel.ScanState.Summary) -> String {
        let names = s.unsupportedCollations + s.unsupportedCharsets
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? "\(shown) and \(names.count - 4) more" : shown
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(model.engine == .postgresql ? "Target schema" : "Target database")
                Picker("Target", selection: $model.targetSchema) {
                    Text("As specified in the file").tag(String?.none)
                    ForEach(pickerSchemas, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(width: 280, alignment: .leading)
                Text("Statements run in this \(model.engine == .postgresql ? "schema" : "database"). Dumps that name their own database switch to it themselves.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if model.supportsCollationFix {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Fix collations for this server")
                    HStack(spacing: 10) {
                        Picker("Fix collations", selection: $model.collationChoice) {
                            Text("Don't change").tag(ImportSheetModel.CollationChoice.none)
                            if let name = model.suggestedName { Text("Suggested: \(name)").tag(ImportSheetModel.CollationChoice.suggested) }
                            else if model.collationChoice == .suggested { Text("Suggested").tag(ImportSheetModel.CollationChoice.suggested) }
                            Text("MySQL 5.7 & MariaDB compatible").tag(ImportSheetModel.CollationChoice.mysql57)
                            Text("Legacy utf8mb4_unicode_ci").tag(ImportSheetModel.CollationChoice.legacy)
                            Text("Custom…").tag(ImportSheetModel.CollationChoice.custom)
                        }
                        .labelsHidden().frame(width: 300, alignment: .leading)
                        if model.collationChoice == .custom {
                            TextField("charset", text: $model.customCharset).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("collation", text: $model.customCollation).textFieldStyle(.roundedBorder).frame(width: 170)
                        }
                    }
                    Text("Only table definitions are rewritten, never row data.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Errors")
                Toggle("Stop at the first error", isOn: $model.stopOnError).toggleStyle(.checkbox).font(.system(size: 13))
                Text(model.stopOnError ? "The import halts at the first failing statement; earlier statements stay applied."
                     : "The import asks what to do at each failing statement and lists them all at the end.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if model.profile.isProduction {
                AmberNote(text: "This is a production database. Importing can replace tables; you will be asked to type the database name.", systemImage: "lock.fill")
            }
        }
    }

    /// The known schemas, plus the current target when the sidebar hasn't listed it (yet).
    private var pickerSchemas: [String] {
        guard let target = model.targetSchema, !model.schemas.contains(target) else { return model.schemas }
        return [target] + model.schemas
    }

    // MARK: Running

    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = model.pendingError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
                    Text("Statement \(pending.error.statementIndex + 1) failed (line \(pending.error.line))").font(.system(size: 13, weight: .semibold))
                }
                Text(pending.error.message).font(.system(size: 12)).textSelection(.enabled)
                Text(pending.error.snippet).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(2).textSelection(.enabled)
                HStack {
                    Button("Continue") { model.resolveError(.continue) }.buttonStyle(AccentFillButtonStyle())
                    Button("Continue, Don't Ask Again") { model.resolveError(.continue, askAgain: false) }.buttonStyle(OutlineButtonStyle())
                    Button("Stop") { model.resolveError(.stop) }.buttonStyle(OutlineButtonStyle(foreground: Theme.dangerText))
                }
                .font(.system(size: 13))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.pendingPillBorder))
    }

    @ViewBuilder
    private var runStatus: some View {
        switch model.phase {
        case .setup:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack {
                        Text("Importing \(Int((model.fraction * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Spacer()
                        Text(progressDetail(elapsed: model.elapsed(at: context.date))).font(.system(size: 12)).foregroundStyle(Theme.chipText).monospacedDigit()
                    }
                }
                SlimProgressBar(fraction: model.fraction, label: "Import progress")
                if let current = model.progress?.currentStatement {
                    Text(current.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        case .finished:
            if let report = model.report { finishedBox(report) }
        case .failed(let message):
            ErrorNote(title: "The import failed", detail: message)
        }
    }

    private func progressDetail(elapsed: TimeInterval) -> String {
        let executed = model.progress?.statementsExecuted ?? 0
        var parts = ["\(executed.formatted()) statements"]
        if model.errorCount > 0 { parts.append("\(model.errorCount) error\(model.errorCount == 1 ? "" : "s")") }
        parts.append(elapsed.clockString)
        return parts.joined(separator: " · ")
    }

    private func finishedBox(_ report: ImportReport) -> some View {
        let ok = report.succeeded
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Theme.connectedDot : Theme.pendingEditBar).accessibilityHidden(true)
                Text(headline(report)).font(.system(size: 13, weight: .semibold))
            }
            Text("\(report.statementsExecuted.formatted()) statements ran" + (report.statementsFailed > 0 ? ", \(report.statementsFailed) failed" : "")
                 + " · \(Double(report.duration.components.seconds).clockString)"
                 + (report.collationRewrites > 0 ? " · \(report.collationRewrites) collation rewrite\(report.collationRewrites == 1 ? "" : "s")" : ""))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ok ? Theme.pillPositiveBackground : Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private func headline(_ r: ImportReport) -> String {
        if r.wasCancelled { return "Import cancelled" }
        if r.stoppedOnError { return "Import stopped at an error" }
        return r.succeeded ? "Import complete" : "Import finished with errors"
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Errors (\(model.errorCount))")
            VStack(spacing: 0) {
                ForEach(Array(model.errors.suffix(100).enumerated()), id: \.offset) { index, e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("#\(e.statementIndex + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text("line \(e.line)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Text(e.message).font(.system(size: 12)).foregroundStyle(Theme.dangerText).lineLimit(2)
                        }
                        Text(e.snippet.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .textSelection(.enabled)
                    if index < min(model.errors.count, 100) - 1 { Divider() }
                }
            }
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
            if model.errorCount > 100 {
                Text("Showing the last 100 of \(model.errorCount) errors.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.profile.effectiveReadOnly {
                Label("This connection is read-only", systemImage: "lock.fill").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            switch model.phase {
            case .setup:
                Button("Cancel") { onClose() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Import…") { Task { await model.start() } }
                    .buttonStyle(AccentFillButtonStyle(tint: model.profile.isProduction ? Theme.prodBadgeFill : nil))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            case .running:
                Button("Stop Import") { model.cancel() }.buttonStyle(OutlineButtonStyle(foreground: Theme.dangerText))
                Button("Importing…") {}.buttonStyle(AccentFillButtonStyle()).disabled(true)
            case .finished, .failed:
                Button("Done") { onClose() }.buttonStyle(AccentFillButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }
}
