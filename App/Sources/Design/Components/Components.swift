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
