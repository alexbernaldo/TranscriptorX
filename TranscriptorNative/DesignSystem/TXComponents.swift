import SwiftUI
import AppKit

// MARK: - Button families (spec 3.4)
//
// Shared states: hover = bg.hover or one step lighter; pressed = bg.pressed or purple.700;
// focus = system ring in the accent colour; disabled = text.disabled and 50 % fill, no hover.
// Pressed is immediate; release eases out in 120 ms (spec 9.5).

enum TXButtonSize {
    case small, regular, large
    var height: CGFloat {
        switch self {
        case .small: return TX.Size.controlSmall
        case .regular: return TX.Size.control
        case .large: return TX.Size.controlLarge
        }
    }
    var horizontalPadding: CGFloat { self == .large ? 18 : (self == .small ? 10 : 14) }
}

private struct HoverTracking<Content: View>: View {
    let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}

struct TXPrimaryButtonStyle: ButtonStyle {
    var size: TXButtonSize = .regular
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? TX.Colors.textOnAccent : TX.Colors.textOnAccent.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .fill(fill(pressed: configuration.isPressed, hovering: hovering))
                )
                .contentShape(Rectangle())
                .animation(configuration.isPressed ? nil : TX.Motion.release, value: configuration.isPressed)
                .animation(TX.Motion.hover, value: hovering)
        }
    }

    private func fill(pressed: Bool, hovering: Bool) -> Color {
        guard isEnabled else { return TX.Colors.purple600.opacity(0.5) }
        if pressed { return TX.Colors.purple700 }
        return hovering ? TX.Colors.purple600Hover : TX.Colors.purple600
    }
}

struct TXSecondaryButtonStyle: ButtonStyle {
    var size: TXButtonSize = .regular
    var destructive = false
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.height)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .fill(isEnabled ? (hovering ? TX.Colors.bgControlHover : TX.Colors.bgControl) : TX.Colors.bgControl.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .fill(configuration.isPressed && isEnabled ? TX.Colors.bgPressed : .clear)
                )
                .contentShape(Rectangle())
                .animation(configuration.isPressed ? nil : TX.Motion.release, value: configuration.isPressed)
                .animation(TX.Motion.hover, value: hovering)
        }
    }

    private var foreground: Color {
        guard isEnabled else { return TX.Colors.textDisabled }
        return destructive ? TX.Colors.error : TX.Colors.textPrimary
    }
}

/// Purple text, no fill until hover. Tertiary actions and links.
struct TXBorderlessButtonStyle: ButtonStyle {
    var tint: Color = TX.Colors.accentText
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? tint : TX.Colors.textDisabled)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: TX.Size.minHit)
                .background(
                    RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .fill(configuration.isPressed ? TX.Colors.bgPressed : (hovering && isEnabled ? TX.Colors.bgHover : .clear))
                )
                .contentShape(Rectangle())
                .animation(TX.Motion.hover, value: hovering)
        }
    }
}

/// 28 × 28 pt icon button. Callers must add `.help(...)` with the shortcut (mandatory tooltip).
struct TXIconButtonStyle: ButtonStyle {
    var iconSize: CGFloat = TX.Size.iconToolbar
    var isActive = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(foreground)
                .frame(width: TX.Size.minHit, height: TX.Size.minHit)
                .background(
                    RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                        .fill(configuration.isPressed ? TX.Colors.bgPressed : (hovering && isEnabled ? TX.Colors.bgHover : .clear))
                )
                .contentShape(Rectangle())
                .animation(TX.Motion.hover, value: hovering)
        }
    }

    private var foreground: Color {
        guard isEnabled else { return TX.Colors.textDisabled }
        if let tint { return tint }
        return isActive ? TX.Colors.accentText : TX.Colors.textSecondary
    }
}

/// Full-width row button (history, settings lists): responds on its whole width.
struct TXRowButtonStyle: ButtonStyle {
    var isSelected = false
    var listFocused = true

    func makeBody(configuration: Configuration) -> some View {
        HoverTracking { hovering in
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TX.Radius.row, style: .continuous)
                        .fill(background(pressed: configuration.isPressed, hovering: hovering))
                )
                .contentShape(Rectangle())
                .animation(TX.Motion.hover, value: hovering)
        }
    }

    private func background(pressed: Bool, hovering: Bool) -> Color {
        if isSelected { return listFocused ? TX.Colors.selectionRow : TX.Colors.selectionRowInactive }
        if pressed { return TX.Colors.bgPressed }
        return hovering ? TX.Colors.bgHover : .clear
    }
}

// MARK: - Status tag (18 pt, radius 4, 11 Medium, fill 14 %)

enum TXTagKind {
    case neutral, purple, info, success, warning, error

    var color: Color {
        switch self {
        case .neutral: return TX.Colors.textSecondary
        case .purple: return TX.Colors.purpleX
        case .info: return TX.Colors.info
        case .success: return TX.Colors.success
        case .warning: return TX.Colors.warning
        case .error: return TX.Colors.error
        }
    }
}

