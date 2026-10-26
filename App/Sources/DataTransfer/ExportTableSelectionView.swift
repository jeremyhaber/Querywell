import AppKit
import QuerywellCore
import SwiftUI

/// The export dialog's table section: presets, remembered rules, a filter with bulk actions, and the grouped
/// list where each table has a Structure and a Data toggle (both on by default).
struct ExportTableSelectionView: View {
    @Bindable var model: ExportSheetModel
    @State private var collapsed: Set<String> = []
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetsRow
            if !model.rules.isEmpty { ruleChips }
            filterRow
            VStack(spacing: 0) {
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(model.groups) { group in groupSection(group) }
                    }
                }
                .frame(maxHeight: 300)
                .focusable()
                .focused($listFocused)
                .onKeyPress(.space) {
                    guard !model.selection.isEmpty else { return .ignored }
                    model.cycleMode(of: Array(model.selection))
                    return .handled
                }
            }
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
            Text(model.selectionSummary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }

    // MARK: Presets, rules, filter

    private var presetsRow: some View {
        HStack(spacing: 8) {
            Text("Quick select").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            ForEach(ExportTablePreset.allCases) { preset in
                let available = preset == .allTables || model.groups.contains { $0.kind == .core }
                Button(preset.title) { model.apply(preset: preset) }
                    .buttonStyle(OutlineButtonStyle())
                    .font(.system(size: 12))
                    .disabled(!available)
                    .help(available ? "" : "No WordPress core tables were found in this database.")
            }
            Spacer(minLength: 0)
            Picker("Sort", selection: $model.sortBySize) {
                Text("Name").tag(false)
                Text("Size").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
        }
    }

    private var ruleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Rules").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                ForEach(model.rules) { rule in
                    HStack(spacing: 4) {
                        Text(rule.label).font(.system(size: 12, design: .monospaced))
                        Button { model.removeRule(rule.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove rule \(rule.label)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(Theme.accentSubtleText)
                    .background(Theme.accentSubtleBackground, in: Capsule())
                    .help("Applied to every export of this connection, including tables added later")
                }
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                TextField("Filter tables — name or pattern like wp_wf*", text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 13))
                if model.isFiltering {
                    Button { model.filterText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
            if model.isFiltering {
                let n = model.visibleTables.count
                Button("Skip \(n) matching") { model.setModeForVisible(.skip) }.buttonStyle(OutlineButtonStyle()).disabled(n == 0)
                Button("Structure only") { model.setModeForVisible(.structureOnly) }.buttonStyle(OutlineButtonStyle()).disabled(n == 0)
                Button("Include") { model.setModeForVisible(.both) }.buttonStyle(OutlineButtonStyle()).disabled(n == 0)
                Menu("Remember as rule") {
                    Button("Always skip “\(model.filterText)”") { model.rememberFilterAsRule(.skip) }
                    Button("Always structure only") { model.rememberFilterAsRule(.structureOnly) }
                    Button("Always include") { model.rememberFilterAsRule(.both) }
                }
                .menuStyle(.button).buttonStyle(OutlineButtonStyle()).fixedSize()
            } else {
                let pending = model.pendingSuggestions.count
                Button("Apply suggestions (\(pending))") { model.applySuggestions() }
                    .buttonStyle(OutlineButtonStyle()).disabled(pending == 0)
                    .help("Sets log, cache and session tables to structure only. Never applied automatically.")
            }
        }
        .font(.system(size: 12))
    }

    // MARK: List

    private var columnHeader: some View {
        let visible = model.visibleTables
        return HStack(spacing: 10) {
            columnToggle(isOn: Binding(get: { !visible.isEmpty && visible.allSatisfy(model.includesStructure) },
                                       set: { model.setStructure($0, for: visible) }), label: "Structure")
            columnToggle(isOn: Binding(get: { !visible.isEmpty && visible.allSatisfy(model.includesData) },
                                       set: { model.setData($0, for: visible) }), label: "Data")
            Text("Table").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("Size").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func columnToggle(isOn: Binding<Bool>, label: String) -> some View {
        Toggle(isOn: isOn) { Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
            .toggleStyle(.checkbox)
            .frame(width: 84, alignment: .leading)
            .help("All \(label.lowercased()) for the tables shown")
    }

    @ViewBuilder
    private func groupSection(_ group: TableGroup) -> some View {
        let tables = model.tables(in: group)
        if !tables.isEmpty {
            let names = tables.map(\.ref.name)
            let isCollapsed = collapsed.contains(group.id)
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { names.allSatisfy(model.includesStructure) }, set: { model.setStructure($0, for: names) }))
                    .toggleStyle(.checkbox).labelsHidden().frame(width: 84, alignment: .leading)
                    .accessibilityLabel("Structure of \(group.title)")
                Toggle("", isOn: Binding(get: { names.allSatisfy(model.includesData) }, set: { model.setData($0, for: names) }))
                    .toggleStyle(.checkbox).labelsHidden().frame(width: 84, alignment: .leading)
                    .accessibilityLabel("Data of \(group.title)")
                Button {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Text(group.title).font(.system(size: 12, weight: .semibold))
                        Text("· \(tables.count) table\(tables.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Skip group") { model.setMode(.skip, for: names) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.chrome)
            if !isCollapsed { ForEach(tables) { row($0) } }
        }
    }

    private func row(_ table: TableInfo) -> some View {
        let name = table.ref.name
        let mode = model.mode(of: name)
        let isSelected = model.selection.contains(name)
        let suggestion = model.suggestion(for: name)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.includesStructure(name) }, set: { model.setStructure($0, for: model.rowTargets(name)) }))
                .toggleStyle(.checkbox).labelsHidden().frame(width: 84, alignment: .leading)
                .accessibilityLabel("Structure of \(name)")
            Toggle("", isOn: Binding(get: { model.includesData(name) }, set: { model.setData($0, for: model.rowTargets(name)) }))
                .toggleStyle(.checkbox).labelsHidden().frame(width: 84, alignment: .leading)
                .accessibilityLabel("Data of \(name)")
            Text(name)
                .font(.system(size: 13, design: .monospaced))
                .strikethrough(mode == .skip)
                .foregroundStyle(mode == .skip ? Theme.textTertiary : Theme.text)
                .lineLimit(1)
            if table.kind != .table { Text("view").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            if let suggestion, mode != suggestion.mode {
                Text("Suggest: structure only")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.pendingPillText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.pendingPillBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.pendingPillBorder.opacity(0.7)))
                    .help(suggestion.reason)
            } else if mode == .structureOnly {
                Text("structure only").font(.system(size: 11)).foregroundStyle(Theme.pendingPillText)
            } else if mode == .dataOnly {
                Text("data only").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(sizeText(table, mode: mode)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(isSelected ? Theme.selectedRow : (mode == .structureOnly ? Theme.pendingPillBackground.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) || flags.contains(.command) {
                if isSelected { model.selection.remove(name) } else { model.selection.insert(name) }
            } else {
                model.selection = [name]
                model.cycleMode(of: [name])
            }
        }
        .contextMenu {
            let targets = model.rowTargets(name)
            Button("Structure and data") { model.setMode(.both, for: targets) }
            Button("Structure only") { model.setMode(.structureOnly, for: targets) }
            Button("Data only") { model.setMode(.dataOnly, for: targets) }
            Button("Skip") { model.setMode(.skip, for: targets) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(modeText(mode))")
    }

    private func modeText(_ mode: TableExportMode) -> String {
        switch mode {
        case .both: "structure and data"
        case .structureOnly: "structure only"
        case .dataOnly: "data only"
        case .skip: "skipped"
        }
    }

    private func sizeText(_ table: TableInfo, mode: TableExportMode) -> String {
        let bytes = (table.dataBytes ?? 0) + (table.indexBytes ?? 0)
        return bytes > 0 ? ExportSheetModel.byteString(bytes) : "—"
    }
}

extension ExportSheetModel {
    /// The tables an action on `name` applies to: the whole selection when `name` is part of it.
    func rowTargets(_ name: String) -> [String] {
        selection.contains(name) && selection.count > 1 ? Array(selection) : [name]
    }
}
