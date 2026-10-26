import AppKit
import QuerywellCore

// AppKit pieces of the data grid. Nothing here is SwiftUI: cells draw themselves, rows and cells are
// reused by NSTableView, and display strings are computed only for rows that are on screen.

enum GridMetrics {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 34
    static let gutterWidth: CGFloat = 46
    static let cellInset: CGFloat = 10
    static let gutterIdentifier = NSUserInterfaceItemIdentifier("qw.gutter")
    static let minColumnWidth: CGFloat = 64
    static let maxColumnWidth: CGFloat = 380
}

@MainActor
enum GridFonts {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let proportional = NSFont.systemFont(ofSize: 13)
    static let pill = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let gutter = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let headerName = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let headerType = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let nullFont: NSFont = {
        NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), toHaveTrait: .italicFontMask)
    }()

    static func cell(mono useMono: Bool) -> NSFont { useMono ? mono : proportional }
}

/// A grid cell that draws its own text. One instance per visible cell, reused across rows.
final class GridCellView: NSView, NSViewToolTipOwner {
    enum Style {
        case plain, null, link, pill(positive: Bool), gutter
    }

    private(set) var string = ""
    private var style: Style = .plain
    private var font: NSFont = GridFonts.mono
    /// Retained so tooltips can show the full value on demand (truncated or long text only).
    private var value: DatabaseValue = .null
    private var tooltipTag: NSView.ToolTipTag?
    /// Where the clickable part of a foreign-key link is, in view coordinates.
    private(set) var linkRect: NSRect = .zero

    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    func configure(
        value: DatabaseValue, string: String, style: Style, font: NSFont, accessibilityText: String
    ) {
        self.value = value
        self.string = string
        self.style = style
        self.font = font
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        setAccessibilityLabel(accessibilityText)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch style {
        case .gutter, .null: return ""
        default: break
        }
        let text = CellDisplay.full(value)
        // Only worth a tooltip when the cell is clipped or multi-line.
        if text.contains("\n") || text.utf16.count > 40 { return text }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width > bounds.width - GridMetrics.cellInset * 2 ? text : ""
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = GridMetrics.cellInset
        let available = NSRect(x: inset, y: 0, width: max(bounds.width - inset * 2, 0), height: bounds.height)
        switch style {
        case .gutter:
            drawText(string, in: NSRect(x: 0, y: 0, width: bounds.width - 10, height: bounds.height), font: font,
                     color: ThemeNS.textTertiary, alignRight: true)
        case .null:
            drawText(string, in: available, font: GridFonts.nullFont, color: ThemeNS.textTertiary)
        case .plain:
            drawText(string, in: available, font: font, color: ThemeNS.text)
        case .link:
            linkRect = .zero
            let arrow = " ↗"
            let arrowWidth = (arrow as NSString).size(withAttributes: [.font: font]).width
            let textWidth = (string as NSString).size(withAttributes: [.font: font]).width
            let shownTextWidth = min(textWidth, max(available.width - arrowWidth, 0))
            drawText(string, in: NSRect(x: available.minX, y: 0, width: max(available.width - arrowWidth, 0), height: bounds.height),
                     font: font, color: ThemeNS.accentText)
            drawText(arrow, in: NSRect(x: available.minX + shownTextWidth, y: 0, width: arrowWidth + 2, height: bounds.height),
                     font: font, color: ThemeNS.accentText)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            linkRect = NSRect(x: available.minX, y: (bounds.height - lineHeight) / 2, width: shownTextWidth + arrowWidth, height: lineHeight)
        case .pill(let positive):
            let size = (string as NSString).size(withAttributes: [.font: GridFonts.pill])
            let width = min(ceil(size.width) + 16, available.width)
            let rect = NSRect(x: available.minX, y: (bounds.height - 18) / 2, width: width, height: 18)
            (positive ? ThemeNS.pillPositiveBackground : ThemeNS.chipBackground).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            drawText(string, in: rect.insetBy(dx: 8, dy: 0), font: GridFonts.pill,
                     color: positive ? ThemeNS.pillPositiveText : ThemeNS.chipText)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignRight: Bool = false) {
        guard rect.width > 2 else { return }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let target = NSRect(x: rect.minX, y: rect.minY + (rect.height - lineHeight) / 2, width: rect.width, height: lineHeight)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: Self.paragraph]
        if alignRight {
            let p = NSMutableParagraphStyle()
            p.alignment = .right
            p.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = p
        }
        (text as NSString).draw(in: target, withAttributes: attributes)
    }

    override func accessibilityPerformPress() -> Bool { false }
}

