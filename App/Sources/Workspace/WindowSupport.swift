import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to `onWindow` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AccessorView)?.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let callback = onWindow
            // Defer so SwiftUI has finished installing its own delegate. Weak: the window may be
            // gone by the time this runs.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                callback?(window)
            }
        }
    }
}

/// Sits in front of SwiftUI's window delegate to (1) ask before closing a connected window and
/// (2) tell the model when the window is gone. Everything else is forwarded to the original delegate.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private let confirmation: () -> (title: String, detail: String)?
    private let didClose: () -> Void
    private var bypass = false

    init(
        original: (any NSWindowDelegate)?,
        confirmation: @escaping () -> (title: String, detail: String)?,
        didClose: @escaping () -> Void
    ) {
        self.original = original
        self.confirmation = confirmation
        self.didClose = didClose
    }

    /// Installs the guard on `window` unless one is already installed.
    static func install(
        on window: NSWindow,
        confirmation: @escaping () -> (title: String, detail: String)?,
        didClose: @escaping () -> Void
    ) {
        if window.delegate is WindowCloseGuard { return }
        let guardian = WindowCloseGuard(original: window.delegate, confirmation: confirmation, didClose: didClose)
        window.delegate = guardian
        // The window only holds its delegate weakly.
        objc_setAssociatedObject(window, &Self.associationKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           original.windowShouldClose?(sender) == false {
            return false
        }
        if bypass { return true }
        guard let prompt = confirmation() else { return true }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.bypass = true
                sender.performClose(nil)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        didClose()
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Catches middle-button clicks over its host view without disturbing normal clicks.
struct MiddleClickModifier: ViewModifier {
    var action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(MiddleClickCatcher(action: action))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the event when it is the middle button; everything else falls through.
            guard let event = NSApp.currentEvent, event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2 else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }
}

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        modifier(MiddleClickModifier(action: action))
    }
}
