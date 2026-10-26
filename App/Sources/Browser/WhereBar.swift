import AppKit
import QuerywellCore
import SwiftUI

/// The WHERE bar: purple label plus an NSTextField with column autocomplete (design: Main.dc.html).
struct WhereBar: View {
    @Bindable var model: TableDataModel
    var focusToken: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("WHERE")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.tabQuery)
                .accessibilityHidden(true)
            WhereTextField(
                text: $model.whereDraft,
                columns: model.columnDefinitions,
                dialect: model.dialect,
                focusToken: focusToken,
                onSubmit: { model.applyWhere() })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 32)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
    }
}

struct WhereTextField: NSViewRepresentable {
    @Binding var text: String
    var columns: [ColumnDefinition]
    var dialect: SQLDialect?
    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> WhereFieldCoordinator { WhereFieldCoordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = ThemeNS.text
        field.placeholderString = "Filter rows with SQL, e.g. ID > 100  (⌘L)"  // never a realistic condition: it would read as an active filter
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Filter rows with a WHERE clause")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text, coordinator.editingText != text {
            field.stringValue = text
            coordinator.dismissPopup()
        }
        if focusToken != coordinator.lastFocusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 18)
    }
}

@MainActor
final class WhereFieldCoordinator: NSObject, NSTextFieldDelegate {
    var parent: WhereTextField?
    weak var field: NSTextField?
    var lastFocusToken = 0
    /// What the field last reported, so a model echo doesn't reset the caret.
    var editingText = ""
    private var popup: CompletionPopup?
    private var result: WhereCompletionResult?

    func controlTextDidChange(_ obj: Notification) {
        guard let field, let editor = field.currentEditor() else { return }
        editingText = field.stringValue
        parent?.text = field.stringValue
        refreshCompletions(editor: editor)
    }

    func controlTextDidEndEditing(_ obj: Notification) { dismissPopup() }

    private func refreshCompletions(editor: NSText) {
        guard let parent, let dialect = parent.dialect, let field else { return }
        let cursor = editor.selectedRange.location
        guard editor.selectedRange.length == 0, !field.stringValue.isEmpty else { dismissPopup(); return }
        let result = WhereCompletion.complete(text: field.stringValue, cursor: cursor, columns: parent.columns, dialect: dialect)
        // Don't offer a lone item that is already fully typed.
        let typed = (field.stringValue as NSString).substring(with: NSRange(location: result.range.lowerBound, length: max(result.range.count, 0)))
        let items = result.items.filter { !($0.insertText == typed && result.items.count == 1) }
        guard !items.isEmpty else { dismissPopup(); return }
        self.result = WhereCompletionResult(range: result.range, items: items)
        if popup == nil { popup = CompletionPopup() }
        popup?.onPick = { [weak self] index in self?.accept(index: index) }
        popup?.show(items: items, below: field)
    }

    func dismissPopup() {
        popup?.close()
        popup = nil
        result = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let popup, popup.isVisible {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): popup.move(1); return true
            case #selector(NSResponder.moveUp(_:)): popup.move(-1); return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                accept(index: popup.highlighted); return true
            case #selector(NSResponder.cancelOperation(_:)): dismissPopup(); return true
            default: break
            }
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            parent?.onSubmit()
            return true
        }
        return false
    }

    private func accept(index: Int) {
        guard let field, let editor = field.currentEditor() as? NSTextView, let result, result.items.indices.contains(index) else { return }
        let item = result.items[index]
        let range = NSRange(location: result.range.lowerBound, length: result.range.count)
        let insertion = item.insertText + " "
        if editor.shouldChangeText(in: range, replacementString: insertion) {
            editor.replaceCharacters(in: range, with: insertion)
            editor.didChangeText()
        }
        dismissPopup()
    }
}

/// A small borderless window listing completion candidates under the field.
@MainActor
final class CompletionPopup {
    private let panel: NSPanel
    private let list = CompletionListView()
    var onPick: ((Int) -> Void)? {
        didSet { list.onPick = onPick }
    }
    var isVisible: Bool { panel.isVisible }
    var highlighted: Int { list.highlighted }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = list
    }

    func show(items: [WhereCompletionItem], below field: NSView) {
        list.items = items
        list.highlighted = 0
        let rows = min(items.count, CompletionListView.maxRows)
        let height = CGFloat(rows) * CompletionListView.rowHeight + 8
        let width: CGFloat = 320
        guard let window = field.window else { return }
        panel.appearance = window.effectiveAppearance
        let fieldRect = field.convert(field.bounds, to: nil)
        let screenRect = window.convertToScreen(fieldRect)
        let origin = NSPoint(x: screenRect.minX - 4, y: screenRect.minY - height - 6)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        list.needsDisplay = true
    }

    func move(_ delta: Int) {
        guard !list.items.isEmpty else { return }
        list.highlighted = (list.highlighted + delta + list.items.count) % list.items.count
        list.needsDisplay = true
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

final class CompletionListView: NSView {
    static let rowHeight: CGFloat = 24
    static let maxRows = 8
    var items: [WhereCompletionItem] = [] {
        didSet { needsDisplay = true }
    }
    var highlighted = 0 {
        didSet {
            needsDisplay = true
            if highlighted != oldValue, items.indices.contains(highlighted) {
                NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
                Announce.post(items[highlighted].label)
            }
        }
    }
    var onPick: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    // VoiceOver: the custom-drawn list is a list of rows; the highlighted row is selected and its label
    // is announced when the highlight moves (focus stays in the field).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Filter suggestions" }
    override func accessibilityChildren() -> [Any]? {
        items.enumerated().map { index, item in
            let row = NSAccessibilityElement()
            row.setAccessibilityRole(.row)
            row.setAccessibilityLabel(item.label)
            row.setAccessibilityParent(self)
            row.setAccessibilitySelected(index == highlighted)
            return row
        }
    }
    override func accessibilitySelectedChildren() -> [Any]? {
        (accessibilityChildren() ?? []).enumerated().filter { $0.offset == highlighted }.map(\.element)
    }

    /// The window of `maxRows` items that contains the highlight.
    private var firstVisible: Int {
        max(0, min(highlighted - Self.maxRows + 1, items.count - Self.maxRows))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ThemeNS.elevated.setFill()
        path.fill()
        ThemeNS.separator.setStroke()
        path.stroke()
        let start = firstVisible
        for (offset, item) in items.dropFirst(start).prefix(Self.maxRows).enumerated() {
            let rect = NSRect(x: 4, y: 4 + CGFloat(offset) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
            let selected = start + offset == highlighted
            if selected {
                ThemeNS.accentSubtleBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let tag: String
            switch item.kind {
            case .column: tag = "col"
            case .keyword: tag = "kw"
            case .op: tag = "op"
            case .value: tag = "val"
            }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            (tag as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - 7),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: ThemeNS.tabQuery])
            let color = selected ? ThemeNS.accentSubtleText : ThemeNS.text
            (item.label as NSString).draw(at: NSPoint(x: rect.minX + 34, y: rect.midY - 8), withAttributes: [.font: font, .foregroundColor: color])
            if let detail = item.detail {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ThemeNS.textTertiary]
                let size = (detail as NSString).size(withAttributes: attrs)
                (detail as NSString).draw(at: NSPoint(x: rect.maxX - size.width - 6, y: rect.midY - 7), withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = firstVisible + Int((point.y - 4) / Self.rowHeight)
        if items.indices.contains(index) { onPick?(index) }
    }
}
