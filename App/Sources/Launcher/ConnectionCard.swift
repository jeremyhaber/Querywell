import QuerywellCore
import SwiftUI

/// One saved connection in the launcher grid. A single accessibility element.
struct ConnectionCard: View {
    let profile: ConnectionProfile
    let summary: ConnectionSummary
    let isSelected: Bool
    let now: Date
    var onSelect: () -> Void
    var onConnect: (_ newWindow: Bool) -> Void
    var onEdit: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var lastUsed: String { summary.lastUsedLabel(relativeTo: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ColorTagSwatch(tag: profile.colorTag)
                Text(profile.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if profile.favourite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tagStaging)
                }
                Spacer(minLength: 4)
                EngineChip(text: summary.engineLabel)
            }
            Text(summary.endpointLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.chipText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Label(summary.accessLabel, systemImage: "lock")
                    .labelStyle(CompactLabelStyle())
                Text(lastUsed)
                Spacer(minLength: 4)
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Connect") {
                    onConnect(NSEvent.modifierFlags.contains(.option))
                }
                .buttonStyle(SubtleAccentButtonStyle())
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture(count: 2) {
            onConnect(NSEvent.modifierFlags.contains(.option))
        }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Connect") { onConnect(false) }
        .accessibilityAction(named: "Connect in New Window") { onConnect(true) }
        .accessibilityAction(named: "Edit") { onEdit() }
    }

    private var borderColor: Color {
        if isSelected { return Theme.cardSelectedBorder }
        return contrast == .increased ? Theme.separatorStrong : Theme.separator
    }

    /// "sunset-web01, Production, MySQL, via SSH key, last used 2 min ago"
    var accessibilityDescription: String {
        var parts = [profile.name]
        if let tag = profile.colorTag { parts.append(tag.displayName) }
        parts.append(profile.engine.displayName)
        parts.append(profile.ssh != nil ? "via \(summary.accessLabel)" : summary.accessLabel)
        parts.append(summary.lastUsedAt == nil ? "never used" : "last used \(lastUsed)")
        if profile.favourite { parts.append("favourite") }
        return parts.joined(separator: ", ")
    }
}

/// Icon + text with a tight gap, for metadata rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}
