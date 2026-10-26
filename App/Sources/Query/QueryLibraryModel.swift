import Foundation
import Observation
import QuerywellCore

/// Wording of history rows (design: `SELECT p.ID, p.post_title …` / `Now · 24 rows`).
enum HistoryRowFormat {
    /// First meaningful line of the SQL, with an ellipsis when there is more.
    static func title(_ sql: String) -> String {
        let lines = sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let code = lines.filter { !$0.hasPrefix("--") && !$0.hasPrefix("#") }
        guard let first = code.first ?? lines.first else { return "" }
        let more = code.count > 1 || (code.isEmpty ? lines.count > 1 : false)
        return more ? first + " …" : first
    }

    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if now.timeIntervalSince(date) < 60, date <= now.addingTimeInterval(5) { return "Now" }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "24 rows", "1 row changed", or the error text.
    static func outcome(_ entry: HistoryEntry) -> String {
        if let error = entry.error { return error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error }
        if let n = entry.rowCount { return n == 1 ? "1 row" : "\(n.formatted(.number.grouping(.automatic))) rows" }
        if let n = entry.affected { return n == 1 ? "1 row changed" : "\(n.formatted(.number.grouping(.automatic))) rows changed" }
        return ""
    }

    static func meta(_ entry: HistoryEntry, now: Date = Date(), calendar: Calendar = .current) -> String {
        let outcome = outcome(entry)
        let when = when(entry.lastRunAt, now: now, calendar: calendar)
        return outcome.isEmpty ? when : "\(when) · \(outcome)"
    }
}

/// Data behind the History / Saved / Snippets sidebar of query tabs.
@MainActor @Observable
final class QueryLibraryModel {
    enum Segment: String, CaseIterable, Identifiable {
        case schema = "Schema", history = "History", saved = "Saved", snippets = "Snippets"
        var id: String { rawValue }
    }

    let connectionID: UUID
    @ObservationIgnored let services: QueryServices

    var segment: Segment = .schema { didSet { if segment != oldValue { Task { await reload() } } } }
    var search = "" { didSet { if search != oldValue { scheduleReload() } } }

    private(set) var history: [HistoryEntry] = []
    private(set) var saved: [SavedQuery] = []
    private(set) var snippets: [Snippet] = []
    /// Every snippet visible to this connection (for the Quick queries menu), whatever the search says.
    private(set) var allSnippets: [Snippet] = []
    /// Every saved query visible to this connection (for the ⌘K switcher), whatever the search says.
    private(set) var allSaved: [SavedQuery] = []
    var savedSheet: SavedQueryDetailsRequest?
    var snippetSheet: SnippetSheetRequest?
    var error: String?
    @ObservationIgnored var onSavedChanged: @MainActor (SavedQuery) -> Void = { _ in }
    @ObservationIgnored var onSavedDeleted: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(connectionID: UUID, services: QueryServices) {
        self.connectionID = connectionID
        self.services = services
    }

    var historyStore: QueryHistoryStore { services.history(for: connectionID) }

    /// Saved queries of this connection, then the ones shared by all connections.
    var connectionSaved: [SavedQuery] { saved.filter { $0.connectionID != nil } }
    var globalSaved: [SavedQuery] { saved.filter { $0.connectionID == nil } }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func refreshAllSaved() async {
        allSaved = (try? await services.savedQueries.list(for: connectionID)) ?? []
        allSnippets = (try? await services.snippets.list(for: connectionID)) ?? []
    }

    func reload() async {
        await refreshAllSaved()
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch segment {
            case .schema:
                break  // the schema list reads the editor's catalog, not the stores
            case .history:
                history = try await historyStore.search(q, limit: 200)
            case .saved:
                let all = try await services.savedQueries.list(for: connectionID)
                saved = q.isEmpty ? all : Self.filter(all, query: q)
            case .snippets:
                snippets = try await services.snippets.search(q, for: connectionID, limit: 200)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func filter(_ queries: [SavedQuery], query: String) -> [SavedQuery] {
        FuzzyMatcher.rank(queries, query: query, key: { "\($0.name) \($0.tags.joined(separator: " ")) \($0.notes ?? "") \($0.sql.prefix(200))" },
                          limit: 200).map(\.0)
    }

    // MARK: History

    func deleteHistory(_ entry: HistoryEntry) async {
        try? await historyStore.delete(id: entry.id)
        await reload()
    }

    func clearHistory() async {
        await services.clearHistory(connectionID: connectionID)
        await reload()
    }

    // MARK: Saved

    func updateSaved(_ id: UUID, name: String, notes: String?, tags: [String], global: Bool) async {
        do {
            let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            let q = try await services.savedQueries.update(
                id: id, name: name, notes: .some((n?.isEmpty ?? true) ? nil : n), tags: tags,
                connectionID: .some(global ? nil : connectionID))
            onSavedChanged(q)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func setGlobal(_ query: SavedQuery, _ global: Bool) async {
        await updateSaved(query.id, name: query.name, notes: query.notes, tags: query.tags, global: global)
    }

    func duplicate(_ query: SavedQuery) async {
        do { _ = try await services.savedQueries.duplicate(id: query.id) } catch { self.error = error.localizedDescription }
        await reload()
    }

    func delete(_ query: SavedQuery) async {
        do {
            try await services.savedQueries.delete(id: query.id)
            onSavedDeleted(query.id)
        } catch { self.error = error.localizedDescription }
        await reload()
    }

    // MARK: Snippets

    func saveSnippet(existing: Snippet?, name: String, sql: String, tags: [String], global: Bool) async -> Bool {
        do {
            if let existing {
                _ = try await services.snippets.update(id: existing.id, name: name, sql: sql, tags: tags)
            } else {
                _ = try await services.snippets.add(name: name, sql: sql, tags: tags, connectionID: global ? nil : connectionID)
            }
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ snippet: Snippet) async {
        do { try await services.snippets.delete(id: snippet.id) } catch { self.error = error.localizedDescription }
        await reload()
    }
}

/// Request to show the "Edit details" sheet for a saved query.
struct SavedQueryDetailsRequest: Identifiable, Equatable {
    var id: UUID { query.id }
    var query: SavedQuery
}
