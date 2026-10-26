import AppKit
import SwiftUI
import QuerywellCore

/// 10pt rounded square in the connection's tag colour (hollow when untagged).
struct ColorTagSwatch: View {
    var tag: ColorTag?
    var size: CGFloat = 10

    var body: some View {
        Group {
            if let tag {
                RoundedRectangle(cornerRadius: 3).fill(tag.color)
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.separatorStrong, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// White "PROD" on the production red.
struct ProdBadge: View {
    var body: some View {
        Text("PROD")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.44)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.prodBadgeFill, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Production connection")
    }
}

/// Small grey chip with the engine name ("MySQL 8.4").
struct EngineChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.chipText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.chipBackground, in: RoundedRectangle(cornerRadius: Theme.badgeRadius))
    }
}

/// Coloured status dot (8pt).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Keyboard hint such as "⌘K".
struct KeyCap: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: Theme.badgeRadius).strokeBorder(Theme.separator))
            .accessibilityHidden(true)
    }
}

/// Section caption in the design's small caps style ("FOLDERS").
struct CaptionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.44)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Accent-filled primary button drawn by us (not system glass), so it reads the same in
/// active/inactive windows and popovers on macOS 26. Dimmed when disabled.
struct AccentFillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// Fill colour; the accent unless a caller needs a variant (destructive confirmations use red).
    var tint: Color?

    init(tint: Color? = nil) { self.tint = tint }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint ?? Theme.accent, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Neutral bordered button drawn by us (sheet secondary actions): white fill, 1pt separator.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var foreground: Color?

    init(foreground: Color? = nil) { self.foreground = foreground }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground ?? Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.elevated.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Selectable monospaced SQL in the design's quiet box (inspector "PENDING SQL", sheets).
struct SQLBox: View {
    var sql: String
    var maxHeight: CGFloat = 160
    var fontSize: CGFloat = 12

    var body: some View {
        ScrollView {
            Text(sql)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        .accessibilityLabel("SQL")
    }
}

/// Amber callout (warnings in sheets, banners).
struct WarningCallout: View {
    var title: String?
    var lines: [String]
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.pendingEditBar).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(.system(size: 12, weight: .semibold)) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.pendingPillText)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pendingPillBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.pendingPillBorder))
        .accessibilityElement(children: .combine)
    }
}

/// Copies `text` to the general pasteboard.
@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
