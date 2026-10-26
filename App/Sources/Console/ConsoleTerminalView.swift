import AppKit
import QuerywellCore
import SwiftUI

/// The scrollback + input line of the SQL console as one text view: output is selectable and copyable, and
/// every edit is routed to the model (which owns the input line), so history, Tab completion and the
/// multi-line prompts behave the same with a real keyboard and in tests.
struct ConsoleTerminalView: NSViewRepresentable {
    let model: ConsoleTabModel
    /// Changes whenever the model's visible state does, so SwiftUI calls `updateNSView`.
    let stamp: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ConsoleNSTextView()
        textView.model = model
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ConsoleThemeNS.background
        scroll.setAccessibilityLabel("SQL console")
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        context.coordinator.render()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.render()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ConsoleTabModel
        weak var textView: ConsoleNSTextView?
        private var renderedClear = -1
        private var renderedCount = 0
        private var liveStart = 0

        init(model: ConsoleTabModel) { self.model = model }

        private var paragraph: NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = 20
            p.maximumLineHeight = 20
            p.lineBreakMode = .byClipping
            return p
        }

        private func attributes(_ role: ConsoleRole, lineID: Int? = nil) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [
                .font: role == .header ? ConsoleThemeNS.boldFont : ConsoleThemeNS.font,
                .foregroundColor: ConsoleThemeNS.color(for: role),
                .paragraphStyle: paragraph,
            ]
            if case .link = role, let lineID, let url = URL(string: "querywell-grid://\(lineID)") {
                a[.link] = url
                a[.cursor] = NSCursor.pointingHand
            }
            return a
        }

        private func attributed(_ line: ConsoleLine) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for seg in line.segments { out.append(NSAttributedString(string: seg.text, attributes: attributes(seg.role, lineID: line.id))) }
            out.append(NSAttributedString(string: "\n", attributes: attributes(.text)))
            return out
        }

        /// Brings the text storage in line with the model: scrollback is appended (or rebuilt after `clear`),
        /// the live prompt + input is replaced.
        func render() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let hadSelection = tv.selectedRange().length > 0
            storage.beginEditing()
            if renderedClear != model.clearCount {
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
                renderedClear = model.clearCount
                renderedCount = 0
                liveStart = 0
            }
            // Drop the old live region, append new scrollback, re-add the live region.
            storage.deleteCharacters(in: NSRange(location: liveStart, length: storage.length - liveStart))
            if renderedCount < model.scrollback.count {
                for line in model.scrollback[renderedCount...] { storage.append(attributed(line)) }
                renderedCount = model.scrollback.count
            }
            liveStart = storage.length

            var starts: [Int] = []
            var promptLengths: [Int] = []
            if !model.isRunning {
                for (i, text) in model.editor.lines.enumerated() {
                    let prompt = model.prompt(forLine: i)
                    starts.append(storage.length)
                    promptLengths.append(prompt.count)
                    storage.append(NSAttributedString(string: prompt, attributes: attributes(.prompt)))
                    storage.append(NSAttributedString(string: text, attributes: attributes(.input)))
                    if i < model.editor.lines.count - 1 { storage.append(NSAttributedString(string: "\n", attributes: attributes(.input))) }
                }
            }
            storage.endEditing()
            tv.liveLineStarts = starts
            tv.livePromptLengths = promptLengths

            if !model.isRunning, !hadSelection, let start = starts[safe: model.editor.line] {
                let chars = Array(model.editor.lines[model.editor.line])
                let prefix = String(chars[..<min(model.editor.column, chars.count)])
                let location = start + promptLengths[model.editor.line] + (prefix as NSString).length
                tv.setSelectedRange(NSRange(location: min(location, storage.length), length: 0))
            }
            tv.sizeToFitContent()
            tv.scrollRangeToVisible(NSRange(location: tv.selectedRange().location, length: 0))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "querywell-grid", let host = url.host, let id = Int(host),
                  let line = model.scrollback.first(where: { $0.id == id }) else { return false }
            for seg in line.segments {
                if case .link(let sql) = seg.role { model.onOpenInGrid(sql); return true }
            }
            return false
        }
    }
}

