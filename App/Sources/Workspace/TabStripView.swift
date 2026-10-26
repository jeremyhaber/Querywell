import QuerywellCore
import SwiftUI

/// Per-tab frames in the strip's scroll viewport space, for paging.
private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Frame of the whole tab row inside the scroll view (its width and scroll offset).
private struct TabContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Horizontal tab strip under the connection header (design: Main.dc.html `nav`). When the tabs don't
/// fit it scrolls, with page chevrons, a thin position bar and a menu listing every tab.
struct TabStripView: View {
    @Bindable var workspace: ConnectionWorkspace
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var viewportWidth: CGFloat = 0
    @State private var content: CGRect = .zero
    @State private var frames: [UUID: CGRect] = [:]

    private static let space = "tabStripViewport"

    private var overflowing: Bool { viewportWidth > 0 && content.width > viewportWidth + 1 }
    private var offset: CGFloat { max(-content.minX, 0) }
    private var canScrollLeft: Bool { offset > 1 }
    private var canScrollRight: Bool { content.width - viewportWidth - offset > 1 }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .bottom, spacing: 2) {
                if overflowing {
                    chevron("chevron.left", label: "Scroll tabs left", enabled: canScrollLeft) { page(-1, proxy) }
                }
                scroller(proxy)
                if overflowing {
                    chevron("chevron.right", label: "Scroll tabs right", enabled: canScrollRight) { page(1, proxy) }
                    overflowMenu
                }
                addButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38, alignment: .bottom)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Theme.chrome
                // The connection's colour tag tints the strip so local / staging / production read at a glance.
                if let tag = workspace.profile.colorTag {
                    tag.color.opacity(contrast == .increased ? 0.2 : 0.1).accessibilityHidden(true)
                }
                Theme.separator.frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open tabs")
    }

    private func scroller(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tabs
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TabContentFrameKey.self, value: geo.frame(in: .named(Self.space)))
                })
        }
        .coordinateSpace(name: Self.space)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { viewportWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, new in viewportWidth = new }
        })
        .onPreferenceChange(TabContentFrameKey.self) { content = $0 }
        .onPreferenceChange(TabFramesKey.self) { frames = $0 }
        .overlay(alignment: .top) { positionBar }
        // The selected tab always scrolls into view (selection by click, shortcut, new tab or the menu).
        .onChange(of: workspace.tabs.selectedID) { _, id in
            guard let id else { return }
            Motion.animate { proxy.scrollTo(id) }
        }
        .onChange(of: overflowing) { _, _ in
            if let id = workspace.tabs.selectedID { proxy.scrollTo(id) }
        }
        .onAppear { if let id = workspace.tabs.selectedID { proxy.scrollTo(id) } }
    }

    /// A thin, always-visible scroll bar (the system's overlay scroller hides itself).
    @ViewBuilder
    private var positionBar: some View {
        if overflowing, content.width > 0 {
            let width = max(viewportWidth * viewportWidth / content.width, 24)
            let travel = max(viewportWidth - width, 0)
            let progress = min(max(offset / max(content.width - viewportWidth, 1), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.separator).frame(height: 3)
                Capsule().fill(Theme.textTertiary).frame(width: width, height: 3).offset(x: travel * progress)
            }
            .padding(.top, 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(workspace.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItemView(
                    tab: tab,
                    position: index + 1,
                    count: workspace.tabs.tabs.count,
                    isSelected: workspace.tabs.selectedID == tab.id,
                    canDuplicate: workspace.tabs.canDuplicate(id: tab.id),
                    hasOthers: workspace.tabs.tabs.count > 1,
                    hasTabsToRight: !workspace.tabs.ids(after: tab.id).isEmpty,
                    onSelect: { workspace.tabs.select(id: tab.id) },
                    onKeep: { workspace.tabs.keep(id: tab.id) },
                    onClose: { workspace.requestClose(tab: tab.id) },
                    onDrop: { movedID in reorder(movedID, onto: tab.id) },
                    onSetColor: { workspace.tabs.setColor(id: tab.id, $0) },
                    onDuplicate: { workspace.duplicateTab(tab.id) },
                    onCloseOthers: { workspace.requestClose(tabs: workspace.tabs.ids(except: tab.id)) },
                    onCloseToRight: { workspace.requestClose(tabs: workspace.tabs.ids(after: tab.id)) })
                    .id(tab.id)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabFramesKey.self, value: [tab.id: geo.frame(in: .named(Self.space))])
                    })
            }
        }
    }

    private func chevron(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .padding(.bottom, 3)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Scrolls about a page: right goes to the first tab starting past 80% of the visible width, left to the
    /// first tab starting within 80% of a viewport to the left.
    private func page(_ direction: Int, _ proxy: ScrollViewProxy) {
        let ordered = workspace.tabs.tabs.compactMap { tab in frames[tab.id].map { (id: tab.id, frame: $0) } }
        guard !ordered.isEmpty else { return }
        let step = viewportWidth * 0.8
        Motion.animate {
            if direction > 0 {
                if let target = ordered.first(where: { $0.frame.minX >= step }) {
                    proxy.scrollTo(target.id, anchor: .leading)
                } else if let last = ordered.last {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            } else {
                let target = ordered.first(where: { $0.frame.minX >= -step }) ?? ordered[0]
                proxy.scrollTo(target.id, anchor: .leading)
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(workspace.tabs.tabs) { tab in
                Button {
                    workspace.tabs.select(id: tab.id)
                } label: {
                    if workspace.tabs.selectedID == tab.id {
                        Label(tab.title, systemImage: "checkmark")
                    } else {
                        Text(tab.title)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 3)
        .help("All tabs")
        .accessibilityLabel("All tabs")
    }

    private var addButton: some View {
        Menu {
            Button("New Query") { workspace.newQuery() }
            Button("Console") { workspace.openConsole() }
            Button("Database Health & Doctor") { workspace.openHealth() }
            Button("SSH Terminal") { workspace.openTerminal() }
                .disabled(workspace.profile.ssh == nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
        } primaryAction: {
            workspace.newQuery()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 3)
        .help("New tab")
        .accessibilityLabel("New tab")
    }

    private func reorder(_ movedID: UUID, onto targetID: UUID) -> Bool {
        let all = workspace.tabs.tabs
        guard let from = all.firstIndex(where: { $0.id == movedID }),
              let to = all.firstIndex(where: { $0.id == targetID }), from != to else { return false }
        workspace.tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return true
    }
}

/// A tab outline that is open at the bottom, so the selected tab flows into the content below.
private struct TabOutline: Shape {
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

private struct TabItemView: View {
    let tab: WorkspaceTab
    let position: Int
    let count: Int
    let isSelected: Bool
    let canDuplicate: Bool
    let hasOthers: Bool
    let hasTabsToRight: Bool
    var onSelect: () -> Void
    var onKeep: () -> Void
    var onClose: () -> Void
    var onDrop: (UUID) -> Bool
    var onSetColor: (TabColor?) -> Void
    var onDuplicate: () -> Void
    var onCloseOthers: () -> Void
    var onCloseToRight: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var dotColor: Color { tab.color.map(Theme.color(for:)) ?? Theme.color(for: tab.accent) }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .italic(tab.isPreview)
            if tab.isDirty {
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close \(tab.title)")
        }
        .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                TabOutline().fill(Theme.background)
            }
        }
        .overlay {
            if isSelected {
                TabOutline().stroke(contrast == .increased ? Theme.separatorStrong : Theme.separator, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            // The user's colour as a top edge (inset so it clears the selected tab's rounded corners).
            if let color = tab.color {
                Capsule().fill(Theme.color(for: color)).frame(height: 2).padding(.horizontal, 8)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // Double-click first so it wins over the single-click select; it keeps a preview tab.
        .onTapGesture(count: 2) { onSelect(); onKeep() }
        .onTapGesture(perform: onSelect)
        .onMiddleClick(perform: onClose)
        .contextMenu { contextMenu }
        // Full Keyboard Access: the tab itself is a stop in the key-view loop; Space/Return selects it.
        .focusable()
        .onKeyPress(.space) { onSelect(); return .handled }
        .onKeyPress(.return) { onSelect(); return .handled }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            return onDrop(id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab") { onClose() }
        .accessibilityAction(named: "Duplicate Tab") { if canDuplicate { onDuplicate() } }
        .accessibilityAction(named: "Keep Tab Open") { onKeep() }
    }

    private var accessibilityLabel: String {
        var label = "\(tab.title), tab \(position) of \(count)"
        if tab.isPreview { label += ", preview" }
        if let color = tab.color { label += ", \(color.displayName.lowercased()) label" }
        if tab.isDirty { label += ", unsaved changes" }
        return label
    }

    @ViewBuilder
    private var contextMenu: some View {
        Menu("Color") {
            Button {
                onSetColor(nil)
            } label: {
                if tab.color == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(TabColor.allCases, id: \.self) { color in
                Button {
                    onSetColor(color)
                } label: {
                    if tab.color == color {
                        Label(color.displayName, systemImage: "checkmark")
                    } else {
                        Text(color.displayName)
                    }
                }
            }
        }
        Button("Duplicate Tab", action: onDuplicate).disabled(!canDuplicate)
        if tab.isPreview { Button("Keep Tab Open", action: onKeep) }
        Divider()
        Button("Close", action: onClose)
        Button("Close Other Tabs", action: onCloseOthers).disabled(!hasOthers)
        Button("Close Tabs to the Right", action: onCloseToRight).disabled(!hasTabsToRight)
    }
}
