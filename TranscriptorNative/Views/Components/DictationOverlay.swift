import SwiftUI

/// #13 — Dictation capsule (spec 6.23), with Handy's motion in Transcriptor X's colours.
///
/// One pill, one row at a time: a dot that pulses once the microphone is live, nine bars
/// that follow the voice and a ✕ to cancel; while whisper works, a spinner and the label,
/// and the pill widens. Permission problems keep the wider pill with their action.
struct DictationOverlay: View {
    @ObservedObject private var dictation = DictationManager.shared
    @ObservedObject private var recorder = SystemAudioRecorder.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false

    /// Pill widths (Handy: 172 resting, 216 working); messages size to their text.
    static let restWidth: CGFloat = 172
    static let workWidth: CGFloat = 216
    static let height: CGFloat = 40

    /// Expo ease-out Handy uses for the pop and the width morph.
    private var morph: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.46)
    }

    var body: some View {
        row
            .frame(height: Self.height)
            .frame(width: width)
            .background(
                Capsule().fill(Color(nsColor: reduceTransparency ? TX.Palette.surface : TX.Palette.hud.withAlphaComponent(0.96)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(Capsule())
            .animation(morph, value: width)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.92, anchor: DictationPreferences.overlay == .top ? .top : .bottom)
            .opacity(appeared ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: DictationPreferences.overlay == .top ? .top : .bottom)
            .environment(\.colorScheme, .dark)
            .onAppear { withAnimation(morph ?? .easeOut(duration: 0.2)) { appeared = true } }
            .accessibilityHidden(true)
    }

    private var width: CGFloat? {
        switch dictation.phase {
        case .idle, .arming, .listening: return Self.restWidth
        case .transcribing, .pasted, .cancelled: return Self.workWidth
        case .noAccessibility, .noMicrophone, .unavailable: return nil
        }
    }

    // MARK: Rows — dot | bars | ✕   ·   spinner | label | ✕

    @ViewBuilder private var row: some View {
        switch dictation.phase {
        case .idle, .arming, .listening:
            threeZones(left: { PulseDot(live: dictation.phase == .listening) },
                       centre: { VoiceBars(level: recorder.audioLevel, live: dictation.phase == .listening) },
                       right: { CancelButton() })
        case .transcribing:
            let modelId = DictationPreferences.transcriptionSettings().selectedModelId
            let modelName = ModelCatalog.descriptor(id: modelId)?.displayName ?? modelId
            threeZones(
                left: { Spinner() },
                centre: {
                    VStack(spacing: 1) {
                        Text(TXL.t("dictation.transcribing", "Transcribiendo…"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: NSColor(txHex: 0xA9A5B5)))
                            .lineLimit(1)
                        Text(modelName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: NSColor(txHex: 0x8E8A9E)))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                },
                right: { CancelButton() }
            )
        case .pasted:
            threeZones(left: { symbol("checkmark", NSColor(txHex: 0x3FCF8E)) }, centre: { label(dictation.statusText) },
                       right: { Color.clear.frame(width: 22) })
        case .cancelled:
            threeZones(left: { symbol("xmark", NSColor(txHex: 0xA9A5B5)) }, centre: { label(TXL.t("dictation.cancelled", "Cancelado")) },
                       right: { Color.clear.frame(width: 22) })
        case .noAccessibility, .noMicrophone, .unavailable:
            message
        }
    }

    /// Equal side columns keep the centre item centred, as Handy's grid does.
    private func threeZones<L: View, C: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder centre: () -> C,
                                                       @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 0) {
            left().frame(minWidth: 22, maxWidth: .infinity, alignment: .leading).padding(.leading, 5)
            centre().layoutPriority(1)
            right().frame(minWidth: 22, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(nsColor: NSColor(txHex: 0xA9A5B5)))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
    }

    private func symbol(_ name: String, _ color: NSColor) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(nsColor: color))
    }

    // MARK: Messages (permissions, errors)

    private var message: some View {
        HStack(spacing: 10) {
            switch dictation.phase {
            case .noAccessibility: symbol("exclamationmark.triangle.fill", NSColor(txHex: 0xF2B441))
            default: symbol("xmark.octagon.fill", NSColor(txHex: 0xFF5D6C))
            }
            Text(messageText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: TX.Palette.paper))
                .lineLimit(1)
            if needsAction {
                Button(TXL.t("dictation.configure", "Configurar")) { configure() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: TX.Palette.purple400))
            }
        }
        .padding(.horizontal, 16)
        .fixedSize()
    }

    private var messageText: String {
        switch dictation.phase {
        case .noAccessibility: return TXL.t("dictation.noAccessibility", "Necesito permiso para pegar")
        case .noMicrophone: return TXL.t("dictation.noMicrophone", "Sin permiso de micrófono")
        case .unavailable(let text): return text
        default: return ""
        }
    }

    private var needsAction: Bool {
        dictation.phase == .noAccessibility || dictation.phase == .noMicrophone
    }

    private func configure() {
        DictationOverlayController.shared.hide()
        if dictation.phase == .noAccessibility {
            WindowCoordinator.showMainWindow()
            WorkspaceState.shared.sheet = .accessibilityPermission
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Pieces

/// Purple dot with a ring that grows and fades every 1.9 s once audio flows; a quiet grey
/// dot while the microphone is opening.
private struct PulseDot: View {
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !live || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.9) / 1.9
            // Handy: box-shadow 0 → 7 px over the first 70 % of the cycle, fading out.
            let progress = min(t / 0.7, 1)
            ZStack {
                if live && !reduceMotion {
                    Circle()
                        .fill(TX.Colors.purpleX.opacity(0.32 * (1 - progress)))
                        .frame(width: 7 + 14 * progress, height: 7 + 14 * progress)
                }
                Circle()
                    .fill(live ? TX.Colors.purpleX : Color(nsColor: NSColor(txHex: 0xA9A5B5)).opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 22, height: 22)
        }
        .animation(.easeOut(duration: 0.18), value: live)
    }
}

