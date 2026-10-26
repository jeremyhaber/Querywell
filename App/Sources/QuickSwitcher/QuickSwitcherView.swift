import QuerywellCore
import SwiftUI

/// ⌘K palette: fuzzy search over open tabs, connections and actions.
struct QuickSwitcherView: View {
    let items: [QuickSwitcherItem]
    /// The window's tabs (for tab icons); `nil` in the launcher.
    let tabs: WorkspaceTabs?
    let profiles: [ConnectionProfile]
    var onSelect: (QuickSwitcherItem) -> Void
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private static let resultLimit = 50

    private struct Section: Identifiable {
        let category: QuickSwitcherCategory
        let rows: [(index: Int, result: QuickSwitcherResult)]
        var id: Int { category.rawValue }
    }

    /// Ranked results grouped under category headings; sections are ordered by their best match.
    private var sections: [Section] {
        let results = QuickSwitcher.results(query: query, items: items, limit: Self.resultLimit)
        var order: [QuickSwitcherCategory] = []
        var byCategory: [QuickSwitcherCategory: [QuickSwitcherResult]] = [:]
        for result in results {
            let category = result.item.category
            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(result)
        }
        var index = 0
        return order.map { category in
            let rows = (byCategory[category] ?? []).map { result -> (Int, QuickSwitcherResult) in
                defer { index += 1 }
                return (index, result)
            }
            return Section(category: category, rows: rows)
        }
    }

    var body: some View {
        let sections = sections
        let flat = sections.flatMap(\.rows).map(\.result)
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                searchRow(flat: flat)
                Divider()
                results(sections: sections, flat: flat)
            }
            .frame(width: 560)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            .padding(.top, 70)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick open")
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func searchRow(flat: [QuickSwitcherResult]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField("Jump to a tab, connection or action…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .accessibilityLabel("Search")
                .onKeyPress(.downArrow) {
                    if !flat.isEmpty { highlighted = min(highlighted + 1, flat.count - 1) }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onSubmit { choose(flat, at: highlighted) }
            KeyCap("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func results(sections: [Section], flat: [QuickSwitcherResult]) -> some View {
        Group {
            if flat.isEmpty {
                Text("No matches")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.category.heading.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(0.44)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.rows, id: \.index) { row in
                                    rowView(row.result, isHighlighted: row.index == highlighted)
                                        .id(row.index)
                                        .onTapGesture { choose(flat, at: row.index) }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
                .frame(maxHeight: 380)
            }
        }
    }

    private func rowView(_ result: QuickSwitcherResult, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            icon(for: result.item)
                .frame(width: 18)
            Text(Self.highlightedTitle(result.item.title, match: result.match))
                .foregroundStyle(isHighlighted ? Theme.accentSubtleText : Theme.text)
                .lineLimit(1)
            if let subtitle = result.item.subtitle {
                Text(subtitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if case .connection(let id, _, _) = result.item, profiles.first(where: { $0.id == id })?.isProduction == true {
                ProdBadge()
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isHighlighted ? Theme.accentSubtleBackground : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(for item: QuickSwitcherItem) -> some View {
        switch item {
        case .connection(_, _, let tag):
            ColorTagSwatch(tag: tag)
        case .openTab(let id, _):
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.color(for: tabs?.tab(id: id)?.accent ?? .table))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        case .table:
            Image(systemName: "tablecells").foregroundStyle(Theme.textSecondary)
        case .savedQuery:
            Image(systemName: "bookmark").foregroundStyle(Theme.tabQuery)
        case .action(let action):
            Image(systemName: Self.symbol(for: action)).foregroundStyle(Theme.textSecondary)
        }
    }

    static func symbol(for action: QuickAction) -> String {
        switch action {
        case .newQuery: "plus.square"
        case .newConsole: "terminal"
        case .openConnections: "externaldrive.connected.to.line.below"
        case .settings: "gearshape"
        }
    }

    private func choose(_ flat: [QuickSwitcherResult], at index: Int) {
        guard flat.indices.contains(index) else { return }
        let item = flat[index].item
        onDismiss()
        onSelect(item)
    }

    /// `title` with the fuzzy-matched characters in bold.
    static func highlightedTitle(_ title: String, match: FuzzyMatch) -> AttributedString {
        var text = AttributedString(title)
        for index in match.matchedIndices where index < title.endIndex {
            let offset = title.distance(from: title.startIndex, to: index)
            let start = text.index(text.startIndex, offsetByCharacters: offset)
            let end = text.index(start, offsetByCharacters: 1)
            text[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}