/// NSTextView whose contents are driven by `ConsoleTabModel`: it never edits its own storage.
@MainActor
final class ConsoleNSTextView: NSTextView {
    weak var model: ConsoleTabModel?
    var liveLineStarts: [Int] = []
    var livePromptLengths: [Int] = []

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = []
        textContainerInset = NSSize(width: 20, height: 14)
        drawsBackground = true
        backgroundColor = ConsoleThemeNS.background
        insertionPointColor = ConsoleThemeNS.caret.withAlphaComponent(0.7)
        selectedTextAttributes = [.backgroundColor: ConsoleThemeNS.selection]
        linkTextAttributes = [.foregroundColor: ConsoleThemeNS.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        font = ConsoleThemeNS.font
        setAccessibilityRole(.textArea)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window || window.firstResponder == nil
                    || !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Grows the view to the text so the scroll view scrolls horizontally for wide tables.
    func sizeToFitContent() {
        guard let layout = layoutManager, let container = textContainer, let scroll = enclosingScrollView else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = max(scroll.contentSize.width, used.width + textContainerInset.width * 2 + 24)
        let height = max(scroll.contentSize.height, used.height + textContainerInset.height * 2)
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: width, height: height)) }
    }

    // MARK: Block cursor

    private var charWidth: CGFloat { ConsoleThemeNS.font.maximumAdvancement.width }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        r.size.width = charWidth
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = rect
        r.size.width += charWidth
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    // MARK: Editing is the model's

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { false }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        model?.edit { $0.insert(text) }
        refresh()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        model?.edit { $0.insert(text) }
        refresh()
    }

    override func cut(_ sender: Any?) {}

    override func insertNewline(_ sender: Any?) {
        model?.enter()
        refresh()
    }

    /// ⌥↩ / ⇧↩: a line break without running.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        model?.edit { $0.newline() }
        refresh()
    }

    override func insertLineBreak(_ sender: Any?) { insertNewlineIgnoringFieldEditor(sender) }

    override func insertTab(_ sender: Any?) {
        guard let model else { return }
        Task { @MainActor in
            await model.complete()
            self.refresh()
        }
    }

    override func insertBacktab(_ sender: Any?) {}

    override func deleteBackward(_ sender: Any?) { change { $0.backspace() } }
    override func deleteForward(_ sender: Any?) { change { $0.deleteForward() } }
    override func deleteWordBackward(_ sender: Any?) { change { $0.deleteWordBackward() } }
    override func deleteToBeginningOfLine(_ sender: Any?) { change { $0.killToStart() } }
    override func deleteToEndOfLine(_ sender: Any?) { change { $0.killToEnd() } }
    override func moveLeft(_ sender: Any?) { move { $0.moveLeft() } }
    override func moveRight(_ sender: Any?) { move { $0.moveRight() } }
    override func moveBackward(_ sender: Any?) { move { $0.moveLeft() } }
    override func moveForward(_ sender: Any?) { move { $0.moveRight() } }
    override func moveToBeginningOfLine(_ sender: Any?) { move { $0.moveToLineStart() } }
    override func moveToEndOfLine(_ sender: Any?) { move { $0.moveToLineEnd() } }
    override func moveToBeginningOfParagraph(_ sender: Any?) { move { $0.moveToLineStart() } }
    override func moveToEndOfParagraph(_ sender: Any?) { move { $0.moveToLineEnd() } }

    override func moveUp(_ sender: Any?) {
        model?.historyPrevious()
        refresh()
    }

    override func moveDown(_ sender: Any?) {
        model?.historyNext()
        refresh()
    }

    override func cancelOperation(_ sender: Any?) {}

    private func change(_ body: (inout ConsoleLineEditor) -> Void) {
        model?.edit(body)
        refresh()
    }

    private func move(_ body: (inout ConsoleLineEditor) -> Void) {
        model?.moveCaret(body)
        refresh()
    }

    /// The model is @Observable, but a keystroke should redraw immediately rather than at the next SwiftUI pass.
    private func refresh() {
        (delegate as? ConsoleTerminalView.Coordinator)?.render()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c": model?.interrupt(); refresh(); return
            case "l": model?.clearScreen(); refresh(); return
            case "a": move { $0.moveToLineStart() }; return
            case "e": move { $0.moveToLineEnd() }; return
            case "u": change { $0.killToStart() }; return
            case "k": change { $0.killToEnd() }; return
            case "w": change { $0.deleteWordBackward() }; return
            case "d": change { $0.deleteForward() }; return
            case "p": moveUp(nil); return
            case "n": moveDown(nil); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            model?.clearScreen()
            refresh()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            model?.openLastResultInGrid()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Clicking into the input moves the caret

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let model else { return }
        let location = selectedRange().location
        guard let index = liveLineStarts.lastIndex(where: { $0 <= location }) else { return }
        let column = max(0, location - liveLineStarts[index] - livePromptLengths[index])
        model.moveCaret { $0.moveTo(line: index, column: column) }
        refresh()
    }
}
