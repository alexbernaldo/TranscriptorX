#!/usr/bin/env swift
// Generates the Transcriptor X brand assets from the «Cruce» geometry (design spec 2.1–2.3, 6.15).
//
//   swift scripts/make_brand_assets.swift
//
// Writes:
//   TranscriptorNative/Resources/Assets.xcassets/AppIcon.appiconset/*.png   (Dock icon, all sizes)
//   TranscriptorNative/Resources/TranscriptorDocument.icns                   (.transcriptor document icon)
//   TranscriptorNative/Resources/AppIcon.icon/                              (Icon Composer document, 3 layers)
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("TranscriptorNative/Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: Geometry (32-unit grid, centre line of the 4-unit round-capped stroke)

struct Mark {
    static let a = (CGPoint(x: 7, y: 25), CGPoint(x: 25, y: 7))
    static let dot = CGPoint(x: 7, y: 7)
    static let frag = (CGPoint(x: 11, y: 11), CGPoint(x: 12, y: 12))
    static let b = (CGPoint(x: 16, y: 16), CGPoint(x: 25, y: 25))
}

/// Draws the mark in `rect` (top-left origin grid mapped into a flipped context).
func drawMark(in ctx: CGContext, rect: CGRect, stroke: CGFloat, reduced: Bool,
              colorA: NSColor, colorFragment: NSColor, colorB: NSColor) {
    func p(_ q: CGPoint) -> CGPoint { CGPoint(x: rect.minX + q.x / 32 * rect.width, y: rect.minY + q.y / 32 * rect.height) }
    let w = stroke / 32 * rect.width
    ctx.setLineCap(.round)
    ctx.setLineWidth(w)
    func line(_ s: CGPoint, _ e: CGPoint, _ c: NSColor) {
        ctx.setStrokeColor(c.cgColor)
        ctx.move(to: p(s)); ctx.addLine(to: p(e)); ctx.strokePath()
    }
    line(Mark.a.0, Mark.a.1, colorA)
    if !reduced {
        ctx.setFillColor(colorFragment.cgColor)
        let c = p(Mark.dot)
        ctx.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w))
    }
    line(Mark.frag.0, Mark.frag.1, colorFragment)
    line(Mark.b.0, Mark.b.1, colorB)
}

func bitmap(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    // Flip so y grows downwards like the 32-unit grid.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// macOS icon template: 824/1024 body with a continuous corner (≈ 22.37 % radius).
func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.height * 0.2237, transform: nil)
}

// MARK: Dock icon (spec 2.3)

func appIcon(pixels: Int) -> Data {
    bitmap(pixels) { ctx, s in
        let scale = s / 1024
        let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let small = pixels <= 32 * 2 && pixels <= 64
        ctx.saveGState()
        ctx.addPath(squircle(body)); ctx.clip()
        if pixels <= 32 {
            // 16 and 32 px: flat #16141C and the reduced symbol.
            ctx.setFillColor(color(0x16141C).cgColor); ctx.fill(body)
        } else {
            // The only gradient of the identity: #1E1B27 top to #121116 bottom.
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x1E1B27).cgColor, color(0x121116).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.maxY), options: [])
            // 2 px inner border at white 8 %, top third only.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height / 3))
            ctx.addPath(squircle(body.insetBy(dx: 1 * scale, dy: 1 * scale)))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.08).cgColor)
            ctx.setLineWidth(2 * scale)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        _ = small
        // Symbol: 512 × 512 centred (1 unit = 16 px at 1024).
        let symbol = CGRect(x: 256 * scale, y: 256 * scale, width: 512 * scale, height: 512 * scale)
        let reduced = pixels <= 32
        let stroke: CGFloat = pixels < 16 * 2 && pixels <= 16 ? 4.5 : 4
        drawMark(in: ctx, rect: symbol, stroke: stroke, reduced: reduced,
                 colorA: color(0xEDEBF2), colorFragment: color(0xB9A9FF, 0.70), colorB: color(0x7C5CFF))
    }
}

// MARK: Document icon (spec 6.15): folded page on bg.surface, reduced symbol, «TRANSCRIPTOR» label

