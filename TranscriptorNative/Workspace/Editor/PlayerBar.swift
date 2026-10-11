import SwiftUI

/// Pie de reproductor (spec 7.2): 56 pt (44 pt in short windows) on bg.surface with a top separator.
struct PlayerBar: View {
    @ObservedObject var editor: DocumentEditor
    @ObservedObject private var playback = PlaybackController.shared
    @Environment(\.isCompactHeight) private var compact
    @Environment(\.workAreaWidth) private var width

    private var available: Bool { playback.hasMedia }

    var body: some View {
        VStack(spacing: 0) {
            TXSeparator()
            HStack(spacing: 12) {
                Button { togglePlay() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(available ? TX.Colors.purple600 : TX.Colors.purple600.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .help(playback.isPlaying ? TXL.t("player.pause.help", "Pausar (Espacio)") : TXL.t("player.play.help", "Reproducir (Espacio)"))
                .accessibilityLabel(playback.isPlaying ? TXL.t("player.pause", "Pausar") : TXL.t("player.play", "Reproducir"))

                Button { playback.skip(-5) } label: { Image(systemName: "gobackward.5") }
                    .buttonStyle(TXIconButtonStyle())
                    .disabled(!available)
                    .help(TXL.t("player.back.help", "Retroceder 5 s (←)"))
                    .accessibilityLabel(TXL.t("player.back", "Retroceder 5 segundos"))
                Button { playback.skip(5) } label: { Image(systemName: "goforward.5") }
                    .buttonStyle(TXIconButtonStyle())
                    .disabled(!available)
                    .help(TXL.t("player.forward.help", "Avanzar 5 s (→)"))
                    .accessibilityLabel(TXL.t("player.forward", "Avanzar 5 segundos"))

                if available {
                    Text(TXFormat.timestamp(playback.currentTime, documentDuration: playback.duration))
                        .font(.system(size: 13, design: .monospaced).monospacedDigit())
                        .foregroundStyle(TX.Colors.textPrimary)
                        .accessibilityHidden(true)
                    PositionSlider(current: playback.currentTime, duration: playback.duration) { playback.seek(to: $0) }
                    Text(TXFormat.timestamp(playback.duration, documentDuration: playback.duration))
                        .font(.system(size: 13, design: .monospaced).monospacedDigit())
                        .foregroundStyle(TX.Colors.textSecondary)
                        .accessibilityHidden(true)
                    Menu {
                        ForEach(PlaybackController.rates, id: \.self) { rate in
                            Button { playback.setRate(rate) } label: {
                                if rate == playback.rate { Label(rateLabel(rate), systemImage: "checkmark") } else { Text(rateLabel(rate)) }
                            }
                        }
                    } label: {
                        Text(rateLabel(playback.rate)).font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(TXL.t("player.speed", "Velocidad de reproducción"))
                    .accessibilityLabel(TXL.f("player.speed.a11y", "Velocidad, %@", rateLabel(playback.rate)))
                    if width > 1100 || editor.visible.count > 500, let position = currentSegmentPosition {
                        Text(TXL.f("player.segmentPosition", "Seg. %@ de %@", TXFormat.integer(position), TXFormat.integer(editor.visible.count)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(TX.Colors.textSecondary)
                    }
                } else {
                    Text(TXL.t("player.unavailable", "El audio original no está disponible"))
                        .font(.system(size: 12))
                        .foregroundStyle(TX.Colors.textSecondary)
                        .help(playback.missingMediaPath ?? editor.document.sourceURL?.path ?? "")
                    Spacer()
                }
            }
            .padding(.horizontal, TX.Space.s16)
            .frame(height: compact ? TX.Size.playerBarCompact : TX.Size.playerBar)
            .background(TX.Colors.bgSurface)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TXL.t("region.player", "Reproductor"))
    }

    private var currentSegmentPosition: Int? {
        guard let id = editor.playingSegmentId ?? editor.primarySelection, let i = editor.index(of: id) else { return nil }
        return i + 1
    }

    private func rateLabel(_ rate: Float) -> String {
        let f = NumberFormatter()
        f.locale = TXL.locale
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: rate)) ?? "\(rate)") + "×"
    }

    private func togglePlay() {
        playback.togglePlayPause()
        // The play button reactivates following (spec 7.7).
        if playback.isPlaying { editor.resumeFollowing() }
    }
}

/// Simple position track (not a waveform): 4 pt track, purple.X played part, 12 pt knob growing to 16 on hover.
struct PositionSlider: View {
    let current: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var hovering = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = dragValue ?? (duration > 0 ? min(max(current / duration, 0), 1) : 0)
            let knob: CGFloat = hovering || dragValue != nil ? 16 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(TX.Colors.bgControl).frame(height: 4)
                Capsule().fill(TX.Colors.purpleX).frame(width: max(4, geo.size.width * fraction), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .offset(x: geo.size.width * fraction - knob / 2)
                    .animation(.easeOut(duration: 0.12), value: knob)
            }
            .frame(height: TX.Size.minHit)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragValue = min(max(g.location.x / max(geo.size.width, 1), 0), 1) }
                .onEnded { g in
                    let v = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                    onSeek(v * duration)
                    dragValue = nil
                })
        }
        .frame(height: TX.Size.minHit)
        .frame(minWidth: 80)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel(TXL.t("player.position", "Posición"))
        .accessibilityValue(TXL.f("player.position.value", "%@ de %@", TXFormat.spokenDuration(current), TXFormat.spokenDuration(duration)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, current + 5))
            case .decrement: onSeek(max(0, current - 5))
            @unknown default: break
            }
        }
    }
}

