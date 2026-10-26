import AppKit
import Testing
@testable import Querywell

/// WCAG contrast audit of the theme tokens. No Core, no network: every colour is resolved in the four
/// appearances (light, dark, and the two Increase Contrast variants) and checked against the surfaces it
/// is drawn on. Normal text needs 4.5:1; large/bold text and non-text UI (borders, dots, focus) need 3:1.
@MainActor
@Suite("Contrast")
struct ContrastTests {
    static let appearances: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
        ("light-hc", .accessibilityHighContrastAqua), ("dark-hc", .accessibilityHighContrastDarkAqua),
    ]

    struct RGB { var r: Double; var g: Double; var b: Double }

    static func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        // The high-contrast appearances cannot be created by name outside a running Increase Contrast session,
        // so they are the base appearance plus the theme's test switch.
        let isHC = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
        let base: NSAppearance.Name = name == .accessibilityHighContrastDarkAqua || name == .darkAqua ? .darkAqua : .aqua
        Thread.current.threadDictionary[NSColor.forceIncreasedContrastKey] = isHC
        defer { Thread.current.threadDictionary[NSColor.forceIncreasedContrastKey] = nil }
        NSAppearance(named: base)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        }
        return out
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    struct Pair {
        var fg: String
        var bg: String
        var minimum: Double
        /// Only enforced in the Increase Contrast appearances (decorative at rest, a boundary when contrast is raised).
        var hcOnly = false
    }

    typealias Named = (String, NSColor)

    /// Foreground token names mapped to colours; backgrounds likewise.
    static let tokens: [String: NSColor] = {
        var t: [String: NSColor] = [:]
        func add(_ n: String, _ c: NSColor) { t[n] = c }
        add("text", ThemeNS.text); add("textSecondary", ThemeNS.textSecondary); add("textTertiary", ThemeNS.textTertiary)
        add("background", ThemeNS.background); add("chrome", ThemeNS.chrome); add("sidebar", ThemeNS.sidebar); add("elevated", ThemeNS.elevated)
        add("selectedRow", ThemeNS.selectedRow); add("accent", ThemeNS.accent); add("accentText", ThemeNS.accentText)
        add("accentSubtleBackground", ThemeNS.accentSubtleBackground); add("accentSubtleText", ThemeNS.accentSubtleText)
        add("cardSelectedBorder", ThemeNS.cardSelectedBorder)
        add("separator", ThemeNS.separator); add("separatorStrong", ThemeNS.separatorStrong); add("gridRule", ThemeNS.gridRule)
        add("chipBackground", ThemeNS.chipBackground); add("chipText", ThemeNS.chipText); add("chipRemoveBackground", ThemeNS.chipRemoveBackground)
        add("tagProduction", ThemeNS.tagProduction); add("tagStaging", ThemeNS.tagStaging); add("tagLocal", ThemeNS.tagLocal)
        add("prodBadgeFill", ThemeNS.prodBadgeFill); add("white", NSColor(hex: 0xFFFFFF))
        add("connectedDot", ThemeNS.connectedDot); add("connectedText", ThemeNS.connectedText)
        add("warningText", ThemeNS.warningText); add("warningBackground", ThemeNS.warningBackground); add("warningAmberFill", ThemeNS.warningAmberFill)
        add("dangerText", ThemeNS.dangerText); add("dangerBackground", ThemeNS.dangerBackground); add("dangerFill", ThemeNS.dangerFill)
        add("tabQuery", ThemeNS.tabQuery)
        add("syntaxKeyword", ThemeNS.syntaxKeyword); add("syntaxString", ThemeNS.syntaxString); add("syntaxFunction", ThemeNS.syntaxFunction)
        add("syntaxNumber", ThemeNS.syntaxNumber); add("syntaxComment", ThemeNS.syntaxComment); add("syntaxVariable", ThemeNS.syntaxVariable)
        add("editorCurrentLine", ThemeNS.editorCurrentLine); add("editorBracketMatch", ThemeNS.editorBracketMatch); add("editorLineNumber", ThemeNS.editorLineNumber)
        add("pendingEditCell", ThemeNS.pendingEditCell); add("pendingEditBar", ThemeNS.pendingEditBar)
        add("pendingPillBackground", ThemeNS.pendingPillBackground); add("pendingPillBorder", ThemeNS.pendingPillBorder); add("pendingPillText", ThemeNS.pendingPillText)
        add("pendingFieldBackground", ThemeNS.pendingFieldBackground); add("pendingDeletedRow", ThemeNS.pendingDeletedRow)
        add("pendingInsertedRow", ThemeNS.pendingInsertedRow); add("pendingInsertedBar", ThemeNS.pendingInsertedBar); add("pendingInsertedText", ThemeNS.pendingInsertedText)
        add("pillPositiveBackground", ThemeNS.pillPositiveBackground); add("pillPositiveText", ThemeNS.pillPositiveText)
        // Editors (JSON / PHP) share the syntax family.
        add("jsonKey", EditorSyntaxColors.key); add("jsonString", EditorSyntaxColors.string)
        add("jsonNumber", EditorSyntaxColors.number); add("jsonLiteral", EditorSyntaxColors.literal)
        // Console and terminal.
        add("consoleBackground", ConsoleThemeNS.background); add("consoleChrome", ConsoleThemeNS.chrome)
        add("consoleText", ConsoleThemeNS.text); add("consoleMuted", ConsoleThemeNS.muted); add("consoleSecondary", ConsoleThemeNS.secondary)
        add("consolePrompt", ConsoleThemeNS.prompt); add("consoleLink", ConsoleThemeNS.link); add("consoleError", ConsoleThemeNS.error)
        add("consoleSuccess", ConsoleThemeNS.success); add("consoleWarning", ConsoleThemeNS.warning)
        add("consoleSegmentTrack", ConsoleThemeNS.segmentTrack); add("consoleSegmentSelected", ConsoleThemeNS.segmentSelected)
        add("consoleSegmentSelectedText", ConsoleThemeNS.segmentSelectedText); add("consoleButtonBorder", ConsoleThemeNS.buttonBorder)
        add("consoleSelection", ConsoleThemeNS.selection)
        add("darkBoxBackground", ConsoleThemeNS.darkBoxBackground); add("darkBoxText", ConsoleThemeNS.darkBoxText)
        add("darkBoxMuted", ConsoleThemeNS.darkBoxMuted); add("darkBoxBlue", ConsoleThemeNS.darkBoxBlue); add("darkBoxHeader", ConsoleThemeNS.darkBoxHeader)
        return t
    }()

    /// Every text-on-background pairing the UI draws, at the normal-text threshold.
    static var pairs: [Pair] {
        var p: [Pair] = []
        func text(_ fgs: [String], on bgs: [String], _ min: Double = 4.5) {
            for f in fgs { for b in bgs { p.append(Pair(fg: f, bg: b, minimum: min)) } }
        }
        let surfaces = ["background", "chrome", "sidebar", "elevated"]
        text(["text", "textSecondary", "textTertiary", "accentText", "tabQuery", "connectedText", "dangerText",
              "chipText", "syntaxComment"], on: surfaces)
        text(["text", "textSecondary", "accentText", "accentSubtleText"], on: ["selectedRow"])
        text(["accentText", "accentSubtleText", "text"], on: ["accentSubtleBackground"])
        text(["chipText", "text"], on: ["chipBackground"])
        text(["accentSubtleText"], on: ["chipRemoveBackground"])
        text(["white"], on: ["prodBadgeFill", "accent", "dangerFill"])
        text(["warningText", "text"], on: ["warningBackground", "warningAmberFill"])
        text(["dangerText", "text"], on: ["dangerBackground", "pendingDeletedRow"])
        text(["text", "textSecondary", "pendingPillText"], on: ["pendingEditCell", "pendingFieldBackground"])
        text(["pendingPillText"], on: ["pendingPillBackground"])
        text(["text", "pendingInsertedText"], on: ["pendingInsertedRow"])
        text(["pillPositiveText"], on: ["pillPositiveBackground"])
        text(["pendingInsertedText"], on: surfaces)
        // SQL editor: syntax colours on the editor background and its current-line / bracket highlights.
        text(["syntaxKeyword", "syntaxString", "syntaxFunction", "syntaxNumber", "syntaxComment", "syntaxVariable", "text", "editorLineNumber"],
             on: ["background", "editorCurrentLine"])
        text(["text"], on: ["editorBracketMatch"])  // brackets are drawn in the text colour
        text(["jsonKey", "jsonString", "jsonNumber", "jsonLiteral", "textSecondary", "text"], on: ["background", "elevated", "chrome"])
        text(["consoleText", "consoleMuted", "consoleSecondary", "consolePrompt", "consoleLink", "consoleError", "consoleSuccess", "consoleWarning"],
             on: ["consoleBackground", "consoleChrome"])
        text(["consoleText", "consoleSecondary", "consoleMuted"], on: ["consoleSegmentTrack"])
        text(["consoleSegmentSelectedText"], on: ["consoleSegmentSelected"])
        text(["consoleText"], on: ["consoleSelection"])
        text(["darkBoxText", "darkBoxMuted", "darkBoxBlue", "darkBoxHeader"], on: ["darkBoxBackground"])
        // Non-text UI: field/card borders, status dots, markers, focus accent. Large text counts here too.
        text(["separatorStrong", "accent", "cardSelectedBorder", "connectedDot", "pendingEditBar", "pendingInsertedBar", "dangerFill"],
             on: ["background"], 3.0)
        text(["tagProduction", "tagStaging", "tagLocal"], on: ["background", "sidebar"], 3.0)
        text(["separatorStrong", "accent", "pendingPillBorder"], on: ["elevated", "chrome"], 3.0)
        text(["pendingEditBar"], on: ["pendingEditCell"], 3.0)
        text(["pendingPillBorder"], on: ["pendingPillBackground"], 3.0)
        text(["pendingInsertedBar"], on: ["pendingInsertedRow"], 3.0)
        text(["accentSubtleText"], on: ["chipRemoveBackground"], 3.0)
        for b in ["background", "chrome", "consoleBackground", "consoleChrome"] { p.append(Pair(fg: "consoleButtonBorder", bg: b, minimum: 3.0, hcOnly: true)) }
        return p
    }

    @Test func everyTextPairingMeetsWCAG() {
        var failures: [String] = []
        var checked = 0
        for (aName, appearance) in Self.appearances {
            for pair in Self.pairs {
                if pair.hcOnly && !aName.hasSuffix("-hc") { continue }
                guard let f = Self.tokens[pair.fg], let b = Self.tokens[pair.bg] else {
                    failures.append("unknown token in \(pair.fg) / \(pair.bg)"); continue
                }
                let r = Self.ratio(Self.resolve(f, appearance), Self.resolve(b, appearance))
                checked += 1
                if r < pair.minimum { failures.append(String(format: "[%@] %@ on %@: %.2f < %.1f", aName, pair.fg, pair.bg, r, pair.minimum)) }
            }
        }
        #expect(checked > 600)
        let report = "\(failures.count) failing pairings:\n" + failures.joined(separator: "\n")
        #expect(failures.isEmpty, Comment(rawValue: report))
    }

    /// Increase Contrast must never lower the contrast of the neutral text tokens or the separators.
    @Test func increaseContrastVariantsAreAtLeastAsStrong() {
        let neutralText = ["text", "textSecondary", "textTertiary", "syntaxComment", "editorLineNumber"]
        for (base, hc, bgNames) in [(NSAppearance.Name.aqua, NSAppearance.Name.accessibilityHighContrastAqua, ["background", "chrome", "sidebar"]),
                                    (.darkAqua, .accessibilityHighContrastDarkAqua, ["background", "chrome", "sidebar"])] {
            for t in neutralText {
                for bg in bgNames {
                    let normal = Self.ratio(Self.resolve(Self.tokens[t]!, base), Self.resolve(Self.tokens[bg]!, base))
                    let high = Self.ratio(Self.resolve(Self.tokens[t]!, hc), Self.resolve(Self.tokens[bg]!, hc))
                    #expect(high >= normal - 0.001, "\(t) on \(bg): \(hc.rawValue) \(high) < \(base.rawValue) \(normal)")
                }
            }
            // Separators become a real 3:1 boundary when Increase Contrast is on.
            for s in ["separator", "separatorStrong"] {
                let r = Self.ratio(Self.resolve(Self.tokens[s]!, hc), Self.resolve(Self.tokens["background"]!, hc))
                #expect(r >= 3.0, "\(s) in \(hc.rawValue) is \(r)")
            }
            let rule = Self.ratio(Self.resolve(Self.tokens["gridRule"]!, hc), Self.resolve(Self.tokens["background"]!, hc))
            #expect(rule >= 1.5, "gridRule in \(hc.rawValue) is \(rule)")
        }
    }
}
