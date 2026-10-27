import AppKit
import QuerywellCore
import SwiftUI

/// The Database Health & Doctor tab: a refreshable health snapshot, baseline recommendations with Apply, and the
/// revision history with Revert. Renders `HealthTabModel`; nothing here decides anything.
struct HealthTabView: View {
    @Bindable var model: HealthTabModel
    let workspace: ConnectionWorkspace

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner { BannerView(banner: banner) { model.banner = nil } }
            Divider()
            Group {
                switch model.segment {
                case .health: HealthPage(model: model)
                case .doctor: DoctorPage(model: model)
                case .history: HistoryPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .task { await model.startIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database health and doctor")
    }

    private var header: some View {
        HStack(spacing: 14) {
            if model.profile.isProduction { ProdBadge() }
            Text(model.profile.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Picker("Section", selection: $model.segment) {
                ForEach(HealthTabModel.Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityLabel("Section")
            Spacer(minLength: 8)
            if let at = model.snapshot?.collectedAt {
                Text("Updated \(at.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading") }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.isApplying)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Read the server's status again (⌘R)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.chrome)
    }
}

// MARK: - Shared pieces

private struct BannerView: View {
    let banner: HealthTabModel.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Theme.dangerText : Theme.connectedText)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss).buttonStyle(.link)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(banner.isError ? Theme.dangerBackground : Theme.pillPositiveBackground)
    }
}

private extension HealthStatus {
    var color: Color {
        switch self {
        case .ok: Theme.connectedText
        case .warn: Theme.warningText
        case .critical: Theme.dangerText
        case .info, .unavailable: Theme.textSecondary
        }
    }

    var background: Color {
        switch self {
        case .ok: Theme.pillPositiveBackground
        case .warn: Theme.warningBackground
        case .critical: Theme.dangerBackground
        case .info, .unavailable: Theme.chipBackground
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .info: "info.circle"
        case .unavailable: "lock.slash"
        }
    }
}

private struct StatusBadge: View {
    let status: HealthStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(status.background, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }
}

private struct Chip: View {
    let text: String
    var tint: Color = Theme.chipText
    var fill: Color = Theme.chipBackground

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
    }
}

private struct EmptyNote: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Health

private struct HealthPage: View {
    let model: HealthTabModel

    var body: some View {
        if let snapshot = model.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summary(snapshot)
                    ForEach(snapshot.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(group.metrics) { MetricCard(metric: $0) }
                            }
                        }
                    }
                    ForEach(snapshot.lists) { ListCard(list: $0) }
                }
                .padding(16)
            }
        } else if model.isLoading {
            ProgressView("Reading server status…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyNote(symbol: "heart.text.square", title: "No health data yet", message: model.loadError ?? "Press Refresh to read the server's status.")
        }
    }

    private func summary(_ snapshot: HealthSnapshot) -> some View {
        HStack(spacing: 10) {
            StatusBadge(status: snapshot.overall == .info ? .info : snapshot.overall)
            Text(snapshot.warningCount == 0 ? "Nothing needs attention." : "\(snapshot.warningCount) item\(snapshot.warningCount == 1 ? "" : "s") need attention.")
                .font(.system(size: 13))
            Spacer()
            Text("Read-only snapshot. Counters are since the server (or its statistics) last restarted.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct MetricCard: View {
    let metric: HealthMetric

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 6)
                    if metric.status != .info { StatusBadge(status: metric.status) }
                }
                Text(metric.value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(metric.status == .unavailable ? Theme.textSecondary : Theme.text)
                    .textSelection(.enabled)
                if let detail = metric.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // Fill the grid row so cards side by side share the tallest one's height.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title): \(metric.value). \(metric.status.label). \(metric.detail ?? "")")
    }
}

private struct ListCard: View {
    let list: HealthList
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(list.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if list.status != .info { StatusBadge(status: list.status) }
                }
                Text(list.summary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if !list.rows.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(list.rows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.title).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(row.detail).font(.system(size: 12)).foregroundStyle(row.status == .info ? Theme.textSecondary : row.status.color)
                                        .multilineTextAlignment(.trailing)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(expanded ? "Hide \(list.rows.count)" : "Show \(list.rows.count)").font(.system(size: 12))
                    }
                    .accessibilityLabel("\(list.title), \(list.rows.count) entries")
                }
            }
        }
    }
}

// MARK: - Doctor

private struct DoctorPage: View {
    @Bindable var model: HealthTabModel
    @State private var showsPassing = false

