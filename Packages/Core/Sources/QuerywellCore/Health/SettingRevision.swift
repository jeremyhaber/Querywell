import Foundation

/// Why a revision was made.
public enum RevisionOrigin: String, Sendable, Hashable, Codable {
    /// "Apply" on a Doctor recommendation.
    case doctor
    /// "Revert" on one revision.
    case revert
    /// "Revert all to before …".
    case revertAll
}

/// One change Querywell made to a server setting. Only changes made through the app are recorded.
public struct SettingRevision: Sendable, Hashable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Hashable, Codable { case succeeded, failed }

    public var id: UUID
    public var date: Date
    public var variable: String
    /// The value before the change; nil when it could not be read.
    public var oldValue: String?
    public var newValue: String
    public var scope: SettingScope
    /// The exact SQL that ran.
    public var statements: [String]
    public var outcome: Outcome
    public var errorMessage: String?
    public var origin: RevisionOrigin
    /// The revision this one undoes (for ``RevisionOrigin/revert`` / ``RevisionOrigin/revertAll``).
    public var revertedRevisionID: UUID?
    public var restartRequired: Bool
    /// PostgreSQL: the old value was the built-in default, so a revert can `RESET`.
    public var oldWasDefault: Bool
    /// Always "Querywell": a reminder in the file that this list is not the server's own audit trail.
    public var appliedFrom: String

    public init(id: UUID = UUID(), date: Date = Date(), variable: String, oldValue: String?, newValue: String,
                scope: SettingScope, statements: [String], outcome: Outcome, errorMessage: String? = nil,
                origin: RevisionOrigin = .doctor, revertedRevisionID: UUID? = nil, restartRequired: Bool = false,
                oldWasDefault: Bool = false) {
        self.id = id
        self.date = date
        self.variable = variable
        self.oldValue = oldValue
        self.newValue = newValue
        self.scope = scope
        self.statements = statements
        self.outcome = outcome
        self.errorMessage = errorMessage
        self.origin = origin
        self.revertedRevisionID = revertedRevisionID
        self.restartRequired = restartRequired
        self.oldWasDefault = oldWasDefault
        self.appliedFrom = "Querywell"
    }

    public var succeeded: Bool { outcome == .succeeded }

    private enum CodingKeys: String, CodingKey {
        case id, date, variable, oldValue, newValue, scope, statements, outcome, errorMessage, origin
        case revertedRevisionID, restartRequired, oldWasDefault, appliedFrom
    }

    /// Tolerant: fields added later default; unknown scope / origin values fall back instead of dropping the revision.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
        variable = try c.decode(String.self, forKey: .variable)
        oldValue = try c.decodeIfPresent(String.self, forKey: .oldValue)
        newValue = try c.decodeIfPresent(String.self, forKey: .newValue) ?? ""
        scope = (try? c.decodeIfPresent(SettingScope.self, forKey: .scope)) ?? .runtime
        statements = try c.decodeIfPresent([String].self, forKey: .statements) ?? []
        outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .failed
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        origin = (try? c.decodeIfPresent(RevisionOrigin.self, forKey: .origin)) ?? .doctor
        revertedRevisionID = try c.decodeIfPresent(UUID.self, forKey: .revertedRevisionID)
        restartRequired = try c.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
        oldWasDefault = try c.decodeIfPresent(Bool.self, forKey: .oldWasDefault) ?? false
        appliedFrom = try c.decodeIfPresent(String.self, forKey: .appliedFrom) ?? "Querywell"
    }
}

/// Comparing a setting's current value with what a revision recorded.
public enum SettingValueComparison {
    /// Equal after normalising case, quotes, ON/1 spellings, number formats and memory units.
    public static func equivalent(_ a: String, _ b: String) -> Bool {
        let x = normalise(a), y = normalise(b)
        if x == y { return true }
        if let nx = Double(x), let ny = Double(y) { return nx == ny }
        if let bx = ByteSize.parse(x), let by = ByteSize.parse(y), x.contains(where: \.isLetter) || y.contains(where: \.isLetter) { return bx == by }
        return false
    }

    static func normalise(_ value: String) -> String {
        var t = value.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("'") && t.hasSuffix("'")) || (t.hasPrefix("\"") && t.hasSuffix("\"")) { t = String(t.dropFirst().dropLast()) }
        switch t.lowercased() {
        case "on", "true", "yes": return "1"
        case "off", "false", "no": return "0"
        default: break
        }
        // sql_mode and similar lists compare as sets.
        if t.contains(",") { return t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.sorted().joined(separator: ",") }
        return t.lowercased()
    }
}

