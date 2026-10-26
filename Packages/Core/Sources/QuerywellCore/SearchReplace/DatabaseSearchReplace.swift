import Foundation

/// Serialization-safe search & replace across tables of one database (a `wp search-replace` for any
/// schema): plan → preview / dry run → run.
///
/// **Scan.** Each table is read in primary-key order with keyset pagination (`batchSize` rows per
/// query), selecting the key and the candidate text columns. A `col LIKE '%search%'` prefilter is
/// ORed over the candidate columns so rows that cannot contain a match are never transferred. The
/// prefilter is only an optimisation and only ever *widens* what `SafeReplacer` sees: it matches the
/// literal search, the JSON-escaped spelling (`/` → `\/`), is case-insensitive where the replace is
/// (`ILIKE` / `_ci` collations), and is omitted entirely when it cannot be proven safe (non-literal
/// regex, case-insensitive search on a case-sensitive/binary collation). Every candidate cell then goes
/// through `SafeReplacer`, which is the sole authority on what changes.
///
/// **Write.** Per table inside one transaction (InnoDB / Postgres; a warning is attached for
/// non-transactional engines): `UPDATE t SET c = <new> WHERE pk = … AND c = <value as scanned>`. If a
/// row changed between scan and write the `UPDATE` matches nothing; the row is reported as a conflict
/// and left alone. Cancellation is honoured between batches and rolls back the table in flight.
public struct DatabaseSearchReplace: Sendable {
    public let session: any DatabaseSession
    public let configuration: SearchReplaceConfiguration
    private let dialect: SQLDialect

    public init(session: any DatabaseSession, configuration: SearchReplaceConfiguration) throws {
        guard !configuration.search.isEmpty else { throw SafeReplacerError.emptySearch }
        // Validate regex / options up front.
        _ = try SafeReplacer(search: configuration.search, replace: configuration.replace, options: configuration.options)
        self.session = session
        self.configuration = configuration
        self.dialect = SQLDialect(session.engine)
    }

    // MARK: Planning

    /// Decides, per table, which columns are searched and which tables/columns are skipped (and why).
    /// Pure: nothing is read from the database.
    public func plan(tables: [TableStructure]) -> SearchReplacePlan {
        SearchReplacePlan(tables: tables.map { planTable($0) })
    }

    private func planTable(_ structure: TableStructure) -> SearchReplaceTablePlan {
        let ref = structure.info.ref
        let pk = structure.primaryKey
        var warnings: [String] = []
        let transactional = Self.isTransactional(engine: structure.info.engine, family: dialect.family)
        if !transactional {
            warnings.append("\(structure.info.engine ?? "This engine") is not transactional: changes can't be rolled back if the run fails or is cancelled.")
        }
        func skip(_ reason: String) -> SearchReplaceTablePlan {
            SearchReplaceTablePlan(table: ref, primaryKey: pk, columns: [], skippedColumns: [], skipReason: reason,
                                   isTransactional: transactional, estimatedRows: structure.info.estimatedRows, warnings: warnings)
        }
        if structure.info.kind != .table { return skip("Not a base table (\(structure.info.kind.rawValue))") }
        if pk.isEmpty { return skip("No primary key: rows can't be addressed safely") }

        let selection = configuration.columnSelection[ref]
        let isWPPosts = Self.isWordPressPosts(structure)
        var columns: [SearchReplaceColumn] = []
        var skipped: [SearchReplaceSkippedColumn] = []
        let pkSet = Set(pk.map { $0.lowercased() })
        for col in structure.columns {
            guard let kind = Self.classify(col.dataType, family: dialect.family) else { continue }
            if let selection, !selection.contains(col.name) {
                skipped.append(.init(name: col.name, reason: "Not selected"))
                continue
            }
            if kind.isBinary && !configuration.includeBinaryColumns {
                skipped.append(.init(name: col.name, reason: "Binary column"))
                continue
            }
            if pkSet.contains(col.name.lowercased()) && !configuration.includePrimaryKeyColumns {
                skipped.append(.init(name: col.name, reason: "Primary key column"))
                continue
            }
            if isWPPosts && col.name.lowercased() == "guid" && !configuration.includeWordPressGUID {
                skipped.append(.init(name: col.name, reason: "WordPress GUIDs are permanent identifiers (skipped like wp-cli)"))
                continue
            }
            columns.append(SearchReplaceColumn(
                name: col.name, dataType: col.dataType, isBinary: kind.isBinary, isJSON: kind.isJSON, collation: col.collation))
        }
        if columns.isEmpty { return SearchReplaceTablePlan(
            table: ref, primaryKey: pk, columns: [], skippedColumns: skipped, skipReason: "No searchable text columns",
            isTransactional: transactional, estimatedRows: structure.info.estimatedRows, warnings: warnings) }
        return SearchReplaceTablePlan(
            table: ref, primaryKey: pk, columns: columns, skippedColumns: skipped, skipReason: nil,
            isTransactional: transactional, estimatedRows: structure.info.estimatedRows, warnings: warnings)
    }

