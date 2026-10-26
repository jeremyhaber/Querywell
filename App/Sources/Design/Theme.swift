import AppKit
import SwiftUI
import QuerywellCore

// Semantic colours from design/DESIGN_NOTES.md. Every token has a light value (the design) and a
// dark value chosen so text tokens reach at least 4.5:1 on the dark surfaces they sit on.

extension NSColor {
    /// `0xRRGGBB` in sRGB.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    /// A colour that resolves to `light` or `dark` with the effective appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

/// AppKit flavours of the tokens (for AppKit drawing).
enum ThemeNS {
    static var accent: NSColor { .dynamic(light: 0x2459D6, dark: 0x3E6FE0) }
    static var accentText: NSColor { .dynamic(light: 0x2459D6, dark: 0x8AB0FF) }
    static var accentSubtleBackground: NSColor { .dynamic(light: 0xE3EBFB, dark: 0x24365F) }
    static var accentSubtleText: NSColor { .dynamic(light: 0x173E99, dark: 0xB5CBFF) }
    static var selectedRow: NSColor { .dynamic(light: 0xEEF3FD, dark: 0x25304A) }
    static var cardSelectedBorder: NSColor { .dynamic(light: 0x9DB6EE, dark: 0x5E86E0) }

    static var background: NSColor { .dynamic(light: 0xFFFFFF, dark: 0x1E1F23) }
    static var elevated: NSColor { .dynamic(light: 0xFFFFFF, dark: 0x2C2D33) }
    static var chrome: NSColor { .dynamic(light: 0xF6F6F8, dark: 0x2A2B30) }
    static var sidebar: NSColor { .dynamic(light: 0xFAFAFB, dark: 0x25262B) }
    static var separator: NSColor { .dynamic(light: 0xE2E3E8, dark: 0x3A3C43) }
    static var separatorStrong: NSColor { .dynamic(light: 0xB9BBC4, dark: 0x6A6D78) }
    static var gridRule: NSColor { .dynamic(light: 0xF0F1F4, dark: 0x2E3036) }

    static var text: NSColor { .dynamic(light: 0x1C1D22, dark: 0xECEDF0) }
    static var textSecondary: NSColor { .dynamic(light: 0x5C5F6A, dark: 0xA6A9B4) }
    // Slightly darker than the mockup's #8A8D98 so it passes 4.5:1 on white.
    static var textTertiary: NSColor { .dynamic(light: 0x727581, dark: 0x8F929E) }
    static var chipBackground: NSColor { .dynamic(light: 0xEFF0F3, dark: 0x363840) }
    static var chipText: NSColor { .dynamic(light: 0x45474F, dark: 0xC4C6CF) }

    static var tagProduction: NSColor { .dynamic(light: 0xC4314B, dark: 0xE5566E) }
    static var tagStaging: NSColor { .dynamic(light: 0xE0A030, dark: 0xF0B84A) }
    static var tagLocal: NSColor { .dynamic(light: 0x2E9E5B, dark: 0x4CC37D) }
    /// Fill of the "PROD" badge; white text on it is 5.4:1 in both appearances.
    static var prodBadgeFill: NSColor { NSColor(hex: 0xC4314B) }

    static var connectedDot: NSColor { .dynamic(light: 0x2E9E5B, dark: 0x4CC37D) }
    static var connectedText: NSColor { .dynamic(light: 0x2E7D4F, dark: 0x6FD39A) }
    static var warningText: NSColor { .dynamic(light: 0x8A5A00, dark: 0xF0C060) }
    static var warningBackground: NSColor { .dynamic(light: 0xFFF7E6, dark: 0x3D3114) }
    static var dangerText: NSColor { .dynamic(light: 0xB3261E, dark: 0xFF8A80) }
    static var dangerBackground: NSColor { .dynamic(light: 0xFDECEE, dark: 0x45202A) }

    static var tabQuery: NSColor { .dynamic(light: 0x6A3FC2, dark: 0xA98BF0) }

