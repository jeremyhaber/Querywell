import Foundation

// Value types for the database-wide, serialization-safe search & replace (like `wp search-replace`).

public enum SearchReplaceMode: Sendable, Equatable {
    /// Scan and count; nothing is written, no transaction is opened.
    case dryRun
    /// Scan and write, one transaction per table.
    case apply
}

public struct SearchReplaceConfiguration: Sendable {
    public var search: String
    public var replace: String
    public var options: SafeReplaceOptions
    /// Also search BLOB / BINARY / bytea columns (off by default).
    public var includeBinaryColumns: Bool
    /// WordPress: the `guid` column of `<prefix>posts` is skipped by default (like wp-cli) because GUIDs
    /// are permanent identifiers, not links. Opt in to rewrite it.
    public var includeWordPressGUID: Bool
    /// Primary-key columns are skipped by default: rewriting a key changes row identity.
    public var includePrimaryKeyColumns: Bool
    /// Restrict the columns searched per table (names). Tables not listed use every eligible column.
    public var columnSelection: [TableRef: Set<String>]
    /// Rows per scan batch (keyset pages).
    public var batchSize: Int
    /// Samples (`ChangePreview`) kept per table.
    public var sampleLimitPerTable: Int
    /// Characters of context kept on each side of a change in a sample.
    public var excerptRadius: Int
    /// Abort the whole run after the first failed table (default: carry on with the next table).
    public var stopOnError: Bool
    /// Also replace the JSON-escaped spelling (`https:\/\/x`) inside plain text values such as Gutenberg
    /// block comments in `post_content`. Only applies to literal (non-regex, non-whole-word) searches
    /// that contain a `/`.
    public var replaceJSONEscapedSlashes: Bool
    /// Called after a batch has been read and before it is written (also in dry runs). Lets a caller
    /// observe or interleave work; used by tests to provoke optimistic-concurrency conflicts and cancellation.
    public var afterBatchScanned: (@Sendable (TableRef) async -> Void)?

    public init(
        search: String, replace: String, options: SafeReplaceOptions = SafeReplaceOptions(),
        includeBinaryColumns: Bool = false, includeWordPressGUID: Bool = false, includePrimaryKeyColumns: Bool = false,
        columnSelection: [TableRef: Set<String>] = [:], batchSize: Int = 500, sampleLimitPerTable: Int = 25,
        excerptRadius: Int = 40, stopOnError: Bool = false, replaceJSONEscapedSlashes: Bool = true,
        afterBatchScanned: (@Sendable (TableRef) async -> Void)? = nil
    ) {
        self.search = search
        self.replace = replace
        self.options = options
        self.includeBinaryColumns = includeBinaryColumns
        self.includeWordPressGUID = includeWordPressGUID
        self.includePrimaryKeyColumns = includePrimaryKeyColumns
        self.columnSelection = columnSelection
        self.batchSize = max(1, batchSize)
        self.sampleLimitPerTable = max(0, sampleLimitPerTable)
        self.excerptRadius = max(8, excerptRadius)
        self.stopOnError = stopOnError
        self.replaceJSONEscapedSlashes = replaceJSONEscapedSlashes
        self.afterBatchScanned = afterBatchScanned
    }
}

// MARK: - Plan

public struct SearchReplaceColumn: Sendable, Hashable {
    public var name: String
    public var dataType: String
    /// BLOB / BINARY / bytea: matched and rewritten as bytes.
    public var isBinary: Bool
    /// JSON column (needs a cast for comparisons).
    public var isJSON: Bool
    public var collation: String?
}

public struct SearchReplaceSkippedColumn: Sendable, Hashable {
    public var name: String
    public var reason: String
}

public struct SearchReplaceTablePlan: Sendable, Hashable {
    public var table: TableRef
    public var primaryKey: [String]
    public var columns: [SearchReplaceColumn]
    public var skippedColumns: [SearchReplaceSkippedColumn]
    /// Non-nil: the whole table is not processed (no primary key, a view, no eligible columns).
    public var skipReason: String?
    /// `false` for MyISAM and friends: changes can't be rolled back on failure or cancel.
    public var isTransactional: Bool
    public var estimatedRows: Int64?
    public var warnings: [String]

    public var isRunnable: Bool { skipReason == nil }
}

public struct SearchReplacePlan: Sendable {
    public var tables: [SearchReplaceTablePlan]
    public var runnableTables: [SearchReplaceTablePlan] { tables.filter(\.isRunnable) }
    public var skippedTables: [SearchReplaceTablePlan] { tables.filter { !$0.isRunnable } }
}

// MARK: - Results

public struct PrimaryKeyValue: Sendable, Hashable {
    public var column: String
    public var value: String
}

public struct CellLocation: Sendable, Hashable {
    public var table: TableRef
    public var primaryKey: [PrimaryKeyValue]
    public var column: String
}

/// One changed cell: what it looked like and what it will / did become (excerpts around the change).
public struct ChangePreview: Sendable, Hashable {
    public var table: TableRef
    public var primaryKey: [PrimaryKeyValue]
    public var column: String
    public var before: String
    public var after: String
    public var kind: ReplaceKind
    public var replacements: Int
}

public struct SearchReplaceColumnCount: Sendable, Hashable {
    public var column: String
    public var cells: Int
    public var replacements: Int
}

public struct SearchReplaceTableReport: Sendable {
    public enum Status: Sendable, Equatable {
        case completed
        case skipped(String)
        case failed(String)
        case cancelled
        /// Never started (earlier failure with stop-on-error, or cancellation).
        case notRun
    }

    public var table: TableRef
    public var status: Status
    /// Candidate rows read (rows that passed the LIKE prefilter).
    public var rowsScanned: Int
    /// Rows with at least one changed cell (written, or would be written in a dry run).
    public var rowsChanged: Int
    public var cellsChanged: Int
    public var replacements: Int
    public var perColumn: [SearchReplaceColumnCount]
    public var samples: [ChangePreview]
    /// Rows whose write matched nothing because the row changed after it was scanned (not written).
    public var conflicts: [CellLocation]
    /// Cells that look like PHP serialized data but don't parse: left untouched. Fix them by hand.
    public var invalidSerialized: [CellLocation]
    /// Apply mode: the table's changes are durable (committed, or non-transactional). `false` after a
    /// rollback (failure/cancel) and in dry runs.
    public var committed: Bool
    public var rolledBack: Bool
    public var isTransactional: Bool
    public var warnings: [String]
}

public struct SearchReplaceReport: Sendable {
    public var mode: SearchReplaceMode
    public var tables: [SearchReplaceTableReport]
    public var wasCancelled: Bool
    public var stoppedOnError: Bool
    public var duration: Duration

    public var rowsChanged: Int { tables.reduce(0) { $0 + $1.rowsChanged } }
    public var cellsChanged: Int { tables.reduce(0) { $0 + $1.cellsChanged } }
    public var replacements: Int { tables.reduce(0) { $0 + $1.replacements } }
    public var conflicts: [CellLocation] { tables.flatMap(\.conflicts) }
    public var invalidSerialized: [CellLocation] { tables.flatMap(\.invalidSerialized) }
    public var failedTables: [SearchReplaceTableReport] {
        tables.filter { if case .failed = $0.status { true } else { false } }
    }
}

public enum SearchReplaceEvent: Sendable {
    case tableStarted(TableRef, index: Int, total: Int, estimatedRows: Int64?)
    case progress(TableRef, rowsScanned: Int, rowsChanged: Int)
    case tableFinished(SearchReplaceTableReport)
    /// Always the last event.
    case finished(SearchReplaceReport)
}