    static func isTransactional(engine: String?, family: SQLDialect.Family) -> Bool {
        guard family == .mysql, let engine else { return true }
        return ["innodb", "ndbcluster", "ndb", "xtradb", "tokudb", "rocksdb"].contains(engine.lowercased())
    }

    /// `<prefix>posts` with `guid` and `post_content` columns.
    static func isWordPressPosts(_ s: TableStructure) -> Bool {
        let names = Set(s.columns.map { $0.name.lowercased() })
        return s.info.ref.name.lowercased().hasSuffix("posts") && names.contains("guid") && names.contains("post_content")
    }

    /// Text-like column classification. `nil`: not searchable (numbers, dates, enums, sets, arrays, …).
    static func classify(_ dataType: String, family: SQLDialect.Family) -> (isBinary: Bool, isJSON: Bool)? {
        let t = dataType.lowercased()
        switch family {
        case .mysql:
            switch t {
            case "char", "varchar", "tinytext", "text", "mediumtext", "longtext": return (false, false)
            case "json": return (false, true)
            case "tinyblob", "blob", "mediumblob", "longblob", "binary", "varbinary": return (true, false)
            default: return nil
            }
        case .postgres:
            switch t {
            case "varchar", "bpchar", "text", "citext", "name": return (false, false)
            case "json", "jsonb": return (false, true)
            case "bytea": return (true, false)
            default: return nil
            }
        }
    }

    // MARK: Running

