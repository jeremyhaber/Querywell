import Foundation
import QuerywellCore
import Testing
@testable import Querywell

@MainActor
private struct HealthHarness {
    let model: HealthTabModel
    let session: FakeSession
    let store: HealthStore
    let confirmations: TabHarness.Box<[ConfirmationRequest]>
    let profile: ConnectionProfile

    init(production: Bool = false, readOnly: Bool = false, answer: Bool = true) {
        var p = ConnectionProfile(name: "test", engine: .mysql, user: "u")
        p.readOnly = readOnly
        if production { p.colorTag = .production }
        profile = p
        let final = p
        let session = FakeSession()
        self.session = session
        store = HealthStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("qw-health-app-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("health.json"))
        let gate = WriteGate()
        gate.contextProvider = { db in GuardContext(profile: final, currentDatabase: db ?? "app") }
        gate.sessionProvider = { session }
        let seen = TabHarness.Box<[ConfirmationRequest]>([])
        gate.confirmationHandler = { request in seen.value.append(request); return answer }
        confirmations = seen
        let model = HealthTabModel(profile: p)
        model.sessionProvider = { session }
        model.gate = gate
        model.store = store
        self.model = model
    }

    func seedRevision() async throws -> SettingRevision {
        let r = SettingRevision(variable: "max_connections", oldValue: "151", newValue: "300", scope: .persist,
                                statements: ["SET PERSIST max_connections = 300"], outcome: .succeeded)
        try await store.append([r], for: profile.id)
        return r
    }
}

@MainActor
@Suite("Health tab model")
struct HealthTabModelTests {
    @Test func revertRunsThroughTheGateAndIsRecordedAsANewRevision() async throws {
        let h = HealthHarness(production: true)
        let original = try await h.seedRevision()
        await h.model.startIfNeeded()
        #expect(h.model.revisions.count == 1)

        await h.model.revert(original)

        // Production: the confirmation sheet saw the exact statement.
        #expect(h.confirmations.value.count == 1)
        #expect(h.confirmations.value[0].statements.map(\.text) == ["SET PERSIST max_connections = 151"])
        #expect(await h.session.executed.contains("SET PERSIST max_connections = 151"))
        let stored = await h.store.revisions(for: h.profile.id)
        #expect(stored.count == 2)
        #expect(stored[1].origin == .revert)
        #expect(stored[1].revertedRevisionID == original.id)
        #expect(stored[1].newValue == "151")
        #expect(h.model.banner?.isError == false)
    }

    @Test func aDeclinedConfirmationChangesNothing() async throws {
        let h = HealthHarness(production: true, answer: false)
        let original = try await h.seedRevision()
        await h.model.startIfNeeded()
        await h.model.revert(original)
        #expect(h.confirmations.value.count == 1)
        #expect(await h.session.executed.contains { $0.hasPrefix("SET") } == false)
        #expect(await h.store.revisions(for: h.profile.id).count == 1)
    }

    @Test func aReadOnlyConnectionIsBlockedBeforeAnythingRuns() async throws {
        let h = HealthHarness(readOnly: true)
        let original = try await h.seedRevision()
        await h.model.startIfNeeded()
        await h.model.revert(original)
        #expect(h.confirmations.value.isEmpty)
        #expect(await h.session.executed.contains { $0.hasPrefix("SET") } == false)
        #expect(await h.store.revisions(for: h.profile.id).count == 1)
        #expect(h.model.banner?.isError == true)
        #expect(h.model.banner?.text.contains("read-only") == true)
    }

    @Test func serverRAMIsValidatedAndStoredPerConnection() async throws {
        let h = HealthHarness()
        await h.model.startIfNeeded()
        h.model.ramText = "lots"
        await h.model.commitRAM()
        #expect(h.model.banner?.isError == true)
        h.model.ramText = "16"
        await h.model.commitRAM()
        #expect(h.model.inputs.serverRAMBytes == 16 * (1 << 30))
        #expect(await h.store.data(for: h.profile.id).serverRAMBytes == 16 * (1 << 30))
        h.model.ramText = ""
        await h.model.commitRAM()
        #expect(h.model.inputs.serverRAMBytes == nil)
    }
}
