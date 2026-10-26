import QuerywellCore
import SwiftUI

/// Right-hand panel for the selected row (design: Main.dc.html, "Row inspector").
///
/// Read-only for now. The edit work plugs in through ``onEdit``: when non-nil each field becomes editable
/// and reports `(column, newValue)`; the "pending" styling (`Theme.pendingEdit*`) and the PENDING SQL box
/// from the mockup belong in ``InspectorField`` / below the fields.
struct RowInspectorView: View {
    var title: String
    var subtitle: String?
    var columns: [GridColumn]
    var values: [DatabaseValue]?
    var focusColumn: String?
    var nullDisplay: String
    var onClose: () -> Void
    /// `nil` = read-only (this commit). Set by the editing feature.
    var onEdit: ((String, DatabaseValue) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close inspector (⌥⌘I)")
                .accessibilityLabel("Close inspector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let values, values.count == columns.count {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                                InspectorField(
                                    column: column, value: values[index], nullDisplay: nullDisplay,
                                    isFocused: focusColumn?.caseInsensitiveCompare(column.name) == .orderedSame,
                                    onEdit: onEdit)
                                    .id(column.name)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: focusColumn) { _, _ in scroll(proxy) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.and.text.magnifyingglass").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                    Text("Select a row to inspect it").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Row inspector")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focusColumn else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(focusColumn, anchor: .center) }
    }
}

/// One labelled value. Short values are one line; long text and JSON get a multiline monospaced box.
struct InspectorField: View {
    var column: GridColumn
    var value: DatabaseValue
    var nullDisplay: String
    var isFocused: Bool
    var onEdit: ((String, DatabaseValue) -> Void)?

    private var fullText: String { CellDisplay.full(value, limit: 20_000) }

    private var isMultiline: Bool {
        guard case .text(let s) = value else { return false }
        return s.contains("\n") || s.count > 60 || column.presentation.kind == .json || column.presentation.kind == .longText
    }

    private var isStructured: Bool {
        guard case .text(let s) = value else { return false }
        return ValueSniffer.isJSONLike(s) || ValueSniffer.isPHPSerialized(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.pendingEditBar).accessibilityLabel("Primary key")
                }
                Text(column.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(column.fullType).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                if isStructured {
                    // Phase 6 brings the JSON / serialized-PHP editor.
                    Button("Open in editor") {}.controlSize(.mini).disabled(true).help("Phase 6")
                }
            }
            // `onEdit != nil` is where editable controls replace this read-only box.
            box
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(column.name): \(value.isNull ? "null" : CellDisplay.text(value, nullDisplay: nullDisplay))")
    }

    @ViewBuilder
    private var box: some View {
        let font: Font = column.presentation.usesMonospace || isMultiline || isStructured
            ? .system(size: 12, design: .monospaced) : .system(size: 13)
        Group {
            if value.isNull {
                Text(nullDisplay).font(.system(size: 12, design: .monospaced)).italic().foregroundStyle(Theme.textTertiary)
            } else if isMultiline {
                ScrollView {
                    Text(fullText).font(font).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            } else {
                Text(fullText).font(font).textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(isFocused ? Theme.accent : Theme.separator, lineWidth: isFocused ? 1.5 : 1))
    }
}