    /// Starts a run and returns its progress events; the last event is `.finished(report)`.
    /// Cancelling the consuming task (or dropping the stream) cancels the run: the table in flight is
    /// rolled back and later tables are reported as not run.
    public func events(plan: SearchReplacePlan, mode: SearchReplaceMode) -> AsyncStream<SearchReplaceEvent> {
        let (stream, continuation) = AsyncStream<SearchReplaceEvent>.makeStream(bufferingPolicy: .unbounded)
        let runner = self
        let task = Task.detached {
            let report = await runner.execute(plan: plan, mode: mode) { continuation.yield($0) }
            continuation.yield(.finished(report))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Runs to the end (honouring cancellation of the calling task) and returns the report.
    public func run(plan: SearchReplacePlan, mode: SearchReplaceMode,
                    onEvent: @escaping @Sendable (SearchReplaceEvent) -> Void = { _ in }) async -> SearchReplaceReport {
        let report = await execute(plan: plan, mode: mode, emit: onEvent)
        onEvent(.finished(report))
        return report
    }

    private func execute(plan: SearchReplacePlan, mode: SearchReplaceMode,
                         emit: @Sendable (SearchReplaceEvent) -> Void) async -> SearchReplaceReport {
        let clock = ContinuousClock()
        let started = clock.now
        var reports: [SearchReplaceTableReport] = []
        var cancelled = false
        var stopped = false
        let runnableTotal = plan.tables.filter(\.isRunnable).count
        var runnableIndex = 0

        guard let replacer = try? SafeReplacer(search: configuration.search, replace: configuration.replace,
                                               options: configuration.options) else {
            return SearchReplaceReport(mode: mode, tables: [], wasCancelled: false, stoppedOnError: true, duration: .zero)
        }

        for table in plan.tables {
            if !table.isRunnable {
                let r = Self.emptyReport(table, .skipped(table.skipReason ?? "Skipped"))
                emit(.tableFinished(r))
                reports.append(r)
                continue
            }
            if Task.isCancelled || cancelled {
                cancelled = true
                let r = Self.emptyReport(table, .notRun)
                emit(.tableFinished(r))
                reports.append(r)
                continue
            }
            if stopped {
                let r = Self.emptyReport(table, .notRun)
                emit(.tableFinished(r))
                reports.append(r)
                continue
            }
            runnableIndex += 1
            emit(.tableStarted(table.table, index: runnableIndex, total: runnableTotal, estimatedRows: table.estimatedRows))
            let report = await processTable(table, mode: mode, replacer: replacer, emit: emit)
            if report.status == .cancelled { cancelled = true }
            if case .failed = report.status, configuration.stopOnError { stopped = true }
            emit(.tableFinished(report))
            reports.append(report)
        }
        return SearchReplaceReport(mode: mode, tables: reports, wasCancelled: cancelled, stoppedOnError: stopped,
                                   duration: clock.now - started)
    }

    private static func emptyReport(_ t: SearchReplaceTablePlan, _ status: SearchReplaceTableReport.Status) -> SearchReplaceTableReport {
        SearchReplaceTableReport(
            table: t.table, status: status, rowsScanned: 0, rowsChanged: 0, cellsChanged: 0, replacements: 0, perColumn: [],
            samples: [], conflicts: [], invalidSerialized: [], committed: false, rolledBack: false,
            isTransactional: t.isTransactional, warnings: t.warnings)
    }

    // MARK: One table

    private func processTable(
        _ table: SearchReplaceTablePlan, mode: SearchReplaceMode, replacer: SafeReplacer,
        emit: @Sendable (SearchReplaceEvent) -> Void
    ) async -> SearchReplaceTableReport {
        var report = Self.emptyReport(table, .completed)
        let apply = mode == .apply
        let useTransaction = apply && table.isTransactional
        var columnCounts: [String: (cells: Int, replacements: Int)] = [:]
        var inTransaction = false
        var lastKey: [DatabaseValue]?
        let q = dialect.quoteIdentifier
        let batchSize = configuration.batchSize

        func finishFailed(_ error: any Error) async -> SearchReplaceTableReport {
            if inTransaction {
                await rollback()
                report.rolledBack = true
            }
            report.committed = false
            report.status = .failed(EditSession.describe(error))
            report.perColumn = Self.counts(columnCounts)
            return report
        }

        do {
            if useTransaction {
                if dialect.family == .mysql { _ = try? await session.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED") }
                _ = try await session.execute(dialect.family == .mysql ? "START TRANSACTION" : "BEGIN")
                inTransaction = true
            }
            let prefilter = prefilterSQL(for: table)
            let selectColumns = (table.primaryKey + table.columns.map(\.name)).map(q).joined(separator: ", ")
            let order = table.primaryKey.map { q($0) + " ASC" }.joined(separator: ", ")

            scan: while true {
                if Task.isCancelled { throw CancellationError() }
                var conditions: [String] = []
                if let prefilter { conditions.append(prefilter) }
                if let lastKey, let k = KeysetPagination.condition(primaryKey: table.primaryKey, after: lastKey, dialect: dialect) {
                    conditions.append(k)
                }
                var sql = "SELECT \(selectColumns) FROM \(dialect.qualified(table.table))"
                if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
                sql += " ORDER BY \(order)" + dialect.limitClause(limit: batchSize, offset: 0)
                let result = try await session.execute(sql)
                if result.rows.isEmpty { break scan }
                let pkCount = table.primaryKey.count

                await configuration.afterBatchScanned?(table.table)

                for row in result.rows {
                    if Task.isCancelled { throw CancellationError() }
                    guard row.count >= pkCount + table.columns.count else { continue }
                    let keyValues = Array(row[0..<pkCount])
                    report.rowsScanned += 1
                    var changes: [(column: SearchReplaceColumn, original: DatabaseValue, updated: DatabaseValue)] = []
                    let keyForReport = zip(table.primaryKey, keyValues).map { PrimaryKeyValue(column: $0, value: $1.displayString) }

                    for (offset, column) in table.columns.enumerated() {
                        let cell = row[pkCount + offset]
                        guard let outcome = process(cell, replacer: replacer) else { continue }
                        if outcome.invalidSerialized {
                            report.invalidSerialized.append(CellLocation(table: table.table, primaryKey: keyForReport, column: column.name))
                        }
                        guard outcome.replacements > 0 else { continue }
                        changes.append((column, cell, outcome.value))
                        report.cellsChanged += 1
                        report.replacements += outcome.replacements
                        var c = columnCounts[column.name] ?? (0, 0)
                        c.cells += 1
                        c.replacements += outcome.replacements
                        columnCounts[column.name] = c
                        if report.samples.count < configuration.sampleLimitPerTable {
                            let (b, a) = Self.excerpts(before: cell, after: outcome.value, radius: configuration.excerptRadius)
                            report.samples.append(ChangePreview(
                                table: table.table, primaryKey: keyForReport, column: column.name, before: b, after: a,
                                kind: outcome.kind, replacements: outcome.replacements))
                        }
                    }
                    guard !changes.isEmpty else { continue }

                    if apply {
                        let sets = changes.map { "\(q($0.column.name)) = \(dialect.literal($0.updated))" }
                        var wheres = zip(table.primaryKey, keyValues).map { "\(q($0)) = \(dialect.literal($1))" }
                        wheres += changes.map { equality($0.column, $0.original) }
                        let update = "UPDATE \(dialect.qualified(table.table)) SET \(sets.joined(separator: ", ")) WHERE \(wheres.joined(separator: " AND "))"
                        let r = try await session.execute(update)
                        if let n = r.rowsAffected, n == 0 {
                            // Row changed after we read it: roll the bookkeeping back for this row.
                            report.conflicts.append(CellLocation(table: table.table, primaryKey: keyForReport,
                                                                  column: changes.map(\.column.name).joined(separator: ", ")))
                            report.cellsChanged -= changes.count
                            for ch in changes {
                                let reps = processedReplacements(ch.original, ch.updated, replacer: replacer)
                                report.replacements -= reps
                                if var c = columnCounts[ch.column.name] {
                                    c.cells -= 1
                                    c.replacements -= reps
                                    columnCounts[ch.column.name] = c
                                }
                            }
                            continue
                        }
                    }
                    report.rowsChanged += 1
                }
                emit(.progress(table.table, rowsScanned: report.rowsScanned, rowsChanged: report.rowsChanged))
                lastKey = Array(result.rows[result.rows.count - 1][0..<pkCount])
                if result.rows.count < batchSize { break scan }
            }

            if inTransaction {
                _ = try await session.execute("COMMIT")
                inTransaction = false
            }
            report.committed = apply
            report.perColumn = Self.counts(columnCounts)
            return report
        } catch is CancellationError {
            if inTransaction {
                await rollback()
                report.rolledBack = true
            }
            report.committed = apply && !table.isTransactional && report.rowsChanged > 0
            report.status = .cancelled
            report.perColumn = Self.counts(columnCounts)
            return report
        } catch {
            return await finishFailed(error)
        }
    }

    private func rollback() async {
        // Detached: a cancelled task must still be able to talk to the server.
        let s = session
        await Task.detached { _ = try? await s.execute("ROLLBACK") }.value
    }

    private static func counts(_ c: [String: (cells: Int, replacements: Int)]) -> [SearchReplaceColumnCount] {
        c.filter { $0.value.cells > 0 }
            .map { SearchReplaceColumnCount(column: $0.key, cells: $0.value.cells, replacements: $0.value.replacements) }
            .sorted { $0.column < $1.column }
    }

    // MARK: Cell processing

    private struct CellOutcome {
        var value: DatabaseValue
        var replacements: Int
        var kind: ReplaceKind
        var invalidSerialized: Bool
    }

    private func process(_ cell: DatabaseValue, replacer: SafeReplacer) -> CellOutcome? {
        switch cell {
        case .null: return nil
        case .text(let s):
            var o = replacer.replace(in: s)
            var text = o.newValue
            var count = o.replacements
            if configuration.replaceJSONEscapedSlashes, o.kind == .plain, let pair = jsonEscapedPair {
                let (t, n) = Self.replaceAll(in: text, search: pair.search, replace: pair.replace,
                                             caseSensitive: configuration.options.caseSensitive)
                if n > 0 { text = t; count += n }
            }
            o.newValue = text
            let invalid = o.kind == .phpSerializedInvalid || o.warnings.contains { if case .invalidSerialized = $0 { true } else { false } }
            return CellOutcome(value: count > 0 ? .text(text) : cell, replacements: count, kind: o.kind, invalidSerialized: invalid)
        case .bytes(let d):
            let o = replacer.replace(inBytes: d)
            let invalid = o.kind == .phpSerializedInvalid || o.warnings.contains { if case .invalidSerialized = $0 { true } else { false } }
            return CellOutcome(value: o.changed ? .bytes(o.newValue) : cell, replacements: o.replacements, kind: o.kind, invalidSerialized: invalid)
        default: return nil
        }
    }

    /// Replacement count for a conflicted cell (recomputed; cheap and only on the rare conflict path).
    private func processedReplacements(_ original: DatabaseValue, _ updated: DatabaseValue, replacer: SafeReplacer) -> Int {
        process(original, replacer: replacer)?.replacements ?? 0
    }

    /// `(search, replace)` with `/` → `\/`, when a JSON-escaped pass makes sense.
    private var jsonEscapedPair: (search: String, replace: String)? {
        let o = configuration.options
        guard !o.regex, !o.wholeWord, configuration.search.contains("/") else { return nil }
        return (configuration.search.replacingOccurrences(of: "/", with: "\\/"),
                configuration.replace.replacingOccurrences(of: "/", with: "\\/"))
    }

    static func replaceAll(in text: String, search: String, replace: String, caseSensitive: Bool) -> (String, Int) {
        guard !search.isEmpty else { return (text, 0) }
        let opts: String.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var out = ""
        var count = 0
        var cursor = text.startIndex
        while let r = text.range(of: search, options: opts, range: cursor..<text.endIndex) {
            out += text[cursor..<r.lowerBound]
            out += replace
            cursor = r.upperBound
            count += 1
        }
        guard count > 0 else { return (text, 0) }
        out += text[cursor...]
        return (out, count)
    }

    // MARK: SQL pieces

    /// `col = <value as scanned>`; JSON and binary columns need engine-specific handling.
    private func equality(_ column: SearchReplaceColumn, _ original: DatabaseValue) -> String {
        let name = dialect.quoteIdentifier(column.name)
        let lit = dialect.literal(original)
        if column.isJSON {
            switch dialect.family {
            case .mysql: return "CAST(\(name) AS CHAR) = \(lit)"
            case .postgres: return "\(name)::text = \(lit)"
            }
        }
        return "\(name) = \(lit)"
    }

    /// OR of per-column `LIKE` conditions, or nil when no safe prefilter exists.
    func prefilterSQL(for table: SearchReplaceTablePlan) -> String? {
        let o = configuration.options
        var needles: [String]
        if o.regex {
            guard !Self.hasRegexMetacharacters(configuration.search) else { return nil }
            needles = [Self.unescapeRegexLiteral(configuration.search)]
        } else {
            needles = [configuration.search]
        }
        if needles[0].contains("/") { needles.append(needles[0].replacingOccurrences(of: "/", with: "\\/")) }

        var perColumn: [String] = []
        for col in table.columns {
            let name = dialect.quoteIdentifier(col.name)
            if !o.caseSensitive && dialect.family == .mysql {
                // LIKE honours the column collation; only `_ci` collations are case-insensitive.
                guard !col.isBinary, let coll = col.collation?.lowercased(), coll.hasSuffix("_ci") else { return nil }
            }
            switch (dialect.family, col.isBinary) {
            case (.postgres, true):
                for n in needles {
                    let hex = "\\x" + n.utf8.map { String(format: "%02x", $0) }.joined()
                    perColumn.append("position('\(hex)'::bytea in \(name)) > 0")
                }
            case (.postgres, false):
                let op = o.caseSensitive ? "LIKE" : "ILIKE"
                for n in needles {
                    perColumn.append("\(name)::text \(op) \(dialect.quoteString("%" + dialect.escapeLikePattern(n) + "%"))")
                }
            case (.mysql, _):
                for n in needles {
                    perColumn.append("\(name) LIKE \(dialect.quoteString("%" + dialect.escapeLikePattern(n) + "%"))")
                }
            }
        }
        guard !perColumn.isEmpty else { return nil }
        return "(" + perColumn.joined(separator: " OR ") + ")"
    }

    static func hasRegexMetacharacters(_ s: String) -> Bool {
        // A backslash followed by a non-alphanumeric is an escaped literal and handled by unescapeRegexLiteral.
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            if c == "\\" {
                guard let next = iterator.next(), !(next.isLetter || next.isNumber) else { return true }
                continue
            }
            if ".^$|?*+()[]{}".contains(c) { return true }
        }
        return false
    }

    static func unescapeRegexLiteral(_ s: String) -> String {
        var out = ""
        var escape = false
        for c in s {
            if escape { out.append(c); escape = false } else if c == "\\" { escape = true } else { out.append(c) }
        }
        return out
    }

    // MARK: Excerpts

    /// Short before/after windows around the first change, with `…` where text was cut.
    static func excerpts(before: DatabaseValue, after: DatabaseValue, radius: Int) -> (String, String) {
        func scalars(_ v: DatabaseValue) -> [Unicode.Scalar] {
            switch v {
            case .text(let s): return Array(s.unicodeScalars)
            case .bytes(let d): return Array(String(decoding: d, as: UTF8.self).unicodeScalars)
            default: return Array(v.displayString.unicodeScalars)
            }
        }
        let b = scalars(before), a = scalars(after)
        var prefix = 0
        while prefix < b.count, prefix < a.count, b[prefix] == a[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < b.count - prefix, suffix < a.count - prefix, b[b.count - 1 - suffix] == a[a.count - 1 - suffix] { suffix += 1 }
        func window(_ x: [Unicode.Scalar]) -> String {
            let start = max(0, prefix - radius)
            let changedEnd = x.count - suffix
            let end = min(x.count, changedEnd + radius)
            var middle = Array(x[prefix..<max(prefix, changedEnd)])
            var cutMiddle = false
            if middle.count > radius * 3 {
                middle = Array(middle.prefix(radius * 3))
                cutMiddle = true
            }
            var s = start > 0 ? "…" : ""
            s += String(String.UnicodeScalarView(x[start..<prefix]))
            s += String(String.UnicodeScalarView(middle))
            if cutMiddle { s += "…" }
            if !cutMiddle || end > changedEnd { s += String(String.UnicodeScalarView(x[min(changedEnd, x.count)..<end])) }
            if end < x.count { s += "…" }
            return s
        }
        return (window(b), window(a))
    }
}