/// Nine bars, 4 pt wide with 3 pt gaps, 3–18 pt tall. The level is smoothed like Handy's
/// (0.7 previous + 0.3 new) and spread over a centre-weighted profile so the bars move
/// as one voice. While the microphone opens, a muted pulse travels across them.
private struct VoiceBars: View {
    let level: Float
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoothed: [Double] = Array(repeating: 0, count: 9)

    private static let profile: [Double] = [0.42, 0.62, 0.8, 0.94, 1, 0.94, 0.8, 0.62, 0.42]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(live ? TX.Colors.purpleX : Color(nsColor: NSColor(txHex: 0xA9A5B5)).opacity(0.5))
                        .frame(width: 4, height: live ? height(for: smoothed[i]) : armingHeight(i, time))
                }
            }
            .frame(height: 18)
            .padding(.trailing, 8)
        }
        .txOnChange(of: level) { newValue in
            let target = Double(newValue)
            for i in smoothed.indices {
                // A little per-bar variation keeps the bars from moving as a block.
                let wobble = 0.85 + 0.15 * sin(Double(i) * 1.7 + Date().timeIntervalSinceReferenceDate * 9)
                smoothed[i] = smoothed[i] * 0.7 + target * Self.profile[i] * wobble * 0.3
            }
        }
        .animation(.linear(duration: 0.08), value: smoothed)
    }

    private func height(for value: Double) -> CGFloat {
        CGFloat(max(3, min(18, 3 + pow(min(value * 1.6, 1), 0.7) * 15)))
    }

    /// 900 ms pulse from the centre outwards (Handy's `swave-arming`).
    private func armingHeight(_ i: Int, _ time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 6 }
        let delay = Double(abs(i - 4)) * 0.075
        let phase = ((time - delay).truncatingRemainder(dividingBy: 0.9)) / 0.9
        return CGFloat(6 * (0.55 + 0.95 * (0.5 - 0.5 * cos(phase * 2 * .pi))))
    }
}

/// Ring with a purple head turning every 0.7 s.
private struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7 * 360
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(TX.Colors.purpleX, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 13, height: 13)
        }
    }
}

/// 22 pt circle ✕: hairline fill, purple tint and 1.05 on hover, 0.95 when pressed.
private struct CancelButton: View {
    @State private var hovering = false

    var body: some View {
        Button { DictationManager.shared.cancel() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(hovering ? Color(nsColor: TX.Palette.paper) : Color(nsColor: NSColor(txHex: 0xA9A5B5)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? TX.Colors.purpleX.opacity(0.22) : Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(CancelPressStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(TXL.t("dictation.cancel.help", "Cancelar (Esc)"))
    }
}

private struct CancelPressStyle: ButtonStyle {
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.05 : 1))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
