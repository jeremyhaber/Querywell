#!/usr/bin/env swift
// Generates the placeholder app icon into App/Resources/Assets.xcassets/AppIcon.appiconset.
// Reproducible: `swift scripts/make-icon.swift [output-dir]` (CoreGraphics/AppKit only, no third-party tools).
// Design: light rounded-square ground, accent #2459D6 database "well" (stacked cylinder) with a
// query prompt glyph (> and cursor) on its face. Replace with final art later.
import AppKit
import CoreGraphics

let accent = CGColor(red: 0x24 / 255, green: 0x59 / 255, blue: 0xD6 / 255, alpha: 1)
let accentDark = CGColor(red: 0x1A / 255, green: 0x43 / 255, blue: 0xA8 / 255, alpha: 1)
let accentLight = CGColor(red: 0x4F / 255, green: 0x82 / 255, blue: 0xEE / 255, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func render(size px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: s, y: s)

    // Apple macOS icon grid: 824pt rounded square centred in 1024, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(tilePath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let ground = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.985, green: 0.989, blue: 1.0, alpha: 1),
        CGColor(red: 0.886, green: 0.918, blue: 0.984, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Cylinder geometry
    let cx: CGFloat = 512, w: CGFloat = 400, rx = w / 2, ry: CGFloat = 78
    let top: CGFloat = 690, bottom: CGFloat = 330
    let k: CGFloat = 0.56 // bezier ellipse constant (approx.)
    let cyl = CGMutablePath()
    cyl.move(to: CGPoint(x: cx - rx, y: top))
    cyl.addLine(to: CGPoint(x: cx - rx, y: bottom))
    cyl.addCurve(to: CGPoint(x: cx, y: bottom - ry),
                 control1: CGPoint(x: cx - rx, y: bottom - ry * k), control2: CGPoint(x: cx - rx * k, y: bottom - ry))
    cyl.addCurve(to: CGPoint(x: cx + rx, y: bottom),
                 control1: CGPoint(x: cx + rx * k, y: bottom - ry), control2: CGPoint(x: cx + rx, y: bottom - ry * k))
    cyl.addLine(to: CGPoint(x: cx + rx, y: top))
    cyl.closeSubpath()

    // soft contact shadow under the well
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: CGColor(red: 0.08, green: 0.2, blue: 0.5, alpha: 0.35))
    ctx.setFillColor(accent)
    ctx.addPath(cyl)
    ctx.fillPath()
    ctx.restoreGState()

    // body shading (left to right)
    ctx.saveGState()
    ctx.addPath(cyl)
    ctx.clip()
    let shade = CGGradient(colorsSpace: space, colors: [accentDark, accent, accentLight, accent, accentDark] as CFArray,
                           locations: [0, 0.22, 0.42, 0.75, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: cx - rx, y: 0), end: CGPoint(x: cx + rx, y: 0), options: [])
    ctx.restoreGState()

    func ellipse(_ cy: CGFloat) -> CGRect { CGRect(x: cx - rx, y: cy - ry, width: w, height: ry * 2) }

    // two light seams following the curvature (front half of an ellipse only)
    for cy in [top - 120, top - 240] as [CGFloat] {
        ctx.saveGState()
        ctx.addPath(cyl)
        ctx.clip()
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: cy))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: ellipse(cy))
        ctx.restoreGState()
    }

    // top cap
    let cap = ellipse(top)
    ctx.saveGState()
    ctx.addEllipse(in: cap)
    ctx.clip()
    let capG = CGGradient(colorsSpace: space, colors: [accentLight, CGColor(red: 0.30, green: 0.52, blue: 0.93, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(capG, start: CGPoint(x: cx, y: cap.maxY), end: CGPoint(x: cx, y: cap.minY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: cap.insetBy(dx: 3, dy: 3))
    // dark "well" opening on the cap
    ctx.setFillColor(CGColor(red: 0.08, green: 0.19, blue: 0.52, alpha: 0.9))
    ctx.fillEllipse(in: cap.insetBy(dx: 70, dy: 26))

    // prompt glyph on the front face: ">" and a cursor bar
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(34)
    ctx.move(to: CGPoint(x: 400, y: 545))
    ctx.addLine(to: CGPoint(x: 462, y: 485))
    ctx.addLine(to: CGPoint(x: 400, y: 425))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 500, y: 420))
    ctx.addLine(to: CGPoint(x: 612, y: 420))
    ctx.strokePath()
    ctx.restoreGState()

    // subtle tile edge highlight
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
    ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.strokePath()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let outDir: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let root = script.deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
}()
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(size: base * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
