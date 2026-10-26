import Foundation
import Observation
import QuerywellCore
import SwiftUI

/// State of the connection editor sheet: the draft, tag helpers and the Test Connection run.
@MainActor @Observable
final class ConnectionEditorModel {
    enum TagChoice: Hashable {
        case none, production, staging, local, custom
    }

    enum TestState {
        case idle
        /// `nil` until the first stage is reported.
        case running(ConnectionStage?)
        case finished(ConnectionTestReport)
    }

    var draft: ConnectionDraft
    let original: ConnectionDraft
    let isNew: Bool
    private(set) var test: TestState = .idle
    var customTagName: String
    var customTagColor: Color
    /// New Production connections start read-only when this is set (Settings ▸ Safety).
    var defaultReadOnlyForProduction = false

    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(draft: ConnectionDraft, isNew: Bool) {
        self.draft = draft
        self.original = draft
        self.isNew = isNew
        if case .custom(let name, let hex)? = draft.colorTag {
            customTagName = name
            customTagColor = Color(hex: hex) ?? .purple
        } else {
            customTagName = "Custom"
            customTagColor = .purple
        }
    }

    var isDirty: Bool { draft != original }
    var issues: [ValidationIssue] { draft.validate() }
    var isValid: Bool { issues.isEmpty }
    var isProduction: Bool { draft.colorTag?.isProduction ?? false }

    // MARK: Tag

    var tagChoice: TagChoice {
        switch draft.colorTag {
        case nil: .none
        case .production?: .production
        case .staging?: .staging
        case .local?: .local
        case .custom?: .custom
        }
    }

    func setTagChoice(_ choice: TagChoice) {
        let wasProduction = isProduction
        switch choice {
        case .none: draft.colorTag = nil
        case .production: draft.colorTag = .production
        case .staging: draft.colorTag = .staging
        case .local: draft.colorTag = .local
        case .custom: draft.colorTag = .custom(name: customTagName, hex: customTagColor.hexString)
        }
        if isNew, !wasProduction, isProduction {
            draft.readOnly = defaultReadOnlyForProduction
        }
    }

    func customTagChanged() {
        guard tagChoice == .custom else { return }
        draft.colorTag = .custom(name: customTagName, hex: customTagColor.hexString)
    }

    // MARK: Test connection

    var isTesting: Bool {
        if case .running = test { return true }
        return false
    }

    func runTest(using tester: ConnectionTester) {
        guard !isTesting, let profile = try? draft.makeProfile() else { return }
        let secrets = draft.testSecrets
        test = .running(nil)
        testTask = Task {
            let report = await tester.test(profile, secrets: secrets) { [weak self] stage in
                Task { @MainActor in self?.report(stage) }
            }
            guard !Task.isCancelled else { return }
            test = .finished(report)
        }
    }

    private func report(_ stage: ConnectionStage) {
        if case .running = test { test = .running(stage) }
    }

    /// Cancels a running test (sheet dismissed) or drops a stale result (draft edited).
    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        test = .idle
    }
}
