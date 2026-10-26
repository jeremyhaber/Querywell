import Foundation
import Observation
import QuerywellCore

/// State of the funnel popover for one column: the chosen condition, checked values and the distinct
/// values list (loaded through `fetch`, which the table model wires to `DistinctValuesQuery`).
@MainActor @Observable
final class FilterEditorModel {
    let columnName: String
    let kind: ColumnKind
    let conditions: [FilterCondition]
    private let editingID: UUID?

    var condition: FilterCondition {
        didSet {
            if condition != oldValue, condition.usesValueList, values.isEmpty, !isLoading { Task { await load() } }
        }
    }
    var selected: Set<DatabaseValue>
    var search = "" {
        didSet { if search != oldValue { scheduleSearch() } }
    }
    var text: String
    var text2: String

    private(set) var values: [DistinctValue] = []
    private(set) var isTruncated = false
    /// Set when the exact list ran out of time and the counts come from a sample of this many rows.
    private(set) var sampledRows: Int?
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Called with the finished filter (Apply) or nil (Clear).
    @ObservationIgnored var onFinish: @MainActor (ColumnFilter?) -> Void = { _ in }
    @ObservationIgnored private let fetch: @MainActor (String?) async throws -> DistinctValuesResult
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(
        columnName: String, dataType: String, existing: ColumnFilter?,
        fetch: @escaping @MainActor (String?) async throws -> DistinctValuesResult
    ) {
        self.columnName = columnName
        self.kind = ColumnKind.classify(dataType: dataType)
        self.conditions = FilterCondition.available(for: kind)
        self.fetch = fetch
        self.editingID = existing?.id
        if let existing, let draft = FilterCondition.draft(from: existing.op), conditions.contains(draft.condition) {
            condition = draft.condition
            selected = Set(draft.values)
            text = draft.text
            text2 = draft.text2
        } else {
            condition = .isAnyOf
            selected = []
            text = ""
            text2 = ""
        }
    }

    var hasExisting: Bool { editingID != nil }

    /// Rows of the checklist: checked values that fell outside the top-N come first, then the fetched ones.
    var rows: [(value: DatabaseValue, count: Int64?)] {
        let shown = Set(values.map(\.value))
        let extras = search.isEmpty ? selected.subtracting(shown).sorted { $0.displayString < $1.displayString } : []
        return extras.map { ($0, nil) } + values.map { ($0.value, $0.count) }
    }

    var canApply: Bool { makeOperator() != nil }

    func makeOperator() -> FilterOperator? {
        condition.makeOperator(values: Array(selected), text: text, text2: text2, kind: kind)
    }

    func toggle(_ value: DatabaseValue) {
        if selected.contains(value) { selected.remove(value) } else { selected.insert(value) }
    }

    func load() async {
        generation += 1
        let gen = generation
        isLoading = true
        loadError = nil
        do {
            let result = try await fetch(search.isEmpty ? nil : search)
            guard gen == generation else { return }
            values = result.values
            isTruncated = result.isTruncated
            sampledRows = result.sampledRows
        } catch {
            guard gen == generation else { return }
            loadError = SchemaBrowserModel.message(error)
        }
        isLoading = false
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func apply() {
        guard let op = makeOperator() else { return }
        onFinish(ColumnFilter(id: editingID ?? UUID(), column: columnName, op: op))
    }

    func clear() {
        onFinish(nil)
    }
}
