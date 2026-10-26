import AppKit
import QuerywellCore
import SwiftUI

// Pieces shared by the export, import and result-export sheets (design: Export.dc.html).

/// "WHERE IT RUNS", "CONTENT": 11pt semibold, tracked, secondary.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.44)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A radio card (the "where it runs" choice): selected = 1.5pt accent border on a tinted fill.
struct ChoiceCard<Content: View>: View {
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) { content() }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(isSelected ? Theme.accentSubtleBackground.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(isSelected ? Theme.accent : Theme.separator, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small tinted tag ("Recommended").
struct TagPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accentSubtleText)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.accentSubtleBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }
}

/// An amber notice (tool problems, plan warnings).
struct AmberNote: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Theme.pendingEditBar).font(.system(size: 12)).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.pendingPillText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.pendingPillBorder.opacity(0.7)))
        .textSelection(.enabled)
    }
}

/// A red notice for failures.
struct ErrorNote: View {
    let title: String
    var detail: String?
    var mono: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.dangerText).font(.system(size: 12)).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dangerText)
            }
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
            if let mono {
                Text(mono)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .textSelection(.enabled)
    }
}

/// The design's 6pt rounded progress bar.
struct SlimProgressBar: View {
    let fraction: Double
    var label = "Progress"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chipBackground)
                Capsule().fill(Theme.accent).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// The dark command box (also used for SQL previews): SF Mono 12, 1.6 line height.
struct CommandBox: View {
    let attributed: AttributedString
    var maxHeight: CGFloat = 170

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(attributed)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
    }

    /// Light syntax colouring: comments muted, the tool name blue.
    static func highlight(_ command: String) -> AttributedString {
        var out = AttributedString()
        let tools: Set<String> = ["ssh", "mysqldump", "mariadb-dump", "pg_dump"]
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            let text = String(line)
            var attr = AttributedString(text)
            attr.foregroundColor = Color(nsColor: ConsoleThemeNS.darkBoxText)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                attr.foregroundColor = Color(nsColor: ConsoleThemeNS.darkBoxMuted)
            } else if let first = text.split(separator: " ").first, tools.contains(String((first as Substring).split(separator: "/").last ?? first)),
                      let range = attr.range(of: String(first)) {
                attr[range].foregroundColor = Color(nsColor: ConsoleThemeNS.darkBoxBlue)
            }
            out.append(attr)
            if i < lines.count - 1 { out.append(AttributedString("\n")) }
        }
        return out
    }
}

extension ConsoleThemeNS {
    /// The export dialog's command box is dark in both appearances (Export.dc.html: #16171C).
    static var darkBoxBackground: NSColor { NSColor(hex: 0x16171C) }
    static var darkBoxText: NSColor { NSColor(hex: 0xE6E7EB) }
    static var darkBoxMuted: NSColor { NSColor(hex: 0x8E92A0) }
    static var darkBoxBlue: NSColor { NSColor(hex: 0x7FA8FF) }
    static var darkBoxHeader: NSColor { NSColor(hex: 0xC9CBD3) }
}

extension TimeInterval {
    /// `0:07`, `12:30`, `1:02:03`.
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum Reveal {
    @MainActor static func inFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
