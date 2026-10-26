import AppKit
import SwiftUI

/// Colours of the console and terminal surfaces. Dark values are the design's (Console.dc.html); the light
/// values are the same roles on a light surface.
enum ConsoleThemeNS {
    static var background: NSColor { .dynamic(light: 0xFBFBFC, dark: 0x16171C) }
    static var chrome: NSColor { .dynamic(light: 0xF1F2F5, dark: 0x1E1F25) }
    static var border: NSColor { .dynamic(light: 0xE2E3E8, dark: 0x2A2C34) }
    static var text: NSColor { .dynamic(light: 0x1C1D22, dark: 0xE6E7EB) }
    static var muted: NSColor { .dynamic(light: 0x626570, dark: 0x9296A3, lightHC: 0x484B56, darkHC: 0xC0C3CC) }
    static var secondary: NSColor { .dynamic(light: 0x5C5F6A, dark: 0xB4B7C1) }
    static var prompt: NSColor { .dynamic(light: 0x2459D6, dark: 0x7FA8FF) }
    static var link: NSColor { .dynamic(light: 0x2459D6, dark: 0x7FA8FF) }
    static var error: NSColor { .dynamic(light: 0xB3261E, dark: 0xFF8A9B) }
    static var success: NSColor { .dynamic(light: 0x1F6B3F, dark: 0x7DD6A0) }
    static var warning: NSColor { .dynamic(light: 0x8A5A00, dark: 0xF0C060) }
    static var segmentTrack: NSColor { .dynamic(light: 0xE6E7EC, dark: 0x2A2C34) }
    static var segmentSelected: NSColor { .dynamic(light: 0xFFFFFF, dark: 0x3A3D47) }
    static var segmentSelectedText: NSColor { .dynamic(light: 0x1C1D22, dark: 0xFFFFFF) }
    // Outline of a labelled button: decorative at rest, a 3:1 boundary under Increase Contrast.
    static var buttonBorder: NSColor { .dynamic(light: 0xCDCFD6, dark: 0x3A3D47, lightHC: 0x84899A, darkHC: 0x7A7F92) }
    static var caret: NSColor { .dynamic(light: 0x1C1D22, dark: 0xE6E7EB) }
    static var selection: NSColor { .dynamic(light: 0xC9D7F5, dark: 0x34518A) }

    static func color(for role: ConsoleRole) -> NSColor {
        switch role {
        case .prompt: prompt
        case .input, .text, .row, .footer: text
        case .muted, .border, .header: muted
        case .success: success
        case .error: error
        case .warning: warning
        case .link: link
        }
    }

    static let fontSize: CGFloat = 13
    static var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    static var boldFont: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .medium) }
}

enum ConsoleTheme {
    static var background: Color { Color(nsColor: ConsoleThemeNS.background) }
    static var chrome: Color { Color(nsColor: ConsoleThemeNS.chrome) }
    static var border: Color { Color(nsColor: ConsoleThemeNS.border) }
    static var text: Color { Color(nsColor: ConsoleThemeNS.text) }
    static var muted: Color { Color(nsColor: ConsoleThemeNS.muted) }
    static var secondary: Color { Color(nsColor: ConsoleThemeNS.secondary) }
    static var prompt: Color { Color(nsColor: ConsoleThemeNS.prompt) }
    static var segmentTrack: Color { Color(nsColor: ConsoleThemeNS.segmentTrack) }
    static var segmentSelected: Color { Color(nsColor: ConsoleThemeNS.segmentSelected) }
    static var segmentSelectedText: Color { Color(nsColor: ConsoleThemeNS.segmentSelectedText) }
    static var buttonBorder: Color { Color(nsColor: ConsoleThemeNS.buttonBorder) }
}
