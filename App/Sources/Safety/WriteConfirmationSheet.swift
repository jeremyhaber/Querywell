import QuerywellCore
import SwiftUI

/// Presents a `ConfirmationRequest` from `WriteGuard`: what is about to run, why it needs a second
/// look, what it will touch (dry-run counts), and, on production, the typed database name.
struct WriteConfirmationSheet: View {
    let request: ConfirmationRequest
    /// Used to run the dry-run counts when the sheet opens; nil skips them (previews).
    var session: (any DatabaseSession)?
    var actionTitle: String = "Run"
    /// Pre-computed results (previews and snapshots); otherwise they are fetched on open.
    var initialResults: [DryRunResult]?
    var onFinish: (Bool) -> Void

    @State private var typed = ""
    @State private var results: [DryRunResult]?
    @State private var isCounting = false
    @FocusState private var typedFocused: Bool

    init(request: ConfirmationRequest, session: (any DatabaseSession)? = nil, actionTitle: String = "Run",
         initialResults: [DryRunResult]? = nil, onFinish: @escaping (Bool) -> Void) {
        self.request = request
        self.session = session
        self.actionTitle = actionTitle
        self.initialResults = initialResults
        self.onFinish = onFinish
        _results = State(initialValue: initialResults)
    }

    private var destructive: Bool { ConfirmationCopy.isDestructive(request) }
    private var canConfirm: Bool { request.isSatisfied(byTyped: typed) && !isCounting }
    private var sqlText: String { request.statements.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) + ";" }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ConfirmationCopy.reasons(for: request).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                        Text(line).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            sqlSection
            if !request.dryRuns.isEmpty { impactSection }
            if let name = request.requiresTypedName { typedSection(name) }
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.background)
        .task { await runDryRuns() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm write")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            if request.isProduction {
                ProdBadge()
                Text("Production database").font(.system(size: 15, weight: .semibold))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18)).foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
                Text("Confirm this change").font(.system(size: 15, weight: .semibold))
            }
            Spacer()
        }
    }

    private var sqlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CaptionLabel("SQL that will run")
                Spacer()
                Button("Copy") { copyToPasteboard(sqlText) }
                    .buttonStyle(OutlineButtonStyle())
                    .font(.system(size: 12))
                    .accessibilityLabel("Copy SQL")
            }
            SQLBox(sql: sqlText, maxHeight: 150)
        }
    }

    private var impactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CaptionLabel("Impact")
                if isCounting { ProgressView().controlSize(.small).accessibilityLabel("Counting affected rows") }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let results {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        impactRow(result)
                    }
                } else {
                    ForEach(Array(request.dryRuns.enumerated()), id: \.offset) { _, plan in
                        HStack(spacing: 6) {
                            Text(plan.subject).font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text("counting…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        }
    }

    private func impactRow(_ result: DryRunResult) -> some View {
        let known = result.count != nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(result.plan.subject).font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(ConfirmationCopy.impact(result))
                .font(.system(size: 12, weight: known ? .semibold : .regular))
                .foregroundStyle(known ? (destructive ? Theme.dangerText : Theme.text) : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func typedSection(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("Type ") + Text(name).font(.system(size: 13, weight: .semibold, design: .monospaced)) + Text(" to confirm"))
                .font(.system(size: 13))
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(request.isSatisfied(byTyped: typed) ? Theme.connectedDot : Theme.separatorStrong, lineWidth: 1.5))
                .focused($typedFocused)
                .onSubmit { if canConfirm { onFinish(true) } }
                .accessibilityLabel("Type \(name) to confirm")
                .onAppear { typedFocused = true }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onFinish(false) }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) { onFinish(true) }
                .buttonStyle(AccentFillButtonStyle(tint: destructive ? Theme.prodBadgeFill : nil))
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .font(.system(size: 13, weight: .medium))
    }

    private func runDryRuns() async {
        guard results == nil, !request.dryRuns.isEmpty else { return }
        guard let session else {
            results = request.dryRuns.map { DryRunResult(plan: $0, count: nil) }
            return
        }
        isCounting = true
        results = await DryRunExecutor.run(request.dryRuns, on: session)
        isCounting = false
    }
}
