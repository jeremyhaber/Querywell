import AppKit
import QuerywellCore
import SwiftUI

/// The export dialog (design: Export.dc.html): where the dump runs, what goes into it, the exact command,
/// then the progress of the run.
struct ExportSheetView: View {
    @Bindable var model: ExportSheetModel
    var onClose: () -> Void
    /// Asks for the destination (NSSavePanel); tests replace it.
    var chooseDestination: @MainActor (ExportSheetModel) async -> URL? = ExportSheetView.runSavePanel

    init(model: ExportSheetModel, expandTables: Bool? = nil, onClose: @escaping () -> Void,
         chooseDestination: @escaping @MainActor (ExportSheetModel) async -> URL? = ExportSheetView.runSavePanel) {
        self.model = model
        self.onClose = onClose
        self.chooseDestination = chooseDestination
        // More than one group means there is something to choose from: show the list.
        _showTables = State(initialValue: expandTables ?? (model.groups.count > 1))
    }

    @State private var showTables: Bool
    @State private var showCommand = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    locationSection
                    HStack(alignment: .top, spacing: 18) {
                        contentSection.frame(maxWidth: .infinity, alignment: .leading)
                        optionsSection.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.supportsCollation { collationSection }
                    tablesRow
                    if showTables { tableList }
                    commandPreview
                    notes
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .disabled(model.isRunning)
            }
            if model.runState != .idle {
                runStatus
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
            }
            footer
        }
        .frame(width: 760)
        .frame(minHeight: 560, idealHeight: showTables ? 780 : 680, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export \(model.database)")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export \(model.database)").font(.system(size: 17, weight: .semibold))
            Text(model.subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    // MARK: Location

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Where it runs")
            let detail = model.locationDetail
            ChoiceCard(isSelected: model.location == .remoteOverSSH, isEnabled: model.canExportOnServer) {
                model.location = .remoteOverSSH
            } content: {
                HStack(spacing: 4) {
                    Text("On the server over SSH").font(.system(size: 13, weight: .semibold))
                    if model.canExportOnServer { TagPill(text: "Recommended").padding(.leading, 2) }
                }
                Text(model.canExportOnServer ? detail.server : "This connection doesn't use SSH, so there is no server to run the dump on.")
                    .font(.system(size: 12)).foregroundStyle(Theme.chipText).fixedSize(horizontal: false, vertical: true)
            }
            ChoiceCard(isSelected: model.location == .localThroughTunnel) {
                model.location = .localThroughTunnel
            } content: {
                Text(model.profile.ssh != nil ? "On this Mac through the tunnel" : "On this Mac").font(.system(size: 13, weight: .semibold))
                Text(detail.local).font(.system(size: 12)).foregroundStyle(Theme.chipText).fixedSize(horizontal: false, vertical: true)
                if model.location == .localThroughTunnel {
                    ForEach(Array(model.toolIssues.enumerated()), id: \.offset) { _, issue in
                        AmberNote(text: issue.message).padding(.top, 4)
                    }
                    if let hint = model.installHint {
                        HStack(spacing: 6) {
                            Text("Install with").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Text(hint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") { copy(hint) }.buttonStyle(.link).font(.system(size: 12))
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: Content and options

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Content")
            Picker("Content", selection: $model.scope) {
                Text("Structure and data").tag(ExportScope.structureAndData)
                Text("Structure only").tag(ExportScope.structureOnly)
                Text("Data only").tag(ExportScope.dataOnly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Options")
            Toggle("Single transaction (no locks)", isOn: $model.singleTransaction)
                .disabled(model.engine == .postgresql)
                .help(model.engine == .postgresql ? "pg_dump always reads one consistent snapshot." : "")
            Toggle("Add DROP TABLE", isOn: $model.addDropTable)
            Toggle("Compress (.sql.gz)", isOn: $model.gzip)
            if model.supportsRoutinesEventsTriggers {
                Toggle("Routines", isOn: $model.includeRoutines)
                Toggle("Triggers", isOn: $model.includeTriggers)
                Toggle("Events", isOn: $model.includeEvents)
            }
            Toggle(model.optionsTables.isEmpty ? "Skip transients in wp_options" : "Skip transients in \(model.optionsTables.joined(separator: " and "))", isOn: $model.skipTransients)
                .disabled(!model.supportsTransients)
                .help(model.supportsTransients ? "Leaves out rows whose option_name starts with _transient_ or _site_transient_."
                      : "Available when the database has a WordPress options table.")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
    }

    private var collationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Target collation")
            HStack(spacing: 10) {
                Picker("Target collation", selection: $model.collationChoice) {
                    ForEach(ExportSheetModel.CollationChoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 260, alignment: .leading)
                if model.collationChoice == .custom {
                    let charsets = model.charsets.isEmpty ? [model.customCharset] : model.charsets
                    Picker("Charset", selection: $model.customCharset) {
                        ForEach(charsets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130, alignment: .leading)
                    let options = model.collations(forCharset: model.customCharset)
                    Picker("Collation", selection: $model.customCollation) {
                        ForEach(options.isEmpty ? [model.customCollation] : options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 190, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            Text(collationHelp).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }

    private var collationHelp: String {
        switch model.collationChoice {
        case .keep: "The dump keeps the collations the server uses."
        case .mysql57: "Rewrites MySQL 8 collations (utf8mb4_0900_ai_ci) so the file imports into MySQL 5.7, older MariaDB and most shared hosts. Only table definitions change, never row data."
        case .legacy: "Everything case-insensitive becomes utf8mb4_unicode_ci; binary and case-sensitive collations become utf8mb4_bin. Only table definitions change."
        case .custom: "Forces this charset and collation on every table definition. Row data is not converted, so use it only when the data is compatible."
        }
    }

    // MARK: Tables and destination

    private var tablesRow: some View {
        HStack(spacing: 12) {
            SectionLabel("Tables")
            Text(model.tablesSummary).font(.system(size: 13))
            Button(showTables ? "Done" : "Choose…") { Motion.animate { showTables.toggle() } }
                .buttonStyle(.link).font(.system(size: 13))
            if !showTables, model.structureOnlyCount > 0 {
                Text("· structure only for \(model.structureOnlyCount)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            SectionLabel("Save to")
            Text(model.destinationDisplay)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .trailing)
                .help(model.destination.path)
        }
    }

    private var tableList: some View { ExportTableSelectionView(model: model) }

    // MARK: Command preview

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Motion.animate { showCommand.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showCommand ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Command preview").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(Color(nsColor: ConsoleThemeNS.darkBoxHeader))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Command preview")
            .accessibilityValue(showCommand ? "expanded" : "collapsed")
            if showCommand {
                if model.commandPreview.isEmpty {
                    Text(model.planError ?? "Looking for the dump tools…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: ConsoleThemeNS.darkBoxMuted))
                        .padding(.horizontal, 12).padding(.bottom, 12)
                } else {
                    CommandBox(attributed: CommandBox.highlight(model.commandPreview))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: ConsoleThemeNS.darkBoxBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var notes: some View {
        if let error = model.planError, model.plan == nil, !model.commandPreview.isEmpty || model.toolsLoaded {
            AmberNote(text: error)
        }
        ForEach(Array((model.plan?.warnings ?? []).enumerated()), id: \.offset) { _, w in AmberNote(text: w) }
    }

    // MARK: Run status

    @ViewBuilder
    private var runStatus: some View {
        switch model.runState {
        case .idle:
            EmptyView()
        case .running:
            progressBox
        case .finished(let summary):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.connectedDot).accessibilityHidden(true)
                    Text("Export complete").font(.system(size: 13, weight: .semibold))
                }
                Text("\(summary.tables.count) table\(summary.tables.count == 1 ? "" : "s") · \(ExportSheetModel.byteString(summary.bytesWritten)) · \(Double(summary.duration.components.seconds).clockString)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(summary.destination.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                ForEach(Array(summary.warnings.enumerated()), id: \.offset) { _, w in AmberNote(text: w) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.pillPositiveBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        case .failed(let failure):
            ErrorNote(title: "The export failed", detail: failure.message, mono: failure.stderrTail)
        case .cancelled:
            AmberNote(text: "Export cancelled. The partial file was deleted.", systemImage: "xmark.circle")
        }
    }

    private var progressBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack {
                    Text(model.progress.currentTable.map { "Dumping \($0)" } ?? "Connecting…").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(progressDetail(elapsed: model.elapsed(at: context.date)))
                        .font(.system(size: 12)).foregroundStyle(Theme.chipText).monospacedDigit()
                }
            }
            SlimProgressBar(fraction: model.progressFraction, label: "Export progress")
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
    }

    private func progressDetail(elapsed: TimeInterval) -> String {
        var parts: [String] = []
        let total = model.progress.tableTotal ?? (model.allSelected ? model.allTables.count : model.selectedCount)
        if model.progress.tableIndex > 0 { parts.append("\(model.progress.tableIndex) of \(total) tables") }
        parts.append("\(ExportSheetModel.byteString(model.progress.bytes)) \(model.location == .remoteOverSSH ? "downloaded" : "written")")
        parts.append(elapsed.clockString)
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Copy command") { copy(model.commandPreview) }
                .buttonStyle(.link).font(.system(size: 13))
                .disabled(model.commandPreview.isEmpty)
            Spacer()
            switch model.runState {
            case .running:
                Button("Cancel Export") { model.cancel() }
                    .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Exporting…") {}.buttonStyle(AccentFillButtonStyle()).disabled(true)
            case .finished(let summary):
                Button("Reveal in Finder") { Reveal.inFinder(summary.destination) }.buttonStyle(OutlineButtonStyle())
                Button("Done") { onClose() }.buttonStyle(AccentFillButtonStyle()).keyboardShortcut(.defaultAction)
            case .failed, .cancelled:
                Button("Close") { onClose() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Try Again") { model.resetAfterRun() }.buttonStyle(AccentFillButtonStyle()).keyboardShortcut(.defaultAction)
            case .idle:
                Button("Cancel") { onClose() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export") { Task { await start() } }
                    .buttonStyle(AccentFillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    private func start() async {
        guard let url = await chooseDestination(model) else { return }
        model.chooseDestination(url)
        await model.run()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func runSavePanel(_ model: ExportSheetModel) async -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.destination.lastPathComponent
        panel.directoryURL = model.destination.deletingLastPathComponent()
        panel.title = "Export \(model.database)"
        panel.prompt = "Export"
        panel.isExtensionHidden = false
        if let window = NSApp.keyWindow {
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
