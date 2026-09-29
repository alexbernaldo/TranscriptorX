#!/usr/bin/env swift

// Genera el fondo de la ventana del DMG de TranscriptorX.
//
// Dibuja un degradado suave, la flecha nativa de macOS (SF Symbols) y el texto
// de instalación. Se renderiza a 2x para que se vea nítido en pantallas Retina.

import AppKit
import Foundation

struct Options {
    var output = ""
    var language = ""
    var width: Int = 640
    var height: Int = 400
    var scale: Int = 2
    var appX = 150
    var appY = 150
    var appsX = 470
    var appsY = 150
    var iconSize = 128
}

var options = Options()
var positional: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let flag = arguments[index]
    let next = index + 1 < arguments.count ? arguments[index + 1] : ""
    switch flag {
    case "--output", "-o": options.output = next; index += 2
    case "--language", "-l": options.language = next; index += 2
    case "--width": options.width = Int(next) ?? 640; index += 2
    case "--height": options.height = Int(next) ?? 400; index += 2
    case "--scale": options.scale = Int(next) ?? 2; index += 2
    case "--app-x": options.appX = Int(next) ?? 150; index += 2
    case "--app-y": options.appY = Int(next) ?? 150; index += 2
    case "--apps-x": options.appsX = Int(next) ?? 470; index += 2
    case "--apps-y": options.appsY = Int(next) ?? 150; index += 2
    case "--icon-size": options.iconSize = Int(next) ?? 128; index += 2
    default: positional.append(flag); index += 1
    }
}

guard !options.output.isEmpty else {
    FileHandle.standardError.write("Falta --output\n".data(using: .utf8)!)
    exit(1)
}
if options.language.isEmpty { options.language = positional.first ?? "en" }

let texts: [String: [String]] = [
    "en": ["Drag TranscriptorX to your Applications folder", "to install it."],
    "es": ["Arrastra TranscriptorX a la carpeta Aplicaciones", "para instalarlo."],
]
let lines = texts[options.language] ?? texts["en"]!

let width = CGFloat(options.width)
let height = CGFloat(options.height)
let scale = CGFloat(options.scale)
let pixelWidth = Int(width * scale)
let pixelHeight = Int(height * scale)

guard let context = CGContext(
    data: nil,
    width: pixelWidth,
    height: pixelHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("No se pudo crear el contexto\n".data(using: .utf8)!)
    exit(1)
}

context.scaleBy(x: scale, y: scale)
context.setAllowsAntialiasing(true)
context.interpolationQuality = CGInterpolationQuality.high

// AppKit trabaja con el eje Y hacia arriba; CoreGraphics, hacia abajo.
let flip = CGAffineTransform(scaleX: 1, y: -1)
context.concatenate(flip)

// Degradado vertical muy suave, de blanco a gris de sistema.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedWhite: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.949, green: 0.949, blue: 0.965, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: height),
    options: []
)

// Geometría: la flecha va centrada entre los dos iconos.
let centerY = CGFloat(options.appY) + CGFloat(options.iconSize) / 2
let gapStart = CGFloat(options.appX) + CGFloat(options.iconSize) + 24
let gapEnd = CGFloat(options.appsX) - 24
let arrowCenterX = (gapStart + gapEnd) / 2

// Flecha nativa de macOS, teñida de gris de sistema.
if let symbol = NSImage(
    systemSymbolName: "arrow.right",
    accessibilityDescription: nil
)?.withSymbolConfiguration(
    .init(pointSize: 56, weight: .medium)
) {
    let targetWidth: CGFloat = 74
    let size = CGSize(
        width: targetWidth,
        height: targetWidth * symbol.size.height / symbol.size.width
    )
    let arrowRect = CGRect(
        x: arrowCenterX - size.width / 2,
        y: centerY - size.height / 2,
        width: size.width,
        height: size.height
    )
    // Se tiñe el símbolo de gris de sistema para que parezca un icono nativo.
    let tinted = NSImage(size: size, flipped: false) { _ in
        NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.51, alpha: 1).set()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        symbol.draw(
            in: CGRect(origin: .zero, size: size),
            from: .zero,
            operation: .destinationIn,
            fraction: 1.0
        )
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    tinted.draw(in: arrowRect)
    NSGraphicsContext.restoreGraphicsState()
}

// Texto centrado bajo la flecha, en la tipografía del sistema.
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
    .paragraphStyle: {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }(),
]

var textY = centerY + 54
for line in lines {
    let attributed = NSAttributedString(string: line, attributes: attributes)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    attributed.draw(at: NSPoint(x: 0, y: textY))
    NSGraphicsContext.restoreGraphicsState()
    textY += 21
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write("No se pudo generar la imagen\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(
    using: NSBitmapImageRep.FileType.png,
    properties: [:]
) else {
    FileHandle.standardError.write("No se pudo codificar el PNG\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: options.output))
print("fondo \(options.language): \(options.output) \(pixelWidth)x\(pixelHeight)")
