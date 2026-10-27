import AppKit
import SwiftUI

/// Multi-line plain-text input with a placeholder drawn by the text view itself, so the placeholder, the caret
/// and the first line of typed text always share one origin (the container inset plus line-fragment padding).
/// Transparent: callers supply the chrome. The vertical scroller only appears when the content overflows.
/// Callers must add `.accessibilityLabel(…)`.
struct PlaceholderTextEditor: NSViewRepresentable {
    /// Inner padding shared with the app's single-line inputs (8pt horizontal, 7pt vertical).
    static let inset = NSSize(width: 8, height: 7)

    @Binding var text: String
    var placeholder = ""
    var font: NSFont = .systemFont(ofSize: 12)
    /// Two-way focus; nil leaves focus entirely to AppKit.
    var isFocused: Binding<Bool>?
    /// Called for ⌘↵ instead of inserting a newline.
    var onCommandReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.insertionPointColor = ThemeNS.accent
        textView.textColor = ThemeNS.text
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: ThemeNS.text]
        textView.placeholder = placeholder
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.setAccessibilityPlaceholderValue(placeholder)
            textView.needsDisplay = true
        }
        // Act only when the binding changes, never on unrelated updates: re-asserting a stale value would
        // steal focus back from a click elsewhere (or drop it mid-typing) before the async focus sync lands.
        if let isFocused, let window = textView.window, isFocused.wrappedValue != context.coordinator.appliedFocus {
            context.coordinator.appliedFocus = isFocused.wrappedValue
            let isFirst = window.firstResponder === textView
            if isFocused.wrappedValue, !isFirst {
                DispatchQueue.main.async { window.makeFirstResponder(textView) }
            } else if !isFocused.wrappedValue, isFirst {
                DispatchQueue.main.async { window.makeFirstResponder(nil) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaceholderTextEditor
        /// The focus value last applied to or reported by AppKit.
        var appliedFocus: Bool?
        init(_ parent: PlaceholderTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }

        func focusChanged(_ focused: Bool) {
            appliedFocus = focused
            guard let binding = parent.isFocused, binding.wrappedValue != focused else { return }
            DispatchQueue.main.async { binding.wrappedValue = focused }
        }
    }
}

final class PlaceholderTextView: NSTextView {
    weak var coordinator: PlaceholderTextEditor.Coordinator?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        // Same origin the first line fragment uses, so it lines up with the caret and typed text.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        placeholder.draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: ThemeNS.textTertiary
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76,
           let handler = coordinator?.parent.onCommandReturn {
            handler()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        return ok
    }
}
