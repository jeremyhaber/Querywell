import Foundation
import Observation
import QuerywellCore

/// The Phase 7 state of one connection window: console and terminal models per tab, and the export / import /
/// result-export sheets. Kept apart from `ConnectionWorkspace` so that file only gains one property.
@MainActor @Observable
final class WorkspaceTools {
    var exportSheet: ExportSheetModel?
    var importSheet: ImportSheetModel?
    var resultExport: ResultExportModel?
    /// A file is being dragged over the window (drop highlight).
    var isDropTargeted = false
    /// Console preferences, kept current by the window.
    var consoleSettings = AppSettings.Console()
    @ObservationIgnored var secretStore: (any SecretStore)?
    /// ssh client options for the terminal and remote exports (tests use a throw-away known_hosts).
    @ObservationIgnored var sshOptions = SSHClientOptions()
    @ObservationIgnored var consoleModels: [UUID: ConsoleTabModel] = [:]
    @ObservationIgnored var terminalModels: [UUID: TerminalTabModel] = [:]

    /// Drops the models of tabs that were closed (ending their ssh processes).
    func prune(openTabs: Set<UUID>) {
        for (id, model) in terminalModels where !openTabs.contains(id) {
            model.close()
            terminalModels[id] = nil
        }
        for id in consoleModels.keys where !openTabs.contains(id) { consoleModels[id] = nil }
    }

    /// The window is closing: end every terminal session.
    func shutdown() {
        for model in terminalModels.values { model.close() }
        terminalModels = [:]
        consoleModels = [:]
    }
}
