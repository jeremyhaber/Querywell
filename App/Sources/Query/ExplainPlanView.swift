import QuerywellCore
import SwiftUI

/// The "Plan" tab: an outline of the EXPLAIN tree with warnings in amber, and the raw output.
struct ExplainPlanView: View {
    @Bindable var model: QueryTabModel
    @State private var showRaw = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            switch model.explainState {
            case .idle:
                placeholder("Press Explain to see how the server will run the statement at the cursor.")
            case .running:
                VStack(spacing: 8) { ProgressView(); Text("Asking the server for a plan…").foregroundStyle(Theme.textSecondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(message, symbol: "exclamationmark.triangle")
            case .done(let outcome):
                if showRaw { rawView(outcome) } else { outline(outcome) }
            }
        }
        .background(Theme.background)
    }

    private var statementIsRead: Bool { model.statementForExplain()?.kind == .read }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $showRaw) {
                Text("Outline").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150, alignment: .leading)
            Toggle("Analyze", isOn: $model.explainAnalyze)
                .toggleStyle(.checkbox)
                .disabled(!statementIsRead)
                .help(statementIsRead
                    ? "Runs the query for real to measure it (reads only)."
                    : "EXPLAIN ANALYZE would execute the statement, so it is only offered for read-only queries.")
            Spacer()
            Button("Re-run Explain") { Task { await model.explain() } }
                .buttonStyle(OutlineButtonStyle())
                .font(.system(size: 12))
                .disabled(model.explainState == .running)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func placeholder(_ text: String, symbol: String = "list.bullet.indent") -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outline(_ outcome: ExplainOutcome) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 10) {
                if let note = outcome.note { WarningCallout(title: nil, lines: [note], symbol: "info.circle.fill") }
                if !outcome.plan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(outcome.plan.warnings.enumerated()), id: \.offset) { _, w in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: w.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(w.severity == .warning ? Theme.pendingEditBar : Theme.textSecondary)
                                    .accessibilityHidden(true)
                                Text(w.message).font(.system(size: 12))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    PlanNodeRow(node: outcome.plan.root, depth: 0, warnings: outcome.plan.warnings, analyzed: outcome.plan.isAnalyze)
                }
                if let ms = outcome.plan.executionTimeMs {
                    Text("Execution \(ms.formatted(.number.precision(.fractionLength(0...2)))) ms" +
                         (outcome.plan.planningTimeMs.map { " · planning \($0.formatted(.number.precision(.fractionLength(0...2)))) ms" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rawView(_ outcome: ExplainOutcome) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(outcome.plan.raw)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PlanNodeRow: View {
    let node: PlanNode
    let depth: Int
    let warnings: [PlanWarning]
    let analyzed: Bool

    private var nodeWarnings: [PlanWarning] { warnings.filter { $0.node == node.title && $0.severity == .warning } }
    private var extraWarns: Bool {
        let joined = node.extra.joined(separator: " ").lowercased()
        return joined.contains("filesort") || joined.contains("temporary")
    }
    private var isFlagged: Bool { !nodeWarnings.isEmpty || extraWarns || node.accessType == "ALL" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if isFlagged {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                            .foregroundStyle(Theme.pendingEditBar).accessibilityLabel("Warning")
                    }
                    Text(node.title).font(.system(size: 12.5, weight: .semibold))
                    if let access = node.accessType {
                        chip("access: \(access)", flagged: access == "ALL")
                    }
                    if let table = node.table, !node.title.contains(table) { chip(table) }
                }
                HStack(spacing: 12) {
                    if let rows = node.rows { stat("rows est.", Self.number(rows)) }
                    if analyzed, let actual = node.actualRows { stat("actual", Self.number(actual)) }
                    if analyzed, let t = node.actualTimeMs { stat("time", "\(t.formatted(.number.precision(.fractionLength(0...2)))) ms") }
                    if let cost = node.cost { stat("cost", cost.formatted(.number.precision(.fractionLength(0...2)))) }
                    if let key = node.keyUsed { stat("key", key) }
                }
                ForEach(Array(node.extra.enumerated()), id: \.offset) { _, line in
                    let flagged = ["filesort", "temporary"].contains { line.lowercased().contains($0) }
                    Text(line).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(flagged ? Theme.warningText : Theme.textSecondary)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFlagged ? Theme.warningAmberFill : Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(isFlagged ? Theme.pendingPillBorder : Theme.separator))
            .accessibilityElement(children: .combine)
            ForEach(node.children) { child in
                PlanNodeRow(node: child, depth: depth + 1, warnings: warnings, analyzed: analyzed)
                    .padding(.leading, 18)
            }
        }
    }

    private func chip(_ text: String, flagged: Bool = false) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(flagged ? Theme.warningText : Theme.chipText)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(flagged ? Theme.pendingPillBackground : Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    static func number(_ v: Double) -> String { v.formatted(.number.grouping(.automatic).precision(.fractionLength(0...1))) }
}
