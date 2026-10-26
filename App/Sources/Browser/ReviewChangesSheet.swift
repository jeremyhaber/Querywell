import QuerywellCore
import SwiftUI

/// "2 unsaved edits · Review": the amber pill in the table header row (Main.dc.html).
struct PendingEditsPill: View {
    var count: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(Theme.pendingEditBar).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("\(count) unsaved edit\(count == 1 ? "" : "s") · Review")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.pendingPillText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.pendingPillBorder))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Review the unsaved edits and the SQL that will run (⌘S)")
        .accessibilityLabel("\(count) unsaved edits. Review")
    }
}

/// Banner above the grid explaining why a table can't be edited.
struct EditBlockBanner: View {
    var block: EditBlock

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: block.symbol).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            Text(block.message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// The Review sheet: every pending change with before → after, the exact SQL, and Discard All / Commit.
struct ReviewChangesSheet: View {
    @Bindable var model: TableDataModel
    var onClose: () -> Void

    private var changes: [ReviewChange] { model.reviewChanges }
    private var count: Int { model.pendingEditCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let report = model.commitReport, !report.isSuccess { failureBox(report) }
                    ForEach(changes) { change in changeCard(change) }
                    if changes.isEmpty {
                        Text("No pending changes.").foregroundStyle(Theme.textSecondary)
                    }
                    sqlSection
                }
                .padding(16)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 660)
        .frame(minHeight: 360, maxHeight: 680)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review changes")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review changes").font(.system(size: 15, weight: .semibold))
                Text("\(model.table.name) · \(model.pendingSummary)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func changeCard(_ change: ReviewChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon(change.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(change.kind))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(change.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(kindLabel(change.kind)).font(.system(size: 11, weight: .medium)).foregroundStyle(tint(change.kind))
            }
            ForEach(change.cells, id: \.column) { cell in cellRow(cell, kind: change.kind) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .combine)
    }

    private func cellRow(_ cell: ReviewChange.Cell, kind: EditSession.ChangeKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(cell.column)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            if kind == .update {
                valueText(cell.before, struck: true)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("becomes")
            }
            valueText(cell.after, struck: false)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(kind == .insert ? Color.clear : Theme.pendingEditCell)
                .overlay(alignment: .leading) {
                    if kind != .insert { Theme.pendingEditBar.frame(width: 3) }
                }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func valueText(_ value: DatabaseValue?, struck: Bool) -> some View {
        if let value {
            if value.isNull {
                Text(model.nullDisplay).italic().font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            } else {
                let text = CellDisplay.text(value, nullDisplay: model.nullDisplay)
                Text(String(text.prefix(90)) + (text.count > 90 ? "…" : ""))
                    .font(.system(size: 12, design: .monospaced))
                    .strikethrough(struck)
                    .foregroundStyle(struck ? Theme.textSecondary : Theme.text)
                    .lineLimit(2)
            }
        } else {
            Text("—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary)
        }
    }

    private var sqlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CaptionLabel("SQL that will run")
                Spacer()
                Button("Copy") { copyToPasteboard(model.reviewScript) }
                    .buttonStyle(OutlineButtonStyle())
                    .font(.system(size: 12))
                    .accessibilityLabel("Copy SQL")
            }
            SQLBox(sql: model.reviewScript, maxHeight: 150, fontSize: 11)
            let warnings = model.reviewWarnings
            if !warnings.isEmpty { WarningCallout(title: "The server may reject this", lines: warnings) }
            if model.editSession?.optimisticConcurrency == true {
                Text("Each UPDATE also checks the values you loaded, so a row changed by someone else is reported instead of overwritten. All statements run in one transaction.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func failureBox(_ report: CommitReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: report.status == .conflict ? "arrow.triangle.2.circlepath" : "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.dangerText).accessibilityHidden(true)
                Text(report.headline).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let detail = report.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = report.serverError {
                Text("Server: \(error)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statement = report.statement {
                Text(statement).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).lineLimit(4)
            }
            HStack {
                Button("Reload, Keep My Edits") { model.reloadKeepingEdits() }
                    .buttonStyle(OutlineButtonStyle())
                    .help("Loads the current data and keeps your edits on top of it; the Review list then shows the new “before” values.")
                Text("or Discard All to start over.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.dangerText.opacity(0.4)))
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Discard All") { model.discardAll(); onClose() }
                .buttonStyle(OutlineButtonStyle(foreground: Theme.dangerText))
                .disabled(model.isCommitting || count == 0)
            Spacer()
            if model.isCommitting { ProgressView().controlSize(.small).accessibilityLabel("Committing") }
            Button("Close", action: onClose)
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(count == 0 ? "Commit" : "Commit \(count)") { Task { await model.commit() } }
                .buttonStyle(AccentFillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCommitting || count == 0)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func icon(_ kind: EditSession.ChangeKind) -> String {
        switch kind { case .update: "pencil"; case .insert: "plus"; case .delete: "trash" }
    }

    private func tint(_ kind: EditSession.ChangeKind) -> Color {
        switch kind { case .update: Theme.pendingEditBar; case .insert: Theme.pendingInsertedBar; case .delete: Theme.dangerText }
    }

    private func kindLabel(_ kind: EditSession.ChangeKind) -> String {
        switch kind { case .update: "UPDATE"; case .insert: "INSERT"; case .delete: "DELETE" }
    }
}

/// Short-lived confirmation or error message at the bottom of the grid.
struct ToastView: View {
    var toast: ModelToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Theme.dangerText : Theme.connectedDot)
                .accessibilityHidden(true)
            Text(toast.message).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
