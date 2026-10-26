import QuerywellCore
import SwiftUI

/// Horizontal tab strip under the connection header (design: Main.dc.html `nav`).
struct TabStripView: View {
    @Bindable var workspace: ConnectionWorkspace

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 2) {
                tabs
                addButton
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) { tabs }
                addButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36, alignment: .bottom)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Theme.chrome
                Theme.separator.frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open tabs")
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(workspace.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItemView(
                    tab: tab,
                    position: index + 1,
                    count: workspace.tabs.tabs.count,
                    isSelected: workspace.tabs.selectedID == tab.id,
                    onSelect: { workspace.tabs.select(id: tab.id) },
                    onClose: { workspace.requestClose(tab: tab.id) },
                    onDrop: { movedID in reorder(movedID, onto: tab.id) })
            }
        }
    }

    private var addButton: some View {
        Menu {
            Button("New Query") { workspace.newQuery() }
            Button("Console") { workspace.openConsole() }
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
    var onSelect: () -> Void
    var onClose: () -> Void
    var onDrop: (UUID) -> Bool

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.color(for: tab.accent))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onMiddleClick(perform: onClose)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            return onDrop(id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tab.title), tab \(position) of \(count)\(tab.isDirty ? ", unsaved changes" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab") { onClose() }
    }
}
