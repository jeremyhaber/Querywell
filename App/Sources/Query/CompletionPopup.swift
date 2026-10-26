import AppKit
import Observation
import QuerywellCore
import SwiftUI

/// State behind the autocomplete list.
@MainActor @Observable
final class SQLCompletionListModel {
    var items: [CompletionItem] = []
    var selected = 0
    var onPick: (CompletionItem) -> Void = { _ in }

    var current: CompletionItem? { items.indices.contains(selected) ? items[selected] : nil }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
    }
}

/// The list in the popup (design: Query.dc.html `role="listbox"`: 12pt rows, selected row in the subtle accent).
struct SQLCompletionListView: View {
    let model: SQLCompletionListModel

    static let rowHeight: CGFloat = 24
    static let maxRows = 9

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        row(item, selected: index == model.selected)
                            .id(index)
                            .onTapGesture { model.onPick(item) }
                    }
                }
                .padding(4)
            }
            .onChange(of: model.selected) { _, new in proxy.scrollTo(new) }
        }
        .background(Theme.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Autocomplete")
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(item.kind))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Theme.accentSubtleText : Self.tint(item.kind))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(item.label)
                .font(.system(size: 12, design: item.kind == .keyword ? .default : .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.accentSubtleText.opacity(0.85) : Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Theme.accentSubtleText : Theme.text)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.accentSubtleBackground : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func symbol(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .table: "tablecells"
        case .view: "eye"
        case .schema: "cylinder"
        case .column: "rectangle.split.3x1"
        case .function: "function"
        case .routine: "curlybraces"
        case .keyword: "textformat"
        case .enumValue: "quote.opening"
        case .alias: "at"
        }
    }

    static func tint(_ kind: CompletionItem.Kind) -> Color {
        switch kind {
        case .keyword: Theme.syntaxKeyword
        case .function, .routine: Theme.syntaxFunction
        case .enumValue: Theme.syntaxString
        default: Theme.textSecondary
        }
    }
}

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the popup window: a borderless, non-activating child window so typing stays in the editor.
@MainActor
final class SQLCompletionPanelController {
    let model = SQLCompletionListModel()
    private var panel: CompletionPanel?
    private(set) var result: CompletionResult?

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ result: CompletionResult, anchor: NSRect, in parent: NSWindow) {
        guard !result.items.isEmpty else { hide(); return }
        self.result = result
        model.items = result.items
        model.selected = 0
        let rows = min(result.items.count, SQLCompletionListView.maxRows)
        let height = CGFloat(rows) * SQLCompletionListView.rowHeight + 8
        let width: CGFloat = 320
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(NSSize(width: width, height: height))

        // Below the caret line; above it when there is no room.
        var origin = NSPoint(x: anchor.minX - 4, y: anchor.minY - height - 2)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = anchor.maxY + 2 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
        }
        panel.setFrameOrigin(origin)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        result = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView:
            SQLCompletionListView(model: model)
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
                .padding(1))
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }
}