// MARK: - Find and replace (40 / 76 pt, spec 7.9)

struct FindBar: View {
    @ObservedObject var editor: DocumentEditor
    @FocusState private var focus: Field?
    enum Field { case find, replace }

    var body: some View {
        let state = editor.find ?? .init()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(TX.Colors.textTertiary)
                        .accessibilityHidden(true)
                    TextField(TXL.t("find.placeholder", "Buscar"), text: binding(\.query))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .find)
                        .onSubmit { editor.stepMatch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                        .onExitCommand { editor.closeFind() }
                        .accessibilityLabel(TXL.t("find.a11y", "Buscar en el documento"))
                }
                .txField()
                .frame(maxWidth: 280)
                Text(counter)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(TX.Colors.textSecondary)
                    .frame(minWidth: 60, alignment: .leading)
                Button { editor.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(TXIconButtonStyle(iconSize: 12))
                    .disabled(editor.matches.isEmpty)
                    .help(TXL.t("find.previous", "Anterior ⇧⌘G"))
                    .accessibilityLabel(TXL.t("find.previous.a11y", "Coincidencia anterior"))
                Button { editor.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(TXIconButtonStyle(iconSize: 12))
                    .disabled(editor.matches.isEmpty)
                    .help(TXL.t("find.next", "Siguiente ⌘G"))
                    .accessibilityLabel(TXL.t("find.next.a11y", "Coincidencia siguiente"))
                Toggle(TXL.t("find.caseSensitive", "Mayúsculas"), isOn: binding(\.caseSensitive))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Toggle(TXL.t("find.wholeWord", "Palabra completa"), isOn: binding(\.wholeWord))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                if !state.showReplace {
                    Button(TXL.t("find.replace", "Reemplazar")) { editor.find?.showReplace = true; focus = .replace }
                        .buttonStyle(TXBorderlessButtonStyle())
                }
                Button { editor.closeFind() } label: { Image(systemName: "xmark") }
                    .buttonStyle(TXIconButtonStyle(iconSize: 11))
                    .help(TXL.t("find.close", "Cerrar (Esc)"))
                    .accessibilityLabel(TXL.t("find.close.a11y", "Cerrar búsqueda"))
            }
            if state.showReplace {
                HStack(spacing: 8) {
                    TextField(TXL.t("find.replace.placeholder", "Reemplazar con"), text: binding(\.replacement))
                        .txField()
                        .frame(maxWidth: 280)
                        .focused($focus, equals: .replace)
                        .onExitCommand { editor.closeFind() }
                    Button(TXL.t("find.replaceOne", "Reemplazar")) { editor.replaceCurrent() }
                        .buttonStyle(TXSecondaryButtonStyle())
                        .disabled(editor.currentMatch == nil)
                    Button(TXL.t("find.replaceAll", "Reemplazar todo")) { editor.replaceAll() }
                        .buttonStyle(TXSecondaryButtonStyle())
                        .disabled(editor.matches.isEmpty)
                }
            }
        }
        .padding(.horizontal, TX.Space.s16)
        .padding(.vertical, 6)
        .frame(height: state.showReplace ? 76 : 40)
        .background(TX.Colors.bgSurface)
        .onAppear { focus = state.showReplace && !state.query.isEmpty ? .replace : .find }
        .txOnChange(of: editor.find?.showReplace ?? false) { show in if show { focus = .replace } }
    }

    private var counter: String {
        guard let f = editor.find, !f.query.isEmpty else { return "" }
        if editor.matches.isEmpty { return TXL.t("find.none", "Sin resultados") }
        return TXL.f("find.counter", "%d de %d", f.current + 1, editor.matches.count)
    }

    private func binding<T>(_ key: WritableKeyPath<DocumentEditor.FindState, T>) -> Binding<T> {
        Binding(get: { (editor.find ?? .init())[keyPath: key] },
                set: { if editor.find != nil { editor.find![keyPath: key] = $0 } })
    }
}
