#!/usr/bin/env swift

// Genera el fondo de la ventana del DMG de Transcriptor X.
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
    "en": ["Drag Transcriptor X to your Applications folder", "to install it."],
    "es": ["Arrastra Transcriptor X a la carpeta Aplicaciones", "para instalarlo."],
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

// Origen arriba a la izquierda, como las posiciones de Finder. Sin la traslación,
// la inversión del eje Y dejaba todo el dibujo fuera del lienzo (fondo vacío).
context.translateBy(x: 0, y: height)
context.scaleBy(x: 1, y: -1)

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

// Geometría: Finder coloca cada icono por su centro, así que la flecha va
// centrada entre los dos centros y a su misma altura.
let centerY = CGFloat(options.appY)
let gapStart = CGFloat(options.appX) + CGFloat(options.iconSize) / 2 + 24
let gapEnd = CGFloat(options.appsX) - CGFloat(options.iconSize) / 2 - 24
let arrowCenterX = (gapStart + gapEnd) / 2

// Flecha nativa de macOS en gris de sistema. Se tiñe con la paleta del símbolo:
// rellenar un rectángulo y recortarlo con el símbolo dejaba una línea en el borde.
let arrowColor = NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.51, alpha: 1)
if let symbol = NSImage(
    systemSymbolName: "arrow.right",
    accessibilityDescription: nil
)?.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 56, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [arrowColor]))
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
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    symbol.draw(in: arrowRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

// Debajo de los nombres de los iconos.
var textY = centerY + CGFloat(options.iconSize) / 2 + 52
for line in lines {
    let attributed = NSAttributedString(string: line, attributes: attributes)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    attributed.draw(in: CGRect(x: 0, y: textY, width: width, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    textY += 21
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write("No se pudo generar la imagen\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
// Tamaño en puntos = ventana: el PNG queda a 144 ppp y Finder lo dibuja a 2x en
// lugar de a tamaño doble (que dejaba flecha y texto fuera de la ventana).
rep.size = NSSize(width: width, height: height)
guard let data = rep.representation(
    using: NSBitmapImageRep.FileType.png,
    properties: [:]
) else {
    FileHandle.standardError.write("No se pudo codificar el PNG\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: options.output))
print("fondo \(options.language): \(options.output) \(pixelWidth)x\(pixelHeight)")
