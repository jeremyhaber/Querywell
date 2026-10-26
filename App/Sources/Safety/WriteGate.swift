import AppKit
import Observation
import QuerywellCore
import SwiftUI

/// The single choke point for anything that writes (inline edits, truncate/drop, batch table
/// operations, and later the query editor). It classifies the SQL, evaluates `WriteGuard` with the
/// connection's profile and current database, and either lets the write through, shows the
/// confirmation sheet, or blocks it with the reason (read-only connection).
@MainActor @Observable
final class WriteGate {
    /// The connection's guard context for `database` (the schema the write targets, which is what a
    /// production user must type); nil while disconnected.
    @ObservationIgnored var contextProvider: @MainActor (_ database: String?) -> GuardContext? = { _ in nil }
    @ObservationIgnored var settingsProvider: @MainActor () -> AppSettings.Safety = { AppSettings.Safety() }
    @ObservationIgnored var sessionProvider: @MainActor () -> (any DatabaseSession)? = { nil }
    @ObservationIgnored var windowProvider: @MainActor () -> NSWindow? = { nil }
    /// Replaces the confirmation sheet (tests drive commits without UI).
    @ObservationIgnored var confirmationHandler: (@MainActor (ConfirmationRequest) async -> Bool)?

    /// What the last `authorize` decided, for tests and diagnostics.
    private(set) var lastDecision: GuardDecision?
    /// Set when a write was blocked by a read-only connection and no window could show the alert.
    private(set) var lastBlockedReason: String?

    init() {}

    /// The guard decision without any UI.
    func decision(for statements: [String], escalateToDestructive: Bool = false, database: String? = nil,
                  origin: WriteOrigin = .script) -> GuardDecision? {
        guard let context = contextProvider(database) else { return nil }
        return WriteGuard.evaluate(
            statements: statements, context: context, settings: settingsProvider(),
            escalateToDestructive: escalateToDestructive, origin: origin)
    }

    /// Returns true when the statements may run now.
    /// - Parameters:
    ///   - escalateToDestructive: treat every statement as destructive (typed name on production).
    ///   - database: the schema the statements target, for the typed confirmation.
    ///   - actionTitle: label of the confirm button ("Commit", "Run", "Drop").
    func authorize(
        statements: [String], escalateToDestructive: Bool = false, origin: WriteOrigin = .script,
        database: String? = nil, actionTitle: String = "Run"
    ) async -> Bool {
        guard let decision = decision(for: statements, escalateToDestructive: escalateToDestructive, database: database, origin: origin) else {
            return false
        }
        lastDecision = decision
        lastBlockedReason = nil
        switch decision {
        case .allow:
            return true
        case .blockedReadOnly(let reason):
            lastBlockedReason = reason
            await showBlocked(reason)
            return false
        case .confirm(let request):
            if let confirmationHandler { return await confirmationHandler(request) }
            return await presentSheet(request, actionTitle: actionTitle)
        }
    }

    // MARK: Presentation

    private func showBlocked(_ reason: String) async {
        guard let parent = Self.topSheet(of: windowProvider()) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This connection is read-only"
        alert.informativeText = reason + "\n\nTurn off “Read-only” in the connection's settings to allow changes."
        alert.addButton(withTitle: "OK")
        _ = await alert.beginSheetModal(for: parent)
    }

    private func presentSheet(_ request: ConfirmationRequest, actionTitle: String) async -> Bool {
        guard let parent = Self.topSheet(of: windowProvider()) else { return false }
        let session = sessionProvider()
        return await withCheckedContinuation { continuation in
            let box = SheetBox()
            let finish: @MainActor (Bool) -> Void = { ok in
                guard !box.finished else { return }
                box.finished = true
                if let sheet = box.window { parent.endSheet(sheet) }
                continuation.resume(returning: ok)
            }
            let view = WriteConfirmationSheet(request: request, session: session, actionTitle: actionTitle, onFinish: finish)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let sheet = NSWindow(contentViewController: host)
            sheet.styleMask = [.titled]
            box.window = sheet
            parent.beginSheet(sheet)
        }
    }

    private final class SheetBox {
        var window: NSWindow?
        var finished = false
    }

    /// The window a new sheet should hang from: the deepest sheet already attached, else `window`.
    static func topSheet(of window: NSWindow?) -> NSWindow? {
        var current = window
        while let sheet = current?.attachedSheet { current = sheet }
        return current
    }
}

/// Plain-English wording for the confirmation sheet, kept out of the view so it can be tested.
enum ConfirmationCopy {
    static func reasons(for request: ConfirmationRequest) -> [String] {
        var out: [String] = []
        for reason in request.reasons {
            switch reason {
            case .productionWrite:
                out.append("This is a production database. Changes here affect real data.")
            case .unfilteredMutation(let index):
                let which = request.statements.count > 1 ? "Statement \(index + 1) has" : "This statement has"
                out.append("\(which) no WHERE clause, so it applies to every row in the table.")
            case .destructiveOnProduction:
                out.append("This removes or overwrites data and can't be undone from Querywell.")
            case .escalated:
                out.append(request.statements.count > 1
                    ? "This changes \(request.statements.count) objects in one go; each change can lock tables and can't be rolled back together."
                    : "This is a structural change that can lock the table and can't be rolled back.")
            }
        }
        // De-duplicate while keeping order.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func impact(_ result: DryRunResult) -> String {
        if let count = result.count {
            return "Affects ~\(CompactCount.grouped(count)) row\(count == 1 ? "" : "s")"
        }
        if let error = result.error { return "Couldn't count: \(error)" }
        return result.plan.explanation
    }

    static func isDestructive(_ request: ConfirmationRequest) -> Bool {
        request.reasons.contains(.destructiveOnProduction) || request.statements.contains { $0.isDestructive }
    }
}
