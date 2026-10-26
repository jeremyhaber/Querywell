import AppKit
import QuerywellCore
import SwiftUI

// The query editor: our own TextKit 2 NSTextView (DECISIONS #34) using Core's SQLHighlighter and
// SQLCompletion. The model talks to it through `SQLEditorController`; the view reports edits,
// selection changes and completion requests back through the controller's closures.

/// An error to underline in the editor (failing statement).
struct EditorDiagnostic: Equatable {
    var range: NSRange
    var message: String
}

struct SQLEditorSettings: Equatable {
    var fontSize: Double
    var showsLineNumbers: Bool
    var dialect: SQLDialect
}

/// Model-side handle on the editor view.
@MainActor
final class SQLEditorController {
    fileprivate(set) weak var textView: SQLEditorTextView?

    var onTextChange: (String) -> Void = { _ in }
    var onSelectionChange: (NSRange) -> Void = { _ in }
    /// Completion at (text, caret); nil or empty hides the popup.
    var completionProvider: ((String, Int) async -> CompletionResult?)?
    /// ⌘↵ pressed inside the editor while another responder swallowed the shortcut (never needed in practice).
    var onRunShortcut: (() -> Void)?

    var text: String { textView?.string ?? "" }
    var selectedRange: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    func focus() { textView?.window?.makeFirstResponder(textView) }

    /// Replaces the selection (or inserts at the caret). Undoable.
    func insert(_ string: String) { textView?.replaceSelection(with: string) }

    /// Replaces the whole text. Undoable.
    func replaceAll(_ string: String) { textView?.replaceAllText(with: string) }

    /// Inserts a snippet template (`$1`, `${2:default}`, `$0`); Tab then walks through its stops.
    func insertSnippet(_ template: String) { textView?.insertSnippet(template) }

    func setDiagnostics(_ diagnostics: [EditorDiagnostic]) { textView?.setDiagnostics(diagnostics) }

    func select(_ range: NSRange, scroll: Bool = true) {
        guard let tv = textView else { return }
        let length = (tv.string as NSString).length
        let r = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        tv.setSelectedRange(r)
        if scroll { tv.scrollRangeToVisible(r) }
    }

    func setText(_ string: String) { textView?.loadText(string) }
}

// MARK: - SwiftUI

struct SQLTextView: NSViewRepresentable {
    let controller: SQLEditorController
    var initialText: String
    var settings: SQLEditorSettings

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, textView) = SQLEditorTextView.make(controller: controller)
        controller.textView = textView
        textView.apply(settings)
        textView.loadText(initialText)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? SQLEditorTextView)?.apply(settings)
    }
}

// MARK: - Text view

final class SQLEditorTextView: NSTextView, NSViewToolTipOwner {
    fileprivate weak var controller: SQLEditorController?
    private(set) var highlighter = SQLHighlighter(dialect: SQLDialect(.mysql))
    private var settings = SQLEditorSettings(fontSize: 12, showsLineNumbers: true, dialect: SQLDialect(.mysql))
    private var ruler: LineNumberRuler?

    private let completionPanel = SQLCompletionPanelController()
    private var completionTask: Task<Void, Never>?

    private var pendingChange: (range: NSRange, replacement: String, removed: String)?
    private var diagnostics: [EditorDiagnostic] = []
    private var toolTipTags: [NSView.ToolTipTag] = []
    private var bracketPair: (NSRange, NSRange)?
    private var skipRanges: [Range<Int>]?
    private var snippet: SnippetSession?
    private var lineStartCache: [Int]?
    private var isLoading = false

    // MARK: Construction

    static func make(controller: SQLEditorController) -> (NSScrollView, SQLEditorTextView) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.textContainer = container

        let tv = SQLEditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        tv.controller = controller
        tv.configure()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = ThemeNS.background
        scroll.documentView = tv
        // The gutter and its divider must never paint outside the editor (e.g. up under the toolbar).
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true

        let ruler = LineNumberRuler(scrollView: scroll, textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.ruler = ruler
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            ruler, selector: #selector(LineNumberRuler.invalidate), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return (scroll, tv)
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = ThemeNS.background
        insertionPointColor = ThemeNS.accent
        textContainerInset = NSSize(width: 6, height: 10)
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = []
        setAccessibilityLabel("SQL editor")
        setAccessibilityRole(.textArea)
        completionPanel.model.onPick = { [weak self] item in self?.accept(item) }
    }

