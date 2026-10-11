import SwiftUI
import AppKit

// MARK: - «Cruce» symbol (spec 2.1)
//
// 32 × 32 unit grid, 4-unit stroke, round caps, no fill.
//   Stroke A (continuous, the text):      (7, 25) → (25, 7)
//   Stroke B, fragment 1 (audio sample):  dot at (7, 7), Ø 4
//   Stroke B, fragment 2 (audio sample):  (11, 11) → (12, 12)
//   Stroke B, continuous (the signal):    (16, 16) → (25, 25)
// The 1.66-unit gap between fragments is a consequence of these coordinates.

enum CruceGeometry {
    static let grid: CGFloat = 32
    static let stroke: CGFloat = 4
    /// Below 16 px the stroke grows to keep its weight.
    static let smallStroke: CGFloat = 4.5

    static let aStart = CGPoint(x: 7, y: 25)
    static let aEnd = CGPoint(x: 25, y: 7)
    static let dotCenter = CGPoint(x: 7, y: 7)
    static let fragStart = CGPoint(x: 11, y: 11)
    static let fragEnd = CGPoint(x: 12, y: 12)
    static let bStart = CGPoint(x: 16, y: 16)
    static let bEnd = CGPoint(x: 25, y: 25)

    /// The three equal fragments used by the menu-bar "queue active" state.
    static let queueFragments: [(CGPoint, CGPoint)] = {
        // The continuous part of B (16 → 25) split into three equal dashes separated by
        // the same 1.66-unit rhythm gap as the fragments. Measured on the diagonal,
        // including the round caps (radius 2).
        let r2 = CGFloat(2).squareRoot()
        let visualStart = 16 * r2 - 2
        let visualEnd = 25 * r2 + 2
        let gap: CGFloat = 1.66
        let dash = (visualEnd - visualStart - 2 * gap) / 3
        return (0..<3).map { i in
            let a = visualStart + CGFloat(i) * (dash + gap) + 2
            let b = a + dash - 4
            return (CGPoint(x: a / r2, y: a / r2), CGPoint(x: b / r2, y: b / r2))
        }
    }()

    static func scaled(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x / grid * rect.width, y: rect.minY + p.y / grid * rect.height)
    }

    static func strokeWidth(for side: CGFloat, override: CGFloat? = nil) -> CGFloat {
        let units = override ?? (side < 16 ? smallStroke : stroke)
        return units / grid * side
    }
}

/// Individual parts of the mark as shapes so they can be coloured and drawn separately.
struct CruceSegment: Shape {
    var from: CGPoint
    var to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CruceGeometry.scaled(from, in: rect))
        p.addLine(to: CruceGeometry.scaled(to, in: rect))
        return p
    }
}

struct CruceDot: Shape {
    var center: CGPoint
    func path(in rect: CGRect) -> Path {
        // The dot is a zero-length stroke with a round cap: Ø = stroke width.
        var p = Path()
        let c = CruceGeometry.scaled(center, in: rect)
        p.move(to: c)
        p.addLine(to: CGPoint(x: c.x + 0.001, y: c.y + 0.001))
        return p
    }
}

/// Colour scheme of the mark.
enum CruceStyle {
    /// Brand colours for the current appearance (spec 2.1).
    case brand
    /// Brand colours forced to the dark-surface values (opening animation, Dock icon, HUDs).
    case brandOnDark
    /// One colour at 100 %; fragments keep their geometry.
    case mono(Color)
}