struct TXStatusTag: View {
    let text: String
    var kind: TXTagKind = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(kind == .neutral ? TX.Colors.textSecondary : TX.Colors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: TX.Radius.tag, style: .continuous)
                    .fill(kind.color.opacity(0.14))
            )
    }
}

/// Chip used for AI tags and settings summaries (radius 4, 11 Medium).
struct TXChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TX.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: TX.Radius.tag, style: .continuous).fill(TX.Colors.bgControl))
    }
}

// MARK: - Progress (spec 3.4 + 8.2 rule: never simulate a percentage)

enum TXProgressKind: Equatable {
    /// Process reports progress.
    case determinate(Double)
    /// Working without a measure.
    case indeterminate
    /// Waiting for its turn or a resource: static dashed track.
    case waiting
}

struct TXProgressLine: View {
    var kind: TXProgressKind
    var height: CGFloat = 3
    var tint: Color = TX.Colors.purpleX
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                switch kind {
                case .determinate(let value):
                    Capsule().fill(TX.Colors.bgControl)
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * CGFloat(min(max(value, 0), 1))))
                case .indeterminate:
                    Capsule().fill(TX.Colors.bgControl)
                    IndeterminateSweep(width: geo.size.width, height: height, tint: tint, animated: !reduceMotion)
                case .waiting:
                    DashedTrack(height: height)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct IndeterminateSweep: View {
    let width: CGFloat
    let height: CGFloat
    let tint: Color
    let animated: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        let segment = width * 0.3
        Capsule()
            .fill(tint)
            .frame(width: segment, height: height)
            .offset(x: animated ? -segment + phase * (width + segment) : (width - segment) / 2)
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Static dashed track: 6 pt fragments and 4 pt gaps.
struct DashedTrack: View {
    var height: CGFloat = 3
    var color: Color = TX.Colors.border
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: height, dash: [6, 4]))
        }
        .frame(height: height)
    }
}

// MARK: - Fragments indicator (waiting for next live segment, AI streaming)

/// Three 6 pt horizontal fragments that pulse in opacity (1.2 s cycle, 150 ms offset).
/// Static at 60 % with Reduce Motion.
struct WaitingFragments: View {
    var color: Color = TX.Colors.textTertiary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 6, height: 2)
                    .opacity(reduceMotion ? 0.6 : (animate ? 1 : 0.3))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                               value: animate)
            }
        }
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

/// Five vertical fragments that follow an audio level (0…1). Used by recording, panel and dictation.
struct LevelFragments: View {
    var level: Float
    var color: Color = TX.Colors.purpleX
    var height: CGFloat = 16
    /// When true the fragments align into a flat line (dictation "Transcribing").
    var aligned = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = Float(i) / 5
                let active = level > threshold
                Capsule()
                    .fill(color.opacity(aligned ? 1 : (active ? 1 : 0.3)))
                    .frame(width: aligned ? 6 : 3, height: aligned ? 3 : barHeight(i))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let shape: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
        let l = CGFloat(min(max(level, 0), 1))
        return max(3, height * shape[i] * (0.35 + 0.65 * l))
    }
}

// MARK: - Speaker mark (shape + colour)

struct SpeakerMark: View {
    let index: Int
    var size: CGFloat = 8

    var body: some View {
        SpeakerShape(kind: TX.Speakers.shape(index))
            .fill(TX.Speakers.color(index))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SpeakerShape: Shape {
    let kind: SpeakerShapeKind
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .circle:
            p.addEllipse(in: r)
        case .square:
            p.addRect(r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06))
        case .triangle:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .diamond:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .hexagon:
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                let pt = CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
        case .invertedTriangle:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Group header (11 Medium small caps)

struct TXGroupHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(TX.Colors.textTertiary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(TX.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Empty state (centred, one action)

struct TXEmptyState<Action: View>: View {
    var systemImage: String? = nil
    var showsMark = false
    let title: String
    var message: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 12) {
            if showsMark {
                CruceSymbol(style: .mono(TX.Colors.textTertiary)).frame(width: 40, height: 40)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(TX.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .txStyle(TX.Typography.sectionTitle)
                .foregroundStyle(TX.Colors.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .txStyle(TX.Typography.ui)
                    .foregroundStyle(TX.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

extension TXEmptyState where Action == EmptyView {
    init(systemImage: String? = nil, showsMark: Bool = false, title: String, message: String? = nil) {
        self.systemImage = systemImage
        self.showsMark = showsMark
        self.title = title
        self.message = message
        self.action = { EmptyView() }
    }
}

// MARK: - Text field (28 pt, bg.surface, 1 px border, radius 6)

struct TXFieldChrome: ViewModifier {
    var isError = false
    var height: CGFloat? = TX.Size.control
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous).fill(TX.Colors.bgSurface))
            .overlay(
                RoundedRectangle(cornerRadius: TX.Radius.control, style: .continuous)
                    .strokeBorder(isError ? TX.Colors.error : (hovering ? TX.Colors.borderStrong : TX.Colors.border), lineWidth: 1)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func txField(error: Bool = false, height: CGFloat? = TX.Size.control) -> some View {
        modifier(TXFieldChrome(isError: error, height: height))
    }
}

// MARK: - Separator

struct TXSeparator: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(TX.Colors.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
