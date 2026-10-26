import SwiftUI

/// What the menu bar can ask of the active window. Each window publishes one through
/// `focusedSceneValue`; commands that need a window disable themselves when there is none.
struct WindowActions {
    enum Kind { case launcher, connection }

    var kind: Kind
    /// New query in this connection window; `nil` in the launcher.
    var newQuery: (() -> Void)?
    /// ⌘W: closes the selected tab, or the window when there is none.
    var closeTab: () -> Void
    /// Menu title for ⌘W: "Close Tab" or "Close Window".
    var closeLabel: String = "Close Window"
    var selectTab: ((Int) -> Void)?
    var nextTab: (() -> Void)?
    var previousTab: (() -> Void)?
    /// File ▸ Export Database… (⇧⌘E); `nil` when not connected.
    var exportDatabase: (() -> Void)?
    /// File ▸ Import SQL… (⇧⌘I); `nil` when not connected or read-only.
    var importSQL: (() -> Void)?
    var quickOpen: () -> Void
    /// Database ▸ Search & Replace… (⇧⌘H); nil while disconnected.
    var searchReplace: (() -> Void)?
    /// Database ▸ Health & Doctor…; nil while disconnected.
    var openHealth: (() -> Void)?
}

private struct WindowActionsKey: FocusedValueKey {
    typealias Value = WindowActions
}

extension FocusedValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}
