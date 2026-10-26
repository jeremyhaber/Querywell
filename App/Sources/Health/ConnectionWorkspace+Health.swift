import Foundation
import QuerywellCore

// Database Health & Doctor tab for a connection window.

extension ConnectionWorkspace {
    func openHealth() { tabs.openHealth() }

    /// The model behind the health tab, created on first use.
    func healthModel(forTab tab: WorkspaceTab) -> HealthTabModel? {
        guard case .health = tab.kind else { return nil }
        if let existing = tools.healthModels[tab.id] { return existing }
        let model = HealthTabModel(profile: profile)
        model.sessionProvider = { [weak self] in self?.live?.session }
        model.gate = gate
        model.store = queryServices.health
        tools.healthModels[tab.id] = model
        return model
    }
}