/// A setting whose live value no longer matches what the last revision set: someone changed it outside Querywell.
public struct SettingDrift: Sendable, Hashable, Identifiable {
    public var id: String { variable }
    public var variable: String
    public var recordedValue: String
    public var currentValue: String?
    public var revisionID: UUID
    public var revisionDate: Date
}

public enum DriftChecker {
    /// For each variable, compares the live value with the `newValue` of its latest successful revision.
    /// `revisions` are in chronological order (the store's order; timestamps are only second-precise on disk).
    public static func drift(revisions: [SettingRevision], current: [String: String]) -> [SettingDrift] {
        var latest: [String: SettingRevision] = [:]
        for revision in revisions where revision.succeeded {
            latest[revision.variable.lowercased()] = revision
        }
        return latest.values.compactMap { revision -> SettingDrift? in
            let live = current[revision.variable.lowercased()]
            // A restart-required change is not live yet; not drift.
            if revision.restartRequired, let live, revision.oldValue.map({ SettingValueComparison.equivalent($0, live) }) == true { return nil }
            if revision.scope == .persistOnly { return nil }
            if let live, SettingValueComparison.equivalent(live, revision.newValue) { return nil }
            return SettingDrift(variable: revision.variable, recordedValue: revision.newValue, currentValue: live,
                                revisionID: revision.id, revisionDate: revision.date)
        }.sorted { $0.variable < $1.variable }
    }
}

public enum RevertError: Error, Equatable, Sendable {
    case revisionFailed
    case oldValueUnknown
    case notFound
}

/// Builds the changes that undo recorded revisions.
public enum RevertPlanner {
    /// Undo one revision: set the variable back to the value it had before.
    public static func change(reverting revision: SettingRevision, current: [String: String], sources: [String: String] = [:],
                              engine: DatabaseEngine) throws -> SettingChange {
        guard revision.succeeded else { throw RevertError.revisionFailed }
        guard let old = revision.oldValue else { throw RevertError.oldValueUnknown }
        let key = revision.variable.lowercased()
        return SettingChange(variable: revision.variable, value: old, currentValue: current[key],
                             currentIsDefault: sources[key] == "default", scope: scopeForRevert(revision.scope, engine: engine),
                             restartRequired: revision.restartRequired, resetToDefault: engine == .postgresql && revision.oldWasDefault)
    }

    /// Undo `revision` and everything after it: every variable changed from then on goes back to its value
    /// from before its first change in that window. Variables already at that value are left out.
    /// Changes come back newest-first so the reverts mirror the history. `revisions` are chronological.
    public static func changes(revertingFrom revision: SettingRevision, in revisions: [SettingRevision], current: [String: String],
                               sources: [String: String] = [:], engine: DatabaseEngine) throws -> [SettingChange] {
        guard let start = revisions.firstIndex(where: { $0.id == revision.id }) else { throw RevertError.notFound }
        let window = revisions[start...].filter(\.succeeded)
        var firstFor: [String: SettingRevision] = [:]
        var lastFor: [String: SettingRevision] = [:]
        var order: [String] = []
        for r in window {
            let key = r.variable.lowercased()
            if firstFor[key] == nil { firstFor[key] = r; order.append(key) }
            lastFor[key] = r
        }
        var out: [SettingChange] = []
        for key in order.reversed() {
            guard let first = firstFor[key], let last = lastFor[key], let old = first.oldValue else { continue }
            if let live = current[key], SettingValueComparison.equivalent(live, old) { continue }
            out.append(SettingChange(variable: first.variable, value: old, currentValue: current[key],
                                     currentIsDefault: sources[key] == "default",
                                     scope: scopeForRevert(last.scope, engine: engine), restartRequired: last.restartRequired,
                                     resetToDefault: engine == .postgresql && first.oldWasDefault))
        }
        return out
    }

    private static func scopeForRevert(_ scope: SettingScope, engine: DatabaseEngine) -> SettingScope {
        switch engine {
        case .postgresql: .alterSystem
        case .mariadb: .runtime
        case .mysql: scope == .alterSystem ? .persist : scope
        }
    }
}
