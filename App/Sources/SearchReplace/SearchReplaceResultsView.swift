import QuerywellCore
import SwiftUI

/// The right-hand side of the Search & Replace sheet: progress, the per-table results with sample
/// before/after excerpts, invalid serialized values and the final report.
struct SearchReplaceResultsView: View {
    @Bindable var model: SearchReplaceModel
    @State private var expanded: Set<TableRef> = []
    @State private var showingAllSamples: Set<TableRef> = []
    @State private var showSkipped = false
    @State private var didAutoExpand = false

    private var reports: [SearchReplaceTableReport] {
        if model.isRunning { return model.liveReports }
        return model.visibleReport?.tables ?? model.liveReports
    }

    private var withChanges: [SearchReplaceTableReport] {
        reports.filter { r in
            if r.rowsChanged > 0 || !r.conflicts.isEmpty || r.rolledBack { return true }
            if case .failed = r.status { return true }
            if case .cancelled = r.status { return true }
            return false
        }
    }

    private var untouched: [SearchReplaceTableReport] {
        reports.filter { r in !withChanges.contains(where: { $0.table == r.table }) && r.invalidSerialized.isEmpty }
    }

    private var invalid: [CellLocation] { reports.flatMap(\.invalidSerialized) }

    var body: some View {
        Group {
            if model.stage == .configuring, reports.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.isRunning { runningHeader } else if let report = model.visibleReport { summary(report) }
                        if let message = model.runError { WarningCallout(title: "Run failed", lines: [message], symbol: "xmark.octagon.fill") }
                        tableSections
                        if !invalid.isEmpty { invalidSection }
                        conflictsSection
                        skippedSection
                    }
                    .padding(16)
                }
                .accessibilityLabel("Search and replace results")
            }
        }
        .background(Theme.background)
        .onAppear { autoExpand() }
        .onChange(of: model.visibleReport?.tables.count) { _, _ in autoExpand() }
        .onChange(of: model.stage) { _, _ in autoExpand() }
    }

    private func autoExpand() {
        guard !model.isRunning else { return }
        expanded = Set(withChanges.prefix(2).map(\.table))
        showingAllSamples = []
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 34)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text("Preview before you replace").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                bullet("Nothing is written during the preview. It scans the selected tables and shows each change.")
                bullet("Serialized PHP is parsed and rewritten, so s:NN: lengths stay correct. A plain find-and-replace would corrupt them.")
                bullet("JSON values are replaced on the decoded text and written back in their original style.")
                bullet("Serialized values that don't parse are left untouched and listed so you can fix them.")
            }
            .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.textTertiary).frame(width: 4, height: 4).offset(y: -2).accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Header

    private var runningHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.stage == .running(.apply) ? "Replacing…" : "Scanning…").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let current = model.currentTable {
                    Text("Table \(model.tableIndex) of \(model.tableTotal) · \(current.name)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            ProgressView(value: Double(max(0, model.tableIndex - 1)), total: Double(max(1, model.tableTotal)))
                .accessibilityLabel("Progress")
                .accessibilityValue("Table \(model.tableIndex) of \(model.tableTotal)")
            if let current = model.currentTable, let p = model.progress[current] {
                Text("\(p.scanned.formatted()) candidate row\(p.scanned == 1 ? "" : "s") read · \(p.changed.formatted()) with changes")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .contain)
    }

    private func summary(_ report: SearchReplaceReport) -> some View {
        let isApply = report.mode == .apply
        let rolledBack = report.tables.filter(\.rolledBack).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: headerSymbol(report, rolledBack: rolledBack))
                    .foregroundStyle(headerColor(report, rolledBack: rolledBack)).accessibilityHidden(true)
                Text(headline(report, isApply: isApply, rolledBack: rolledBack)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(isApply ? "Applied" : "Dry run · nothing was written")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isApply ? Theme.pillPositiveText : Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(isApply ? Theme.pillPositiveBackground : Theme.chipBackground, in: Capsule())
            }
            HStack(spacing: 0) {
                stat(report.replacements, isApply ? "replacements made" : "replacements")
                stat(report.rowsChanged, isApply ? "rows changed" : "rows to change")
                stat(report.tables.filter { $0.rowsChanged > 0 }.count, "tables")
                if !report.invalidSerialized.isEmpty { stat(report.invalidSerialized.count, "invalid, untouched", tint: Theme.pendingEditBar) }
                if isApply, !report.conflicts.isEmpty { stat(report.conflicts.count, "conflicts", tint: Theme.pendingEditBar) }
                if isApply, rolledBack > 0 { stat(rolledBack, "rolled back", tint: Theme.dangerText) }
            }
        }
        .padding(12)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: Int, _ label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint ?? Theme.text)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ r: SearchReplaceReport, isApply: Bool, rolledBack: Int) -> String {
        if isApply {
            if r.wasCancelled { return "Cancelled · the table in progress was rolled back" }
            if r.stoppedOnError { return "Stopped on error" }
            if !r.failedTables.isEmpty { return "Finished with \(r.failedTables.count) failed table\(r.failedTables.count == 1 ? "" : "s")" }
            return r.replacements == 0 ? "Nothing needed replacing" : "Replacement complete"
        }
        if r.wasCancelled { return "Preview cancelled" }
        return r.replacements == 0 ? "No matches" : "\(r.replacements.formatted()) replacement\(r.replacements == 1 ? "" : "s") found"
    }

    private func headerSymbol(_ r: SearchReplaceReport, rolledBack: Int) -> String {
        if r.wasCancelled || r.stoppedOnError || !r.failedTables.isEmpty || rolledBack > 0 { return "exclamationmark.triangle.fill" }
        return r.mode == .apply ? "checkmark.circle.fill" : "eye.fill"
    }

    private func headerColor(_ r: SearchReplaceReport, rolledBack: Int) -> Color {
        if r.wasCancelled || r.stoppedOnError || !r.failedTables.isEmpty || rolledBack > 0 { return Theme.pendingEditBar }
        return r.mode == .apply ? Theme.connectedDot : Theme.accentText
    }

    // MARK: Tables

    @ViewBuilder
    private var tableSections: some View {
        if model.isRunning, let current = model.currentTable {
            runningRow(current)
        }
        if withChanges.isEmpty, !model.isRunning, model.visibleReport != nil {
            Text("No values in the selected tables match.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 8)
        }
        ForEach(withChanges, id: \.table) { report in tableCard(report) }
    }

    private func runningRow(_ ref: TableRef) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(ref.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            Spacer()
            if let p = model.progress[ref] {
                Text("\(p.scanned.formatted()) read · \(p.changed.formatted()) changed").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .combine)
    }

    private func tableCard(_ r: SearchReplaceTableReport) -> some View {
        let isOpen = expanded.contains(r.table)
        let canExpand = !r.samples.isEmpty || !r.perColumn.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canExpand else { return }
                if isOpen { expanded.remove(r.table) } else { expanded.insert(r.table) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary).frame(width: 12)
                        .opacity(canExpand ? 1 : 0)
                        .accessibilityHidden(true)
                    Text(r.table.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    statusBadges(r)
                    Spacer()
                    Text(counts(r)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(r.table.name), \(counts(r))")
            .accessibilityValue(canExpand ? (isOpen ? "expanded" : "collapsed") : "")
            .accessibilityHint(canExpand ? "Shows sample changes" : "")

            if case .failed(let message) = r.status {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                    .padding(.horizontal, 12).padding(.bottom, 8).fixedSize(horizontal: false, vertical: true)
            }
            if isOpen {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if !r.perColumn.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(r.perColumn, id: \.column) { c in
                                HStack(spacing: 6) {
                                    Text(c.column).font(.system(size: 12, design: .monospaced))
                                    Text("\(c.cells.formatted()) cell\(c.cells == 1 ? "" : "s") · \(c.replacements.formatted()) replacement\(c.replacements == 1 ? "" : "s")")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    let all = showingAllSamples.contains(r.table)
                    let samples = all ? r.samples : Array(r.samples.prefix(4))
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in SampleView(sample: sample) }
                    if r.samples.count > 4 {
                        Button(all ? "Show fewer samples" : "Show \(r.samples.count - 4) more sample\(r.samples.count - 4 == 1 ? "" : "s")") {
                            if all { showingAllSamples.remove(r.table) } else { showingAllSamples.insert(r.table) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
    }

    private func counts(_ r: SearchReplaceTableReport) -> String {
        if r.rowsChanged == 0 { return statusText(r) }
        return "\(r.rowsChanged.formatted()) row\(r.rowsChanged == 1 ? "" : "s") · \(r.replacements.formatted()) replacement\(r.replacements == 1 ? "" : "s")"
    }

    private func statusText(_ r: SearchReplaceTableReport) -> String {
        switch r.status {
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .notRun: "not run"
        case .skipped(let why): why
        case .completed: r.conflicts.isEmpty ? "no changes" : "\(r.conflicts.count) conflict\(r.conflicts.count == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private func statusBadges(_ r: SearchReplaceTableReport) -> some View {
        if !r.isTransactional {
            badge("not transactional", symbol: "exclamationmark.triangle.fill", fg: Theme.warningText, bg: Theme.warningBackground)
        }
        if r.rolledBack { badge("rolled back", symbol: "arrow.uturn.backward", fg: Theme.dangerText, bg: Theme.dangerBackground) }
        if case .failed = r.status { badge("failed", symbol: "xmark.octagon.fill", fg: Theme.dangerText, bg: Theme.dangerBackground) }
        if r.committed, r.rowsChanged > 0 { badge("committed", symbol: "checkmark", fg: Theme.pillPositiveText, bg: Theme.pillPositiveBackground) }
    }

    private func badge(_ text: String, symbol: String, fg: Color, bg: Color) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(bg, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }

    // MARK: Invalid serialized

    private var invalidSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
                Text("Invalid serialized values — left untouched").font(.system(size: 13, weight: .semibold))
            }
            Text("These look like PHP serialized data but don't parse (usually a wrong string length). Replacing inside them would only make it worse, so they were skipped. Open one to repair it, then run the preview again.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(invalid.prefix(50).enumerated()), id: \.offset) { index, location in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Text(location.table.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(location.primaryKey.map { "\($0.column) \($0.value)" }.joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        Text(location.column).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Open in PHP Editor") { model.openInvalid(location) }
                            .controlSize(.small)
                            .accessibilityLabel("Open \(location.table.name) \(location.column) in the PHP editor")
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                }
                if invalid.count > 50 {
                    Text("and \(invalid.count - 50) more").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.pendingPillBorder.opacity(0.6)))
        }
        .padding(12)
        .background(Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.pendingPillBorder))
    }

    @ViewBuilder
    private var conflictsSection: some View {
        let conflicts = reports.flatMap(\.conflicts)
        if !conflicts.isEmpty, model.stage == .applied {
            WarningCallout(
                title: "\(conflicts.count) row\(conflicts.count == 1 ? " was" : "s were") changed by someone else while the run was in progress",
                lines: ["They were not overwritten. Run the preview again to pick them up.",
                        conflicts.prefix(5).map { "\($0.table.name) · \($0.primaryKey.map { "\($0.column) \($0.value)" }.joined(separator: ", "))" }.joined(separator: "   ")])
        }
    }

    @ViewBuilder
    private var skippedSection: some View {
        let skipped = untouched
        if !skipped.isEmpty, !model.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Button { showSkipped.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showSkipped ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                        Text("\(skipped.count) table\(skipped.count == 1 ? "" : "s") without changes or skipped")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                if showSkipped {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(skipped, id: \.table) { r in
                            HStack(spacing: 8) {
                                Text(r.table.name).font(.system(size: 12, design: .monospaced))
                                Text(statusText(r)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.leading, 15)
                }
            }
        }
    }
}

// MARK: - Sample

/// One changed cell: kind badge, where it is, and the before / after excerpts with the change marked.
private struct SampleView: View {
    var sample: ChangePreview

    var body: some View {
        let (before, after) = ExcerptDiff.highlight(before: sample.before, after: sample.after)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                KindBadge(kind: sample.kind)
                Text(sample.primaryKey.map { "\($0.column) \($0.value)" }.joined(separator: ", ") + " · " + sample.column)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if sample.replacements > 1 {
                    Text("\(sample.replacements) replacements").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            line("−", before, tint: Theme.dangerText)
            line("+", after, tint: Theme.pendingInsertedText)
        }
        .padding(9)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sample.table.name) \(sample.column), \(KindBadge.name(sample.kind)). Before: \(sample.before). After: \(sample.after)")
    }

    private func line(_ sign: String, _ text: AttributedString, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(tint).frame(width: 10)
            Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct KindBadge: View {
    var kind: ReplaceKind

    static func name(_ kind: ReplaceKind) -> String {
        switch kind {
        case .plain: "plain text"
        case .phpSerialized: "PHP serialized"
        case .json: "JSON"
        case .phpSerializedInvalid: "invalid serialized"
        }
    }

    var body: some View {
        let (label, tone): (String, TreeTone) = switch kind {
        case .plain: ("plain", .neutral)
        case .phpSerialized: ("serialized", .className)
        case .json: ("JSON", .container)
        case .phpSerializedInvalid: ("invalid", .number)
        }
        TypeBadge(text: label, tone: tone)
    }
}

/// Marks what differs between two short excerpts: removed characters in the before text, inserted
/// characters in the after text (a character-level diff; the excerpts are at most a few hundred characters).
enum ExcerptDiff {
    static func highlight(before: String, after: String) -> (AttributedString, AttributedString) {
        let b = Array(before), a = Array(after)
        var removed = Set<Int>(), inserted = Set<Int>()
        if b.count + a.count <= 1_200 {
            for change in a.difference(from: b) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        }
        return (
            attributed(b, marked: removed, foreground: Theme.dangerText, background: Theme.dangerBackground),
            attributed(a, marked: inserted, foreground: Theme.pendingInsertedText, background: Theme.pendingInsertedRow))
    }

    private static func attributed(_ chars: [Character], marked: Set<Int>, foreground: Color, background: Color) -> AttributedString {
        var out = AttributedString()
        var i = 0
        while i < chars.count {
            let isMarked = marked.contains(i)
            var j = i
            while j < chars.count, marked.contains(j) == isMarked { j += 1 }
            var piece = AttributedString(String(chars[i..<j]))
            if isMarked {
                piece.foregroundColor = foreground
                piece.backgroundColor = background
            }
            out.append(piece)
            i = j
        }
        return out
    }
}