func documentIcon(pixels: Int) -> Data {
    bitmap(pixels) { ctx, s in
        let u = s / 32
        let page = CGRect(x: 5 * u, y: 2 * u, width: 22 * u, height: 28 * u)
        let fold = 6 * u
        let path = CGMutablePath()
        path.move(to: CGPoint(x: page.minX, y: page.minY))
        path.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
        path.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        path.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
        path.addLine(to: CGPoint(x: page.minX, y: page.maxY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color(0x1B1A22).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(color(0x34313F).cgColor)
        ctx.setLineWidth(max(1, s / 256))
        ctx.strokePath()
        // Fold
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
        corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
        corner.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        corner.closeSubpath()
        ctx.addPath(corner)
        ctx.setFillColor(color(0x2C2A37).cgColor)
        ctx.fillPath()
        // Reduced symbol centred.
        let symbolSide = 14 * u
        let symbol = CGRect(x: page.midX - symbolSide / 2, y: page.minY + 6 * u, width: symbolSide, height: symbolSide)
        drawMark(in: ctx, rect: symbol, stroke: pixels < 32 ? 4.5 : 4, reduced: true,
                 colorA: color(0xEDEBF2), colorFragment: color(0xB9A9FF, 0.70), colorB: color(0x7C5CFF))
        // «TRANSCRIPTOR» at 11 pt (relative to a 128 pt icon) at the base.
        if pixels >= 64 {
            let fontSize = 11 * s / 128
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color(0xA9A5B5),
                .kern: fontSize * 0.08
            ]
            let text = NSAttributedString(string: "TRANSCRIPTOR", attributes: attrs)
            let size = text.size()
            ctx.saveGState()
            ctx.translateBy(x: 0, y: s)
            ctx.scaleBy(x: 1, y: -1)
            let y = s - (page.maxY - 3 * u) - size.height / 2
            text.draw(at: CGPoint(x: page.midX - size.width / 2, y: y))
            ctx.restoreGState()
        }
    }
}

// MARK: Write files

let fm = FileManager.default
let iconset = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, scale) in sizes {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try appIcon(pixels: pt * scale).write(to: iconset.appendingPathComponent(name))
}

let docIconset = fm.temporaryDirectory.appendingPathComponent("TranscriptorDocument.iconset")
try? fm.removeItem(at: docIconset)
try fm.createDirectory(at: docIconset, withIntermediateDirectories: true)
for (pt, scale) in sizes {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try documentIcon(pixels: pt * scale).write(to: docIconset.appendingPathComponent(name))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", docIconset.path, "-o", resources.appendingPathComponent("TranscriptorDocument.icns").path]
try iconutil.run(); iconutil.waitUntilExit()

// Icon Composer document (macOS 26): background, stroke A and stroke B as separate layers so the
// system can build the dark, clear, tinted and transparent variants (spec 2.3).
let iconDoc = resources.appendingPathComponent("AppIcon.icon")
let assets = iconDoc.appendingPathComponent("Assets")
try? fm.removeItem(at: iconDoc)
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
// Layers are drawn on a 1024 canvas; the symbol is 512 centred (1 unit = 16 px, 64 px stroke).
func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\(body)</svg>\n"
}
func px(_ u: CGFloat) -> CGFloat { 256 + u * 16 }
let strokeA = "<line x1=\"\(px(7))\" y1=\"\(px(25))\" x2=\"\(px(25))\" y2=\"\(px(7))\" stroke=\"#EDEBF2\" stroke-width=\"64\" stroke-linecap=\"round\"/>"
let strokeB = "<circle cx=\"\(px(7))\" cy=\"\(px(7))\" r=\"32\" fill=\"#B9A9FF\" fill-opacity=\"0.7\"/>"
    + "<line x1=\"\(px(11))\" y1=\"\(px(11))\" x2=\"\(px(12))\" y2=\"\(px(12))\" stroke=\"#B9A9FF\" stroke-opacity=\"0.7\" stroke-width=\"64\" stroke-linecap=\"round\"/>"
    + "<line x1=\"\(px(16))\" y1=\"\(px(16))\" x2=\"\(px(25))\" y2=\"\(px(25))\" stroke=\"#7C5CFF\" stroke-width=\"64\" stroke-linecap=\"round\"/>"
try svg(strokeA).write(to: assets.appendingPathComponent("StrokeA.svg"), atomically: true, encoding: .utf8)
try svg(strokeB).write(to: assets.appendingPathComponent("StrokeB.svg"), atomically: true, encoding: .utf8)
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.11765,0.10588,0.15294,1.00000",
      "srgb:0.07059,0.06667,0.08627,1.00000"
    ],
    "orientation" : {
      "start" : { "x" : 0.5, "y" : 0 },
      "stop" : { "x" : 0.5, "y" : 1 }
    }
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "StrokeB.svg", "name" : "StrokeB" }
      ],
      "name" : "Stroke B",
      "specular" : false
    },
    {
      "layers" : [
        { "image-name" : "StrokeA.svg", "name" : "StrokeA" }
      ],
      "name" : "Stroke A",
      "specular" : false
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
"""
try iconJSON.write(to: iconDoc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Brand assets written")
