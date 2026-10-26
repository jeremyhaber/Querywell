import AppKit
import Observation
import QuerywellCore
import SwiftTerm

/// Bridges SwiftTerm's (non-isolated) delegate callbacks to the main-actor model.
private final class TerminalDelegateBridge: LocalProcessTerminalViewDelegate, @unchecked Sendable {
    // @unchecked Sendable: the closure is immutable after init and only hops to the main actor.
    private let onTerminated: @Sendable (Int32?) -> Void

    init(onTerminated: @escaping @Sendable (Int32?) -> Void) { self.onTerminated = onTerminated }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated(exitCode) }
}

/// SwiftTerm's local-process view, themed with the console colours (re-applied when the appearance changes).
final class QuerywellTerminalView: LocalProcessTerminalView {
    func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = ConsoleThemeNS.text
            nativeBackgroundColor = ConsoleThemeNS.background
            caretColor = ConsoleThemeNS.prompt
        }
        font = ConsoleThemeNS.font
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }
}

/// The SSH terminal tab: `/usr/bin/ssh -t user@host` in a pseudo-terminal. The view is owned by the model so the
/// session survives switching to another tab; closing the tab (or the window) ends the process and removes
/// the temporary askpass helper.
@MainActor @Observable
final class TerminalTabModel {
    enum State: Equatable {
        case notStarted
        case running
        case exited(Int32?)
        /// Can't start: the connection has no SSH settings, or ssh couldn't be launched.
        case unavailable(String)
    }

    @ObservationIgnored let profile: ConnectionProfile
    @ObservationIgnored var secretProvider: @MainActor () -> String? = { nil }
    @ObservationIgnored let terminalView = QuerywellTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    @ObservationIgnored private var askpass: SSHAskpass?
    @ObservationIgnored private var bridge: TerminalDelegateBridge?
    private(set) var state: State = .notStarted
    /// Bumped on every (re)start so SwiftUI refreshes.
    private(set) var generation = 0

    init(profile: ConnectionProfile) {
        self.profile = profile
        guard profile.ssh != nil else {
            state = .unavailable("This connection doesn't use SSH, so there is no server to open a terminal on.")
            return
        }
        let bridge = TerminalDelegateBridge { [weak self] code in
            Task { @MainActor in self?.processEnded(code) }
        }
        self.bridge = bridge
        terminalView.processDelegate = bridge
        terminalView.applyTheme()
    }

    var title: String {
        guard let ssh = profile.ssh else { return profile.name }
        return "\(ssh.user)@\(ssh.host)" + (ssh.port == 22 ? "" : ":\(ssh.port)")
    }

    /// The command line that would be run, with no secret in it (tests and the status line).
    var command: SSHTerminalCommand? {
        guard let ssh = profile.ssh else { return nil }
        return SSHTerminalCommand.make(for: ssh, hasSecret: secretProvider() != nil)
    }

    func startIfNeeded() {
        if case .notStarted = state { start() }
    }

    /// Starts (or restarts, after the session ended) the ssh process.
    func start() {
        guard let ssh = profile.ssh else { return }
        if case .running = state { return }
        cleanupAskpass()
        let secret = secretProvider().flatMap { $0.isEmpty ? nil : $0 }
        let command = SSHTerminalCommand.make(for: ssh, hasSecret: secret != nil)
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "SSH_AUTH_SOCK", "TMPDIR", "SHELL", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { env.append("\(key)=\(value)") }
        }
        if let secret, ssh.auth != .agent(socketPath: nil) {
            do {
                let helper = try SSHAskpass.create(secret: secret)
                askpass = helper
                for (key, value) in helper.environment { env.append("\(key)=\(value)") }
            } catch {
                state = .unavailable("Couldn't prepare the SSH password helper: \(error.localizedDescription)")
                return
            }
        }
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            state = .unavailable("The ssh client was not found at \(command.executable).")
            return
        }
        terminalView.getTerminal().resetToInitialState()
        terminalView.applyTheme()
        terminalView.startProcess(executable: command.executable, args: command.arguments, environment: env, execName: "ssh")
        generation += 1
        state = .running
    }

    func reconnect() {
        if case .running = state { return }
        start()
    }

    private func processEnded(_ code: Int32?) {
        guard case .running = state else { return }
        state = .exited(code)
        cleanupAskpass()
    }

    /// Ends the session and removes the temporary askpass files (tab or window closing).
    func close() {
        if case .running = state { terminalView.terminate() }
        cleanupAskpass()
        if case .running = state { state = .exited(nil) }
    }

    private func cleanupAskpass() {
        askpass?.cleanup()
        askpass = nil
    }

    var isRunning: Bool { if case .running = state { true } else { false } }
}