    var body: some View {
        if let report = model.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    ramField
                    section("Recommendations", findings: report.recommendations, empty: "Everything checked matches the baseline.")
                    if !report.needingInput.isEmpty {
                        section("Needs your input", findings: report.needingInput, empty: "")
                    }
                    if !report.passing.isEmpty {
                        DisclosureGroup(isExpanded: $showsPassing) {
                            VStack(spacing: 10) { ForEach(report.passing) { FindingCard(model: model, finding: $0) } }.padding(.top, 8)
                        } label: {
                            Text("Matching the baseline (\(report.passing.count))").font(.system(size: 13, weight: .semibold))
                        }
                    }
                    if !report.ignored.isEmpty {
                        DisclosureGroup(isExpanded: $model.showsIgnored) {
                            VStack(spacing: 10) { ForEach(report.ignored) { FindingCard(model: model, finding: $0) } }.padding(.top, 8)
                        } label: {
                            Text("Ignored (\(report.ignored.count))").font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                .padding(16)
            }
        } else if model.isLoading {
            ProgressView("Reading server settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyNote(symbol: "stethoscope", title: "No settings read yet", message: model.loadError ?? "Press Refresh to read the server's settings.")
        }
    }

    private var intro: some View {
        Text("The Doctor compares this server's settings with a conservative baseline of commonly recommended values. These are starting points, not rules: the app can't see your hardware or workload, so read the reasoning and use Ignore for deliberate choices.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ramField: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Server RAM (optional)").font(.system(size: 13, weight: .semibold))
                    Text("Memory recommendations need to know how much RAM the database server has. It is stored for this connection only and never sent anywhere.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                TextField("e.g. 16", text: $model.ramText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit { Task { await model.commitRAM() } }
                    .accessibilityLabel("Server RAM in gibibytes")
                Text("GiB").foregroundStyle(Theme.textSecondary)
                Button("Save") { Task { await model.commitRAM() } }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, findings: [DoctorFinding], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) (\(findings.count))").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if findings.isEmpty, !empty.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(findings) { FindingCard(model: model, finding: $0) }
        }
    }
}

