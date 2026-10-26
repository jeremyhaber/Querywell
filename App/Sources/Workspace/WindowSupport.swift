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
    private let unsavedEdits: () -> String?
    private let reviewUnsaved: () -> Void
    private let discardUnsaved: () -> Void
    private var bypass = false

    init(
        original: (any NSWindowDelegate)?,
        confirmation: @escaping () -> (title: String, detail: String)?,
        unsavedEdits: @escaping () -> String? = { nil },
        reviewUnsaved: @escaping () -> Void = {},
        discardUnsaved: @escaping () -> Void = {},
        didClose: @escaping () -> Void
    ) {
        self.original = original
        self.confirmation = confirmation
        self.unsavedEdits = unsavedEdits
        self.reviewUnsaved = reviewUnsaved
        self.discardUnsaved = discardUnsaved
        self.didClose = didClose
    }

    /// Installs the guard on `window` unless one is already installed.
    static func install(
        on window: NSWindow,
        confirmation: @escaping () -> (title: String, detail: String)?,
        unsavedEdits: @escaping () -> String? = { nil },
        reviewUnsaved: @escaping () -> Void = {},
        discardUnsaved: @escaping () -> Void = {},
        didClose: @escaping () -> Void
    ) {
        if window.delegate is WindowCloseGuard { return }
        let guardian = WindowCloseGuard(
            original: window.delegate, confirmation: confirmation, unsavedEdits: unsavedEdits,
            reviewUnsaved: reviewUnsaved, discardUnsaved: discardUnsaved, didClose: didClose)
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
        if let unsaved = unsavedEdits() {
            let alert = NSAlert()
            alert.messageText = "You have unsaved edits"
            alert.informativeText = "\(unsaved). If you close this window they are lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Review Changes")
            alert.addButton(withTitle: "Discard and Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: sender) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if response == .alertFirstButtonReturn {
                        self.reviewUnsaved()
                    } else if response == .alertSecondButtonReturn {
                        self.discardUnsaved()
                        self.bypass = true
                        sender.performClose(nil)
                    }
                }
            }
            return false
        }
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

/// Keeps a window's title hidden (the toolbar carries the identity) while `title` stays set for
/// the Window menu, Mission Control and VoiceOver. SwiftUI re-applies the title visibility when the
/// scene's title changes, so this observes the property and puts it back.
@MainActor
enum WindowTitleHider {
    nonisolated(unsafe) private static var key: UInt8 = 0

    static func install(on window: NSWindow) {
        window.titleVisibility = .hidden
        guard objc_getAssociatedObject(window, &key) == nil else { return }
        let observation = window.observe(\.titleVisibility, options: [.new]) { window, _ in
            DispatchQueue.main.async {
                if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            }
        }
        objc_setAssociatedObject(window, &key, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// Hides the title (see ``WindowTitleHider``) as soon as the view lands in a window.
struct HideWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HiderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated { WindowTitleHider.install(on: window) }
        }
    }
}

/// Removes the system title from the toolbar so it takes no space (and can't push items into
/// the overflow menu). macOS 15+ has API for it; on 14 the title is hidden on the NSWindow.
struct RemoveToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.background(HideWindowTitle())
        }
    }
}
