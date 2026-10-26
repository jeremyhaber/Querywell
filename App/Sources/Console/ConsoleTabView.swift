import QuerywellCore
import SwiftUI

/// The SQL console tab (design: Console.dc.html): a terminal-like scrollback with a `mysql>` prompt, a header
/// with the connection, the console/terminal switch and the current database, and a footer with key hints.
struct ConsoleTabView: View {
    let model: ConsoleTabModel
    let workspace: ConnectionWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeader(
                profile: workspace.profile, statusText: model.statusText,
                mode: .sql, canUseTerminal: workspace.profile.ssh != nil,
                onSwitchToTerminal: { workspace.openTerminal() },
                onClear: { model.clearScreen() })
            ConsoleTerminalView(model: model, stamp: stamp)
            ConsoleFooter(trailing: tunnelText)
        }
        .background(ConsoleTheme.background)
        .task { await model.startIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SQL console")
    }

    private var stamp: Int {
        var h = Hasher()
        h.combine(model.scrollback.count)
        h.combine(model.clearCount)
        h.combine(model.editor)
        h.combine(model.isRunning)
        h.combine(model.continuation)
        h.combine(model.currentDatabase)
        return h.finalize()
    }

    private var tunnelText: String? {
        guard let ssh = workspace.profile.ssh else { return nil }
        let latency = workspace.latency.map { " · \(LatencyFormatter.string(for: $0))" } ?? ""
        return "Tunnel via \(ssh.host):\(ssh.port)\(latency)"
    }
}

enum ConsoleMode { case sql, terminal }

/// Header strip shared by the console and the terminal tab: PROD badge, name, mode switch, status, action.
struct ConsoleHeader: View {
    let profile: ConnectionProfile
    let statusText: String
    let mode: ConsoleMode
    let canUseTerminal: Bool
    var onSwitchToTerminal: () -> Void = {}
    var onSwitchToConsole: () -> Void = {}
    var actionTitle: String = "Clear"
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if profile.isProduction { ProdBadge() }
            Text(profile.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ConsoleTheme.text)
                .lineLimit(1)
            modeSwitch
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(ConsoleTheme.secondary)
                .lineLimit(1)
            Button(action: onClear) {
                Text(actionTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(ConsoleTheme.text)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(ConsoleTheme.buttonBorder))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionTitle)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(ConsoleTheme.chrome)
        .overlay(alignment: .bottom) { ConsoleTheme.border.frame(height: 1) }
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment("SQL console", selected: mode == .sql, enabled: true) { onSwitchToConsole() }
            segment("SSH terminal", selected: mode == .terminal, enabled: canUseTerminal) { onSwitchToTerminal() }
                .help(canUseTerminal ? "Open an SSH terminal on the server" : "This connection doesn't use SSH, so there is no server to open a terminal on.")
        }
        .padding(2)
        .background(ConsoleTheme.segmentTrack, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Console mode")
    }

    private func segment(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? ConsoleTheme.segmentSelectedText : ConsoleTheme.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selected ? ConsoleTheme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ConsoleFooter: View {
    var hints: [String] = ["↑↓ history", "Tab autocomplete", "⇧⌘G open result in grid"]
    var trailing: String?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.self) { Text($0) }
            Spacer(minLength: 8)
            if let trailing { Text(trailing) }
        }
        .font(.system(size: 12))
        .foregroundStyle(ConsoleTheme.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(ConsoleTheme.chrome)
        .overlay(alignment: .top) { ConsoleTheme.border.frame(height: 1) }
    }
}
