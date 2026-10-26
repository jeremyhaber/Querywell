import AppKit
import QuerywellCore
import SwiftUI

@main
struct QuerywellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        // The launcher is declared first so it is the window that opens at launch.
        Window("Connections", id: "launcher") {
            LauncherView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .task { await model.load() }
        }
        .defaultSize(width: 980, height: 660)
        .commands { AppCommands(model: model) }

        // The value is a workspace id, not a profile id: one profile can have two windows.
        WindowGroup("Connection", id: "connection", for: UUID.self) { $workspaceID in
            ConnectionWindowView(workspaceID: workspaceID)
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.load() }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs live inside connection windows (DECISIONS #24), never as NSWindow tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Close every live connection before quitting so no ssh process is left behind. Capped at
    /// about three seconds so a hung server can't block quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, !model.workspaces.isEmpty else { return .terminateNow }
        if let dirty = model.workspaces.values.first(where: \.hasUnsavedEdits), let detail = dirty.unsavedEditsDescription {
            let alert = NSAlert()
            alert.messageText = "You have unsaved edits"
            alert.informativeText = "\(detail) in “\(dirty.title)”. If you quit they are lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Review Changes")
            alert.addButton(withTitle: "Quit and Discard")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                dirty.bringToFront()
                dirty.reviewFirstUnsaved()
                return .terminateCancel
            }
            if response != .alertSecondButtonReturn { return .terminateCancel }
        }
        var replied = false
        let reply: @MainActor () -> Void = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await model.closeAllWorkspaces()
            reply()
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            reply()
        }
        return .terminateLater
    }
}

/// Menu bar commands. Window-specific ones act through the focused window's `WindowActions`.
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                model.wantsNewConnection = true
                openWindow(id: "launcher")
            }
            .keyboardShortcut("n")
        }

        CommandGroup(replacing: .saveItem) {
            Button(actions?.closeLabel ?? "Close Window") {
                if let actions {
                    actions.closeTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }

        CommandGroup(after: .importExport) {
            Button("Export Database…") { actions?.exportDatabase?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportDatabase == nil)
            Button("Import SQL…") { actions?.importSQL?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.importSQL == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Connections") { openWindow(id: "launcher") }
                .keyboardShortcut("0")
        }

        CommandMenu("Go") {
            Button("Quick Open…") { actions?.quickOpen() }
                .keyboardShortcut("k")
                .disabled(actions == nil)
        }

        CommandMenu("Database") {
            Button("Search & Replace…") { actions?.searchReplace?() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(actions?.searchReplace == nil)
        }

        CommandMenu("Tab") {
            Button("New Query") { actions?.newQuery?() }
                .keyboardShortcut("t")
                .disabled(actions?.newQuery == nil)
            Divider()
            Button("Next Tab") { actions?.nextTab?() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(actions?.nextTab == nil)
            Button("Previous Tab") { actions?.previousTab?() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(actions?.previousTab == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { actions?.selectTab?(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(actions?.selectTab == nil)
            }
        }

        #if DEBUG
        CommandMenu("Debug") {
            Button("Add Docker test connections") {
                Task { await model.addDockerTestConnections() }
            }
        }
        #endif
    }
}