private struct FindingCard: View {
    let model: HealthTabModel
    let finding: DoctorFinding

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(finding.title).font(.system(size: 13, weight: .semibold))
                    Chip(text: finding.variable)
                    Spacer(minLength: 6)
                    badges
                }
                if finding.state == .recommendation { values }
                else if finding.state == .ok, let current = finding.currentValue {
                    Text("Current: \(SettingDisplay.pretty(variable: finding.variable, value: current, kind: finding.kind, engineIsPostgres: finding.scopes.contains(.alterSystem)))")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if let note = finding.note {
                    Text(note).font(.system(size: 12)).foregroundStyle(finding.state == .needsInput ? Theme.warningText : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(finding.rationale).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let drift = model.isDrifted(finding.variable) {
                    Label("Changed outside Querywell since the last revision (recorded \(drift.recordedValue)).", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                }
                if finding.state == .recommendation { actions }
                if model.snippetFor == finding.ruleID, let snippet = model.snippet(for: finding) { snippetView(snippet) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            switch finding.state {
            case .ok: StatusBadge(status: .ok)
            case .needsInput: Chip(text: "Needs RAM", tint: Theme.warningText, fill: Theme.warningBackground)
            case .recommendation:
                Chip(text: finding.severity.label,
                     tint: finding.severity == .important ? Theme.dangerText : Theme.chipText,
                     fill: finding.severity == .important ? Theme.dangerBackground : Theme.chipBackground)
            }
            if finding.restartRequired { Chip(text: "Restart required", tint: Theme.warningText, fill: Theme.warningBackground) }
            if finding.isIgnored { Chip(text: "Ignored") }
        }
    }

    private var values: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text(finding.currentDisplay).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            Image(systemName: "arrow.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text(finding.recommendedDisplay).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current \(finding.currentDisplay), recommended \(finding.recommendedDisplay)")
    }

    @ViewBuilder
    private var actions: some View {
        let canApply = !finding.scopes.isEmpty
        HStack(spacing: 10) {
            if finding.scopes.count > 1 {
                Picker("How", selection: Binding(
                    get: { model.scope(for: finding) ?? finding.scopes[0] },
                    set: { model.scopeChoices[finding.ruleID] = $0 })) {
                    ForEach(finding.scopes, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("How to apply \(finding.title)")
            } else if let only = finding.scopes.first {
                Text(only.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Button("Apply") { Task { await model.apply(finding) } }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply || model.isApplying)
                .help(canApply ? "Run the SQL shown in the confirmation" : "This setting can't be changed while the server runs")
            Button(model.snippetFor == finding.ruleID ? "Hide config" : "Config file…") {
                model.snippetFor = model.snippetFor == finding.ruleID ? nil : finding.ruleID
            }
            Spacer(minLength: 6)
            if finding.isIgnored {
                Button("Stop ignoring") { Task { await model.setIgnored(finding, false) } }
            } else {
                Button("Ignore") { Task { await model.setIgnored(finding, true) } }
                    .help("Hide this recommendation for this connection")
            }
        }
        .controlSize(.small)
        if !canApply {
            Text(model.engine == .postgresql
                 ? "This can't be changed with ALTER SYSTEM here."
                 : "This variable is read-only while the server runs. Put the line from “Config file…” in my.cnf and restart.")
                .font(.system(size: 12)).foregroundStyle(Theme.warningText)
        } else if model.engine == .mariadb || (finding.scopes.first == .runtime && model.engine == .mysql) {
            Text("SET GLOBAL lasts until the server restarts. Use “Config file…” to keep it.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func snippetView(_ snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.engine == .postgresql ? "postgresql.conf" : "my.cnf (or a file in conf.d)").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text(snippet).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet, forType: .string)
                Announce.post("Copied.")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    let model: HealthTabModel
    @State private var confirmAll: SettingRevision?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Only changes made from Querywell are recorded here. Changes made elsewhere (my.cnf, other tools, other people) aren't tracked, but a setting that no longer has the value recorded by its last revision is flagged below.",
                      systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.drift.isEmpty { driftCard }
                if model.revisions.isEmpty {
                    EmptyNote(symbol: "clock.arrow.circlepath", title: "No changes yet",
                              message: "Settings you apply from the Doctor are recorded here with their old value, so you can revert them.")
                        .frame(minHeight: 220)
                } else {
                    ForEach(model.revisionsNewestFirst) { revision in
                        RevisionRow(model: model, revision: revision) { confirmAll = revision }
                    }
                }
            }
            .padding(16)
        }
        .confirmationDialog(
            "Revert to before this change?", isPresented: Binding(get: { confirmAll != nil }, set: { if !$0 { confirmAll = nil } }),
            titleVisibility: .visible, presenting: confirmAll
        ) { revision in
            Button("Revert \(model.revertAllCount(from: revision)) setting\(model.revertAllCount(from: revision) == 1 ? "" : "s")", role: .destructive) {
                Task { await model.revertAll(from: revision) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { revision in
            Text("Every setting changed from “\(revision.variable)” on goes back to its value before that change. This is recorded as new revisions.")
        }
    }

    private var driftCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Changed outside Querywell", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warningText)
                ForEach(model.drift) { d in
                    Text("\(d.variable): recorded \(d.recordedValue), now \(d.currentValue ?? "unknown") (set \(d.revisionDate.formatted(date: .abbreviated, time: .shortened)))")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}

private struct RevisionRow: View {
    let model: HealthTabModel
    let revision: SettingRevision
    let onRevertAll: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(revision.variable).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Chip(text: origin)
                    Chip(text: revision.scope.shortTitle)
                    if revision.restartRequired { Chip(text: "Restart required", tint: Theme.warningText, fill: Theme.warningBackground) }
                    Spacer(minLength: 6)
                    StatusBadge(status: revision.succeeded ? .ok : .critical)
                    Text(revision.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(revision.oldValue ?? "unknown").foregroundStyle(Theme.textSecondary)
                    Image(systemName: "arrow.right").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                    Text(revision.newValue).fontWeight(.semibold)
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("From \(revision.oldValue ?? "unknown") to \(revision.newValue)")
                Text(revision.statements.joined(separator: ";  ") + ";")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                if let error = revision.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Text("Applied from \(revision.appliedFrom)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if revision.succeeded {
                        Button("Revert") { Task { await model.revert(revision) } }
                            .disabled(!model.canRevert(revision))
                            .help(revision.oldValue == nil ? "The previous value wasn't recorded" : "Set \(revision.variable) back to \(revision.oldValue ?? "")")
                        Button("Revert all to before this…", action: onRevertAll)
                            .disabled(model.isApplying || model.facts == nil)
                    }
                }
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var origin: String {
        switch revision.origin {
        case .doctor: "Doctor"
        case .revert: "Revert"
        case .revertAll: "Revert all"
        }
    }
}
