import QuerywellCore
import SwiftUI

/// The column funnel popover (design: Filters.dc.html, 280pt wide).
struct FilterPopoverView: View {
    @Bindable var model: FilterEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter \(model.columnName)")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 4) {
                Text("Condition").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Picker("Condition", selection: $model.condition) {
                    ForEach(model.conditions) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Condition")
            }

            if model.condition.usesValueList {
                valueList
            } else if model.condition.usesText {
                TextField(model.condition == .regex ? "Regular expression" : "Text", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.apply() }
                    .accessibilityLabel(model.condition.title)
            } else if model.condition.usesRange {
                rangeFields
            }

            HStack(spacing: 8) {
                Button {
                    model.clear()
                } label: {
                    Text("Clear").frame(maxWidth: .infinity, minHeight: 22)
                }
                .controlSize(.large)
                Button {
                    model.apply()
                } label: {
                    Text("Apply").fontWeight(.medium).frame(maxWidth: .infinity, minHeight: 22)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.elevated)
        .task { if model.condition.usesValueList { await model.load() } }
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                TextField("Search values", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Search values")
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.separator))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                        valueRow(row.value, count: row.count)
                    }
                }
            }
            .frame(minHeight: 40, maxHeight: 210)
            .overlay {
                if let error = model.loadError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText).padding(6)
                } else if model.rows.isEmpty, !model.isLoading {
                    Text("No values").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            if model.isTruncated {
                Text("Showing top 100").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func valueRow(_ value: DatabaseValue, count: Int64?) -> some View {
        Toggle(isOn: Binding(get: { model.selected.contains(value) }, set: { _ in model.toggle(value) })) {
            HStack(spacing: 8) {
                valueLabel(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(CompactCount.grouped(count))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .accessibilityLabel("\(Self.valueText(value))\(count.map { ", \($0) rows" } ?? "")")
    }

    @ViewBuilder
    private func valueLabel(_ value: DatabaseValue) -> some View {
        switch value {
        case .null:
            Text("NULL").font(.system(size: 12, design: .monospaced)).italic().foregroundStyle(Theme.textTertiary)
        case .text(let s) where s.isEmpty:
            Text("(empty string)").font(.system(size: 12)).italic().foregroundStyle(Theme.textTertiary)
        default:
            Text(CellDisplay.text(value, nullDisplay: "NULL"))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    static func valueText(_ value: DatabaseValue) -> String {
        switch value {
        case .null: "NULL"
        case .text(let s) where s.isEmpty: "empty string"
        default: CellDisplay.text(value, nullDisplay: "NULL")
        }
    }

    @ViewBuilder
    private var rangeFields: some View {
        let isDate = model.condition == .dateRange
        VStack(alignment: .leading, spacing: 8) {
            labelled(isDate ? "From (inclusive)" : "From", text: $model.text, prompt: isDate ? "2026-09-26" : "0")
            labelled(isDate ? "To (exclusive)" : "To", text: $model.text2, prompt: isDate ? "2026-10-26" : "100")
            if isDate {
                HStack(spacing: 6) {
                    ForEach([("7 days", 7), ("30 days", 30), ("90 days", 90)], id: \.1) { label, days in
                        Button("Last \(label)") { setLast(days) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func labelled(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { model.apply() }
                .accessibilityLabel(title)
        }
    }

    private func setLast(_ days: Int) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        model.text = formatter.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        model.text2 = ""
    }
}
