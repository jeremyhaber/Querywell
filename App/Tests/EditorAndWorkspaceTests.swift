import Foundation
import SwiftUI
import Testing
import QuerywellCore
@testable import Querywell

@MainActor
@Suite("Connection editor model")
struct ConnectionEditorModelTests {
    @Test("picking Production on a new draft applies the read-only default; editing does not")
    func productionReadOnlyDefault() {
        let model = ConnectionEditorModel(draft: ConnectionDraft(newFor: .mysql), isNew: true)
        model.defaultReadOnlyForProduction = true
        model.setTagChoice(.production)
        #expect(model.draft.readOnly)
        #expect(model.isProduction)

        model.draft.readOnly = false
        model.setTagChoice(.staging)
        model.setTagChoice(.production)
        #expect(model.draft.readOnly)  // re-picking Production on a new draft re-applies it

        let existing = ConnectionEditorModel(draft: ConnectionDraft(newFor: .mysql), isNew: false)
        existing.defaultReadOnlyForProduction = true
        existing.setTagChoice(.production)
        #expect(existing.draft.readOnly == false)
    }

    @Test("custom tags carry their name and colour")
    func customTag() {
        let model = ConnectionEditorModel(draft: ConnectionDraft(newFor: .postgresql), isNew: true)
        model.customTagName = "Client X"
        model.customTagColor = Color(hex: "#112233")!
        model.setTagChoice(.custom)
        #expect(model.draft.colorTag == .custom(name: "Client X", hex: "#112233"))
        model.customTagName = "Renamed"
        model.customTagChanged()
        #expect(model.draft.colorTag == .custom(name: "Renamed", hex: "#112233"))
        model.setTagChoice(.none)
        #expect(model.draft.colorTag == nil)
    }

    @Test("dirty and valid reflect the draft")
    func dirtyAndValid() {
        let model = ConnectionEditorModel(draft: ConnectionDraft(newFor: .mysql), isNew: true)
        #expect(!model.isDirty)
        #expect(!model.isValid)
        model.draft.name = "x"
        model.draft.user = "u"
        #expect(model.isDirty)
        #expect(model.isValid)
    }
}

@MainActor
@Suite("Workspace and helpers")
struct WorkspaceTests {
    @Test("a new workspace is idle with no tabs; tab helpers delegate to WorkspaceTabs")
    func tabs() {
        let opener = ConnectionOpener(secretStore: InMemorySecretStore())
        let workspace = ConnectionWorkspace(profile: ConnectionProfile(name: "x", engine: .mysql, user: "u"), opener: opener)
        #expect(workspace.state == .idle)
        #expect(!workspace.isConnected)
        #expect(workspace.closeSelectedTab() == false)
        workspace.newQuery()
        workspace.openConsole()
        #expect(workspace.tabs.titles == ["Query 1", "Console"])
        workspace.selectTab(at: 0)
        #expect(workspace.tabs.selectedTab?.title == "Query 1")
        workspace.selectTab(at: 9)
        #expect(workspace.tabs.selectedTab?.title == "Query 1")
        #expect(workspace.closeSelectedTab())
        #expect(workspace.tabs.titles == ["Console"])
    }

    @Test("an invalid profile fails to connect without touching the network")
    func invalidProfileFails() async {
        let opener = ConnectionOpener(secretStore: InMemorySecretStore())
        let workspace = ConnectionWorkspace(profile: ConnectionProfile(name: "", engine: .mysql, user: ""), opener: opener)
        await workspace.connect()
        guard case .failed(let error) = workspace.state else {
            Issue.record("expected failed, got \(workspace.state)")
            return
        }
        #expect(!error.message.isEmpty)
        await workspace.close()
        #expect(workspace.isClosed)
    }

    @Test("hex colours round-trip")
    func hex() {
        #expect(Color(hex: "#C4314B")?.hexString == "#C4314B")
        #expect(Color(hex: "nope") == nil)
        #expect(Duration.milliseconds(38).wholeMilliseconds == 38)
    }

    @Test("quick switcher bolds the matched characters")
    func highlight() throws {
        let match = try #require(FuzzyMatcher.score(query: "sw", candidate: "sunset-web01"))
        let text = QuickSwitcherView.highlightedTitle("sunset-web01", match: match)
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(text[$0.range].characters) }
        #expect(bold.joined() == "sw")
        #expect(String(text.characters) == "sunset-web01")
    }
}