    func apply(_ new: SQLEditorSettings) {
        guard new != settings else { return }
        let fontChanged = new.fontSize != settings.fontSize
        let dialectChanged = new.dialect != settings.dialect
        settings = new
        if dialectChanged { highlighter = SQLHighlighter(dialect: new.dialect) }
        ruler?.update(fontSize: new.fontSize)
        enclosingScrollView?.rulersVisible = new.showsLineNumbers
        if fontChanged || dialectChanged { restyleAll() }
    }

    // MARK: Fonts and highlighting

    private var baseFont: NSFont { .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular) }
    private var keywordFont: NSFont { .monospacedSystemFont(ofSize: settings.fontSize, weight: .medium) }

    private var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = (settings.fontSize * 0.45).rounded()
        p.lineBreakMode = .byClipping
        return p
    }

    private func updateTypingAttributes() {
        typingAttributes = [.font: baseFont, .foregroundColor: ThemeNS.text, .paragraphStyle: paragraphStyle]
        defaultParagraphStyle = paragraphStyle
    }

    private func restyleAll() {
        updateTypingAttributes()
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.font: baseFont, .foregroundColor: ThemeNS.text, .paragraphStyle: paragraphStyle], range: all)
        storage.endEditing()
        highlight(0..<all.length)
        ruler?.needsDisplay = true
    }

    private func style(_ style: SQLHighlightStyle) -> (NSColor, NSFont)? {
        switch style {
        case .keyword: (ThemeNS.syntaxKeyword, keywordFont)
        case .function: (ThemeNS.syntaxFunction, baseFont)
        case .string: (ThemeNS.syntaxString, baseFont)
        case .number: (ThemeNS.syntaxNumber, baseFont)
        case .comment: (ThemeNS.syntaxComment, baseFont)
        case .variable: (ThemeNS.syntaxVariable, baseFont)
        case .quotedIdentifier: (ThemeNS.text, baseFont)
        case .identifier, .operator: nil
        }
    }

    /// Re-colours `range` (UTF-16, statement-aligned) from Core's highlighter.
    private func highlight(_ range: Range<Int>) {
        guard let storage = textStorage else { return }
        let text = storage.string
        let length = (text as NSString).length
        let lo = max(0, min(range.lowerBound, length)), hi = max(lo, min(range.upperBound, length))
        guard hi > lo else { return }
        let nsRange = NSRange(location: lo, length: hi - lo)
        storage.beginEditing()
        storage.addAttributes([.foregroundColor: ThemeNS.text, .font: baseFont], range: nsRange)
        for span in highlighter.highlight(text, in: lo..<hi) {
            guard let (color, font) = style(span.style) else { continue }
            storage.addAttributes([.foregroundColor: color, .font: font], range: span.nsRange)
        }
        storage.endEditing()
    }

    // MARK: Loading and replacing

    /// Sets the text without an undo step (initial text, restored tab).
    func loadText(_ string: String) {
        isLoading = true
        defer { isLoading = false }
        undoManager?.removeAllActions()
        setPlain(string)
        updateTypingAttributes()
        restyleAll()
        lineStartCache = nil
        skipRanges = nil
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        controller?.onTextChange(string)
    }

    private func setPlain(_ s: String) {
        textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [.font: baseFont, .foregroundColor: ThemeNS.text, .paragraphStyle: paragraphStyle]))
    }

    func replaceSelection(with string: String) {
        replace(range: selectedRange(), with: string, selecting: nil)
    }

    func replaceAllText(with string: String) {
        let full = NSRange(location: 0, length: (self.string as NSString).length)
        replace(range: full, with: string, selecting: NSRange(location: (string as NSString).length, length: 0))
    }

    /// Undoable programmatic edit.
    func replace(range: NSRange, with string: String, selecting: NSRange?) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        setSelectedRange(selecting ?? NSRange(location: range.location + (string as NSString).length, length: 0))
    }

    fileprivate func endSnippet() { snippet = nil }

    private func apply(_ edit: EditorTransforms.Edit) {
        replace(range: edit.range, with: edit.replacement, selecting: edit.selection)
    }

    // MARK: Change tracking

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok {
            let ns = string as NSString
            let safe = NSIntersectionRange(affectedCharRange, NSRange(location: 0, length: ns.length))
            pendingChange = (affectedCharRange, replacementString ?? "", ns.substring(with: safe))
        }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        lineStartCache = nil
        skipRanges = nil
        let text = string
        if let change = pendingChange {
            let location = change.range.location
            let edited = location..<(location + (change.replacement as NSString).length)
            let r = highlighter.rehighlightRange(in: text, edited: edited, removed: change.removed)
            highlight(r)
            snippet?.textDidChange(range: change.range, replacementLength: (change.replacement as NSString).length)
        } else {
            highlight(0..<(text as NSString).length)
        }
        let typed = pendingChange?.replacement
        pendingChange = nil
        if !diagnostics.isEmpty { setDiagnostics([]) }
        ruler?.needsDisplay = true
        needsDisplay = true
        if !isLoading { controller?.onTextChange(text) }

        if let typed, EditorTransforms.triggersCompletion(inserted: typed) {
            requestCompletion(force: false)
        } else if completionPanel.isVisible {
            requestCompletion(force: false)  // deletions and pastes refine or close the list
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        selectionDidChange()
    }

    private func selectionDidChange() {
        let sel = selectedRange()
        updateBracketMatch(caret: sel.location, hasSelection: sel.length > 0)
        needsDisplay = true
        if completionPanel.isVisible, let r = completionPanel.result, !(r.range.lowerBound...r.range.upperBound + 1).contains(sel.location) {
            hideCompletion()
        }
        if let snippet, !snippet.contains(sel) { self.snippet = nil }
        controller?.onSelectionChange(sel)
    }

    // MARK: Bracket matching

    private func updateBracketMatch(caret: Int, hasSelection: Bool) {
        guard !hasSelection else { bracketPair = nil; return }
        let text = string
        let ns = text as NSString
        guard caret <= ns.length else { bracketPair = nil; return }
        // Only lex when the caret touches a bracket.
        let touches = [caret - 1, caret].contains { i in
            i >= 0 && i < ns.length && "()[]{}".utf16.contains(ns.character(at: i))
        }
        guard touches else { bracketPair = nil; return }
        if skipRanges == nil {
            skipRanges = highlighter.highlight(text).filter { [.string, .comment, .quotedIdentifier].contains($0.style) }.map(\.range)
        }
        bracketPair = EditorTransforms.matchingBrackets(in: text, caret: caret, skipping: skipRanges ?? [])
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let tlm = textLayoutManager, let storage = textContentStorage else { return }
        let origin = textContainerOrigin
        let sel = selectedRange()
        if sel.length == 0, window?.firstResponder === self || window?.isKeyWindow != true,
           let range = textRange(for: NSRange(location: sel.location, length: 0), storage: storage),
           let fragment = tlm.textLayoutFragment(for: range.location) {
            let frame = fragment.layoutFragmentFrame
            let line = NSRect(x: 0, y: frame.minY + origin.y, width: bounds.width, height: frame.height)
            if line.intersects(rect) {
                ThemeNS.editorCurrentLine.setFill()
                line.fill()
            }
        }
        if let (a, b) = bracketPair {
            ThemeNS.editorBracketMatch.setFill()
            for r in [a, b] {
                for var seg in segmentRects(for: r) {
                    seg = seg.insetBy(dx: -0.5, dy: 1)
                    NSBezierPath(roundedRect: seg, xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !diagnostics.isEmpty else { return }
        ThemeNS.dangerText.setStroke()
        for d in diagnostics {
            for rect in segmentRects(for: d.range) where rect.intersects(dirtyRect) {
                let path = NSBezierPath()
                path.lineWidth = 1.2
                let y = rect.maxY - 1
                var x = rect.minX
                path.move(to: NSPoint(x: x, y: y))
                var up = true
                while x < rect.maxX {
                    x = min(x + 2, rect.maxX)
                    path.line(to: NSPoint(x: x, y: up ? y - 2 : y))
                    up.toggle()
                }
                path.stroke()
            }
        }
    }

    private func textRange(for range: NSRange, storage: NSTextContentStorage) -> NSTextRange? {
        guard let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Rects (in this view's coordinates) covering `range`, one per line segment.
    func segmentRects(for range: NSRange) -> [NSRect] {
        guard let tlm = textLayoutManager, let storage = textContentStorage, range.length > 0,
              let textRange = textRange(for: range, storage: storage) else { return [] }
        let origin = textContainerOrigin
        var out: [NSRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            out.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return out
    }

    // MARK: Diagnostics

    func setDiagnostics(_ new: [EditorDiagnostic]) {
        guard new != diagnostics else { return }
        diagnostics = new
        for tag in toolTipTags { removeToolTip(tag) }
        toolTipTags = []
        layoutSubtreeIfNeeded()
        for (i, d) in new.enumerated() {
            for rect in segmentRects(for: d.range) {
                toolTipTags.append(addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)))
            }
        }
        needsDisplay = true
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        return diagnostics.indices.contains(index) ? diagnostics[index].message : ""
    }

    // MARK: Line numbers

    var lineStarts: [Int] {
        if let cache = lineStartCache { return cache }
        let ns = string as NSString
        var starts = [0]
        for i in 0..<ns.length where ns.character(at: i) == 10 { starts.append(i + 1) }
        lineStartCache = starts
        return starts
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if completionPanel.isVisible, handleCompletionKey(event) { return }
        // ⌃Space forces the popup.
        if event.keyCode == 49, event.modifierFlags.intersection([.control, .command, .option]) == .control {
            requestCompletion(force: true)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "/", window?.firstResponder === self {
            apply(EditorTransforms.toggleComment(in: string, selection: selectedRange()))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        hideCompletion()
        snippet = nil
        let sel = selectedRange()
        let indent = EditorTransforms.newlineIndent(in: string, caret: sel.location)
        replace(range: sel, with: "\n" + indent, selecting: nil)
    }

    override func insertTab(_ sender: Any?) {
        if snippet?.advance(in: self) == true { return }
        let sel = selectedRange()
        if EditorTransforms.isMultiline(string, selection: sel) {
            apply(EditorTransforms.indent(in: string, selection: sel))
        } else {
            replace(range: sel, with: EditorTransforms.indentUnit, selecting: nil)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        apply(EditorTransforms.outdent(in: string, selection: selectedRange()))
    }

    override func cancelOperation(_ sender: Any?) {
        if completionPanel.isVisible { hideCompletion(); return }
        if snippet != nil { snippet = nil; return }
        super.cancelOperation(sender)
    }

    override func resignFirstResponder() -> Bool {
        hideCompletion()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    // MARK: Completion

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        let model = completionPanel.model
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.move(1); return true  // down
        case 126: model.move(-1); return true  // up
        case 36, 76, 48:  // return, enter, tab
            if let item = model.current { accept(item) } else { hideCompletion() }
            return true
        case 53: hideCompletion(); return true  // escape
        default: return false
        }
    }

    func requestCompletion(force: Bool) {
        guard let provider = controller?.completionProvider else { return }
        completionTask?.cancel()
        let text = string
        let caret = selectedRange().location
        guard selectedRange().length == 0 else { hideCompletion(); return }
        completionTask = Task { @MainActor [weak self] in
            let result = await provider(text, caret)
            guard !Task.isCancelled, let self, self.string == text, self.selectedRange().location == caret else { return }
            guard let result, !result.items.isEmpty, result.context != .suppressed else { self.hideCompletion(); return }
            // Auto-popups need a typed prefix or a dot; ⌃Space may list everything.
            if !force, result.range.isEmpty {
                let ns = text as NSString
                let prev = caret > 0 ? ns.character(at: caret - 1) : 0
                if prev != UInt16(ascii: ".") { self.hideCompletion(); return }
            }
            guard let window = self.window else { return }
            let anchor = self.firstRect(forCharacterRange: NSRange(location: result.range.lowerBound, length: 0), actualRange: nil)
            self.completionPanel.show(result, anchor: anchor, in: window)
        }
    }

    func hideCompletion() {
        completionTask?.cancel()
        completionPanel.hide()
    }

    private func accept(_ item: CompletionItem) {
        guard let result = completionPanel.result else { return }
        hideCompletion()
        let range = NSRange(location: result.range.lowerBound, length: result.range.count)
        replace(range: range, with: item.insertText, selecting: nil)
    }

    // MARK: Snippets

    func insertSnippet(_ template: String) {
        let parsed = SnippetTemplate.parse(template)
        let sel = selectedRange()
        replace(range: sel, with: parsed.text, selecting: nil)
        snippet = nil
        guard !parsed.stops.isEmpty else { return }
        let session = SnippetSession(template: parsed, base: sel.location)
        snippet = session
        _ = session.advance(in: self)
    }
}

// MARK: - Snippet tab stops

@MainActor
final class SnippetSession {
    private struct Stop {
        var index: Int
        var ranges: [NSRange]
    }
    private var stops: [Stop]
    private var current = -1

    init(template: SnippetTemplate, base: Int) {
        stops = template.stops.map { stop in
            Stop(index: stop.index, ranges: stop.ranges.map { NSRange(location: base + $0.lowerBound, length: $0.count) })
        }
    }

    /// Selects the next stop; false (and ends the session) after the last one.
    func advance(in tv: SQLEditorTextView) -> Bool {
        // Mirror what was typed in the stop we're leaving.
        if stops.indices.contains(current), stops[current].ranges.count > 1 {
            let ns = tv.string as NSString
            let first = stops[current].ranges[0]
            if NSMaxRange(first) <= ns.length {
                let typed = ns.substring(with: first)
                for i in stride(from: stops[current].ranges.count - 1, to: 0, by: -1) {
                    let r = stops[current].ranges[i]
                    guard NSMaxRange(r) <= (tv.string as NSString).length else { continue }
                    tv.replace(range: r, with: typed, selecting: nil)
                }
            }
        }
        current += 1
        guard stops.indices.contains(current) else {
            tv.endSnippet()
            return false
        }
        tv.setSelectedRange(stops[current].ranges[0])
        if current == stops.count - 1 { tv.endSnippet() }
        return true
    }

    func contains(_ sel: NSRange) -> Bool {
        let all = stops.flatMap(\.ranges)
        guard let lo = all.map(\.location).min(), let hi = all.map({ NSMaxRange($0) }).max() else { return false }
        return sel.location >= lo - 1 && NSMaxRange(sel) <= hi + 1
    }

    /// Keeps the remembered ranges aligned with edits.
    func textDidChange(range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length
        for s in stops.indices {
            for r in stops[s].ranges.indices {
                var x = stops[s].ranges[r]
                if range.location >= NSMaxRange(x) {
                    continue
                } else if NSMaxRange(range) <= x.location {
                    x.location += delta
                } else {
                    x.length = max(0, x.length + delta)
                }
                stops[s].ranges[r] = x
            }
        }
    }
}

// MARK: - Line number ruler

final class LineNumberRuler: NSRulerView {
    private weak var textView: SQLEditorTextView?
    private var fontSize: CGFloat = 12

    init(scrollView: NSScrollView, textView: SQLEditorTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(fontSize: Double) {
        self.fontSize = CGFloat(fontSize)
        needsDisplay = true
    }

    @objc func invalidate() { needsDisplay = true }

    override var isOpaque: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Paint only inside the ruler's own bounds.
        NSBezierPath(rect: bounds).setClip()
        ThemeNS.sidebar.setFill()
        bounds.fill()
        ThemeNS.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let tv = textView, let tlm = tv.textLayoutManager, let storage = tv.textContentStorage else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, fontSize - 1), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ThemeNS.editorLineNumber]
        let starts = tv.lineStarts
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin

        let digits = max(2, String(starts.count).count)
        let wanted = CGFloat(digits) * (font.maximumAdvancement.width) + 22
        if abs(ruleThickness - max(44, wanted)) > 0.5 { ruleThickness = max(44, wanted) }

        let startPoint = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let first = tlm.textLayoutFragment(for: startPoint)?.rangeInElement.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: first, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            guard let line = Self.lineIndex(of: offset, in: starts), starts[line] == offset else { return true }
            guard let lineFragment = fragment.textLineFragments.first else { return true }
            let baselineInView = frame.minY + origin.y + lineFragment.typographicBounds.minY + lineFragment.glyphOrigin.y
            let label = NSAttributedString(string: String(line + 1), attributes: attributes)
            let size = label.size()
            let local = self.convert(NSPoint(x: 0, y: baselineInView), from: tv)
            let y = self.isFlipped ? local.y - font.ascender : local.y + font.descender
            label.draw(at: NSPoint(x: self.bounds.maxX - 10 - size.width, y: y))
            return true
        }
    }

    private static func lineIndex(of offset: Int, in starts: [Int]) -> Int? {
        var lo = 0, hi = starts.count - 1
        guard hi >= 0 else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