/// Row background: selection fill and the hairline under each row.
final class GridRowView: NSTableRowView {
    override var isFlipped: Bool { true }

    override func drawSelection(in dirtyRect: NSRect) {
        ThemeNS.selectedRow.setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        ThemeNS.background.setFill()
        bounds.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ThemeNS.gridRule.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Information a header cell draws (kept on the cell so the header can repaint without the data source).
struct GridHeaderInfo {
    var name = ""
    var typeLabel = ""
    var isPrimaryKey = false
    var showsType = true
    var sortAscending: Bool?
    var sortPriority: Int?
    var isFiltered = false
    var isHovered = false
}

final class GridHeaderCell: NSTableHeaderCell {
    var info = GridHeaderInfo()

    static let funnelSize: CGFloat = 22

    /// The funnel button's frame inside a header cell of `frame`.
    static func funnelRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - funnelSize - 6, y: frame.midY - funnelSize / 2, width: funnelSize, height: funnelSize)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        (info.isFiltered ? ThemeNS.selectedRow : ThemeNS.sidebar).setFill()
        cellFrame.fill()
        ThemeNS.separator.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        // Faint column divider on the right, as the mockup's cell padding implies columns.
        ThemeNS.gridRule.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 8, width: 1, height: cellFrame.height - 16).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var x = cellFrame.minX + GridMetrics.cellInset
        let trailingReserved: CGFloat = GridHeaderCell.funnelSize + 8 + (info.sortAscending != nil ? 14 : 0)
        let limit = cellFrame.maxX - trailingReserved
        let midY = cellFrame.midY

        if info.isPrimaryKey, let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            let image = key.withSymbolConfiguration(config) ?? key
            let size = image.size
            let tinted = Self.tinted(image, color: ThemeNS.pendingEditBar)
            tinted.draw(in: NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + 5
        }
        let name = NSAttributedString(string: info.name, attributes: [.font: GridFonts.headerName, .foregroundColor: ThemeNS.text])
        let nameSize = name.size()
        let nameWidth = min(nameSize.width, max(limit - x, 0))
        drawClipped(name, x: x, midY: midY, width: nameWidth)
        x += nameWidth + 6
        if info.showsType, x < limit - 16 {
            let type = NSAttributedString(string: info.typeLabel, attributes: [.font: GridFonts.headerType, .foregroundColor: ThemeNS.textTertiary])
            drawClipped(type, x: x, midY: midY, width: min(type.size().width, limit - x))
        }

        // Trailing: sort indicator then funnel.
        let funnel = Self.funnelRect(in: cellFrame)
        if let ascending = info.sortAscending {
            let symbol = ascending ? "chevron.up" : "chevron.down"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
                let tinted = Self.tinted(image, color: ThemeNS.accentText)
                tinted.draw(in: NSRect(x: funnel.minX - 12, y: midY - image.size.height / 2, width: image.size.width, height: image.size.height))
            }
            if let priority = info.sortPriority {
                let text = NSAttributedString(string: "\(priority)", attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: ThemeNS.accentText])
                text.draw(at: NSPoint(x: funnel.minX - 5, y: midY - 9))
            }
        }
        if info.isFiltered || info.isHovered {
            let name = info.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
                let tinted = Self.tinted(image, color: info.isFiltered ? ThemeNS.accent : ThemeNS.textSecondary)
                tinted.draw(in: NSRect(x: funnel.midX - image.size.width / 2, y: midY - image.size.height / 2,
                                       width: image.size.width, height: image.size.height))
            }
        }
    }

    private func drawClipped(_ text: NSAttributedString, x: CGFloat, midY: CGFloat, width: CGFloat) {
        guard width > 2 else { return }
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: x, y: midY - size.height, width: width, height: size.height * 2).clip()
        text.draw(at: NSPoint(x: x, y: midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return copy
    }
}

/// Header that reports hover and funnel clicks, and leaves everything else (resize, reorder, sort
/// clicks) to NSTableView.
final class GridHeaderView: NSTableHeaderView {
    var onFunnelClick: ((Int, NSRect) -> Void)?
    var onHoverChange: ((Int?) -> Void)?
    private var hoveredColumn: Int?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        setHover(column >= 0 ? column : nil)
    }

    private func setHover(_ column: Int?) {
        guard column != hoveredColumn else { return }
        hoveredColumn = column
        onHoverChange?(column)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column > 0, let table = tableView, table.tableColumns[column].identifier != GridMetrics.gutterIdentifier {
            let frame = headerRect(ofColumn: column)
            let funnel = GridHeaderCell.funnelRect(in: frame)
            if funnel.contains(point) {
                onFunnelClick?(column, funnel)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