struct CruceSymbol: View {
    var style: CruceStyle = .brand
    /// Reduced version (≤ 24 pt): drops the (7, 7) dot.
    var reduced: Bool? = nil
    /// Drawing progress for the opening animation (0…1 for each part).
    var dotProgress: CGFloat = 1
    var fragmentProgress: CGFloat = 1
    var continuousProgress: CGFloat = 1
    var strokeAProgress: CGFloat = 1
    /// Menu-bar "queue active": continuous part drawn as three equal fragments.
    var dashedContinuous = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let isReduced = reduced ?? (side <= 24)
            let width = CruceGeometry.strokeWidth(for: side)
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round)
            let colors = palette
            ZStack {
                // Stroke A: continuous, the resulting text.
                CruceSegment(from: CruceGeometry.aStart, to: CruceGeometry.aEnd)
                    .trim(from: 0, to: strokeAProgress)
                    .stroke(colors.a, style: stroke)
                if !isReduced {
                    CruceDot(center: CruceGeometry.dotCenter)
                        .stroke(colors.fragment, style: stroke)
                        .scaleEffect(0.4 + 0.6 * dotProgress, anchor: anchor(CruceGeometry.dotCenter))
                        .opacity(dotProgress)
                }
                CruceSegment(from: CruceGeometry.fragStart, to: CruceGeometry.fragEnd)
                    .stroke(colors.fragment, style: stroke)
                    .scaleEffect(0.4 + 0.6 * fragmentProgress, anchor: anchor(CGPoint(x: 11.5, y: 11.5)))
                    .opacity(fragmentProgress)
                if dashedContinuous {
                    ForEach(0..<CruceGeometry.queueFragments.count, id: \.self) { i in
                        let f = CruceGeometry.queueFragments[i]
                        CruceSegment(from: f.0, to: f.1).stroke(colors.continuous, style: stroke)
                    }
                } else {
                    // Continuous part of B grows from the crossing (16, 16).
                    CruceSegment(from: CruceGeometry.bStart, to: CruceGeometry.bEnd)
                        .trim(from: 0, to: continuousProgress)
                        .stroke(colors.continuous, style: stroke)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func anchor(_ p: CGPoint) -> UnitPoint {
        UnitPoint(x: p.x / CruceGeometry.grid, y: p.y / CruceGeometry.grid)
    }

    private var palette: (a: Color, fragment: Color, continuous: Color) {
        switch style {
        case .mono(let color):
            return (color, color, color)
        case .brandOnDark:
            return Self.darkPalette
        case .brand:
            return colorScheme == .dark ? Self.darkPalette : Self.lightPalette
        }
    }

    static let darkPalette = (a: Color(nsColor: TX.Palette.paper),
                              fragment: Color(nsColor: TX.Palette.purple300).opacity(0.70),
                              continuous: Color(nsColor: TX.Palette.purpleX))
    static let lightPalette = (a: Color(nsColor: TX.Palette.ink),
                               fragment: Color(nsColor: TX.Palette.purple600).opacity(0.55),
                               continuous: Color(nsColor: TX.Palette.purple600))
}

// MARK: - AppKit rendering (menu bar, icons)

enum CruceRenderer {
    enum MenuBarState: Equatable {
        case idle
        case queueActive
        case meeting
    }

    /// 18 × 18 pt template image: 16 pt symbol, 2 pt stroke, reduced version (spec 2.4).
    static func menuBarImage(state: MenuBarState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let symbolRect = CGRect(x: 1, y: 1, width: 16, height: 16)
            (state == .meeting ? NSColor.labelColor : NSColor.black).setStroke()
            let width: CGFloat = 2
            func line(_ a: CGPoint, _ b: CGPoint) {
                let p = NSBezierPath()
                p.lineWidth = width
                p.lineCapStyle = .round
                p.move(to: CruceGeometry.scaled(a, in: symbolRect))
                p.line(to: CruceGeometry.scaled(b, in: symbolRect))
                p.stroke()
            }
            line(CruceGeometry.aStart, CruceGeometry.aEnd)
            line(CruceGeometry.fragStart, CruceGeometry.fragEnd)
            if state == .queueActive {
                for f in CruceGeometry.queueFragments { line(f.0, f.1) }
            } else {
                line(CruceGeometry.bStart, CruceGeometry.bEnd)
            }
            if state == .meeting {
                // The only colour exception: 5 pt orange dot, top right.
                NSColor(txHex: 0xFF8A3D).setFill()
                NSBezierPath(ovalIn: CGRect(x: 13, y: 0, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = state != .meeting
        return image
    }
}
