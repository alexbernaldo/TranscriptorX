import SwiftUI
import AppKit

// MARK: - Transcriptor X design tokens
//
// Single source for colour, type, spacing, radii, borders, sizes and motion.
// Values come from the design specification (sections 3.1–3.3 and 9.5).
// Dark is the reference appearance; light is its translation.

enum TX {}

// MARK: Colour

extension NSColor {
    /// Dynamic colour resolved against the effective appearance.
    /// `contrast` variants are used when Increase Contrast is on (spec 10.3).
    static func tx(dark: NSColor, light: NSColor,
                   darkContrast: NSColor? = nil, lightContrast: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua,
                                               .accessibilityHighContrastDarkAqua,
                                               .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua: return darkContrast ?? dark
            case .accessibilityHighContrastAqua: return lightContrast ?? light
            case .darkAqua: return dark
            default: return light
            }
        }
    }

    convenience init(txHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension TX {
    enum Palette {
        // Raw values (only used to build semantic tokens and the brand mark).
        static let purpleX = NSColor(txHex: 0x7C5CFF)
        static let purple300 = NSColor(txHex: 0xB9A9FF)
        static let purple400 = NSColor(txHex: 0x9A82FF)
        static let purple600 = NSColor(txHex: 0x6847EF)
        static let purple600Hover = NSColor(txHex: 0x7452F7)
        static let purple700 = NSColor(txHex: 0x5A3AD6)
        static let ink = NSColor(txHex: 0x1A1820)
        static let paper = NSColor(txHex: 0xEDEBF2)
        static let window = NSColor(txHex: 0x141319)
        static let sidebarSolid = NSColor(txHex: 0x100F14)
        static let surface = NSColor(txHex: 0x1B1A22)
        static let hud = NSColor(txHex: 0x0E0D12)
        static let meeting = NSColor(txHex: 0xFF8A3D)
        static let meetingInk = NSColor(txHex: 0x1A1208)
    }

    enum Colors {
        private static func c(_ dark: UInt32, _ light: UInt32) -> Color {
            Color(nsColor: .tx(dark: NSColor(txHex: dark), light: NSColor(txHex: light)))
        }

        // Surfaces and lines
        static let bgWindow = c(0x141319, 0xFFFFFF)
        static let bgSidebarTint = Color(nsColor: .tx(dark: NSColor(txHex: 0x100F14, alpha: 0.88),
                                                       light: NSColor(txHex: 0xF1EFF5, alpha: 0.92)))
        static let bgSidebarSolid = c(0x100F14, 0xF1EFF5)
        static let bgSurface = c(0x1B1A22, 0xF7F6FA)
        static let bgElevated = c(0x23212C, 0xFFFFFF)
        static let bgControl = c(0x2C2A37, 0xE9E7F0)
        static let bgControlHover = c(0x34313F, 0xE1DEEA)
        static let bgHover = Color(nsColor: .tx(dark: NSColor(white: 1, alpha: 0.05),
                                                light: NSColor(white: 0, alpha: 0.04)))
        static let bgPressed = Color(nsColor: .tx(dark: NSColor(white: 1, alpha: 0.09),
                                                  light: NSColor(white: 0, alpha: 0.08)))
        static let separator = c(0x2A2833, 0xE2E0E8)
        static let border = Color(nsColor: .tx(dark: NSColor(txHex: 0x34313F), light: NSColor(txHex: 0xD6D3DF),
                                               darkContrast: NSColor(txHex: 0x4A4658),
                                               lightContrast: NSColor(txHex: 0xB9B5C6)))
        static let borderStrong = c(0x4A4658, 0xB9B5C6)

        // Text
        static let textPrimary = c(0xEDEBF2, 0x1A1820)
        static let textSecondary = c(0xA9A5B5, 0x5C5868)
        /// Only on bgWindow or the sidebar (contrast rule in spec 3.1).
        static let textTertiary = Color(nsColor: .tx(dark: NSColor(txHex: 0x848094), light: NSColor(txHex: 0x6E6A7B),
                                                     darkContrast: NSColor(txHex: 0xA9A5B5),
                                                     lightContrast: NSColor(txHex: 0x5C5868)))
        static let textDisabled = c(0x5A5766, 0xA8A4B4)
        static let textOnAccent = Color.white

        // Purple: state, never decoration
        static let purpleX = Color(nsColor: Palette.purpleX)
        static let purple300 = Color(nsColor: Palette.purple300)
        /// Purple text and links: purple.400 on dark, purple.600 on light (spec 3.5).
        static let accentText = Color(nsColor: .tx(dark: Palette.purple400, light: Palette.purple600))
        static let purple600 = Color(nsColor: Palette.purple600)
        static let purple600Hover = Color(nsColor: Palette.purple600Hover)
        static let purple700 = Color(nsColor: Palette.purple700)
        static let selectionRow = Color(nsColor: .tx(dark: Palette.purpleX.withAlphaComponent(0.22),
                                                     light: Palette.purpleX.withAlphaComponent(0.16),
                                                     darkContrast: Palette.purpleX.withAlphaComponent(0.32),
                                                     lightContrast: Palette.purpleX.withAlphaComponent(0.28)))
        static let selectionRowInactive = Color(nsColor: .tx(dark: NSColor(white: 1, alpha: 0.08),
                                                             light: NSColor(white: 0, alpha: 0.06)))
        static let selectionText = Color(nsColor: Palette.purpleX.withAlphaComponent(0.40))
        static let wordActive = Color(nsColor: .tx(dark: Palette.purpleX.withAlphaComponent(0.34),
                                                   light: Palette.purpleX.withAlphaComponent(0.20)))

        // Semantic
        static let success = c(0x3FCF8E, 0x12875A)
        static let warning = c(0xF2B441, 0x9A6400)
        static let error = c(0xFF5D6C, 0xC62F3E)
        static let info = c(0x5AB0FF, 0x1F6FC4)
        static let record = c(0xFF4D5E, 0xD92B3D)
        static let meeting = c(0xFF8A3D, 0xC25A12)
        static let searchMatch = c(0xF2B441, 0x9A6400)
    }
}

extension TX {
    /// AppKit versions of the tokens used by AppKit-drawn views (dynamic per appearance).
    enum NSColors {
        static let textPrimary = NSColor.tx(dark: NSColor(txHex: 0xEDEBF2), light: NSColor(txHex: 0x1A1820))
        static let textSecondary = NSColor.tx(dark: NSColor(txHex: 0xA9A5B5), light: NSColor(txHex: 0x5C5868))
        static let accentText = NSColor.tx(dark: Palette.purple400, light: Palette.purple600)
        static let wordActive = NSColor.tx(dark: Palette.purpleX.withAlphaComponent(0.34), light: Palette.purpleX.withAlphaComponent(0.20))
        static let searchMatch = NSColor.tx(dark: NSColor(txHex: 0xF2B441), light: NSColor(txHex: 0x9A6400))
        static let selectionText = Palette.purpleX.withAlphaComponent(0.40)
    }
}

// MARK: Speakers (colour + shape + name, never colour alone)

enum SpeakerShapeKind: CaseIterable {
    case circle, square, triangle, diamond, hexagon, invertedTriangle
}

extension TX {
    enum Speakers {
        /// Dark values from spec 3.1; on light surfaces the hue is darkened so name labels keep
        /// ≥ 4.5:1 (same rule the spec applies to semantic colours in 3.5).
        static let colors: [Color] = [
            (0x9A82FF, 0x6847EF), (0x4FC3D9, 0x0E7287), (0xF2B441, 0x8A5A00),
            (0xFF7AA8, 0xB8235A), (0x7BD88F, 0x1D7A37), (0xD9A87C, 0x81552C)
        ].map { pair in Color(nsColor: .tx(dark: NSColor(txHex: UInt32(pair.0)), light: NSColor(txHex: UInt32(pair.1)))) }
        static func color(_ index: Int) -> Color { colors[((index % 6) + 6) % 6] }
        static func shape(_ index: Int) -> SpeakerShapeKind { SpeakerShapeKind.allCases[((index % 6) + 6) % 6] }
        /// From the seventh speaker on, the palette repeats and the number is shown ("H7").
        static func needsNumber(_ index: Int) -> Bool { index >= 6 }
    }
}

// MARK: Typography

extension TX {
    struct TextStyle {
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: Font.Weight
        var design: Font.Design = .default
        var tracking: CGFloat = 0
        var tabular = false

        var font: Font {
            let f = Font.system(size: size, weight: weight, design: design)
            return tabular ? f.monospacedDigit() : f
        }
        /// SwiftUI adds `lineSpacing` on top of the font's natural line height.
        var lineSpacing: CGFloat {
            let f = NSFont.systemFont(ofSize: size)
            let natural = ceil(f.ascender - f.descender + f.leading)
            return max(0, lineHeight - natural)
        }
    }

    enum Typography {
        static let display = TextStyle(size: 26, lineHeight: 32, weight: .semibold)
        static let documentTitle = TextStyle(size: 20, lineHeight: 26, weight: .semibold)
        static let sectionTitle = TextStyle(size: 15, lineHeight: 20, weight: .semibold)
        static let transcript = TextStyle(size: 15, lineHeight: 24, weight: .regular)
        static let speaker = TextStyle(size: 12, lineHeight: 16, weight: .semibold, tracking: 0.4)
        static let ui = TextStyle(size: 13, lineHeight: 18, weight: .regular)
        static let uiMedium = TextStyle(size: 13, lineHeight: 18, weight: .medium)
        static let uiSemibold = TextStyle(size: 13, lineHeight: 18, weight: .semibold)
        static let secondary = TextStyle(size: 12, lineHeight: 16, weight: .regular)
        static let meta = TextStyle(size: 11, lineHeight: 14, weight: .medium, tracking: 0.2, tabular: true)
        static let timestamp = TextStyle(size: 11, lineHeight: 14, weight: .medium, design: .monospaced, tabular: true)
        static let technical = TextStyle(size: 12, lineHeight: 16, weight: .regular, design: .monospaced)
        static let caption = TextStyle(size: 22, lineHeight: 28, weight: .semibold)
    }

    /// Transcript size setting (Ajustes › Comportamiento, spec 3.2).
    enum TranscriptSize: String, CaseIterable, Identifiable {
        case small, normal, large, extraLarge
        var id: String { rawValue }
        var style: TextStyle {
            switch self {
            case .small: return TextStyle(size: 13, lineHeight: 21, weight: .regular)
            case .normal: return Typography.transcript
            case .large: return TextStyle(size: 17, lineHeight: 27, weight: .regular)
            case .extraLarge: return TextStyle(size: 20, lineHeight: 31, weight: .regular)
            }
        }
    }
}

extension View {
    func txStyle(_ style: TX.TextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

// MARK: Geometry

extension TX {
    enum Space {
        static let s2: CGFloat = 2, s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12
        static let s16: CGFloat = 16, s20: CGFloat = 20, s24: CGFloat = 24, s32: CGFloat = 32
        static let s40: CGFloat = 40, s48: CGFloat = 48
    }

    enum Radius {
        static let tag: CGFloat = 4
        static let control: CGFloat = 6
        static let row: CGFloat = 8
        static let popover: CGFloat = 10
        static let dropZone: CGFloat = 12
        static let panel: CGFloat = 14
        static let caption: CGFloat = 18
    }

    enum Size {
        static let controlSmall: CGFloat = 22
        static let control: CGFloat = 28
        static let controlLarge: CGFloat = 36
        static let iconRow: CGFloat = 13
        static let iconToolbar: CGFloat = 15
        static let iconSidebar: CGFloat = 16
        static let iconEmpty: CGFloat = 40
        static let minHit: CGFloat = 28
        static let historyRow: CGFloat = 52
        static let historyRowSearch: CGFloat = 72
        static let queueRow: CGFloat = 56
        static let settingsRow: CGFloat = 36
        static let readingColumn: CGFloat = 680
        static let timestampGutter: CGFloat = 88
        static let toolbar: CGFloat = 52
        static let playerBar: CGFloat = 56
        static let playerBarCompact: CGFloat = 44
        static let sidebar: CGFloat = 260
        static let sidebarMin: CGFloat = 220
        static let sidebarMax: CGFloat = 360
        static let inspector: CGFloat = 300
        static let inspectorMin: CGFloat = 280
        static let inspectorMax: CGFloat = 400
        static let workspaceMin: CGFloat = 480
        static let inspectorCollapseWidth: CGFloat = 1040
    }

    enum Window {
        static let initial = CGSize(width: 1280, height: 820)
        static let minimum = CGSize(width: 720, height: 520)
        static let compactHeight: CGFloat = 600
    }
}

// MARK: Motion (spec 9.5)

extension TX {
    enum Motion {
        /// cubic-bezier(0.2, 0.8, 0.2, 1): entrances and the inspector.
        static func enter(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
        /// cubic-bezier(0.4, 0, 0.2, 1): elements travelling to another place.
        static func travel(_ duration: Double) -> Animation { .timingCurve(0.4, 0, 0.2, 1, duration: duration) }
        /// cubic-bezier(0.3, 0, 0.1, 1): strokes being drawn.
        static func draw(_ duration: Double) -> Animation { .timingCurve(0.3, 0, 0.1, 1, duration: duration) }
        /// cubic-bezier(0.4, 0, 1, 1): exits.
        static func exit(_ duration: Double) -> Animation { .timingCurve(0.4, 0, 1, 1, duration: duration) }
        static let hover = Animation.linear(duration: 0.08)
        static let release = Animation.easeOut(duration: 0.12)
        static let fade = Animation.easeOut(duration: 0.12)
        static let inspector = enter(0.24)
        static let liveSegment = Animation.easeOut(duration: 0.18)
        static let wordActive = Animation.linear(duration: 0.08)
        static let followPlayback = Animation.easeInOut(duration: 0.24)
        /// Option tiles switching on or off.
        static let tileToggle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
        static let banner = Animation.easeOut(duration: 0.22)
        static let bannerClose = Animation.easeOut(duration: 0.16)
        static let toast = Animation.easeOut(duration: 0.2)
        static let jobCompleted = Animation.easeInOut(duration: 0.24)
        static let chipsToQueue = travel(0.28)

        /// Returns `animation` unless Reduce Motion asks for `reduced` (default: none).
        static func respecting(_ reduceMotion: Bool, _ animation: Animation, reduced: Animation? = nil) -> Animation? {
            reduceMotion ? reduced : animation
        }
    }
}

// MARK: Shadow (only popovers and floating panels)

extension View {
    func txFloatingShadow(cornerRadius: CGFloat) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 8)
    }
}
