import AppKit
import Foundation
import Observation
import QuerywellCore

/// Everything one connection window owns: the live connection, its lifecycle state, the tabs and
/// the database list. Closing the window closes the workspace, which closes the connection (and
/// any ssh process behind it).
@MainActor @Observable
final class ConnectionWorkspace: Identifiable {
    enum State: Equatable {
        /// Not connected: before the first attempt, or after Disconnect.
        case idle
        case connecting(ConnectionStage)
        case connected(ServerInfo, latency: Duration?)
        case failed(ConnectionOpenError)
    }

    let id = UUID()
    let openedAt = Date()
    private(set) var profile: ConnectionProfile
    private(set) var state: State = .idle
    var tabs = WorkspaceTabs()
    private(set) var databases: [String] = []
    var selectedDatabase: String?

    @ObservationIgnored private(set) var live: LiveConnection?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let opener: ConnectionOpener
    @ObservationIgnored private let keepaliveInterval: Duration
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private(set) var isClosed = false

    init(profile: ConnectionProfile, opener: ConnectionOpener, keepaliveInterval: Duration = .seconds(60)) {
        self.profile = profile
        self.opener = opener
        self.keepaliveInterval = keepaliveInterval
    }

    // MARK: Derived

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var serverInfo: ServerInfo? {
        if case .connected(let info, _) = state { return info }
        return nil
    }

    var latencyMilliseconds: Int? {
        if case .connected(_, let latency) = state { return latency?.wholeMilliseconds }
        return nil
    }

    var summary: ConnectionSummary { ConnectionSummary(profile: profile, serverInfo: serverInfo) }

    /// Window title text: name and, once connected, nothing else (the toolbar shows the rest).
    var title: String { profile.name }

    // MARK: Lifecycle

    /// Replaces the profile used for the next (re)connect. A live connection is not touched.
    func updateProfile(_ new: ConnectionProfile) {
        profile = new
    }

    /// Connects the first time the window appears; later appearances don't undo a Disconnect.
    func startIfNeeded() async {
        guard !hasStarted else { return }
        await connect()
    }

    func connect() async {
        guard !isClosed else { return }
        switch state {
        case .connecting, .connected: return
        case .idle, .failed: break
        }
        hasStarted = true
        state = .connecting(.validating)
        do {
            let live = try await opener.open(profile) { [weak self] stage in
                Task { @MainActor in self?.report(stage) }
            }
            guard !isClosed else {
                await live.close()
                return
            }
            self.live = live
            let latency = await measureLatency(live)
            // The window may have been closed (or the user disconnected) while we pinged.
            guard !isClosed, self.live === live else { return }
            state = .connected(live.session.serverInfo, latency: latency)
            startKeepalive(live)
            await loadDatabases(live)
        } catch let error as ConnectionOpenError {
            if !isClosed { state = .failed(error) }
        } catch {
            if !isClosed { state = .failed(.database(.connectionFailed(error.localizedDescription))) }
        }
    }

    private func report(_ stage: ConnectionStage) {
        if case .connecting = state { state = .connecting(stage) }
    }

    func reconnect() async {
        await teardown()
        state = .idle
        await connect()
    }

    /// Closes the connection but keeps the window and tabs.
    func disconnect() async {
        await teardown()
        state = .idle
    }

    /// Final: the window is going away.
    func close() async {
        isClosed = true
        await teardown()
        state = .idle
    }

    private func teardown() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        databases = []
        selectedDatabase = nil
        let live = self.live
        self.live = nil
        await live?.close()
    }

    // MARK: Health

    private func measureLatency(_ live: LiveConnection) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await live.session.execute("SELECT 1")
            return start.duration(to: clock.now)
        } catch {
            return nil
        }
    }

    private func startKeepalive(_ live: LiveConnection) {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.ping(live)
            }
        }
    }

    private func ping(_ live: LiveConnection) async {
        guard self.live === live, case .connected(let info, _) = state else { return }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await live.session.execute("SELECT 1")
            guard self.live === live, case .connected = state else { return }
            state = .connected(info, latency: start.duration(to: clock.now))
        } catch {
            guard self.live === live else { return }
            let detail: String
            if let db = error as? DatabaseError {
                detail = ConnectionOpenError.database(db).message
            } else {
                detail = error.localizedDescription
            }
            keepaliveTask?.cancel()
            keepaliveTask = nil
            self.live = nil
            state = .failed(.database(.connectionFailed("The connection was lost. \(detail)")))
            await live.close()
        }
    }

    private func loadDatabases(_ live: LiveConnection) async {
        do {
            let names = try await live.session.listDatabases()
            guard self.live === live else { return }
            databases = names
            let current = (try? await live.session.currentDatabase()) ?? nil
            selectedDatabase = [profile.defaultDatabase, current].compactMap { $0 }.first(where: names.contains) ?? names.first
        } catch {
            databases = []
        }
    }

    // MARK: Tabs

    func newQuery() { tabs.newQuery() }
    func openConsole() { tabs.openConsole() }
    func openTerminal() { tabs.openTerminal() }

    /// Closes the selected tab; returns `false` when there was none.
    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let id = tabs.selectedID else { return false }
        tabs.close(id: id)
        return true
    }

    /// ⌘1…⌘9: selects the tab at `index` (0-based) if it exists.
    func selectTab(at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        tabs.select(id: tabs.tabs[index].id)
    }

    // MARK: Window

    func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