    // Phase 4 (data grid).
    static var pendingEditCell: NSColor { .dynamic(light: 0xFFF4D6, dark: 0x4A3B12) }
    static var pendingEditBar: NSColor { .dynamic(light: 0xD48806, dark: 0xE8A33A) }
    static var pendingPillBackground: NSColor { .dynamic(light: 0xFFF7E6, dark: 0x3D3114) }
    static var pendingPillBorder: NSColor { .dynamic(light: 0xE8B04A, dark: 0x8A6A25) }
    static var pendingPillText: NSColor { .dynamic(light: 0x7A4B00, dark: 0xF2CD83) }
}

/// SwiftUI flavours of the tokens.
enum Theme {
    static var accent: Color { Color(nsColor: ThemeNS.accent) }
    static var accentText: Color { Color(nsColor: ThemeNS.accentText) }
    static var accentSubtleBackground: Color { Color(nsColor: ThemeNS.accentSubtleBackground) }
    static var accentSubtleText: Color { Color(nsColor: ThemeNS.accentSubtleText) }
    static var selectedRow: Color { Color(nsColor: ThemeNS.selectedRow) }
    static var cardSelectedBorder: Color { Color(nsColor: ThemeNS.cardSelectedBorder) }

    static var background: Color { Color(nsColor: ThemeNS.background) }
    static var elevated: Color { Color(nsColor: ThemeNS.elevated) }
    static var chrome: Color { Color(nsColor: ThemeNS.chrome) }
    static var sidebar: Color { Color(nsColor: ThemeNS.sidebar) }
    static var separator: Color { Color(nsColor: ThemeNS.separator) }
    static var separatorStrong: Color { Color(nsColor: ThemeNS.separatorStrong) }
    static var gridRule: Color { Color(nsColor: ThemeNS.gridRule) }

    static var text: Color { Color(nsColor: ThemeNS.text) }
    static var textSecondary: Color { Color(nsColor: ThemeNS.textSecondary) }
    static var textTertiary: Color { Color(nsColor: ThemeNS.textTertiary) }
    static var chipBackground: Color { Color(nsColor: ThemeNS.chipBackground) }
    static var chipText: Color { Color(nsColor: ThemeNS.chipText) }

    static var tagProduction: Color { Color(nsColor: ThemeNS.tagProduction) }
    static var tagStaging: Color { Color(nsColor: ThemeNS.tagStaging) }
    static var tagLocal: Color { Color(nsColor: ThemeNS.tagLocal) }
    static var prodBadgeFill: Color { Color(nsColor: ThemeNS.prodBadgeFill) }

    static var connectedDot: Color { Color(nsColor: ThemeNS.connectedDot) }
    static var connectedText: Color { Color(nsColor: ThemeNS.connectedText) }
    static var warningText: Color { Color(nsColor: ThemeNS.warningText) }
    static var warningBackground: Color { Color(nsColor: ThemeNS.warningBackground) }
    static var dangerText: Color { Color(nsColor: ThemeNS.dangerText) }
    static var dangerBackground: Color { Color(nsColor: ThemeNS.dangerBackground) }

    static var tabQuery: Color { Color(nsColor: ThemeNS.tabQuery) }

    static var pendingEditCell: Color { Color(nsColor: ThemeNS.pendingEditCell) }
    static var pendingEditBar: Color { Color(nsColor: ThemeNS.pendingEditBar) }
    static var pendingPillBackground: Color { Color(nsColor: ThemeNS.pendingPillBackground) }
    static var pendingPillBorder: Color { Color(nsColor: ThemeNS.pendingPillBorder) }
    static var pendingPillText: Color { Color(nsColor: ThemeNS.pendingPillText) }

    // Radii (design): window 12, cards 10, controls 8, small 6, badges 4.
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let smallRadius: CGFloat = 6
    static let badgeRadius: CGFloat = 4

    /// Dot colour for a tab kind.
    static func color(for accent: TabAccent) -> Color {
        switch accent {
        case .table: accentText
        case .query: tabQuery
        case .console: text
        }
    }
}

// MARK: - Colour tags and hex helpers

extension ColorTag {
    /// The colour to draw for this tag; presets adapt to dark mode, custom tags use their hex.
    var color: Color {
        switch self {
        case .production: Theme.tagProduction
        case .staging: Theme.tagStaging
        case .local: Theme.tagLocal
        case .custom(_, let hex): Color(hex: hex) ?? .gray
        }
    }
}

extension Color {
    /// Parses `#RRGGBB` (the `#` is optional).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(nsColor: NSColor(hex: value))
    }

    /// `#RRGGBB` in sRGB (resolved for the current appearance).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(ns.redComponent), c(ns.greenComponent), c(ns.blueComponent))
    }
}

extension Duration {
    /// Whole milliseconds, rounded down.
    var wholeMilliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
