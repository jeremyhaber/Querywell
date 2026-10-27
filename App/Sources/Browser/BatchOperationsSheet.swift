import QuerywellCore
import SwiftUI

/// "Table Operations…": change the storage engine or convert the character set of several tables.
struct BatchOperationsSheet: View {
    @Bindable var model: BatchOperationsModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    optionsSection
                    tableList
                    if let error = model.planError {
                        WarningCallout(title: "Can't plan this", lines: [error], symbol: "xmark.octagon.fill")
                    }
                    if let plan = model.plan, !plan.warnings.isEmpty, !model.isRunning, model.runState == .idle {
                        WarningCallout(title: "Before you run this", lines: plan.warnings)
                    }
                    if let summary = model.summary { summaryBox(summary) }
                    if model.runState == .idle { sqlSection }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 740, height: 680)
        .background(Theme.background)
        .task { await model.loadMetadata() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table operations")
    }

    // MARK: Header and options

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Table operations").font(.system(size: 15, weight: .semibold))
                Text("\(model.schema) · \(model.tables.count) table\(model.tables.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.isLoadingMetadata { ProgressView().controlSize(.small).accessibilityLabel("Loading server details") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Operation", selection: $model.operation) {
                ForEach(BatchOperationsModel.Operation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.runState != .idle)
            .accessibilityLabel("Operation")

            switch model.operation {
            case .engine:
                labeled("Storage engine") {
                    Picker("Storage engine", selection: $model.engine) {
                        ForEach(model.engines.isEmpty ? [model.engine] : model.engines, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    .disabled(model.runState != .idle)
                }
            case .convert:
                HStack(alignment: .top, spacing: 16) {
                    labeled("Character set") {
                        Picker("Character set", selection: $model.charset) {
                            ForEach(model.characterSets.isEmpty ? [model.charset] : model.characterSets, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170, alignment: .leading)
                        .disabled(model.runState != .idle)
                    }
                    labeled("Collation") {
                        Picker("Collation", selection: $model.collation) {
                            let options = model.collationsForCharset
                            if options.isEmpty { Text(model.collation.isEmpty ? "—" : model.collation).tag(model.collation) }
                            ForEach(options, id: \.name) { Text($0.name + ($0.isDefault ? "  (default)" : "")).tag($0.name) }
                        }
                        .labelsHidden()
                        .frame(width: 270, alignment: .leading)
                        .disabled(model.runState != .idle)
                    }
                }
                Toggle("Also set the default for the database “\(model.schema)”", isOn: $model.alsoSetDatabaseDefault)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .disabled(model.runState != .idle)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptionLabel(title)
            content()
        }
    }

    // MARK: Table list

    private var tableList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 20)
                Text("TABLE").frame(maxWidth: .infinity, alignment: .leading)
                Text("ENGINE").frame(width: 70, alignment: .leading)
                Text("COLLATION").frame(width: 150, alignment: .leading)
                Text("ROWS").frame(width: 56, alignment: .trailing)
                Text("SIZE").frame(width: 64, alignment: .trailing)
                if model.runState != .idle { Text("RESULT").frame(width: 120, alignment: .leading) }
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.sidebar)
            Divider()
            ForEach(model.tables) { info in
                row(info)
                if info.id != model.tables.last?.id { Divider().opacity(0.5) }
            }
        }
        .background(Theme.background)
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    private func row(_ info: TableInfo) -> some View {
        let skipReason = model.skipReasons[info.ref]
        let step = model.plan?.steps.first { $0.table == info.ref }
        let status = step.flatMap { model.statuses[$0.id] }
        let isIncluded = model.included.contains(info.ref) && skipReason == nil
        let dimmed = skipReason != nil
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isIncluded }, set: { _ in model.toggle(info.ref) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(dimmed || model.runState != .idle)
                .frame(width: 20)
                .accessibilityLabel("Include \(info.ref.name)")
            HStack(spacing: 6) {
                Image(systemName: info.kind == .table ? "tablecells" : "eye").font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                Text(info.ref.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if dimmed, model.runState == .idle, let skipReason {
                    Text(skipReason)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(info.engine ?? "—").font(.system(size: 12)).frame(width: 70, alignment: .leading)
            Text(info.collation ?? "—").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                .truncationMode(.middle).frame(width: 150, alignment: .leading)
            Text(info.estimatedRows.map { "~" + CompactCount.string($0) } ?? "—").font(.system(size: 12, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
            Text(Self.sizeText(info)).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .trailing)
            if model.runState != .idle { statusView(status: status, skip: skipReason).frame(width: 120, alignment: .leading) }
        }
        .foregroundStyle(dimmed ? Theme.textTertiary : Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(dimmed ? Theme.sidebar.opacity(0.6) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.ref.name), \(info.engine ?? "no engine"), \(info.collation ?? "no collation")\(skipReason.map { ", skipped: \($0)" } ?? "")")
    }

    @ViewBuilder
    private func statusView(status: BatchOperationsModel.StepStatus?, skip: String?) -> some View {
        Group { statusContent(status: status, skip: skip) }.font(.system(size: 11))
    }

    @ViewBuilder
    private func statusContent(status: BatchOperationsModel.StepStatus?, skip: String?) -> some View {
        switch status {
        case .pending?:
            Label("Waiting", systemImage: "circle").foregroundStyle(Theme.textTertiary)
        case .running?:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Running…") }
        case .done(let d)?:
            Label(LatencyFormatter.string(for: d), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.connectedText)
        case .failed(let message)?:
            Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(Theme.dangerText).help(message)
        case .skipped(let reason)?:
            Label(reason, systemImage: "minus.circle").foregroundStyle(Theme.textTertiary).lineLimit(1)
        case .notRun(let reason)?:
            Label(reason, systemImage: "pause.circle").foregroundStyle(Theme.textTertiary).lineLimit(1)
        case nil:
            Text(skip ?? "Not selected").foregroundStyle(Theme.textTertiary)
        }
    }

    static func sizeText(_ info: TableInfo) -> String {
        guard info.kind == .table, info.dataBytes != nil || info.indexBytes != nil else { return "—" }
        return ByteCountFormatter.string(fromByteCount: (info.dataBytes ?? 0) + (info.indexBytes ?? 0), countStyle: .file)
    }

    // MARK: SQL, summary and footer

    private var sqlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CaptionLabel("SQL that will run")
                Spacer()
                Button("Copy") { copyToPasteboard(model.previewSQL) }
                    .buttonStyle(OutlineButtonStyle())
                    .font(.system(size: 12))
                    .disabled(model.statementCount == 0)
                    .accessibilityLabel("Copy SQL")
            }
            if model.statementCount == 0 {
                Text("Nothing to do: every selected table already matches, or none is checked.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                SQLBox(sql: model.previewSQL, maxHeight: 140, fontSize: 11)
            }
        }
    }

    private func summaryBox(_ summary: String) -> some View {
        guard case .finished(let report) = model.runState else { return AnyView(EmptyView()) }
        let clean = report.isClean
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(clean ? Theme.connectedDot : Theme.pendingEditBar).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(clean ? "Done" : (report.wasCancelled ? "Cancelled" : "Finished with problems")).font(.system(size: 13, weight: .semibold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    ForEach(report.entries.filter { if case .failed = $0.outcome { true } else { false } }, id: \.step.id) { entry in
                        if case .failed(let message) = entry.outcome {
                            Text("\(entry.step.title): \(message)").font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(clean ? Theme.pillPositiveBackground : Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .accessibilityElement(children: .combine))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: Double(model.completedStepCount), total: Double(max(model.totalStepCount, 1)))
                        .accessibilityLabel("Progress")
                    Text("\(model.completedStepCount) of \(model.totalStepCount)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Toggle("Stop on error", isOn: $model.stopOnError)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .disabled(model.runState != .idle)
                    .help("Stop after the first failing table. Off: keep going and report every failure at the end.")
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(OutlineButtonStyle())
                        .help("Stops after the table in progress finishes")
                } else {
                    Button(model.runState == .idle ? "Close" : "Done", action: onClose)
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                if model.runState == .idle {
                    Button(model.statementCount == 0 ? "Run" : "Run \(model.statementCount) statement\(model.statementCount == 1 ? "" : "s")") {
                        Task { await model.run() }
                    }
                    .buttonStyle(AccentFillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
                }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
