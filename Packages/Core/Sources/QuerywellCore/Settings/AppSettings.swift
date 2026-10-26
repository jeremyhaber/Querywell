import Foundation

/// AI provider choices for the assistant.
public enum AIProviderID: String, Codable, Sendable, Hashable, CaseIterable {
    case openai
    case anthropic
    case openrouter
}

/// What "open connection" does when the connection already has a window.
public enum OpenConnectionBehaviour: String, Codable, Sendable, Hashable, CaseIterable {
    case focusExisting
    case newWindow
}

/// User preferences, persisted as `settings.json`. Decoding is tolerant: missing sections,
/// missing fields and unknown enum values all fall back to defaults.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Highest schema version this build understands.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var general: General
    public var safety: Safety
    public var editor: Editor
    public var dataGrid: DataGrid
    public var ai: AI
    public var historyRetention: HistoryRetention
    public var console: Console

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        general: General = General(),
        safety: Safety = Safety(),
        editor: Editor = Editor(),
        dataGrid: DataGrid = DataGrid(),
        ai: AI = AI(),
        historyRetention: HistoryRetention = HistoryRetention(),
        console: Console = Console()
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.safety = safety
        self.editor = editor
        self.dataGrid = dataGrid
        self.ai = ai
        self.historyRetention = historyRetention
        self.console = console
    }

    public struct General: Codable, Sendable, Equatable {
        public var reopenLastSession: Bool
        public var openConnectionBehaviour: OpenConnectionBehaviour
        public var confirmBeforeClosingConnectionWindow: Bool
        /// What a single click on a table in the sidebar does.
        public var tableClickBehaviour: TableClickBehaviour

        public init(
            reopenLastSession: Bool = true,
            openConnectionBehaviour: OpenConnectionBehaviour = .focusExisting,
            confirmBeforeClosingConnectionWindow: Bool = true,
            tableClickBehaviour: TableClickBehaviour = .preview
        ) {
            self.tableClickBehaviour = tableClickBehaviour
            self.reopenLastSession = reopenLastSession
            self.openConnectionBehaviour = openConnectionBehaviour
            self.confirmBeforeClosingConnectionWindow = confirmBeforeClosingConnectionWindow
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = General()
            reopenLastSession = c.value(.reopenLastSession, d.reopenLastSession)
            openConnectionBehaviour = c.value(.openConnectionBehaviour, d.openConnectionBehaviour)
            confirmBeforeClosingConnectionWindow = c.value(
                .confirmBeforeClosingConnectionWindow, d.confirmBeforeClosingConnectionWindow)
            tableClickBehaviour = c.value(.tableClickBehaviour, d.tableClickBehaviour)
        }
    }

    public struct Safety: Codable, Sendable, Equatable {
        /// Confirm write statements on Production-tagged connections. The UI shows this
        /// locked ON for production: the field exists for persistence/forward-compat but
        /// the app must not let the user turn it off.
        public var confirmWritesOnProduction: Bool
        /// Require typing the database name to confirm destructive operations (drop, truncate).
        public var requireTypingDatabaseNameForDestructive: Bool
        /// Pre-tick "read-only" when creating a Production connection.
        public var defaultReadOnlyForNewProductionConnections: Bool

        public init(
            confirmWritesOnProduction: Bool = true,
            requireTypingDatabaseNameForDestructive: Bool = true,
            defaultReadOnlyForNewProductionConnections: Bool = false
        ) {
            self.confirmWritesOnProduction = confirmWritesOnProduction
            self.requireTypingDatabaseNameForDestructive = requireTypingDatabaseNameForDestructive
            self.defaultReadOnlyForNewProductionConnections = defaultReadOnlyForNewProductionConnections
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Safety()
            confirmWritesOnProduction = c.value(.confirmWritesOnProduction, d.confirmWritesOnProduction)
            requireTypingDatabaseNameForDestructive = c.value(
                .requireTypingDatabaseNameForDestructive, d.requireTypingDatabaseNameForDestructive)
            defaultReadOnlyForNewProductionConnections = c.value(
                .defaultReadOnlyForNewProductionConnections, d.defaultReadOnlyForNewProductionConnections)
        }
    }

    public struct Editor: Codable, Sendable, Equatable {
        /// Allowed font sizes (points); values outside are clamped.
        public static let fontSizeRange: ClosedRange<Double> = 8...36

        /// Editor font size in points, clamped to ``fontSizeRange``.
        public var fontSize: Double {
            didSet { fontSize = Self.clamp(fontSize) }
        }
        public var showLineNumbers: Bool

        public init(fontSize: Double = 12, showLineNumbers: Bool = true) {
            self.fontSize = Self.clamp(fontSize)
            self.showLineNumbers = showLineNumbers
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Editor()
            fontSize = Self.clamp(c.value(.fontSize, d.fontSize))
            showLineNumbers = c.value(.showLineNumbers, d.showLineNumbers)
        }

        private static func clamp(_ v: Double) -> Double {
            v.isFinite ? min(max(v, fontSizeRange.lowerBound), fontSizeRange.upperBound) : 12
        }
    }

    public struct DataGrid: Codable, Sendable, Equatable {
        /// Allowed rows per page; values outside are clamped.
        public static let pageSizeRange: ClosedRange<Int> = 50...10_000

        /// Rows fetched per page, clamped to ``pageSizeRange``.
        public var pageSize: Int {
            didSet { pageSize = Self.clamp(pageSize) }
        }
        public var showColumnTypes: Bool
        /// Text shown for SQL NULL.
        public var nullDisplay: String

        public init(pageSize: Int = 500, showColumnTypes: Bool = true, nullDisplay: String = "NULL") {
            self.pageSize = Self.clamp(pageSize)
            self.showColumnTypes = showColumnTypes
            self.nullDisplay = nullDisplay
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = DataGrid()
            pageSize = Self.clamp(c.value(.pageSize, d.pageSize))
            showColumnTypes = c.value(.showColumnTypes, d.showColumnTypes)
            nullDisplay = c.value(.nullDisplay, d.nullDisplay)
        }

        private static func clamp(_ v: Int) -> Int {
            min(max(v, pageSizeRange.lowerBound), pageSizeRange.upperBound)
        }
    }

    /// The SQL console tab.
    public struct Console: Codable, Sendable, Equatable {
        public static let maxCellWidthRange: ClosedRange<Int> = 8...400

        /// Cells wider than this many characters are cut with an ellipsis in the console's tables.
        public var maxCellWidth: Int {
            didSet { maxCellWidth = Self.clamp(maxCellWidth) }
        }
        /// Show tables with every cell in full (ignores ``maxCellWidth``).
        public var showFullCells: Bool

        public init(maxCellWidth: Int = 64, showFullCells: Bool = false) {
            self.maxCellWidth = Self.clamp(maxCellWidth)
            self.showFullCells = showFullCells
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Console()
            maxCellWidth = Self.clamp(c.value(.maxCellWidth, d.maxCellWidth))
            showFullCells = c.value(.showFullCells, d.showFullCells)
        }

        private static func clamp(_ v: Int) -> Int { min(max(v, maxCellWidthRange.lowerBound), maxCellWidthRange.upperBound) }
    }

    public struct AI: Codable, Sendable, Equatable {
        public var provider: AIProviderID?
        public var model: String?
        public var includeSampleRowsByDefault: Bool
        /// Per-connection override of ``includeSampleRowsByDefault``, keyed by the connection profile's
        /// UUID string. Sample rows are only ever sent for connections the user turned this on for.
        public var sampleRowsByConnection: [String: Bool]

        public init(provider: AIProviderID? = nil, model: String? = nil, includeSampleRowsByDefault: Bool = false,
                    sampleRowsByConnection: [String: Bool] = [:]) {
            self.provider = provider
            self.model = model
            self.includeSampleRowsByDefault = includeSampleRowsByDefault
            self.sampleRowsByConnection = sampleRowsByConnection
        }

        /// Whether the assistant may send sample rows of this connection's tables.
        public func includesSampleRows(for connectionID: UUID) -> Bool {
            sampleRowsByConnection[connectionID.uuidString] ?? includeSampleRowsByDefault
        }

        public mutating func setIncludesSampleRows(_ on: Bool, for connectionID: UUID) {
            sampleRowsByConnection[connectionID.uuidString] = on
        }

        /// Forgets the per-connection choice (the connection was deleted).
        public mutating func forgetConnection(_ connectionID: UUID) {
            sampleRowsByConnection.removeValue(forKey: connectionID.uuidString)
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = (try? c.decodeIfPresent(AIProviderID.self, forKey: .provider)) ?? nil
            model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
            includeSampleRowsByDefault = c.value(.includeSampleRowsByDefault, false)
            sampleRowsByConnection = c.value(.sampleRowsByConnection, [:])
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, general, safety, editor, dataGrid, ai, historyRetention, console }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, Self.currentSchemaVersion)
        general = c.value(.general, General())
        safety = c.value(.safety, Safety())
        editor = c.value(.editor, Editor())
        dataGrid = c.value(.dataGrid, DataGrid())
        ai = c.value(.ai, AI())
        historyRetention = c.value(.historyRetention, HistoryRetention())
        console = c.value(.console, Console())
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when missing, null or malformed.
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
