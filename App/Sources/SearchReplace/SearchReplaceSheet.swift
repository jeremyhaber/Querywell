import QuerywellCore
import SwiftUI

/// Database ▸ Search & Replace…: serialization-safe search and replace across tables, in two steps:
/// a dry-run preview, then the replacement.
struct SearchReplaceSheet: View {
    @Bindable var model: SearchReplaceModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                configuration
                    .frame(width: 330)
                    .background(Theme.sidebar)
                Divider()
                SearchReplaceResultsView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1060, maxWidth: .infinity, minHeight: 620, idealHeight: 740, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search and replace")
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Search & Replace").font(.system(size: 15, weight: .semibold))
                Text("Serialization-safe across \(model.schema) · PHP serialized and JSON values keep valid lengths")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 0) {
                StepLabel(number: 1, title: "Preview", state: step1State)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 8)
                    .accessibilityHidden(true)
                StepLabel(number: 2, title: "Replace", state: step2State)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var step1State: StepLabel.State {
        switch model.stage {
        case .configuring: .current
        case .running(.dryRun): .current
        default: .done
        }
    }

    private var step2State: StepLabel.State {
        switch model.stage {
        case .configuring: .upcoming
        case .running(.dryRun): .upcoming
        case .previewed: model.confirmingApply ? .current : .upcoming
        case .running(.apply): .current
        case .applied: .done
        case .running: .upcoming
        }
    }

    // MARK: Configuration

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                    options
                }
                .padding(16)
            }
            Divider()
            tablePicker
                .frame(height: 250)
        }
        .disabled(model.isRunning)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Search for")
                TextField("Text or pattern", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel("Search for")
                if let error = model.inputError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.dangerText).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                CaptionLabel("Replace with")
                TextField("Replacement", text: $model.replace)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel("Replace with")
                if model.regex {
                    Text("Use $1, $2 for captured groups.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 7) {
            CaptionLabel("Options")
            Toggle("Case sensitive", isOn: $model.caseSensitive)
            Toggle("Regular expression", isOn: $model.regex)
            Toggle("Whole word", isOn: $model.wholeWord)
            Toggle("Include JSON keys", isOn: $model.includeJSONKeys)
                .help("Also search the names of JSON object keys, not just values")
            Toggle("Include PHP array keys", isOn: $model.includePHPKeys)
                .help("Also search string keys of serialized PHP arrays. Object property names and class names are never changed.")
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Replace JSON-escaped slashes (\\/) too", isOn: $model.replaceEscapedSlashes)
                Text(verbatim: "Finds https:\\/\\/example.com inside block comments and JSON text when you search for https://example.com.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if model.wordPressPrefix != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Include WordPress guid", isOn: $model.includeWordPressGUID)
                    Text("Off by default: a post's guid is its permanent ID, not a link. Changing it can make feed readers show old posts as new.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            Toggle("Include binary columns", isOn: $model.includeBinary)
                .help("Also search BLOB, BINARY and bytea columns as bytes")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    // MARK: Tables

    private var tablePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CaptionLabel("Tables").fixedSize()  // never wrap ("TABLE / S") when the WordPress badge is shown
                if let prefix = model.wordPressPrefix {
                    Text("WordPress (\(prefix))").font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize().foregroundStyle(Theme.accentSubtleText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.accentSubtleBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                        .help("WordPress detected: its tables are pre-selected")
                }
                Text("\(model.selectedCount) of \(model.eligibleTables.count)")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                if model.structuresLoaded < model.tables.filter({ $0.info.kind == .table }).count, !model.tables.isEmpty {
                    ProgressView().controlSize(.mini).accessibilityLabel("Reading table structures")
                }
                Spacer()
                Button("All") { model.selectAll() }.controlSize(.small).accessibilityLabel("Select all tables")
                Button("None") { model.selectNone() }.controlSize(.small).accessibilityLabel("Select no tables")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                TextField("Filter tables", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("Filter tables")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.separator))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let error = model.tablesError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText).padding(16)
            } else if model.isLoadingTables {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleTables) { table in tableRow(table) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .accessibilityLabel("Tables")
            }
        }
    }

    private func tableRow(_ table: SearchReplaceModel.TableChoice) -> some View {
        let isOn = model.selected.contains(table.id)
        let disabled = table.ineligibleReason != nil
        return Button { model.toggle(table.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    if let reason = table.ineligibleReason {
                        Text(reason).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if table.isNonTransactional, let engine = table.info.engine {
                    Label(engine, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.warningText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
                        .help("\(engine) isn't transactional: if a run fails or is cancelled, changes already made to this table can't be rolled back.")
                }
                if let rows = table.info.estimatedRows, !disabled {
                    Text(CompactCount.grouped(rows)).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(table.name)\(table.isNonTransactional ? ", \(table.info.engine ?? "") is not transactional" : "")\(table.ineligibleReason.map { ", unavailable: \($0)" } ?? "")")
        .accessibilityValue(isOn ? "selected" : "not selected")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            footerStatus
            Spacer()
            if model.isRunning {
                Button("Cancel") { model.cancelRun() }
                    .help("Stops after the current batch. The table being written is rolled back.")
            } else {
                Button(model.stage == .applied ? "Done" : "Close", action: onClose).keyboardShortcut(.cancelAction)
                Toggle("Stop on error", isOn: $model.stopOnError)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Stop at the first table that fails. Otherwise the remaining tables still run.")
                Button { Task { await model.runPreview() } } label: { Text("Preview (dry run)") }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canPreview)
                    .help(model.previewBlocker ?? "Scan the selected tables and show what would change. Nothing is written. (⌘↵)")
                if model.confirmingApply {
                    Button("Not Now") { model.cancelApplyConfirmation() }
                    Button { Task { await model.confirmApply() } } label: { Text("Replace \(model.previewTotals.rows.formatted()) Row\(model.previewTotals.rows == 1 ? "" : "s")") }
                        .buttonStyle(AccentFillButtonStyle(tint: model.isProduction ? Theme.tagProduction : nil))
                } else {
                    Button { model.beginApply() } label: { Text("Replace…") }
                        .buttonStyle(AccentFillButtonStyle())
                        .disabled(!model.canApply)
                        .help(model.applyBlocker ?? "Apply the previewed replacement")
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var footerStatus: some View {
        if model.confirmingApply {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
                Text("\(model.applySummary). This can't be undone from Querywell.")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .accessibilityElement(children: .combine)
        } else if let blocker = model.applyBlocker, model.previewReport != nil, model.stage != .applied, !model.isRunning {
            Text(blocker).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        } else if model.previewReport != nil, model.stage == .previewed {
            Text(model.applySummary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        } else if let blocker = model.previewBlocker, model.stage == .configuring {
            Text(blocker).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct StepLabel: View {
    enum State { case upcoming, current, done }
    var number: Int
    var title: String
    var state: State

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(state == .current ? Theme.accent : state == .done ? Theme.pillPositiveBackground : Theme.chipBackground)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.pillPositiveText)
                } else {
                    Text("\(number)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(state == .current ? Color.white : Theme.chipText)
                }
            }
            .frame(width: 18, height: 18)
            Text(title).font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? Theme.textTertiary : Theme.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title), \(state == .done ? "done" : state == .current ? "current" : "upcoming")")
    }
}
