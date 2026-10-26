import Foundation

// Remembered table-selection rules for the export dialog, per connection.

/// Glob matching for table names: `*` and `?`, case-insensitive. A pattern without wildcards matches as a
/// substring when `substringIfPlain` (the filter field) and exactly otherwise (saved rules).
public enum GlobPattern {
    public static func matches(_ pattern: String, _ name: String, substringIfPlain: Bool = false) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        if !p.contains("*") && !p.contains("?") {
            return substringIfPlain ? (p.isEmpty || String(n).contains(String(p))) : p == n
        }
        // Iterative wildcard match with backtracking to the last `*`.
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] { pi += 1; ni += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ni; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ni = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

public struct ExportRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var pattern: String
    public var mode: TableExportMode

    public init(id: UUID = UUID(), pattern: String, mode: TableExportMode) {
        self.id = id
        self.pattern = pattern
        self.mode = mode
    }

    /// "Skip wp_wf*", "Structure only wp_*_log".
    public var label: String {
        let verb: String = switch mode {
        case .skip: "Skip"
        case .structureOnly: "Structure only"
        case .dataOnly: "Data only"
        case .both: "Include"
        }
        return "\(verb) \(pattern)"
    }
}

/// One connection's rules plus the explicit per-table choices of its last export.
public struct ExportSelectionConfig: Codable, Sendable, Equatable {
    public var rules: [ExportRule] = []
    public var overrides: [String: TableExportMode] = [:]

    public init(rules: [ExportRule] = [], overrides: [String: TableExportMode] = [:]) {
        self.rules = rules
        self.overrides = overrides
    }

    /// Mode per table (only non-default entries): rules in order, the last match wins, then the last export's
    /// explicit choices for tables that still exist.
    public func resolve(tableNames: [String]) -> [String: TableExportMode] {
        var out: [String: TableExportMode] = [:]
        for name in tableNames {
            var mode = TableExportMode.both
            for rule in rules where GlobPattern.matches(rule.pattern, name) { mode = rule.mode }
            if let o = overrides[name] { mode = o }
            if mode != .both { out[name] = mode }
        }
        return out
    }
}

private struct ExportRulesFile: Codable {
    var schemaVersion = 1
    var connections: [String: ExportSelectionConfig] = [:]
}

/// `export-rules.json` (0600, atomic) keyed by connection id. Mutations commit in memory only after the write succeeds.
public actor ExportRulesStore {
    private let fileURL: URL
    private var file: ExportRulesFile?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(appName: String = "Querywell") throws -> URL {
        try AppDirectories.applicationSupport(appName: appName).appendingPathComponent("export-rules.json", isDirectory: false)
    }

    public func config(for connectionID: UUID) throws -> ExportSelectionConfig {
        try load().connections[connectionID.uuidString] ?? ExportSelectionConfig()
    }

    public func save(_ config: ExportSelectionConfig, for connectionID: UUID) throws {
        var copy = try load()
        if config == ExportSelectionConfig() { copy.connections[connectionID.uuidString] = nil } else { copy.connections[connectionID.uuidString] = config }
        try write(copy)
    }

    /// Forgets a deleted connection's rules.
    public func purge(connectionID: UUID) throws {
        var copy = try load()
        guard copy.connections.removeValue(forKey: connectionID.uuidString) != nil else { return }
        try write(copy)
    }

    private func load() throws -> ExportRulesFile {
        if let file { return file }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            file = ExportRulesFile()
            return file!
        }
        let decoded = (try? JSONFileStore.makeDecoder().decode(ExportRulesFile.self, from: Data(contentsOf: fileURL))) ?? ExportRulesFile()
        file = decoded
        return decoded
    }

    private func write(_ new: ExportRulesFile) throws {
        try JSONFileStore.writeAtomically(try JSONFileStore.makeEncoder().encode(new), to: fileURL, permissions: 0o600)
        file = new
    }
}
