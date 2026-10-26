import AppKit
import QuerywellCore
import SwiftTerm
import SwiftUI

/// The SSH terminal tab (design: Console.dc.html, "SSH terminal" mode).
struct TerminalTabView: View {
    let model: TerminalTabModel
    let workspace: ConnectionWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeader(
                profile: workspace.profile, statusText: model.title, mode: .terminal,
                canUseTerminal: workspace.profile.ssh != nil,
                onSwitchToConsole: { workspace.openConsole() },
                actionTitle: "Reconnect", onClear: { model.reconnect() })
            ZStack(alignment: .bottom) {
                if case .unavailable(let reason) = model.state {
                    TerminalUnavailableView(reason: reason, workspace: workspace)
                } else {
                    TerminalHost(view: model.terminalView, generation: model.generation)
                        .background(ConsoleTheme.background)
                    if case .exited(let code) = model.state { endedBanner(code) }
                }
            }
            ConsoleFooter(hints: ["⌘C copy", "⌘V paste", "Resizes with the window"], trailing: tunnelText)
        }
        .background(ConsoleTheme.background)
        .task {
            model.startIfNeeded()
            // Focus once SwiftUI has put the view in the window.
            try? await Task.sleep(for: .milliseconds(150))
            model.terminalView.window?.makeFirstResponder(model.terminalView)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSH terminal")
    }

    private var tunnelText: String? {
        workspace.profile.ssh.map { "ssh \($0.user)@\($0.host):\($0.port)" }
    }

    private func endedBanner(_ code: Int32?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(ConsoleTheme.muted).accessibilityHidden(true)
            Text(code.map { $0 == 0 ? "The SSH session ended." : "The SSH session ended (exit status \($0))." } ?? "The SSH session ended.")
                .font(.system(size: 13))
                .foregroundStyle(ConsoleTheme.text)
            Button("Reconnect") { model.reconnect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ConsoleTheme.chrome, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(ConsoleTheme.border))
        .padding(.bottom, 24)
    }
}

/// Hosts the model-owned SwiftTerm view.
private struct TerminalHost: NSViewRepresentable {
    let view: QuerywellTerminalView
    let generation: Int

    func makeNSView(context: Context) -> QuerywellTerminalView { view }
    func updateNSView(_ nsView: QuerywellTerminalView, context: Context) {}
}

/// Shown instead of the terminal when the connection has no SSH settings.
struct TerminalUnavailableView: View {
    let reason: String
    let workspace: ConnectionWorkspace
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 36))
                .foregroundStyle(ConsoleTheme.muted)
                .accessibilityHidden(true)
            Text("SSH terminal isn't available").font(.title3.weight(.semibold)).foregroundStyle(ConsoleTheme.text)
            Text(reason).foregroundStyle(ConsoleTheme.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Open SQL Console") { workspace.openConsole() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsoleTheme.background)
        .accessibilityElement(children: .combine)
    }
}
